// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScreenTranslator",
    platforms: [.macOS("15.0")],
    targets: [
        // Header C của sherpa-onnx (giọng AI offline). Thư viện dựng sẵn nằm ở Vendor/sherpa-onnx (Scripts/fetch-sherpa.sh).
        .target(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        // Cầu nối C tới libchiaki (PS5 Remote Play nhúng). Thư viện dựng bởi Scripts/build-chiaki.sh vào Vendor/chiaki-ng/build.
        .target(name: "CChiakiBridge", path: "Sources/CChiakiBridge",
                cSettings: [.headerSearchPath("../../Vendor/chiaki-ng/lib/include"), .headerSearchPath("../../Vendor/chiaki-ng/build/lib/include"), .unsafeFlags(["-w"])]),
        .executableTarget(
            name: "ScreenTranslator",
            dependencies: ["CSherpaOnnx", "CChiakiBridge"],
            path: "Sources/ScreenTranslator",
            linkerSettings: [
                .unsafeFlags(["-LVendor/sherpa-onnx/lib", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("sherpa-onnx-c-api"),
                // libchiaki + phụ thuộc, liên kết tĩnh để app tự chứa (curl dùng bản của hệ điều hành).
                .unsafeFlags([
                    "Vendor/chiaki-ng/build/lib/libchiaki.a",
                    "Vendor/chiaki-ng/build/third-party/libjerasure.a",
                    "Vendor/chiaki-ng/build/third-party/libgf_complete.a",
                    "Vendor/chiaki-ng/build/third-party/nanopb/libprotobuf-nanopb.a",
                    "/opt/homebrew/opt/openssl@3/lib/libcrypto.a",
                    "/opt/homebrew/opt/json-c/lib/libjson-c.a",
                    "/opt/homebrew/opt/miniupnpc/lib/libminiupnpc.a",
                    "/opt/homebrew/opt/opus/lib/libopus.a",
                    "/opt/homebrew/opt/libevent/lib/libevent_core.a",
                ]),
                .linkedLibrary("curl"),
                .linkedFramework("CoreServices"),
            ]
        )
    ]
)
