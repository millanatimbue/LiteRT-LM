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
    // dSYMs are bundled. See the xcframework-detector-lora-v3.1 release.
    // This branch also strips prebuilt/ (LFS blobs) so SPM checkouts stay
    // light. For local runtime iteration use the experiment branch instead
    // (path-based .local-xcframeworks targets).
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3.1/CLiteRTLM.xcframework.zip",
      checksum: "e02a5451a7e773a2e45e5718b192e61598d8e7f1c71094f54869c8d6869f748e"
    ),
    .binaryTarget(
      name: "GemmaProvider",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3.1/GemmaProvider.xcframework.zip",
      checksum: "73e7f23b0b4cd07efc0cc7183d345d8bb428ec7853735cadb97cd212bceaee1c"
    ),
    .binaryTarget(
      name: "LiteRt",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3.1/LiteRt.xcframework.zip",
      checksum: "a9c94adaa251d40b017c9bc42be4c9210bc764f0db5544ca64b9b37f7ce7ae4a"
    ),
    .binaryTarget(
      name: "MtlAcc",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3.1/MtlAcc.xcframework.zip",
      checksum: "5719c0f76776a4c9a4e441187806c0b3fff2003573f32855270e2b62bbc46736"
    ),
    .binaryTarget(
      name: "TopKMS",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v3.1/TopKMS.xcframework.zip",
      checksum: "e8d61381caad798152fb8b081ac3e5f7488fe418123df2406d0364ef3c4ba504"
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