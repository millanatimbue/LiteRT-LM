// Copyright 2025 The ODML Authors.
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

#ifndef THIRD_PARTY_ODML_LITERT_LM_RUNTIME_COMPONENTS_LORA_MANAGER_H_
#define THIRD_PARTY_ODML_LITERT_LM_RUNTIME_COMPONENTS_LORA_MANAGER_H_

#include <cstdint>
#include <memory>
#include <optional>

#include "absl/container/flat_hash_map.h"  // from @com_google_absl
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "litert/cc/litert_compiled_model.h"  // from @litert
#include "litert/cc/litert_tensor_buffer.h"  // from @litert
#include "runtime/components/lora.h"
#include "runtime/executor/executor_settings_base.h"
#include "runtime/util/lora_data.h"

namespace litert::lm {

// The class managing LoRA weights for LiteRT-LM.
// It is responsible for loading LoRA weights, creating LoRA objects, and
// managing the current LoRA ID to use.
// It will create LoRA objects on the backend (e.g. GPU) lazily, only when
// UseLoRA() is called with the corresponding LoRA ID.
class LoraManager {
 public:
  // Args:
  // compiled_model: The CompiledModel object containing model and environment
  // information. It is used for creating backend resources for model buffers.
  // It also contains the LoRA input signature information
  static absl::StatusOr<std::unique_ptr<LoraManager>> Create(
      const litert::CompiledModel& compiled_model,
      absl::string_view decode_signature_name = "decode");

  // Returns the current LoRA ID.
  std::optional<uint32_t> GetCurrentLoRAId() const { return current_lora_id_; }

  // Loads the LoRA model into tensor loader, but does not use it.
  // To use the lora weights, call `UseLoRA()` with the lora_id.
  // Args:
  // lora_id: The unique id to assign to the loaded LoRA model.
  // model_assets: Contains the LoRA model to load.
  absl::Status LoadLoRA(uint32_t lora_id, const ModelAssets& model_assets);

  // Sets the current LoRA ID to use. If the LoRA object for the given ID
  // doesn't exist, it will be created.
  absl::Status UseLoRA(uint32_t lora_id);

  // Resets the current LoRA so subsequent GetLoRABuffers() calls report no
  // active LoRA. Loaded LoRAs remain available — switch back with UseLoRA().
  void ClearCurrentLoRA() { current_lora_id_ = std::nullopt; }

  // Returns a map of all the LoRA tensor names to their duplicated
  // TensorBuffers for the current LoRA ID, defaulting to the "decode"
  // signature's buffer set. Kept for back-compat with callers that don't
  // know or care which signature they're binding to.
  absl::StatusOr<absl::flat_hash_map<absl::string_view, litert::TensorBuffer>>
  GetLoRABuffers() const;

  // Returns the LoRA tensor buffers populated for the given `signature`. The
  // active LoRA's Init() populates one buffer set per (decode + each prefill_*)
  // signature; callers binding LoRA tensors into a specific signature's
  // input map must pass that signature's name here so the returned buffers
  // are compatible with LiteRT's per-signature buffer-type requirements.
  absl::StatusOr<absl::flat_hash_map<absl::string_view, litert::TensorBuffer>>
  GetLoRABuffers(absl::string_view signature) const;

  // Returns LoRA buffers appropriate for a per-context dispatch. When the
  // caller's context has a `lora_id` (i.e. its session scoped a LoRA), the
  // buffers from that specific LoRA are returned. Otherwise — including
  // when LoraManager's `current_lora_id_` is set by a sibling session on
  // the same engine — a lazily-created null LoRA's zero buffers are
  // returned. Use this from the executor's per-call Bind*And-Run path so
  // each session gets its own LoRA without leaking the engine-scoped
  // `current_lora_id_` state across sessions.
  //
  // The null-LoRA path keeps GPU-aware buffer allocation (Metal/WebGPU
  // delegate-managed tensors) on every prefill+decode call. Bypassing it
  // for non-LoRA sessions feeds uninitialized memory into the LoRA branch
  // of attention and the model emits pad tokens / template echo.
  absl::StatusOr<absl::flat_hash_map<absl::string_view, litert::TensorBuffer>>
  GetLoRABuffersOrZero(absl::string_view signature,
                       std::optional<uint32_t> context_lora_id);

 private:
  explicit LoraManager(const litert::CompiledModel& compiled_model,
                       absl::string_view decode_signature_name);

  // Lazily build a null LoRA — same allocation path as a real LoRA but
  // every tensor is zero-filled. Constant cost (one CreateInputBuffer per
  // LoRA tensor on the requested signature); cached in null_lora_.
  absl::Status EnsureNullLora();

  const litert::CompiledModel& compiled_model_;
  std::string decode_signature_name_;

  absl::flat_hash_map<uint32_t, std::unique_ptr<LoraData>> lora_data_;
  absl::flat_hash_map<uint32_t, std::unique_ptr<LoRA>> loras_;
  std::optional<uint32_t> current_lora_id_;
  std::unique_ptr<LoRA> null_lora_;
};

}  // namespace litert::lm

#endif  // THIRD_PARTY_ODML_LITERT_LM_RUNTIME_COMPONENTS_LORA_MANAGER_H_
