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
    // Release-hosted binary targets (iOS only), built from
    // experiment/upstream-v0.14-minimal @ 73c862db — see the
    // xcframework-detector-lora-v2 release. This branch also strips prebuilt/
    // (LFS blobs) so SPM checkouts stay light. For local runtime iteration use
    // the experiment branch instead (path-based .local-xcframeworks targets).
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v2/CLiteRTLM.xcframework.zip",
      checksum: "fc211b7f63bd59f49e79f46910cda1b1e3d55f003abdd3992503780dec6c8ce9"
    ),
    .binaryTarget(
      name: "libGemmaModelConstraintProvider",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v2/libGemmaModelConstraintProvider.xcframework.zip",
      checksum: "50efa310235fdaf3914cc97ee971cbb90429599fcdf2db83f14adb219ba2eabd"
    ),
    .binaryTarget(
      name: "libLiteRt",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v2/libLiteRt.xcframework.zip",
      checksum: "f527d001db9e067c5e4e99df6b4ddb1867374f72b132fb59afa28efb75ef4db1"
    ),
    .binaryTarget(
      name: "libLiteRtMetalAccelerator",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v2/libLiteRtMetalAccelerator.xcframework.zip",
      checksum: "e4429ae8ec53bea592e15af15d4c02ae4b9c90eae2bf7aa87dd0f58d95442655"
    ),
    .binaryTarget(
      name: "libLiteRtTopKMetalSampler",
      url: "https://github.com/millanatimbue/LiteRT-LM/releases/download/xcframework-detector-lora-v2/libLiteRtTopKMetalSampler.xcframework.zip",
      checksum: "edaa90e51fce6ddf6693e176e8f377731405906d27915b33e3c0f6cc39bd7ad4"
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