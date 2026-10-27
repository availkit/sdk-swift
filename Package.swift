// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "AvailKit",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "AvailKit", targets: ["AvailKit"]),
    .executable(name: "availkit-first-booking", targets: ["FirstBooking"]),
  ],
  targets: [
    .target(name: "AvailKit", resources: [.process("Resources")]),
    .executableTarget(name: "FirstBooking", dependencies: ["AvailKit"]),
    .testTarget(
      name: "AvailKitTests", dependencies: ["AvailKit", "FirstBooking"],
      resources: [.copy("fixture.py")]),
  ],
  swiftLanguageModes: [.v6]
)
