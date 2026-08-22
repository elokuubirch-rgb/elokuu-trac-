// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LifeFootprintsLogic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CoreLogic", path: "LifeFootprints/CoreLogic"),
        .executableTarget(name: "FootprintTests", dependencies: ["CoreLogic"], path: "Tests")
    ]
)
