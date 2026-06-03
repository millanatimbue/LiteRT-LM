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

#include "runtime/util/litert_util.h"

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <filesystem>  // NOLINT(build/c++17)
#include "absl/base/const_init.h"  // from @com_google_absl
#include "absl/base/no_destructor.h"  // from @com_google_absl
#include "absl/log/absl_log.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl  // IWYU pragma: keep
#include "absl/synchronization/mutex.h"  // from @com_google_absl
#include "litert/cc/litert_environment.h"  // from @litert
#include "litert/cc/litert_environment_options.h"  // from @litert
#include "litert/cc/litert_macros.h"  // from @litert
#include "runtime/components/model_resources.h"
#include "runtime/engine/engine_settings.h"
#include "runtime/executor/executor_settings_base.h"
#include "runtime/executor/magic_number_configs_helper.h"
#include "runtime/util/logging.h"

namespace litert::lm {

absl::StatusOr<Environment&> GetEnvironment(EngineSettings& engine_settings,
                                            ModelResources* model_resources) {
  const auto& main_executor_settings =
      engine_settings.GetMainExecutorSettings();
  Backend backend = main_executor_settings.GetBackend();

  // [ENV-ISOLATION] Two engines that load the same model but target different
  // decode signatures (e.g. a chat engine on decode_chat and a classifier
  // engine on decode_classifier in a dual-sig bundle) used to share a single
  // cached Environment because the cache was keyed only by Backend. With a
  // shared Metal device + LiteRT environment, classifier inference (LoRA-
  // bound) corrupted the chat engine's KV state across calls — chat output
  // collapsed to "a vague, vague, vague description." after each classifier
  // run. Including the decode signature in the cache key gives each engine
  // its own Environment instance while preserving caching for the common
  // case (two engines with identical settings hit the same entry).
  // b/454383477 (referenced in the header) requires we keep ONE Environment
  // per logical (backend × signature) — not one per app — so this key bump
  // doesn't reintroduce the multi-instance hazard the original singleton
  // guards against.
  using CacheKey = std::pair<Backend, std::string>;
  struct CacheKeyHash {
    std::size_t operator()(const CacheKey& k) const {
      return std::hash<int>()(static_cast<int>(k.first)) ^
             (std::hash<std::string>()(k.second) << 1);
    }
  };
  CacheKey cache_key = {backend, main_executor_settings.GetDecodeSignatureName()};

  struct CachedEnvironment {
    Environment env;
    std::unique_ptr<MagicNumberConfigsHelper> helper;
  };

  static absl::Mutex environments_mu(absl::kConstInit);
  static absl::NoDestructor<std::unordered_map<
      CacheKey, absl::StatusOr<CachedEnvironment>, CacheKeyHash>>
      kEnvironments;

  absl::MutexLock lock(&environments_mu);

  auto it = kEnvironments->find(cache_key);
  if (it == kEnvironments->end()) {
    auto env_res = [&]() -> absl::StatusOr<CachedEnvironment> {
      std::vector<EnvironmentOptions::Option> env_options;
      auto helper = std::make_unique<MagicNumberConfigsHelper>();

      if (model_resources != nullptr &&
          (backend == Backend::CPU || backend == Backend::GPU)) {
        if (!main_executor_settings.GetAdvancedSettings() ||
            main_executor_settings.GetAdvancedSettings()
                ->configure_magic_numbers) {
          env_options = helper->GetLiteRtEnvOptions(*model_resources,
                                                    main_executor_settings);
        }
      }

      bool uses_npu =
          (backend == Backend::NPU ||
           (engine_settings.GetVisionExecutorSettings().has_value() &&
            engine_settings.GetVisionExecutorSettings()->GetBackend() ==
                Backend::NPU) ||
           (engine_settings.GetAudioExecutorSettings().has_value() &&
            engine_settings.GetAudioExecutorSettings()->GetBackend() ==
                Backend::NPU));

      if (uses_npu) {
#if !defined(LITERT_DISABLE_NPU)
        if (!main_executor_settings.GetLitertDispatchLibDir().empty()) {
          // If the dispatch library directory is provided, use it.
          env_options.push_back(::litert::EnvironmentOptions::Option{
              ::litert::EnvironmentOptions::Tag::kDispatchLibraryDir,
              main_executor_settings.GetLitertDispatchLibDir()});
          ABSL_LOG(INFO) << "Setting dispatch library path from "
                            "main_executor_settings: "
                         << main_executor_settings.GetLitertDispatchLibDir();
        } else {
          // Otherwise, use the directory of the model file.
          std::string model_path(
              main_executor_settings.GetModelAssets().GetPath().value_or(""));
          std::filesystem::path path(model_path);
          std::string dispatch_library_path = path.parent_path().string();
          // In WASM, the parent path is often just "/" which is usually not
          // what we want for dispatch libraries.
#ifdef __EMSCRIPTEN__
          bool should_set_path =
              !dispatch_library_path.empty() && dispatch_library_path != "/";
#else
          bool should_set_path = !dispatch_library_path.empty();
#endif
          if (should_set_path) {
            ABSL_LOG(INFO) << "Setting dispatch library path: "
                           << dispatch_library_path;
            env_options.push_back(::litert::EnvironmentOptions::Option{
                ::litert::EnvironmentOptions::Tag::kDispatchLibraryDir,
                absl::string_view(dispatch_library_path)});
          } else {
            ABSL_LOG(INFO) << "No dispatch library path provided.";
          }
        }
#endif  // defined(LITERT_DISABLE_NPU)
      }

      if (auto severity = GetMinLogSeverity()) {
        env_options.push_back(::litert::EnvironmentOptions::Option{
            ::litert::EnvironmentOptions::Tag::kMinLoggerSeverity,
            static_cast<int64_t>(ToLiteRtLogSeverityInt8(*severity))});
      }

      LITERT_ASSIGN_OR_RETURN(
          auto env, Environment::Create(EnvironmentOptions(env_options)));
      return CachedEnvironment{std::move(env), std::move(helper)};
    }();
    it = kEnvironments->emplace(cache_key, std::move(env_res)).first;
  }

  if (!it->second.ok()) {
    return it->second.status();
  }
  return it->second->env;
}

}  // namespace litert::lm
