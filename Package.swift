// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// ONNX Runtime ships as a dylib plus C headers under vendor/, populated by
// Scripts/fetch-onnxruntime.sh. It is linked directly rather than through the
// official Swift package, which exposes only the Objective-C API — and that API
// has no Bool tensor type, while Moonshine's merged decoder requires a Bool
// `use_cache_branch` input.
let ortLinkerFlags: [String] = [
    "-L\(packageRoot)/vendor/onnxruntime/lib",
    // The packaged .app resolves the dylib from Contents/Frameworks. Dev builds
    // land at varying depths under .build, so they get an absolute rpath into
    // vendor/ instead of a guessed relative one; Scripts/make-app.sh strips
    // that absolute entry from the shipped binary.
    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    "-Xlinker", "-rpath", "-Xlinker", "\(packageRoot)/vendor/onnxruntime/lib",
]

// The app relies on main-thread callbacks and opaque ONNX Runtime handles that
// Swift 6 strict concurrency checking cannot verify, so targets stay on the
// Swift 5 language mode.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OpenWhisperFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenWhisperFlow", targets: ["OpenWhisperFlow"]),
        .executable(name: "mstest", targets: ["mstest"]),
        .library(name: "MoonshineKit", targets: ["MoonshineKit"]),
        .library(name: "DictationCore", targets: ["DictationCore"]),
        .library(name: "TranscriptionEngines", targets: ["TranscriptionEngines"]),
    ],
    dependencies: [
        // Whisper via CoreML. Whisper on the Neural Engine is both more
        // accurate and faster than running it on the CPU through ONNX Runtime,
        // and WhisperKit brings its own mel front end, tokenizer and chunking.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        .systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime"),

        // Speech-to-text: ONNX Runtime bridging, the Moonshine decode loop,
        // tokenizer, audio helpers, and the model downloader.
        .target(
            name: "MoonshineKit",
            dependencies: ["COnnxRuntime"],
            path: "Sources/MoonshineKit",
            swiftSettings: swift5Mode,
            linkerSettings: [.unsafeFlags(ortLinkerFlags)]
        ),

        // Hotkey semantics and preferences, kept free of AppKit so the timing
        // rules can be unit tested without a window server or permissions.
        .target(
            name: "DictationCore",
            path: "Sources/DictationCore",
            swiftSettings: swift5Mode
        ),

        // The selectable speech engines behind one protocol: Apple's built-in
        // transcriber, Whisper through CoreML, and Moonshine through ONNX.
        .target(
            name: "TranscriptionEngines",
            dependencies: [
                "MoonshineKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/TranscriptionEngines",
            swiftSettings: swift5Mode
        ),

        .executableTarget(
            name: "OpenWhisperFlow",
            dependencies: ["MoonshineKit", "DictationCore", "TranscriptionEngines"],
            path: "Sources/OpenWhisperFlow",
            swiftSettings: swift5Mode
        ),

        // Transcribes a WAV from the command line, for checking a model
        // without granting any permissions.
        .executableTarget(
            name: "mstest",
            dependencies: ["MoonshineKit"],
            path: "Tools/mstest",
            swiftSettings: swift5Mode
        ),

        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"],
            path: "Tests/DictationCoreTests",
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "TranscriptionEnginesTests",
            dependencies: ["TranscriptionEngines"],
            path: "Tests/TranscriptionEnginesTests",
            swiftSettings: swift5Mode
        ),
        .testTarget(
            name: "MoonshineKitTests",
            dependencies: ["MoonshineKit"],
            path: "Tests/MoonshineKitTests",
            swiftSettings: swift5Mode
        ),
    ]
)
