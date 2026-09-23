import Foundation

/// The user-visible text: `Resources/{language}.lproj/Evlat.strings`.
///
/// A narrow port of v1's `Localization/Catalog.swift`. **Left behind:** the
/// language picker's parts (`languageKey`, a stored choice, `name(of:)`) —
/// there is no settings window yet, so the language is the system's.
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

    /// The first of the system's languages there is a table for, else the
    /// source. Measured in v1: `en-TR` → en, `tr-TR` → tr, `de-DE` → en.
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

/// The app's catalogue and language. Read once; the language is the system's
/// and is resolved once too — the bar has no language setting to follow.
enum L10n {
    static let catalog = Catalog(root: root())
    static let language = catalog.resolve(preferred: Locale.preferredLanguages)

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
