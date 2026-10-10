// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConceptStudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConceptCore", targets: ["ConceptCore"]),
        .executable(name: "ConceptStudio", targets: ["ConceptStudio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.2"),
    ],
    targets: [
        .target(
            name: "ConceptCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            resources: [.copy("Resources/Skills")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .executableTarget(
            name: "ConceptStudio",
            dependencies: ["ConceptCore"],
            resources: [.copy("Resources/Demo"), .process("Resources/OpenAI")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "ConceptCoreTests",
            dependencies: ["ConceptCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "ConceptStudioTests",
            dependencies: ["ConceptStudio"],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
    ],
)
