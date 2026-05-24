// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetRec",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "MeetRec",
            path: "Sources/MeetRec",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
