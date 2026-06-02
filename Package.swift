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
    // Bouncer iteration mode: xcframeworks are vendored under
    // .local-xcframeworks/ so we avoid the download/checksum/artifact-cache
    // dance that triggered "There is no XCFramework found at
    // …/SourcePackages/artifacts/litert-lm/…" after every Xcode Clean.
    // Restore the url:/checksum: form when cutting a release tag.
    .binaryTarget(
      name: "CLiteRTLM",
      path: ".local-xcframeworks/CLiteRTLM.xcframework"
    ),
    // 1a. GPU / accelerator dylibs — shipped as library-style xcframeworks so
    // they land at the top of Bouncer.app/Frameworks/ (not nested inside
    // CLiteRTLM.framework, which AMFI rejects on real iOS devices). The main
    // CLiteRTLM binary's existing `@executable_path/Frameworks` rpath resolves
    // these via dyld at app launch.
    .binaryTarget(
      name: "libGemmaModelConstraintProvider",
      path: ".local-xcframeworks/libGemmaModelConstraintProvider.xcframework"
    ),
    .binaryTarget(
      name: "libLiteRt",
      path: ".local-xcframeworks/libLiteRt.xcframework"
    ),
    .binaryTarget(
      name: "libLiteRtMetalAccelerator",
      path: ".local-xcframeworks/libLiteRtMetalAccelerator.xcframework"
    ),
    // libLiteRtTopKMetalSampler ships device-only (no simulator slice exists
    // in upstream's prebuilts). The C++ code is expected to dlopen it
    // conditionally on device; sim builds run without it.
    .binaryTarget(
      name: "libLiteRtTopKMetalSampler",
      path: ".local-xcframeworks/libLiteRtTopKMetalSampler.xcframework"
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