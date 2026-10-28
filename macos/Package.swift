// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ascii-screen",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "ascii-screen",
      path: "Sources/ascii-screen",
      swiftSettings: [.unsafeFlags(["-Ounchecked", "-wmo"])]
    ),
    .testTarget(name: "ascii-screenTests", dependencies: ["ascii-screen"]),
  ]
)
