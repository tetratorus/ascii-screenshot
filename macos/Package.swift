// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ascii-screen",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/tetratorus/lightpinky.git",
             revision: "c5da49b28171ebab1912984c78bc9399146c7f19"),
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
