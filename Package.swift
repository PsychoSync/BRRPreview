// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BRRPreview",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BRRPreview", targets: ["BRRPreview"])
    ],
    targets: [
        .target(name: "BRRCore"),
        .target(
            name: "CStbVorbis",
            cSettings: [.unsafeFlags(["-Wno-tautological-compare"])]
        ),
        .target(name: "CSpcEmu"),
        .executableTarget(name: "BRRPreview", dependencies: ["BRRCore", "CStbVorbis", "CSpcEmu"]),
        .testTarget(name: "BRRCoreTests", dependencies: ["BRRCore"]),
        .testTarget(name: "BRRPreviewTests", dependencies: ["BRRPreview", "BRRCore"])
    ]
)
