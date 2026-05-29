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

// End-to-end test for the LoRA-hot-swap + classifier_logits pipeline.
//
// Loads a .litertlm whose decode signature declares LoRA tensor inputs
// (matching the LiteRT-LM regex `lora_atten_(q|k|v|o)_(a|b)_prime_weight_N`)
// and emits a `classifier_logits` named output. Wires the LoRA via
// SessionConfig::SetScopedLoraFile, sends a single user message capped at
// 1 output token (so the decode step processes the last input token held as
// pending after prefill), then reads
// Conversation::GetAuxiliaryOutput("classifier_logits").
//
// Usage:
//   litert_lm_classify_main \
//     --model_path=/.../model.litertlm \
//     --lora_path=/.../lora_adapter.tflite \
//     --input_prompt='Detect this text.'

#include <iostream>
#include <memory>
#include <string>
#include <utility>

#include "absl/base/log_severity.h"  // from @com_google_absl
#include "absl/flags/flag.h"  // from @com_google_absl
#include "absl/flags/parse.h"  // from @com_google_absl
#include "absl/log/absl_check.h"  // from @com_google_absl
#include "absl/log/globals.h"  // from @com_google_absl
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "absl/time/time.h"  // from @com_google_absl
#include "nlohmann/json.hpp"  // from @nlohmann_json
#include "litert/cc/internal/scoped_file.h"  // from @litert
#include "runtime/conversation/conversation.h"
#include "runtime/conversation/io_types.h"
#include "runtime/engine/engine.h"
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/engine_settings.h"
// EngineFactory::EngineType enum.
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/io_types.h"
#include "runtime/executor/executor_settings_base.h"
#include "runtime/util/status_macros.h"

ABSL_FLAG(std::string, backend, "cpu",
          "Executor backend to use for LLM execution (cpu, gpu, etc.)");
ABSL_FLAG(std::string, model_path, "",
          "Path to the .litertlm bundle (base model + classifier head).");
ABSL_FLAG(std::string, lora_path, "",
          "Path to the standalone LoRA adapter .tflite.");
ABSL_FLAG(std::string, input_prompt, "",
          "Input text to classify.");
ABSL_FLAG(std::string, aux_name, "classifier_logits",
          "Auxiliary output name to read after the first decode step.");
ABSL_FLAG(std::string, vision_backend, "",
          "If set, configure the vision backend (cpu/gpu) on EngineSettings. "
          "Mirrors what the iOS app passes via EngineConfig(visionBackend:). "
          "Use this to verify a text-only .litertlm still loads when the host "
          "configures a vision backend it'll never use.");

namespace {

using ::litert::lm::Backend;
using ::litert::lm::Conversation;
using ::litert::lm::ConversationConfig;
using ::litert::lm::EngineSettings;
using ::litert::lm::Message;
using ::litert::lm::ModelAssets;
using ::nlohmann::json;

absl::Status MainHelper(int argc, char** argv) {
  absl::ParseCommandLine(argc, argv);
  absl::SetMinLogLevel(absl::LogSeverityAtLeast::kError);
  absl::SetStderrThreshold(absl::LogSeverityAtLeast::kFatal);

  const std::string model_path = absl::GetFlag(FLAGS_model_path);
  const std::string lora_path = absl::GetFlag(FLAGS_lora_path);
  const std::string prompt = absl::GetFlag(FLAGS_input_prompt);
  const std::string aux_name = absl::GetFlag(FLAGS_aux_name);

  if (model_path.empty()) {
    return absl::InvalidArgumentError("--model_path is required.");
  }
  if (prompt.empty()) {
    return absl::InvalidArgumentError("--input_prompt is required.");
  }

  ASSIGN_OR_RETURN(ModelAssets model_assets,  // NOLINT
                   ModelAssets::Create(model_path));
  auto backend_str = absl::GetFlag(FLAGS_backend);
  ASSIGN_OR_RETURN(Backend backend,
                   litert::lm::GetBackendFromString(backend_str));
  std::optional<Backend> vision_backend;
  const std::string vision_backend_str = absl::GetFlag(FLAGS_vision_backend);
  if (!vision_backend_str.empty()) {
    ASSIGN_OR_RETURN(Backend vb,
                     litert::lm::GetBackendFromString(vision_backend_str));
    vision_backend = vb;
    std::cout << "[classify_main] vision_backend set to: "
              << vision_backend_str
              << " (testing text-only .litertlm with vision config)"
              << std::endl;
  }
  ASSIGN_OR_RETURN(
      EngineSettings engine_settings,
      EngineSettings::CreateDefault(std::move(model_assets), backend,
                                    vision_backend));

  // Use the Advanced engine so the SessionAdvanced::GetAuxiliaryOutput hook
  // is wired through. The default ("LiteRT Compiled Model") engine returns
  // UnimplementedError for GetAuxiliaryOutput.
  ASSIGN_OR_RETURN(auto engine, litert::lm::EngineFactory::Create(
                                    litert::lm::EngineFactory::EngineType::
                                        kAdvancedLiteRTCompiledModel,
                                    std::move(engine_settings)));

  // Build SessionConfig with LoRA file + max_output_tokens=1.
  auto session_config = litert::lm::SessionConfig::CreateDefault();
  if (!lora_path.empty()) {
    ASSIGN_OR_RETURN(::litert::ScopedFile scoped_file,
                     ::litert::ScopedFile::Open(lora_path));
    auto file_ptr =
        std::make_shared<::litert::ScopedFile>(std::move(scoped_file));
    session_config.SetScopedLoraFile(file_ptr);
    std::cout << "[classify_main] LoRA file set: " << lora_path << std::endl;
  } else {
    std::cout << "[classify_main] WARNING: no --lora_path; running without LoRA."
              << std::endl;
  }
  session_config.SetMaxOutputTokens(1);

  ASSIGN_OR_RETURN(auto conversation_config,
                   ConversationConfig::Builder()
                       .SetSessionConfig(session_config)
                       .Build(*engine));
  std::unique_ptr<Conversation> conversation;
  ASSIGN_OR_RETURN(conversation,
                   Conversation::Create(*engine, conversation_config));

  // Send the input text and wait for completion. With max_output_tokens=1, the
  // runtime runs prefill + exactly one decode step. The decode step processes
  // the last input token held as pending after prefill, so the resulting
  // auxiliary output corresponds to the classifier applied to that token's
  // hidden state — which is what the SEQ_CLS head was trained on.
  std::cout << "[classify_main] prompt: " << prompt << std::endl;
  json content_list = json::array();
  content_list.push_back({{"type", "text"}, {"text", prompt}});
  RETURN_IF_ERROR(conversation->SendMessageAsync(
      json::object({{"role", "user"}, {"content", content_list}}),
      [](absl::StatusOr<Message> /*message*/) {}));
  RETURN_IF_ERROR(engine->WaitUntilDone(absl::Minutes(5)));

  // Read the classifier_logits auxiliary output.
  ASSIGN_OR_RETURN(auto logits, conversation->GetAuxiliaryOutput(aux_name));
  std::cout << "[classify_main] " << aux_name << " (" << logits.size()
            << " floats):" << std::endl;
  for (size_t i = 0; i < logits.size(); ++i) {
    std::cout << "  [" << i << "] = " << logits[i] << std::endl;
  }
  return absl::OkStatus();
}

}  // namespace

int main(int argc, char** argv) {
  ABSL_CHECK_OK(MainHelper(argc, argv));
  return 0;
}
