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

#ifndef THIRD_PARTY_ODML_LITERT_LM_RUNTIME_COMPONENTS_LORA_H_
#define THIRD_PARTY_ODML_LITERT_LM_RUNTIME_COMPONENTS_LORA_H_

#include <memory>
#include <string>
#include <utility>

#include "absl/container/flat_hash_map.h"  // from @com_google_absl
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "litert/cc/litert_compiled_model.h"  // from @litert
#include "litert/cc/litert_model.h"  // from @litert
#include "litert/cc/litert_tensor_buffer.h"  // from @litert
#include "runtime/util/lora_data.h"

namespace litert::lm {

// The LoRA interface for LiteRT-LM.
// It handles the LoRA weight loading, filling Lora weights into LiteRT objects
// (e.g. TensorBuffer), and weight rearranging.
// Note that LoRA backend resources are held in litert::TensorBuffer, which is
// essentially a shared_ptr to the real data, so the LoRA class is not the sore
// owner of the underlying resources. But we should still treat LoRA as the main
// owner of the lora data, and destroy it to free resources when necessary.
//
// Per-signature storage: LiteRT's `CreateInputBuffer(signature, name)` returns
// a buffer whose backend type / memory layout is specialized for that specific
// signature's compiled graph. The prefill and decode signatures are compiled
// to different runners with potentially different buffer-type expectations,
// so a buffer created for the decode signature cannot in general be reused as
// an input to the prefill signature (LiteRT rejects with "The given buffer
// type is not supported"). LoRA::Init therefore creates one buffer set per
// signature: the "decode" signature plus every signature whose name begins
// with "prefill" (e.g. "prefill", "prefill_128", "prefill_512"). Callers
// retrieve the matching set via GetLoRABuffers(signature).
class LoRA {
 public:
  // Creates and initializes a LoRA object.
  //
  // @param lora_data The LoraData object containing the LoRA weights.
  // @param compiled_model The CompiledModel object containing model and
  // environment information. It is used for creating backend resources for
  // model buffers.
  // @return A unique_ptr to the LoRA instance, or an error status.
  static absl::StatusOr<std::unique_ptr<LoRA>> Create(
      std::unique_ptr<LoraData> lora_data,
      const litert::CompiledModel& compiled_model);

  virtual ~LoRA() = default;

  // Returns a duplicated TensorBuffer for the given LoRA tensor name from the
  // decode signature's buffer set. TensorBuffer is a shared_ptr to the real
  // data, so users are responsible for destroying the TensorBuffer received
  // after use to properly decrease reference count to the underlying data.
  absl::StatusOr<litert::TensorBuffer> GetLoRABuffer(
      const std::string& name) const;

  // Returns a map of all the LoRA tensor names to their duplicated
  // TensorBuffers, for the decode signature. Equivalent to
  // GetLoRABuffers("decode"). Kept for callers that don't care which signature
  // they're binding to (e.g. tests).
  // See GetLoRABuffer() for more details about resource ownership.
  absl::StatusOr<absl::flat_hash_map<absl::string_view, litert::TensorBuffer>>
  GetLoRABuffers() const;

  // Returns a map of all the LoRA tensor names to their duplicated
  // TensorBuffers for the given `signature`. The signature must be one of the
  // signatures populated at Init time: "decode" or a name beginning with
  // "prefill". Returns NotFoundError otherwise.
  absl::StatusOr<absl::flat_hash_map<absl::string_view, litert::TensorBuffer>>
  GetLoRABuffers(absl::string_view signature) const;

 private:
  LoRA(std::unique_ptr<LoraData> lora_data,
       const litert::CompiledModel& compiled_model)
      : lora_data_(std::move(lora_data)), compiled_model_(compiled_model) {}

  // Initializes the LoRA object by enumerating compiled-model signatures
  // (decode + any prefill_*) and creating TensorBuffers for each signature's
  // LoRA inputs, populated from the LoraData payload.
  absl::Status Init();

  // Populate per_signature_lora_buffers_[signature] with one buffer per LoRA
  // input declared by `signature`. Copies the same lora_data_ bytes into each
  // signature's buffer (or zeros if the tensor isn't in LoraData).
  absl::Status InitForSignature(absl::string_view signature);

  std::unique_ptr<LoraData> lora_data_;
  const litert::CompiledModel& compiled_model_;
  // Outer key: signature name ("decode", "prefill", "prefill_128", ...).
  // Inner key: LoRA tensor name. Stored owning the std::string keys so callers
  // can use absl::string_view safely against the lifetime of this object.
  absl::flat_hash_map<std::string,
                      absl::flat_hash_map<std::string, litert::TensorBuffer>>
      per_signature_lora_buffers_;
};

}  // namespace litert::lm

#endif  // THIRD_PARTY_ODML_LITERT_LM_RUNTIME_COMPONENTS_LORA_H_
