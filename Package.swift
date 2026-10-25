// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "PiDesktop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PiDesktop", targets: ["PiDesktop"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .executableTarget(name: "PiDesktop", dependencies: ["SwiftTerm"], path: "Sources/PiDesktop"),
        .testTarget(name: "PiDesktopTests", dependencies: ["PiDesktop"], path: "Tests/PiDesktopTests")
    ]
)
