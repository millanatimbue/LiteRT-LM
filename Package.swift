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
    // Fork-hosted build from millanatimbue/LiteRT-LM main @ c6823c0b. Exposes
    // `litert_lm_conversation_config_set_prefill_preface_on_init` through the
    // C/Swift API so `Conversation.clone()` can succeed against a prefilled
    // base — required for prefix caching in the Bouncer iOS app. Also bundles
    // [CLONE-DBG] ABSL_LOG diagnostics throughout the clone path. To rebuild,
    // see the recipe in commit 58977bad.
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-minimal-fork-v3/CLiteRTLM.xcframework.zip",
      checksum: "07acd1b90302d463f0ac9cc19c346fa40c8def418379f7dcfa26f010846eadb7"
    ),
    // 1a. GPU / accelerator dylibs — shipped as library-style xcframeworks so
    // they land at the top of Bouncer.app/Frameworks/ (not nested inside
    // CLiteRTLM.framework, which AMFI rejects on real iOS devices). The main
    // CLiteRTLM binary's existing `@executable_path/Frameworks` rpath resolves
    // these via dyld at app launch. Built by `xcodebuild -create-xcframework
    // -library` against /prebuilt/{ios_arm64,ios_sim_arm64}/lib*.dylib.
    .binaryTarget(
      name: "libGemmaModelConstraintProvider",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-minimal-fork-v3/libGemmaModelConstraintProvider.xcframework.zip",
      checksum: "ba6f1738fd034926f2300a13e31886dbff4649b09b70b2cebe02ccf4d18040b8"
    ),
    .binaryTarget(
      name: "libLiteRt",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-minimal-fork-v3/libLiteRt.xcframework.zip",
      checksum: "65d018507ed3fac1f0478135cf9012500c0f9052fc248372d7177ba27197832b"
    ),
    .binaryTarget(
      name: "libLiteRtMetalAccelerator",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-minimal-fork-v3/libLiteRtMetalAccelerator.xcframework.zip",
      checksum: "e2eddc654d78d0e2ad07f76fedfa5a2fcf9089dbdef22b3ca0644a9d4d470109"
    ),
    // libLiteRtTopKMetalSampler ships device-only (no simulator slice exists
    // in upstream's prebuilts). The C++ code is expected to dlopen it
    // conditionally on device; sim builds run without it.
    .binaryTarget(
      name: "libLiteRtTopKMetalSampler",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-minimal-fork-v3/libLiteRtTopKMetalSampler.xcframework.zip",
      checksum: "aa0e15a445d5da79005bc7f578928e1c1ad98bc939c5418ea280e8089f85bfae"
    ),
    // 2. The Swift Wrapper Target
    .target(
      name: "LiteRTLM",
      dependencies: [
        "CLiteRTLM",
        "libGemmaModelConstraintProvider",
        "libLiteRt",
        "libLiteRtMetalAccelerator",
        "libLiteRtTopKMetalSampler",
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