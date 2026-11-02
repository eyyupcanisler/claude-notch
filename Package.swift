// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ClaudeNotch",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "ClaudeNotch", targets: ["ClaudeNotch"])
  ],
  targets: [
    .target(
      name: "ClaudeNotchCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "ClaudeNotch",
      dependencies: ["ClaudeNotchCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "ClaudeNotchCoreTests",
      dependencies: ["ClaudeNotchCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    )
  ]
)
