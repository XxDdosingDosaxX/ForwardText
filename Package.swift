// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForwardText",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "ForwardText", targets: ["ForwardText"]),
    ],
    targets: [
        .target(name: "ForwardText"),
    ]
)
