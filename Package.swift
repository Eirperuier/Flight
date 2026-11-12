// swift-tools-version: 6.0

import PackageDescription

/// Flight: things flying from one place on screen to another, as springs that follow their
/// targets while those move, can be turned back mid-way, and never take a touch.
///
/// ImagePreview: a photo viewer that opens from the thumbnail you tapped and closes back into it.
/// iPhone, iPad, Mac (Catalyst and AppKit) and Vision Pro, with a SwiftUI and a UIKit/AppKit API.
let package = Package(
    name: "Flight",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14), .visionOS(.v1)],
    products: [
        .library(name: "Flight", targets: ["Flight"]),
        .library(name: "ImagePreview", targets: ["ImagePreview"]),
    ],
    targets: [
        .target(name: "Flight", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "ImagePreview", dependencies: ["Flight"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "FlightTests", dependencies: ["Flight"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ImagePreviewTests", dependencies: ["ImagePreview"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
