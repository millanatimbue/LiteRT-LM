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
    // Fork-hosted build from millanatimbue/LiteRT-LM @ xcframework-bouncer-v3-lora-prefill
    // (branch expose-aux-tensor-outputs, commit af6d6fbe). Adds on top of v2:
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
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v3-lora-prefill/CLiteRTLM.xcframework.zip",
      checksum: "37b438de199ea3716fbd35897833d089a8effcdcba4f7c6d22acc5b830b60711"
    ),
    // 1a. GPU / accelerator dylibs — shipped as library-style xcframeworks so
    // they land at the top of Bouncer.app/Frameworks/ (not nested inside
    // CLiteRTLM.framework, which AMFI rejects on real iOS devices). The main
    // CLiteRTLM binary's existing `@executable_path/Frameworks` rpath resolves
    // these via dyld at app launch. Built by `xcodebuild -create-xcframework
    // -library` against /prebuilt/{ios_arm64,ios_sim_arm64}/lib*.dylib.
    .binaryTarget(
      name: "libGemmaModelConstraintProvider",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v3-lora-prefill/libGemmaModelConstraintProvider.xcframework.zip",
      checksum: "303339947cf15767e6c29a87b06a28eb45009c13f56f79db5d85b1fffb2eaddc"
    ),
    .binaryTarget(
      name: "libLiteRt",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v3-lora-prefill/libLiteRt.xcframework.zip",
      checksum: "a0de437299e7ec44dd288087c5861d7938deb08a90fe5375fb1bab8d00821835"
    ),
    .binaryTarget(
      name: "libLiteRtMetalAccelerator",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v3-lora-prefill/libLiteRtMetalAccelerator.xcframework.zip",
      checksum: "5b557f59b39155d26d1e6c321bfdb003e8bd953a37a0d496d47c58b67360890c"
    ),
    // libLiteRtTopKMetalSampler ships device-only (no simulator slice exists
    // in upstream's prebuilts). The C++ code is expected to dlopen it
    // conditionally on device; sim builds run without it.
    .binaryTarget(
      name: "libLiteRtTopKMetalSampler",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v3-lora-prefill/libLiteRtTopKMetalSampler.xcframework.zip",
      checksum: "f31356d33e25382c5da5d581ce0fee15090a108cbd2126a68c9e3d963a59d96a"
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