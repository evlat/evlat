// swift-tools-version:5.9
import PackageDescription

// Üç hedef, iki katman. `EvlatCore` ile `EvlatApp` ROADMAP'in iki katmanı;
// `Evlat` yalnız main.swift taşıyan ince kabuk. Kabuğun ayrı olmasının sebebi
// sınama: SPM'de yürütülebilir hedefin testi top-level kodla çakışabiliyor,
// oysa panelin yapılandırması (PanelConfigTests) kodla sınanmak zorunda.
//
// Katman yönü DERLEYİCİYLE kapalı: EvlatCore hiçbir şeye bağlı değil, yani
// `import EvlatApp` mümkün değil. Import sınaması bunun üstüne yalnız
// tripwire ekler (Tests/EvlatCoreTests/ImportPurityTests.swift).
let package = Package(
    name: "Evlat",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EvlatCore", path: "Sources/EvlatCore"),
        .target(name: "EvlatApp", dependencies: ["EvlatCore"], path: "Sources/EvlatApp"),
        .executableTarget(name: "Evlat", dependencies: ["EvlatApp"], path: "Sources/Evlat"),
        .testTarget(name: "EvlatCoreTests", dependencies: ["EvlatCore"], path: "Tests/EvlatCoreTests"),
        .testTarget(name: "EvlatAppTests", dependencies: ["EvlatApp"], path: "Tests/EvlatAppTests"),
    ],
    swiftLanguageVersions: [.v5]
)
