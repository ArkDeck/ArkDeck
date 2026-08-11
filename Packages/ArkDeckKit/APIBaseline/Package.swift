// swift-tools-version: 6.0

import PackageDescription

// External-consumer API baseline for ArkDeckKit.
//
// This package deliberately lives OUTSIDE the ArkDeckKit package boundary
// (a nested directory is not part of any ArkDeckKit target), so `package`
// access is invisible here — exactly the visibility a repository-external
// consumer has. Building it proves the published library products expose a
// usable public API: entry points, structured error contracts, and the
// result fields callers branch on. The in-package compiler cannot prove any
// of this (untyped throws and unread fields never surface there).
//
// Gate: swift build --package-path Packages/ArkDeckKit/APIBaseline
let package = Package(
  name: "ArkDeckKitAPIBaseline",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "ArkDeckKit", path: "..")
  ],
  targets: [
    .target(
      name: "APIBaseline",
      dependencies: [
        .product(name: "ArkDeckCore", package: "ArkDeckKit"),
        .product(name: "ArkDeckProcess", package: "ArkDeckKit"),
        .product(name: "ArkDeckRuntime", package: "ArkDeckKit"),
        .product(name: "ArkDeckOpenHarmony", package: "ArkDeckKit"),
        .product(name: "ArkDeckHarness", package: "ArkDeckKit"),
        .product(name: "ArkDeckWorkflows", package: "ArkDeckKit"),
        .product(name: "ArkDeckStorage", package: "ArkDeckKit"),
        .product(name: "ArkDeckAgentDaemon", package: "ArkDeckKit"),
        .product(name: "ArkDeckAgentClient", package: "ArkDeckKit"),
      ])
  ]
)
