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
    // Locally-built binary targets (iOS only). Rebuild from THIS source before
    // consuming — see LOCAL_BUILD.md:
    //   bazelisk build //swift:CLiteRTLM        → CLiteRTLM.xcframework
    //   xcodebuild -create-xcframework …        → the 4 accelerator xcframeworks
    // then unzip/assemble into .local-xcframeworks/. The four accelerator
    // dylibs are opaque upstream LFS blobs — keep them the SAME vintage as this
    // runtime source (this branch is based on upstream/main @ v0.14, so pull the
    // v0.14 dylibs via `git lfs pull`, not an older pin).
    .binaryTarget(
      name: "CLiteRTLM",
      path: ".local-xcframeworks/CLiteRTLM.xcframework"
    ),
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
    .binaryTarget(
      name: "libLiteRtTopKMetalSampler",
      path: ".local-xcframeworks/libLiteRtTopKMetalSampler.xcframework"
    ),
    // The Swift Wrapper Target
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