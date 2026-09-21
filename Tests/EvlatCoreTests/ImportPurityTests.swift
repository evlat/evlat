import XCTest

/// `EvlatCore`'un import yüzeyini bekçileyen **tripwire**.
///
/// Bunun bir KANIT olmadığını bilerek yazıyoruz: macOS'ta `Foundation` Darwin'i
/// yeniden ihraç eder, dolayısıyla `sysctl`, `kill`, `open` yalnız `Foundation`
/// import eden bir dosyadan da çağrılabilir ve bu sınama onu **göremez**.
/// Karşı örnek gerçek: v1'in `Sources/Evlat/Sessions/SessionHost.swift`'i tek
/// başına `Foundation` import eder, `kinfo_proc`/`CTL_KERN`/`sysctl` kullanır
/// ve Linux'ta derlenmez.
///
/// Taşınabilirliğin gerçek kapısı bu yüzden mekanizmadır, sınama değil:
/// platform yeteneği `Platform` üstünden **enjekte edilir**. Bu sınamanın işi
/// yalnız kaba kaçağı — `import AppKit` gibi — commit'e girmeden yakalamak.
final class ImportPurityTests: XCTestCase {
    /// İzin verilenler. Liste **allowlist**: yasak listesi eksik kalırdı
    /// (`Combine` ve `os.log` Linux'ta yok ama "AppKit değil" diye geçerdi).
    private static let allowed: Set<String> = ["Foundation", "Dispatch"]

    private var coreRoot: URL {
        // Tests/EvlatCoreTests/ImportPurityTests.swift → depo kökü → Sources/EvlatCore
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EvlatCore")
    }

    /// Yalnız platform kabuğu deyimi muaftır: `#if canImport(Darwin)` /
    /// `#else` `import Glibc`. Keyfi bir modülü `canImport` ardına saklamak
    /// muafiyet değil, kaçaktır — ilk sürüm `#if canImport(AppKit)` yazan bir
    /// dosyayı sessizce geçiriyordu (kapıda yakalandı).
    private static let shimModules: Set<String> = ["Darwin", "Glibc", "WinSDK", "Musl"]

    func testCoreImportsOnlyAllowedModules() throws {
        let files = try swiftFiles()
        XCTAssertFalse(files.isEmpty, "EvlatCore kaynağı bulunamadı: \(coreRoot.path)")

        var violations: [String] = []
        for file in files {
            // Yorumlar burada da ayıklanır. Bu depoda yorumlar "neden BUNU
            // yapmıyoruz"u anlatıyor ve `// import AppKit` yazan bir satır ham
            // taramada ihlal sayılıyordu.
            let text = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for (index, module) in Self.imports(in: text) {
                guard !Self.allowed.contains(module) else { continue }
                violations.append("\(file.lastPathComponent):\(index + 1) → import \(module)")
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            EvlatCore yalnız \(Self.allowed.sorted().joined(separator: ", ")) import eder.
            İhlaller:
            \(violations.joined(separator: "\n"))
            Platforma özgü yetenek EvlatCore'a import edilmez, Platform ile enjekte edilir.
            """)
    }

    /// Yorumsuz kaynaktan `(satır, modül)` çiftleri. Muaf blokların içindeki
    /// satırlar atlanır.
    ///
    /// Import satırı üç şekilde yazılabiliyor ve üçü de yakalanmalı:
    /// `import AppKit`, `@_exported import AppKit`, `public import AppKit`.
    /// Ayrıca `import struct Foundation.Data` biçiminde **tür belirteci**
    /// gelebilir (`struct`, `class`, `func`, …) — modül adı ondan sonrakidir.
    static func imports(in source: String) -> [(Int, String)] {
        let kindKeywords: Set<String> = ["struct", "class", "enum", "protocol",
                                         "typealias", "func", "let", "var", "actor"]
        var out: [(Int, String)] = []
        var stack: [Bool] = []   // true = muaf (platform kabuğu) blok

        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#if") || line.hasPrefix("#elseif") {
                let exempt = Self.shimModules.contains { line.contains("canImport(\($0))") }
                if line.hasPrefix("#if") { stack.append(exempt) }
                else if !stack.isEmpty { stack[stack.count - 1] = exempt }
                continue
            }
            if line.hasPrefix("#else") {
                // `#else` dalı da kabuk sayılır: `#if canImport(Darwin) … #else import Glibc`
                if !stack.isEmpty, stack[stack.count - 1] { stack[stack.count - 1] = true }
                continue
            }
            // HER `#endif` bir blok kapatır. İlk sürüm yalnız `#if canImport`
            // için derinlik açıp her `#endif`te kapatıyordu; içteki `#if DEBUG`
            // muafiyeti erken bitiriyordu (kapıda yakalandı).
            if line.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if stack.contains(true) { continue }

            var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Öneki at: @_exported, @testable, public, internal, …
            while let first = tokens.first, first != "import" { tokens.removeFirst() }
            guard tokens.first == "import", tokens.count >= 2 else { continue }
            tokens.removeFirst()
            if kindKeywords.contains(tokens[0]), tokens.count >= 2 { tokens.removeFirst() }
            let module = tokens[0]
                .components(separatedBy: CharacterSet(charactersIn: " ."))
                .first ?? tokens[0]
            out.append((index, module))
        }
        return out
    }

    /// `EvlatCore` Darwin'i import etmeden de çağırabilir; kaba kaçakları
    /// adıyla arıyoruz. Bu da tripwire — tam liste değil.
    func testCoreDoesNotCallDarwinDirectly() throws {
        let markers = ["sysctl", "kinfo_proc", "kill(", "CTL_KERN", "DispatchSource.makeFileSystemObjectSource"]
        var violations: [String] = []
        for file in try swiftFiles() {
            // Yorumlar ayıklanır: bu dosyaların yorumları tam olarak bu
            // API'lerin NEDEN burada olmadığını anlatıyor ve ham metin taraması
            // onları ihlal sanıyordu (ölçüldü — Platform.swift'in kendi yorumu).
            let text = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for marker in markers where text.contains(marker) {
                violations.append("\(file.lastPathComponent) → \(marker)")
            }
        }
        XCTAssertTrue(violations.isEmpty, """
            EvlatCore Darwin çağırmaz; bu yetenekler Platform ile enjekte edilir.
            İhlaller: \(violations.joined(separator: ", "))
            """)
    }

    private func swiftFiles() throws -> [URL] {
        guard let e = FileManager.default.enumerator(at: coreRoot, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Satır (`//`) ve blok (`/* */`) yorumlarını boşlukla değiştirir.
    /// Dizge içindeki `//` yanlışlıkla yorum sayılmasın diye tırnak durumu izlenir.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var inLineComment = false, inBlockComment = false, inString = false
        var previous: Character = " "
        var iterator = Array(source)
        var i = 0
        while i < iterator.count {
            let c = iterator[i]
            let next: Character? = i + 1 < iterator.count ? iterator[i + 1] : nil

            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
            } else if inBlockComment {
                if c == "*", next == "/" { inBlockComment = false; i += 1 }
            } else if inString {
                if c == "\"", previous != "\\" { inString = false }
                out.append(c)
            } else if c == "/", next == "/" {
                inLineComment = true; i += 1
            } else if c == "/", next == "*" {
                inBlockComment = true; i += 1
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            previous = c
            i += 1
        }
        return out
    }

}
