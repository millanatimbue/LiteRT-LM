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

#include "runtime/components/lora.h"

#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/container/flat_hash_map.h"  // from @com_google_absl
#include "absl/memory/memory.h"  // from @com_google_absl
#include "absl/status/status.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "absl/strings/match.h"  // from @com_google_absl
#include "absl/strings/str_cat.h"  // from @com_google_absl
#include "absl/strings/string_view.h"  // from @com_google_absl
#include "litert/cc/litert_compiled_model.h"  // from @litert
#include "litert/cc/litert_tensor_buffer.h"  // from @litert
#include "runtime/util/lora_data.h"
#include "runtime/util/lora_util.h"
#include "runtime/util/status_macros.h"

namespace litert::lm {

namespace {

// Names of the signature runners, used to get the signature runners from the
// interpreter.
// TODO: b/450616365 - Consolidate constant definitions.
constexpr char kDecodeSignatureRunner[] = "decode";
constexpr absl::string_view kPrefillSignaturePrefix = "prefill";

}  // namespace

absl::StatusOr<std::unique_ptr<LoRA>> LoRA::Create(
    std::unique_ptr<LoraData> lora_data,
    const litert::CompiledModel& compiled_model) {
  auto lora = absl::WrapUnique(new LoRA(std::move(lora_data), compiled_model));
  RETURN_IF_ERROR(lora->Init());
  return lora;
}

absl::Status LoRA::Init() {
  // Discover every signature the compiled model exposes. We populate buffers
  // for the decode signature (always present) and every prefill_* signature
  // (one per supported prefill chunk length). LiteRT requires that input
  // buffers be created via CreateInputBuffer(signature, name) for the
  // specific signature they'll be passed to — buffers created against one
  // signature have a backend type / memory layout that another signature's
  // runner will reject with "The given buffer type is not supported".
  LITERT_ASSIGN_OR_RETURN(auto signature_keys,
                          compiled_model_.GetSignatureKeys());

  bool found_decode = false;
  for (const auto& key_sv : signature_keys) {
    absl::string_view key(key_sv.data(), key_sv.size());
    const bool is_decode = (key == kDecodeSignatureRunner);
    const bool is_prefill = absl::StartsWith(key, kPrefillSignaturePrefix);
    if (!is_decode && !is_prefill) {
      continue;
    }
    if (is_decode) {
      found_decode = true;
    }
    RETURN_IF_ERROR(InitForSignature(key));
  }

  if (!found_decode) {
    return absl::FailedPreconditionError(
        "Model does not expose a 'decode' signature; cannot initialize LoRA.");
  }
  return absl::OkStatus();
}

absl::Status LoRA::InitForSignature(absl::string_view signature) {
  LITERT_ASSIGN_OR_RETURN(
      auto input_names, compiled_model_.GetSignatureInputNames(signature));

  absl::flat_hash_map<std::string, litert::TensorBuffer> buffers;
  for (const auto& input_name_sv : input_names) {
    absl::string_view input_name(input_name_sv.data(), input_name_sv.size());
    if (!IsLoRAInputName(input_name)) {
      continue;
    }

    LITERT_ASSIGN_OR_RETURN(
        litert::TensorBuffer tensor_buffer,
        compiled_model_.CreateInputBuffer(signature, input_name));

    LITERT_ASSIGN_OR_RETURN(
        auto lock_and_addr,
        litert::TensorBufferScopedLock::Create(
            tensor_buffer, TensorBuffer::LockMode::kWrite));
    LITERT_ASSIGN_OR_RETURN(auto tensor_buffer_size,
                            tensor_buffer.PackedSize());

    if (lora_data_->HasTensor(input_name)) {
      ASSIGN_OR_RETURN(auto lora_tensor_data,
                       lora_data_->ReadTensor(input_name));
      RET_CHECK_EQ(tensor_buffer_size, lora_tensor_data->Size())
          << "LoRA tensor size mismatch between model input and Lora Data: "
          << tensor_buffer_size << " vs. " << lora_tensor_data->Size()
          << " (signature=" << signature << ", tensor=" << input_name << ")";
      std::memcpy(lock_and_addr.second, lora_tensor_data->Data(),
                  lora_tensor_data->Size());
    } else {
      std::memset(lock_and_addr.second, 0, tensor_buffer_size);
    }
    buffers[std::string(input_name)] = std::move(tensor_buffer);
  }

  per_signature_lora_buffers_[std::string(signature)] = std::move(buffers);
  return absl::OkStatus();
}

absl::StatusOr<litert::TensorBuffer> LoRA::GetLoRABuffer(
    const std::string& name) const {
  auto sig_it = per_signature_lora_buffers_.find(kDecodeSignatureRunner);
  if (sig_it == per_signature_lora_buffers_.end()) {
    return absl::FailedPreconditionError(
        "LoRA decode signature buffers not initialized.");
  }
  auto it = sig_it->second.find(name);
  if (it == sig_it->second.end()) {
    return absl::NotFoundError("LoRA tensor not found.");
  }
  LITERT_ASSIGN_OR_RETURN(auto duplicated_buffer, it->second.Duplicate());
  return duplicated_buffer;
}

absl::StatusOr<absl::flat_hash_map<absl::string_view, litert::TensorBuffer>>
LoRA::GetLoRABuffers() const {
  return GetLoRABuffers(kDecodeSignatureRunner);
}

absl::StatusOr<absl::flat_hash_map<absl::string_view, litert::TensorBuffer>>
LoRA::GetLoRABuffers(absl::string_view signature) const {
  auto sig_it = per_signature_lora_buffers_.find(signature);
  if (sig_it == per_signature_lora_buffers_.end()) {
    return absl::NotFoundError(
        absl::StrCat("No LoRA buffers populated for signature '", signature,
                     "'. Init() only populates 'decode' and 'prefill*' "
                     "signatures."));
  }
  absl::flat_hash_map<absl::string_view, litert::TensorBuffer> buffers;
  for (const auto& [name, buffer] : sig_it->second) {
    LITERT_ASSIGN_OR_RETURN(buffers[name], buffer.Duplicate());
  }
  return buffers;
}

}  // namespace litert::lm
