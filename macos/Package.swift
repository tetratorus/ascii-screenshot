// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ascii-screen",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/tetratorus/lightpinky.git",
             revision: "81e1e1cce5fd5b14939072b965d7bb6ac26d18e6"),
  ],
  targets: [
    .executableTarget(
      name: "ascii-screen",
      dependencies: [.product(name: "LightpinkyCore", package: "lightpinky")],
      path: "Sources/ascii-screen",
      swiftSettings: [.unsafeFlags(["-Ounchecked", "-wmo"])],
      linkerSettings: [.linkedLibrary("z"), .linkedLibrary("sqlite3")]
    ),
    .testTarget(name: "ascii-screenTests", dependencies: ["ascii-screen"]),
  ]
)
