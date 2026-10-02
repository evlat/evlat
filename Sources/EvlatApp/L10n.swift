import Foundation

/// The user-visible text: `Resources/{language}.lproj/Evlat.strings`.
///
/// A narrow port of v1's `Localization/Catalog.swift`. The language is the
/// system's unless one is chosen in Settings (`LanguageChoice`).
///
/// The tables sit outside SwiftPM on purpose. `Bundle.module`'s accessor did
/// not read the copy inside the packaged app and hit `fatalError` when
/// `.build` was gone (measured in v1). The table is named `Evlat`, not
/// `Localizable`: a stray `Text("status.idle")` would be resolved by SwiftUI
/// against `Localizable` in the package and show the key in development; under
/// this name nothing resolves it anywhere, so the mistake looks the same
/// everywhere.
struct Catalog {
    static let source = "en"
    static let table = "Evlat"

    /// language → key → text
    let tables: [String: [String: String]]
    /// The source language first, the rest alphabetical. A new language is a
    /// new `lproj` folder; no code changes. Ordered because
    /// `Bundle.preferredLocalizations` returns the **first** entry when
    /// nothing matches, and that has to be the source.
    let available: [String]

    static let placeholderPattern = "\\{[A-Za-z][A-Za-z0-9]*\\}"
    private static let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern)

    init(tables: [String: [String: String]]) {
        self.tables = tables
        // `false` for equal elements too: `a == source || …` answered `true`
        // for the source against itself, which is not a valid ordering.
        available = tables.keys.sorted { a, b in
            a == Self.source ? b != Self.source : (b != Self.source && a < b)
        }
    }

    /// Reads every `*.lproj/Evlat.strings` under `root`. One broken line drops
    /// the whole table (measured in v1: a missing semicolon), so an unreadable
    /// file is logged rather than skipped quietly. `bundle-app.sh` lints the
    /// tables before packaging for the same reason.
    init(root: URL?) {
        var tables: [String: [String: String]] = [:]
        let fm = FileManager.default
        if let root, let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for dir in items where dir.pathExtension == "lproj" {
                let url = dir.appendingPathComponent("\(Self.table).strings")
                guard fm.fileExists(atPath: url.path) else { continue }
                guard let data = try? Data(contentsOf: url),
                      let table = try? PropertyListSerialization
                          .propertyList(from: data, format: nil) as? [String: String] else {
                    NSLog("Evlat: string table unreadable: %@", url.path)
                    continue
                }
                tables[dir.deletingPathExtension().lastPathComponent] = table
            }
        }
        self.init(tables: tables)
    }

    /// A language's name in that language ("Deutsch", "日本語"): the same
    /// in every table, so it is read from its own.
    func name(of language: String) -> String {
        tables[language]?["language.name"] ?? language
    }

    /// The first of the system's languages there is a table for, else the
    /// source. Measured: `en-TR` → en, `tr-TR` → tr, `it-IT` → en, `pt-PT` →
    /// pt-BR, `zh-TW` → zh-Hant.
    func resolve(preferred: [String]) -> String {
        Bundle.preferredLocalizations(from: available, forPreferences: preferred).first
            ?? Self.source
    }

    /// The language asked for → the source language → the key itself. The key
    /// on screen is ugly on purpose: a quiet blank would hide the mistake.
    func text(_ key: String, in language: String, _ values: [String: String] = [:]) -> String {
        guard let raw = tables[language]?[key] ?? tables[Self.source]?[key] else {
            NSLog("Evlat: no catalogue key: %@", key)
            return key
        }
        return Self.fill(raw, values)
    }

    /// Fills `{name}` placeholders. One with no value stays as it is — `{…}`
    /// on screen is a visible translation bug, not a silent one.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        // Most texts have no placeholder and never reach the pattern.
        guard text.contains("{"), let pattern = placeholderRegex else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: NSRange(location: match.range.location + 1,
                                                  length: match.range.length - 2))
            out += values[name] ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// The app's catalogue and language. The catalogue is read once; the
/// language is resolved at launch from the system's list — which already
/// carries a choice made in Settings or in System Settings, both the same
/// value (`LanguageChoice`) — and written again only when Settings changes
/// it (`AppController.setLanguage`).
enum L10n {
    static let catalog = Catalog(root: root())

    /// The language the text is drawn in now. Written on the main thread;
    /// held under a lock because a `String` is not read atomically and
    /// nothing promises every reader is on the main thread.
    static var language: String {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    private static var current = catalog.resolve(preferred: Locale.preferredLanguages)

    static func t(_ key: String, _ values: [String: String] = [:], in lang: String = language) -> String {
        catalog.text(key, in: lang, values)
    }

    /// Inside the app, `Contents/Resources` only: the development path must
    /// not mask a copy missing from the package. Outside it (`swift run`,
    /// `swift test`) the repository's `Resources/`, in DEBUG builds only;
    /// `bundle-app.sh` builds release, so that path never reaches the package.
    /// Walking up from the executable lands in `.build` under `swift run`
    /// (measured in v1), so the source file's own path is used instead.
    static func root() -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.resourceURL }
        #if DEBUG
        return URL(fileURLWithPath: #filePath)   // …/Sources/EvlatApp/L10n.swift
            .deletingLastPathComponent()         // EvlatApp
            .deletingLastPathComponent()         // Sources
            .deletingLastPathComponent()         // repository root
            .appendingPathComponent("Resources")
        #else
        return nil
        #endif
    }
}

/// Evlat's language, kept where macOS keeps any app's own: `AppleLanguages`
/// in the app's domain, the key macOS's per-app language uses (System
/// Settings → General → Language & Region → Applications; that Evlat is
/// listed there was not measured). The parts Evlat does not draw (Sparkle's
/// window, a text field's menu) follow it from the next launch. Measured: written to
/// the app's domain it is the process's `Locale.preferredLanguages` at the
/// next launch, and the global domain keeps the system's list beside it.
enum LanguageChoice {
    static let key = "AppleLanguages"

    /// The language chosen, as a table's name; `nil`: the system's. Read
    /// from the app's own domain only — the merged value always has one.
    static func read(_ defaults: UserDefaults, domain: String, catalog: Catalog) -> String? {
        guard let first = (defaults.persistentDomain(forName: domain)?[key] as? [String])?.first else {
            return nil
        }
        return catalog.resolve(preferred: [first])
    }

    /// `nil` removes the choice: the system's list shows through again.
    static func write(_ language: String?, to defaults: UserDefaults) {
        if let language { defaults.set([language], forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// The system's own list, under any choice of Evlat's.
    static func systemLanguages(_ defaults: UserDefaults) -> [String] {
        defaults.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
            ?? Locale.preferredLanguages
    }

    /// What the text is drawn in for a choice.
    static func resolve(_ choice: String?, system: [String], catalog: Catalog) -> String {
        if let choice, catalog.tables[choice] != nil { return choice }
        return catalog.resolve(preferred: system)
    }
}
