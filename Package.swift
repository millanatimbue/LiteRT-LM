// swift-tools-version: 5.9
// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import PackageDescription

let package = Package(
  name: "LiteRTLM",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(
      name: "LiteRTLM",
      targets: ["LiteRTLM"]
    )
  ],
  targets: [
    // 1. The Prebuilt Binary Target
    //
    // Fork-hosted build from millanatimbue/LiteRT-LM @ xcframework-bouncer-v4-lora-state-fix
    // (branch expose-aux-tensor-outputs, commit bc467fdf). Adds on top of v3:
    //   • Clear LoraManager.current_lora_id_ when a session has no
    //     scopedLoraFile. LoraManager state was engine-scoped, not
    //     session-scoped; a chat-style sendMessage after a classifyText call
    //     would inherit the classifier LoRA and produce garbage (Gemma 4 IT
    //     ran under the classifier LoRA generates repeating `.\n` instead of
    //     yes/no verdicts).
    // Previously (v3) on top of v2:
    //   • Per-signature LoRA buffer maps in runtime/components/lora.{h,cc}.
    //     LoRA::Init now enumerates compiled-model signatures and creates a
    //     separate buffer set per (decode + each prefill_*) signature; the
    //     v2 LoRA-in-prefill change handed decode-shaped buffers to the
    //     prefill graph and litert rejected them with "buffer type is not
    //     supported". Verified end-to-end via litert_lm_classify_main.
    // Previously (v2) on top of v1:
    //   • LoRA-in-prefill: BindTensorsAndRunPrefill merges scoped LoRA buffers
    //     so prefill K/V matches training-time forward (not just decode).
    //   • LockedLlmExecutor forwards GetAuxiliaryOutput + lora_manager().
    //   • minijinja `.get()` shim so HF chat templates (incl. Gemma 4 IT)
    //     stop tripping on safe-optional-field lookups.
    //   • Swift API: ConversationConfig now accepts `scopedLoraFile: URL?`
    //     and `maxOutputTokens: Int?`, threaded through a new
    //     litert_lm_session_config_set_scoped_lora_file C binding.
    // Together these unblock the iOS classification path:
    //   conv = engine.createConversation(with: ConversationConfig(
    //       samplerConfig: ..., scopedLoraFile: loraURL, maxOutputTokens: 1))
    //   _  = try await conv.sendMessage(.text(text))
    //   logits = try conv.getAuxiliaryOutput(name: "classifier_logits")
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v4-lora-state-fix/CLiteRTLM.xcframework.zip",
      checksum: "73874afbf91ab807d3f1d1f18765e896b3eaa7fa5ec0b12981817cee60a8b6be"
    ),
    // 1a. GPU / accelerator dylibs — shipped as library-style xcframeworks so
    // they land at the top of Bouncer.app/Frameworks/ (not nested inside
    // CLiteRTLM.framework, which AMFI rejects on real iOS devices). The main
    // CLiteRTLM binary's existing `@executable_path/Frameworks` rpath resolves
    // these via dyld at app launch. Built by `xcodebuild -create-xcframework
    // -library` against /prebuilt/{ios_arm64,ios_sim_arm64}/lib*.dylib.
    .binaryTarget(
      name: "libGemmaModelConstraintProvider",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v4-lora-state-fix/libGemmaModelConstraintProvider.xcframework.zip",
      checksum: "7ebf8ad46861b745ba6185f5f09d7876173d9b43402293e8aec4d33deed25c9d"
    ),
    .binaryTarget(
      name: "libLiteRt",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v4-lora-state-fix/libLiteRt.xcframework.zip",
      checksum: "3805decbf675ae0f1cac2153dc2a454ba7dc858f1abc8c1f3bcddccb25114e43"
    ),
    .binaryTarget(
      name: "libLiteRtMetalAccelerator",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v4-lora-state-fix/libLiteRtMetalAccelerator.xcframework.zip",
      checksum: "5937268057b7699bf46afbbe4d85bef64763112118c75a7b2a0e1bbee470fb56"
    ),
    // libLiteRtTopKMetalSampler ships device-only (no simulator slice exists
    // in upstream's prebuilts). The C++ code is expected to dlopen it
    // conditionally on device; sim builds run without it.
    .binaryTarget(
      name: "libLiteRtTopKMetalSampler",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v4-lora-state-fix/libLiteRtTopKMetalSampler.xcframework.zip",
      checksum: "1216719a45167c7d68b924b891bd7bf77a94a4856ef107142855e26cec20b803"
    ),
    // 2. The Swift Wrapper Target
    .target(
      name: "LiteRTLM",
      dependencies: [
        "CLiteRTLM",
        "libGemmaModelConstraintProvider",
        "libLiteRt",
        "libLiteRtMetalAccelerator",
        // libLiteRtTopKMetalSampler dropped — no simulator slice; dlopen'd on device.
      ],
      path: "swift",
      exclude: [
        "CapabilitiesTests.swift",
        "EngineTests.swift",
        "ConversationTests.swift",
        "ToolTests.swift",
        "MessageTests.swift",
        "BUILD",
        "Info.plist",
      ]
      // imbue fork: dropped
      //   linkerSettings: [.unsafeFlags(["-Xlinker", "-all_load"])]
      // because SPM rejects remote packages that propagate .unsafeFlags into
      // consuming targets. The same `-Xlinker -all_load` is applied at the
      // consuming app target's OTHER_LDFLAGS instead (see Bouncer iOS target
      // build settings in Bouncer.xcodeproj/project.pbxproj).
    ),
    // Separate test targets for each file to avoid naming conflicts:
    .testTarget(
      name: "CapabilitiesTests",
      dependencies: ["LiteRTLM"],
      path: "swift",
      sources: ["CapabilitiesTests.swift"]
    ),
    .testTarget(
      name: "ConversationTests",
      dependencies: ["LiteRTLM"],
      path: "swift",
      sources: ["ConversationTests.swift"]
    ),
    .testTarget(
      name: "ToolTests",
      dependencies: ["LiteRTLM"],
      path: "swift",
      sources: ["ToolTests.swift"]
    ),
    .testTarget(
      name: "EngineTests",
      dependencies: ["LiteRTLM"],
      path: "swift",
      sources: ["EngineTests.swift"]
    ),
    .testTarget(
      name: "MessageTests",
      dependencies: ["LiteRTLM"],
      path: "swift",
      sources: ["MessageTests.swift"]
    ),
  ]
)