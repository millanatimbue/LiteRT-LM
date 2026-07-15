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
    // Release-hosted binary targets (iOS only). Same binaries as the
    // xcframework-detector-lora-v2 release (built from
    // experiment/upstream-v0.14-minimal @ 73c862db), repackaged for App Store
    // submission by tools/package_appstore_xcframeworks.sh: bare dylibs are
    // wrapped in .framework bundles (ASC rejects loose dylibs with
    // ITMS-90426), dlopen strings are patched to the framework paths, and
    // dSYMs are bundled. See the xcframework-detector-lora-v3 release.
    // This branch also strips prebuilt/ (LFS blobs) so SPM checkouts stay
    // light. For local runtime iteration use the experiment branch instead
    // (path-based .local-xcframeworks targets).
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3/CLiteRTLM.xcframework.zip",
      checksum: "d0b27f8865ac696a84a834ac7d4f018ce71a90a8977daa0d5ce84e39820be861"
    ),
    .binaryTarget(
      name: "GemmaProvider",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3/GemmaProvider.xcframework.zip",
      checksum: "73e7f23b0b4cd07efc0cc7183d345d8bb428ec7853735cadb97cd212bceaee1c"
    ),
    .binaryTarget(
      name: "LiteRt",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3/LiteRt.xcframework.zip",
      checksum: "17e25278bd328960fefb8f4c56784b1269803435a3854d93583bba66feb675d4"
    ),
    .binaryTarget(
      name: "MtlAcc",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3/MtlAcc.xcframework.zip",
      checksum: "702be95f68152e676325f198ed66b5115565f23c332f564a88bb63e5e38ff2ff"
    ),
    .binaryTarget(
      name: "TopKMS",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3/TopKMS.xcframework.zip",
      checksum: "6789c090f12d8c8246ae701d14a792144802a3a634b32e35d73449d868b3e254"
    ),
    // The Swift Wrapper Target
    .target(
      name: "LiteRTLM",
      dependencies: [
        "CLiteRTLM",
        "GemmaProvider",
        "LiteRt",
        "MtlAcc",
        "TopKMS",
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
      ],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-all_load"])
      ]
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