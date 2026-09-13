// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "StoreFrames",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "storeframes",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
