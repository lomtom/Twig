// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Twig",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Twig", targets: ["Twig"])],
    targets: [.executableTarget(name: "Twig", path: "Sources/Twig")]
)
