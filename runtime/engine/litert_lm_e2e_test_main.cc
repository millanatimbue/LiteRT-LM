// Copyright 2026 The ODML Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// End-to-end stress harness for the Bouncer iOS classify+classifyText flow,
// runnable on Mac (CPU or Metal backend) without an iOS device or simulator.
//
// Mirrors what `LocalInferenceService` does on iOS:
//   • One engine, shared across both call types.
//   • A persistent "chat" base conversation built with
//     `prefillPrefaceOnInit=true` and no scopedLoraFile. Each chat
//     classification call clones the base and sends a short user message,
//     expecting yes/no verdicts (here we just check the output is non-empty
//     and isn't pure padding/dots).
//   • A "classifyText" call type that creates a fresh ConversationConfig
//     per call with `scopedLoraFile` + `maxOutputTokens=1`, runs the input,
//     and reads `classifier_logits`. Expects 4 finite floats.
//
// The harness then runs N iterations in two patterns:
//   (a) Interleaved: chat, classifyText, chat, classifyText, ... — the
//       exact pattern that caused iOS to leak LoRA state into chat sessions
//       and emit `.\n.\n.\n` or `<pad><pad>` instead of verdicts.
//   (b) Rapid-fire: a single LONG run of randomized chat/classifyText calls
//       to catch slow leaks or accumulation bugs.
//
// Each iteration validates:
//   • Chat output is non-empty AND not pure-padding (no "<pad>" tokens AND
//     not all-".").
//   • Classifier logits are all finite (no NaN/Inf) AND not all-zero (which
//     would mean LoRA isn't being applied to the classifier head's input).
//
// Returns nonzero exit if any iteration fails the validation.
//
// Usage:
//   litert_lm_e2e_test_main \
//     --model_path=/.../model.litertlm \
//     --lora_path=/.../lora_adapter.tflite \
//     --backend=cpu \
//     --iterations=20

#include <sys/resource.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <memory>
#include <random>
#include <string>
#include <utility>
#include <vector>

#include "absl/base/log_severity.h"  // from @com_google_absl
#include "absl/flags/flag.h"  // from @com_google_absl
#include "absl/flags/parse.h"  // from @com_google_absl
#include "absl/log/absl_check.h"  // from @com_google_absl
#include "absl/log/globals.h"  // from @com_google_absl
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/match.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "absl/time/time.h"  // from @com_google_absl
#include "nlohmann/json.hpp"  // from @nlohmann_json
#include "litert/cc/internal/scoped_file.h"  // from @litert
#include "runtime/conversation/conversation.h"
#include "runtime/conversation/io_types.h"
#include "runtime/engine/engine.h"
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/engine_settings.h"
#include "runtime/engine/io_types.h"
#include "runtime/executor/executor_settings_base.h"
#include "runtime/util/status_macros.h"

ABSL_FLAG(std::string, model_path, "", "Path to the .litertlm bundle.");
ABSL_FLAG(std::string, lora_path, "",
          "Path to the standalone LoRA adapter .tflite (required).");
ABSL_FLAG(std::string, backend, "cpu",
          "Backend: cpu or gpu (Metal on Mac).");
ABSL_FLAG(int, iterations, 20,
          "Number of interleaved chat/classifyText iterations to run.");
ABSL_FLAG(uint64_t, seed, 42,
          "RNG seed for the rapid-fire phase. Same seed → reproducible.");
ABSL_FLAG(bool, verbose, false,
          "Print full raw chat output and full classifier logits per call.");
ABSL_FLAG(std::string, mode, "interleave",
          "Test mode: 'interleave' (chat+classifier), 'classifier_only' "
          "(N classifier calls back-to-back, no chat base), "
          "'classifier_after_chat' (build chat base, then N classifier "
          "calls — no chat clones).");
ABSL_FLAG(bool, double_engine, false,
          "If true, build TWO engines pointing at the same model file and "
          "report RSS after each. Used to measure whether mmap'd file "
          "pages are physically shared between the two engines.");
ABSL_FLAG(std::string, decode_signature_name, "",
          "If non-empty, set the engine's decode signature name to this. Use "
          "with multi-variant .litertlm files that ship more than one decode "
          "signature (e.g. bouncer's decode_chat / decode_classifier).");
ABSL_FLAG(std::string, prefill_signature_filter, "",
          "If non-empty, only consider prefill signatures whose name "
          "contains this substring (e.g. \"_chat\" / \"_classifier\"). Pairs "
          "with --decode_signature_name for multi-variant models.");
