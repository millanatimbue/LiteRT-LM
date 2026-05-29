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
    // Fork-hosted build from millanatimbue/LiteRT-LM @ xcframework-bouncer-v2-classifier
    // (branch expose-aux-tensor-outputs, commit 82b0de3). Adds on top of v1:
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
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v2-classifier/CLiteRTLM.xcframework.zip",
      checksum: "65ddabec63b965d01754c87566b1e6cba2789dd16759812063828af137a6c7dd"
    ),
    // 1a. GPU / accelerator dylibs — shipped as library-style xcframeworks so
    // they land at the top of Bouncer.app/Frameworks/ (not nested inside
    // CLiteRTLM.framework, which AMFI rejects on real iOS devices). The main
    // CLiteRTLM binary's existing `@executable_path/Frameworks` rpath resolves
    // these via dyld at app launch. Built by `xcodebuild -create-xcframework
    // -library` against /prebuilt/{ios_arm64,ios_sim_arm64}/lib*.dylib.
    .binaryTarget(
      name: "libGemmaModelConstraintProvider",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v2-classifier/libGemmaModelConstraintProvider.xcframework.zip",
      checksum: "0a3dff483e7be841461f10aca61ecdc26fec66f634681a91e8a3cb6c5d974bea"
    ),
    .binaryTarget(
      name: "libLiteRt",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v2-classifier/libLiteRt.xcframework.zip",
      checksum: "f94484d2ccd51c6615ee10c77e7971e2dbe464a1a576413edde36b361d4838f7"
    ),
    .binaryTarget(
      name: "libLiteRtMetalAccelerator",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v2-classifier/libLiteRtMetalAccelerator.xcframework.zip",
      checksum: "e73fd63fcdfb1da41b4ac38b904872ed213ec1bf6341e7b62af92f327b39bcd4"
    ),
    // libLiteRtTopKMetalSampler ships device-only (no simulator slice exists
    // in upstream's prebuilts). The C++ code is expected to dlopen it
    // conditionally on device; sim builds run without it.
    .binaryTarget(
      name: "libLiteRtTopKMetalSampler",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-bouncer-v2-classifier/libLiteRtTopKMetalSampler.xcframework.zip",
      checksum: "cee1a861dd67db7236016cb7a3d5df98c3cc48f68bbe20358e7cdafa18b75e2f"
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