ABSL_FLAG(std::string, classifier_decode_signature_name, "",
          "When set together with --double_engine, the SECOND engine is "
          "pinned to this decode signature and the classifier path is "
          "routed to it. Mirrors the iOS dual-engine architecture (chat "
          "on engine1, classifier on engine2). When empty, both engines "
          "share --decode_signature_name (legacy behavior).");
ABSL_FLAG(std::string, classifier_prefill_signature_filter, "",
          "Companion to --classifier_decode_signature_name for the second "
          "engine's prefill filter (e.g. \"_classifier\").");
ABSL_FLAG(std::string, classifier_backend, "",
          "Backend for the classifier engine (cpu or gpu). Empty = use the "
          "global --backend. Used to test Mac with CPU classifier (avoids "
          "WebGPU buffer-alignment errors that silently zero LoRA output).");
ABSL_FLAG(std::string, system_message,
          "You are a moderation classifier. For each post, output exactly "
          "one row of pipe-delimited verdicts (yes or no), one per "
          "category, in the order they were given. Output nothing else.\n\n"
          "Categories (in order): crypto-shilling, engagement-bait",
          "System message for the chat base conversation. Defaults to the "
          "same shape as Bouncer's filter prompt.");

namespace {

using ::litert::lm::Backend;
using ::litert::lm::Conversation;
using ::litert::lm::ConversationConfig;
using ::litert::lm::EngineSettings;
using ::litert::lm::Message;
using ::litert::lm::ModelAssets;
using ::litert::lm::SessionConfig;
using ::nlohmann::json;

// A handful of representative prompts. Mix of human-flavored and
// AI-flavored writing so we exercise both ends of the classifier.
constexpr const char* kPrompts[] = {
    "Post (includes images): I'm not sure why people like Opus 4.8's writing "
    "style though admittedly haven't tried it.\n\nOutput the verdict row:",
    "Post: Cape Canaveral residents waking up to one of the biggest manmade "
    "non-nuclear explosions in history.\n\nOutput the verdict row:",
    "Post: GM frens 🚀 The next 10x is coming. Don't fade this. NFA but you "
    "know what to do. #crypto\n\nOutput the verdict row:",
    "Post: This thread will change how you think about productivity. A "
    "must-read 🧵 RT for the algorithm 🙏\n\nOutput the verdict row:",
    "Post: Just shipped a small refactor that cleaned up the auth layer. "
    "Took longer than expected but worth it.\n\nOutput the verdict row:",
};
constexpr int kNumPrompts =
    sizeof(kPrompts) / sizeof(const char*);

// Report the process's resident set size. On macOS, ru_maxrss is reported
// in *bytes* (Linux returns kilobytes; that branch is unused here but kept
// correct for portability). RSS includes mmap'd file-backed pages that are
// currently resident; if two engines mmap the same file, the kernel
// reference-counts the underlying physical pages and the process's RSS only
// grows by per-engine writable state, NOT by another model's worth.
long ProcessRssBytes() {
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
#ifdef __APPLE__
  return usage.ru_maxrss;
#else
  return usage.ru_maxrss * 1024L;
#endif
}

void PrintRss(absl::string_view label) {
  long bytes = ProcessRssBytes();
  std::cout << "[RSS] " << label << ": " << (bytes / (1024.0 * 1024.0))
            << " MiB (max so far)\n"
            << std::flush;
}

// Returns true if `output` looks like a legitimate verdict-row response
// (not pure padding, not all dots-with-newlines). The padding mode we saw
// on iOS was repeated `<pad>` tokens or `.\n.\n.\n` strings — both are
// trivially distinguishable from any reasonable yes/no row.
bool ChatOutputLooksSane(absl::string_view output) {
  if (output.empty()) return false;
  // Reject mostly-padding outputs.
  if (absl::StrContains(output, "<pad>")) return false;
  // Count non-whitespace, non-dot characters. If 90%+ of the output is
  // dots/whitespace, that's the dotline failure mode.
  size_t total = 0;
  size_t meaningful = 0;
  for (char c : output) {
    ++total;
    if (c == '.' || c == '\n' || c == '\r' || c == '\t' || c == ' ')
      continue;
    ++meaningful;
  }
  if (total > 0 && meaningful * 10 < total) return false;
  return true;
}

// True if every float is finite and at least one is nonzero. All-zero
// classifier logits happen when LoRA isn't actually applied; NaN/Inf
// indicates corrupted runtime state.
bool LogitsLookSane(const std::vector<float>& logits) {
  if (logits.empty()) return false;
  bool any_nonzero = false;
  for (float v : logits) {
    if (!std::isfinite(v)) return false;
    if (v != 0.0f) any_nonzero = true;
  }
  return any_nonzero;
}

absl::StatusOr<std::unique_ptr<Conversation>> BuildChatBase(
    litert::lm::Engine& engine, absl::string_view system_message,
    absl::string_view lora_path) {
  auto session_config = SessionConfig::CreateDefault();
  // The bouncer model is a LoRA-finetune — chat decode produces only <pad>
  // tokens without the adapter bound. So we scope it onto the chat base too,
  // and Clone() inherits the binding.
  if (!lora_path.empty()) {
    ASSIGN_OR_RETURN(::litert::ScopedFile scoped_file,
                     ::litert::ScopedFile::Open(std::string(lora_path)));
    auto file_ptr =
        std::make_shared<::litert::ScopedFile>(std::move(scoped_file));
    session_config.SetScopedLoraFile(file_ptr);
  }
  ASSIGN_OR_RETURN(auto cc, ConversationConfig::Builder()
                                .SetSessionConfig(session_config)
                                .SetPreface(litert::lm::JsonPreface{
                                    .messages = json::array({json::object(
                                        {{"role", "system"},
                                         {"content", system_message}})})})
                                .SetPrefillPrefaceOnInit(true)
                                .Build(engine));
  return Conversation::Create(engine, cc);
}

absl::StatusOr<std::string> RunChatClone(Conversation& base,
                                         absl::string_view user_prompt) {
  ASSIGN_OR_RETURN(auto cloned, base.Clone());
  json content_list = json::array();
  content_list.push_back({{"type", "text"}, {"text", std::string(user_prompt)}});
  RETURN_IF_ERROR(cloned->SendMessageAsync(
      json::object({{"role", "user"}, {"content", content_list}}),
      [](absl::StatusOr<Message> /*m*/) {}));
  // SendMessageAsync routes through engine; use SendMessage instead for sync.
  // Engine API differs across forks — we use the simpler sync send below.
  return std::string("");
}

absl::StatusOr<std::string> RunChatSync(litert::lm::Engine& engine,
                                        Conversation& base,
                                        absl::string_view user_prompt) {
  ASSIGN_OR_RETURN(auto cloned, base.Clone());
  json content_list = json::array();
  content_list.push_back({{"type", "text"}, {"text", std::string(user_prompt)}});
  // Use the synchronous SendMessage so we can capture the full assistant
  // response. This is what iOS does (`response.toString` in Swift).
  ASSIGN_OR_RETURN(
      Message response,
      cloned->SendMessage(
          json::object({{"role", "user"}, {"content", content_list}})));
  // Belt-and-suspenders flush.
  RETURN_IF_ERROR(engine.WaitUntilDone(absl::Minutes(2)));

  // Extract concatenated text from the assistant content blocks.
  std::string text;
  if (response.contains("content")) {
    const auto& content = response["content"];
    if (content.is_string()) {
      text = content.get<std::string>();
    } else if (content.is_array()) {
      for (const auto& part : content) {
        if (part.is_object() && part.contains("text") &&
            part["text"].is_string()) {
          text += part["text"].get<std::string>();
        }
      }
    }
  }
  return text;
}

absl::StatusOr<std::vector<float>> RunClassifierOnce(
    litert::lm::Engine& engine, absl::string_view lora_path,
    absl::string_view prompt) {
  std::cout << "[e2e-dbg] RunClassifierOnce: opening lora file...\n"
            << std::flush;
  auto session_config = SessionConfig::CreateDefault();
  ASSIGN_OR_RETURN(::litert::ScopedFile scoped_file,
                   ::litert::ScopedFile::Open(std::string(lora_path)));
  auto file_ptr =
      std::make_shared<::litert::ScopedFile>(std::move(scoped_file));
  session_config.SetScopedLoraFile(file_ptr);
  session_config.SetMaxOutputTokens(1);
  std::cout << "[e2e-dbg] session_config.GetScopedLoraFile() != nullptr: "
            << (session_config.GetScopedLoraFile() != nullptr) << "\n"
            << std::flush;

  ASSIGN_OR_RETURN(auto cc, ConversationConfig::Builder()
                                .SetSessionConfig(session_config)
                                .SetSkipChatTemplate(true)
                                .Build(engine));
  std::cout << "[e2e-dbg] config built. cc.GetSessionConfig.GetScopedLoraFile: "
            << (cc.GetSessionConfig().GetScopedLoraFile() != nullptr)
            << " skip_chat_template=" << cc.skip_chat_template() << "\n"
            << std::flush;
  ASSIGN_OR_RETURN(auto convo, Conversation::Create(engine, cc));
  std::cout << "[e2e-dbg] Conversation::Create returned\n" << std::flush;

  json content_list = json::array();
  content_list.push_back({{"type", "text"}, {"text", std::string(prompt)}});
  RETURN_IF_ERROR(convo->SendMessageAsync(
      json::object({{"role", "user"}, {"content", content_list}}),
      [](absl::StatusOr<Message> /*m*/) {}));
  std::cout << "[e2e-dbg] SendMessageAsync dispatched\n" << std::flush;
  RETURN_IF_ERROR(engine.WaitUntilDone(absl::Minutes(2)));
  std::cout << "[e2e-dbg] WaitUntilDone returned\n" << std::flush;
  auto logits = convo->GetAuxiliaryOutput("classifier_logits");
  std::cout << "[e2e-dbg] GetAuxiliaryOutput returned ok="
            << logits.ok() << " size=" << (logits.ok() ? logits->size() : 0)
            << "\n" << std::flush;
  return logits;
}

absl::Status MainHelper(int argc, char** argv) {
  absl::ParseCommandLine(argc, argv);
  // Keep INFO logs visible so [LoRA-DBG] etc. surface; suppress only
  // DEBUG/VERBOSE noise.
  absl::SetMinLogLevel(absl::LogSeverityAtLeast::kInfo);
  absl::SetStderrThreshold(absl::LogSeverityAtLeast::kInfo);

  const std::string model_path = absl::GetFlag(FLAGS_model_path);
  const std::string lora_path = absl::GetFlag(FLAGS_lora_path);
  const std::string backend_str = absl::GetFlag(FLAGS_backend);
  const int iterations = absl::GetFlag(FLAGS_iterations);
  const uint64_t seed = absl::GetFlag(FLAGS_seed);
  const std::string system_message = absl::GetFlag(FLAGS_system_message);

  if (model_path.empty() || lora_path.empty()) {
    return absl::InvalidArgumentError(
        "--model_path and --lora_path are required.");
  }

  ASSIGN_OR_RETURN(Backend backend,
                   litert::lm::GetBackendFromString(backend_str));

  const std::string decode_sig = absl::GetFlag(FLAGS_decode_signature_name);
  const std::string prefill_filter =
      absl::GetFlag(FLAGS_prefill_signature_filter);
  const std::string classifier_decode_sig =
      absl::GetFlag(FLAGS_classifier_decode_signature_name);
  const std::string classifier_prefill_filter =
      absl::GetFlag(FLAGS_classifier_prefill_signature_filter);
  auto build_engine_with_sig = [&](absl::string_view ds, absl::string_view pf,
                                    Backend be)
      -> absl::StatusOr<std::unique_ptr<litert::lm::Engine>> {
    ASSIGN_OR_RETURN(ModelAssets assets, ModelAssets::Create(model_path));
    ASSIGN_OR_RETURN(EngineSettings s, EngineSettings::CreateDefault(
                                          std::move(assets), be));
    if (!ds.empty()) {
      s.GetMutableMainExecutorSettings().SetDecodeSignatureName(std::string(ds));
    }
    if (!pf.empty()) {
      s.GetMutableMainExecutorSettings().SetPrefillSignatureFilter(
          std::string(pf));
    }
    return litert::lm::EngineFactory::Create(
        litert::lm::EngineFactory::EngineType::kAdvancedLiteRTCompiledModel,
        std::move(s));
  };
  auto build_engine = [&]() {
    return build_engine_with_sig(decode_sig, prefill_filter, backend);
  };

  PrintRss("before engine 1");
  ASSIGN_OR_RETURN(auto engine, build_engine());
  PrintRss("after engine 1");

  // Second engine. When --classifier_decode_signature_name is set, this
  // engine is pinned to that signature and the classifier path routes
  // through it (mirroring the iOS dual-engine setup). Otherwise it shares
  // the same signature as engine1 (legacy behavior — was only used for
  // RSS measurement).
  std::unique_ptr<litert::lm::Engine> engine2;
  if (absl::GetFlag(FLAGS_double_engine)) {
    Backend cls_backend = backend;
    const std::string cls_backend_flag =
        absl::GetFlag(FLAGS_classifier_backend);
    if (!cls_backend_flag.empty()) {
      ASSIGN_OR_RETURN(cls_backend,
                       litert::lm::GetBackendFromString(cls_backend_flag));
    }
    if (!classifier_decode_sig.empty()) {
      ASSIGN_OR_RETURN(engine2,
          build_engine_with_sig(classifier_decode_sig,
                                classifier_prefill_filter, cls_backend));
      std::cout << "[e2e] engine2 pinned to decode_sig=\""
                << classifier_decode_sig << "\" prefill_filter=\""
                << classifier_prefill_filter << "\" backend="
                << cls_backend_flag << "\n";
    } else {
      ASSIGN_OR_RETURN(engine2, build_engine());
    }
    PrintRss("after engine 2");
  }
  // Pick the engine the classifier path will use: engine2 if it was pinned
  // to a classifier signature, otherwise fall back to engine1 (legacy).
  litert::lm::Engine* classifier_engine =
      (engine2 && !classifier_decode_sig.empty()) ? engine2.get() : engine.get();

  const std::string mode = absl::GetFlag(FLAGS_mode);
  std::cout << "[e2e] backend=" << backend_str << " iterations=" << iterations
            << " seed=" << seed << " mode=" << mode << "\n";

  std::unique_ptr<Conversation> chat_base;
  if (mode != "classifier_only") {
    // Pass empty lora_path to keep the chat base LoRA-free. The fix in
    // CreateDecodeBuffers/CreatePrefillInputBuffers means decode now
    // defaults LoRA-named inputs to zero, so chat without LoRA should
    // emit base-Gemma-IT text instead of <pad>.
    ASSIGN_OR_RETURN(chat_base,
                     BuildChatBase(*engine, system_message,
                                   /*lora_path=*/""));
    std::cout << "[e2e] chat base built\n";
  }

  // chat_lora mode: like chat_fresh but with LoRA scoped in. Tests whether
  // the bug only hits when LoRA isn't bound. (If chat is fine with LoRA
  // but broken without, the issue is the chat path's LoRA-default
  // tensors being wrong.)
  if (mode == "chat_lora") {
    int failures = 0;
    for (int i = 0; i < iterations; ++i) {
      const absl::string_view prompt = kPrompts[i % kNumPrompts];
      auto session_config = SessionConfig::CreateDefault();
      auto scoped_or = ::litert::ScopedFile::Open(std::string(lora_path));
      if (!scoped_or.ok()) {
        std::cout << "[e2e] iter=" << i << " lora open FAILED\n";
        ++failures; continue;
      }
      auto file_ptr = std::make_shared<::litert::ScopedFile>(
          std::move(*scoped_or));
      session_config.SetScopedLoraFile(file_ptr);
      auto cc_or = ConversationConfig::Builder()
                       .SetSessionConfig(session_config)
                       .SetPreface(litert::lm::JsonPreface{
                           .messages = json::array({json::object(
                               {{"role", "system"},
                                {"content", system_message}})})})
                       .Build(*engine);
      if (!cc_or.ok()) { ++failures; continue; }
      auto convo_or = Conversation::Create(*engine, *cc_or);
      if (!convo_or.ok()) { ++failures; continue; }
      json content_list = json::array();
      content_list.push_back({{"type", "text"}, {"text", std::string(prompt)}});
      auto response = (*convo_or)->SendMessage(json::object(
          {{"role", "user"}, {"content", content_list}}));
      if (!response.ok()) {
        std::cout << "[e2e] iter=" << i << " SendMessage FAILED: "
                  << response.status() << "\n";
        ++failures; continue;
      }
      std::string text;
      if (response->contains("content")) {
        const auto& content = (*response)["content"];
        if (content.is_string()) text = content.get<std::string>();
        else if (content.is_array()) {
          for (const auto& part : content) {
            if (part.is_object() && part.contains("text") &&
                part["text"].is_string())
              text += part["text"].get<std::string>();
          }
        }
      }
      const bool sane = ChatOutputLooksSane(text);
      std::cout << "[e2e] iter=" << i << " chat_lora sane=" << sane
                << " out=\"" << text.substr(0, 120) << "\"\n";
      if (!sane) ++failures;
    }
    std::cout << "[e2e] done. failures=" << failures << "/" << iterations << "\n";
    if (failures > 0)
      return absl::InternalError("e2e harness saw failed iterations.");
    return absl::OkStatus();
  }

  // chat_fresh mode: build a FRESH conversation per call (no shared
  // chat_base, no clone). The conversation prefills system+user in one
  // shot when sendMessage runs. Used to test whether the bug is in
  // Conversation::Clone() or in the chat path itself.
  if (mode == "chat_fresh") {
    int failures = 0;
    for (int i = 0; i < iterations; ++i) {
      const absl::string_view prompt = kPrompts[i % kNumPrompts];
      auto session_config = SessionConfig::CreateDefault();
      auto cc_or = ConversationConfig::Builder()
                       .SetSessionConfig(session_config)
                       .SetPreface(litert::lm::JsonPreface{
                           .messages = json::array({json::object(
                               {{"role", "system"},
                                {"content", system_message}})})})
                       .Build(*engine);
      if (!cc_or.ok()) {
        std::cout << "[e2e] iter=" << i << " config build FAILED: "
                  << cc_or.status() << "\n";
        ++failures;
        continue;
      }
      auto convo_or = Conversation::Create(*engine, *cc_or);
      if (!convo_or.ok()) {
        std::cout << "[e2e] iter=" << i << " Conversation::Create FAILED: "
                  << convo_or.status() << "\n";
        ++failures;
        continue;
      }
      json content_list = json::array();
      content_list.push_back({{"type", "text"}, {"text", std::string(prompt)}});
      auto response = (*convo_or)->SendMessage(json::object(
          {{"role", "user"}, {"content", content_list}}));
      if (!response.ok()) {
        std::cout << "[e2e] iter=" << i << " SendMessage FAILED: "
                  << response.status() << "\n";
        ++failures;
        continue;
      }
      std::string text;
      if (response->contains("content")) {
        const auto& content = (*response)["content"];
        if (content.is_string()) text = content.get<std::string>();
        else if (content.is_array()) {
          for (const auto& part : content) {
            if (part.is_object() && part.contains("text") &&
                part["text"].is_string())
              text += part["text"].get<std::string>();
          }
        }
      }
      const bool sane = ChatOutputLooksSane(text);
      std::cout << "[e2e] iter=" << i << " chat_fresh sane=" << sane
                << " out=\"" << text.substr(0, 120) << "\"\n";
      if (!sane) ++failures;
    }
    std::cout << "[e2e] done. failures=" << failures << "/" << iterations
              << "\n";
    if (failures > 0)
      return absl::InternalError("e2e harness saw failed iterations.");
    return absl::OkStatus();
  }

  // chat_only mode: run N consecutive chat clone+sendMessage calls. No
  // classifier interleave. Used to confirm whether chat decode is broken
  // independently of any LoRA/classifier session state.
  if (mode == "chat_only") {
    int failures = 0;
    for (int i = 0; i < iterations; ++i) {
      const absl::string_view prompt = kPrompts[i % kNumPrompts];
      auto out = RunChatSync(*engine, *chat_base, prompt);
      if (!out.ok()) {
        std::cout << "[e2e] iter=" << i << " chat FAILED: " << out.status()
                  << "\n";
        ++failures;
        continue;
      }
      const bool sane = ChatOutputLooksSane(*out);
      std::cout << "[e2e] iter=" << i << " chat sane=" << sane
                << " out=\"" << out->substr(0, 120) << "\"\n";
      if (!sane) ++failures;
    }
    std::cout << "[e2e] done. failures=" << failures << "/" << iterations
              << "\n";
    if (failures > 0)
      return absl::InternalError("e2e harness saw failed iterations.");
    return absl::OkStatus();
  }

  // classifier_only / classifier_after_chat modes: run N consecutive
  // classifier calls and bail out (no chat clones).
  if (mode == "classifier_only" || mode == "classifier_after_chat") {
    int failures = 0;
    for (int i = 0; i < iterations; ++i) {
      const absl::string_view prompt = kPrompts[i % kNumPrompts];
      auto logits = RunClassifierOnce(*classifier_engine, lora_path, prompt);
      if (!logits.ok()) {
        std::cout << "[e2e] iter=" << i << " classifier FAILED: "
                  << logits.status() << "\n";
        ++failures;
        continue;
      }
      std::cout << "[e2e] iter=" << i << " logits:";
      for (float v : *logits) std::cout << " " << v;
      std::cout << "  sane=" << LogitsLookSane(*logits) << "\n";
      if (!LogitsLookSane(*logits)) ++failures;
    }
    PrintRss("after classifier runs");
    std::cout << "[e2e] done. failures=" << failures << "/" << iterations
              << "\n";
    if (failures > 0)
      return absl::InternalError("e2e harness saw failed iterations.");
    return absl::OkStatus();
  }

  // ---------- Phase 1: strict interleave ----------
  int failures = 0;
  for (int i = 0; i < iterations; ++i) {
    const absl::string_view prompt = kPrompts[i % kNumPrompts];

    // Chat clone path.
    auto chat_status = RunChatSync(*engine, *chat_base, prompt);
    if (!chat_status.ok()) {
      std::cout << "[e2e] iter=" << i << " phase=interleave chat FAILED: "
                << chat_status.status() << "\n";
      ++failures;
      continue;
    }
    const std::string& chat_text = *chat_status;
    const bool chat_sane = ChatOutputLooksSane(chat_text);
    std::cout << "[e2e] iter=" << i
              << " phase=interleave chat sane=" << chat_sane
              << " out=\"" << chat_text.substr(0, 120) << "\"\n";
    if (!chat_sane) ++failures;

    // Classifier path.
    auto logits = RunClassifierOnce(*classifier_engine, lora_path, prompt);
    if (!logits.ok()) {
      std::cout << "[e2e] iter=" << i
                << " phase=interleave classifier FAILED: " << logits.status()
                << "\n";
      ++failures;
      continue;
    }
    if (!LogitsLookSane(*logits)) {
      std::cout << "[e2e] iter=" << i
                << " phase=interleave classifier logits insane:";
      for (float v : *logits) std::cout << " " << v;
      std::cout << "\n";
      ++failures;
      continue;
    }
    if (absl::GetFlag(FLAGS_verbose)) {
      std::cout << "[e2e] iter=" << i << " phase=interleave logits:";
      for (float v : *logits) std::cout << " " << v;
      std::cout << "\n";
    } else if (i % 5 == 0) {
      std::cout << "[e2e] iter=" << i << " ok\n";
    }
  }

  // ---------- Phase 2: randomized rapid-fire ----------
  std::mt19937_64 rng(seed);
  std::uniform_int_distribution<int> coin(0, 1);
  std::uniform_int_distribution<int> pick(0, kNumPrompts - 1);
  for (int i = 0; i < iterations; ++i) {
    const absl::string_view prompt = kPrompts[pick(rng)];
    const bool do_chat = (coin(rng) == 0);
    if (do_chat) {
      auto chat_status = RunChatSync(*engine, *chat_base, prompt);
      if (!chat_status.ok()) {
        std::cout << "[e2e] iter=" << i << " phase=rapid chat FAILED: "
                  << chat_status.status() << "\n";
        ++failures;
      } else if (!ChatOutputLooksSane(*chat_status)) {
        std::cout << "[e2e] iter=" << i
                  << " phase=rapid chat output insane: \""
                  << chat_status->substr(0, 120) << "\"\n";
        ++failures;
      }
    } else {
      auto logits = RunClassifierOnce(*classifier_engine, lora_path, prompt);
      if (!logits.ok()) {
        std::cout << "[e2e] iter=" << i
                  << " phase=rapid classifier FAILED: " << logits.status()
                  << "\n";
        ++failures;
      } else if (!LogitsLookSane(*logits)) {
        std::cout << "[e2e] iter=" << i
                  << " phase=rapid classifier logits insane:";
        for (float v : *logits) std::cout << " " << v;
        std::cout << "\n";
        ++failures;
      }
    }
  }

  std::cout << "[e2e] done. failures=" << failures << "/" << (iterations * 2)
            << "\n";
  if (failures > 0) {
    return absl::InternalError("e2e harness saw failed iterations.");
  }
  return absl::OkStatus();
}

}  // namespace

int main(int argc, char** argv) {
  ABSL_CHECK_OK(MainHelper(argc, argv));
  return 0;
}
