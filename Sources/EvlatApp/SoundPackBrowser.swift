import AppKit
import CryptoKit
import SwiftUI
import EvlatCore

/// Settings → Mascot → Who speaks? → More characters…: the OpenPeon
/// registry's characters, searched, heard and installed into
/// `~/.openpeon/packs` under `home`. From PR #8 (gabeperez).
///
/// An install is checked end to end before anything lands: the manifest
/// against the index's sha256, each sound against the manifest's (when it
/// gives one), each file under 1 MB and the pack under 50 MB (CESP 4.2). It
/// is assembled in a temporary folder and moved into place whole, so a
/// failed install leaves nothing half-written. Evlat downloads only here,
/// only when asked, and never in an isolated process (`AppController`).
@MainActor
final class SoundPackBrowser: ObservableObject {
    enum Loading: Equatable { case idle, loading, failed }

    @Published private(set) var entries: [SoundRegistry.Entry] = []
    @Published private(set) var loading = Loading.idle
    @Published var query = ""
    /// The character being installed, and the ones that failed.
    @Published private(set) var installing: String?
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var installed: Set<String> = []

    let home: URL
    /// The voice in use, its writer, and the remover (to the Trash).
    var voice: () -> SoundVoice = { .evlat }
    var use: (String) -> Void = { _ in }
    var remove: (String) -> Void = { _ in }
    private var preview: NSSound?

    init(home: URL) {
        self.home = home
        refreshInstalled()
    }

    var shown: [SoundRegistry.Entry] { SoundRegistry.search(entries, query) }

    func load() {
        refreshInstalled()
        guard loading != .loading, entries.isEmpty else { return }
        loading = .loading
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: SoundRegistry.index)
                entries = SoundRegistry.entries(from: data)
                loading = entries.isEmpty ? .failed : .idle
            } catch {
                loading = .failed
            }
        }
    }

    func refreshInstalled() {
        installed = Set(SoundPack.installed(in: SoundPack.directory(home: home)).map(\.name))
    }

    /// A character whose previews are all in a format this Mac cannot play
    /// (Ogg) is shown but not offered: installed, it would never speak.
    nonisolated static func plays(_ entry: SoundRegistry.Entry) -> Bool {
        entry.previews.isEmpty || entry.previews.contains(where: AudioSupport.canPlay)
    }

    func playPreview(_ entry: SoundRegistry.Entry) {
        guard Self.plays(entry),
              let name = entry.previews.first(where: AudioSupport.canPlay),
              let url = SoundRegistry.url(of: "sounds/\(name)", in: entry) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), data.count <= 1_048_576,
                  let sound = NSSound(data: data) else { return }
            preview?.stop()
            sound.volume = SoundPlayer.volume
            preview = sound
            sound.play()
        }
    }

    func install(_ entry: SoundRegistry.Entry) {
        guard installing == nil else { return }
        installing = entry.name
        failed.remove(entry.name)
        let root = SoundPack.directory(home: home)
        Task {
            let ok = await Self.install(entry, into: root)
            installing = nil
            if ok { refreshInstalled() } else { failed.insert(entry.name) }
        }
    }

    func removeInstalled(_ name: String) {
        remove(name)
        refreshInstalled()
    }

    /// Whether it landed whole.
    nonisolated static func install(_ entry: SoundRegistry.Entry, into root: URL) async -> Bool {
        guard let manifestURL = SoundRegistry.manifestURL(entry),
              let (manifestData, _) = try? await URLSession.shared.data(from: manifestURL),
              sha256(manifestData) == entry.manifestSHA256,
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            return false
        }
        let files = SoundRegistry.files(in: manifest)
        guard !files.isEmpty else { return false }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-pack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var total = manifestData.count
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try manifestData.write(to: staging.appendingPathComponent("openpeon.json"))
            for file in files {
                guard let url = SoundRegistry.url(of: file.path, in: entry) else { continue }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                guard data.count <= 1_048_576 else { return false }
                if let expected = file.sha256, sha256(data) != expected { return false }
                total += data.count
                guard total <= SoundRegistry.maxPackBytes else { return false }
                let target = staging.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: target)
            }
            guard let read = SoundPack.read(directory: staging, isPlayable: AudioSupport.canPlay),
                  !read.sounds.isEmpty else { return false }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(entry.name, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The characters sheet (mockup 4): search, then one row per character —
/// its initial, name and what it is, its licence, ▶, and Install, Use or
/// Remove.
struct SoundPackBrowserView: View {
    @ObservedObject var browser: SoundPackBrowser
    let t: (String, [String: String]) -> String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("packs.title", [:])).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsPalette.ink)
                Text(t("packs.intro", [:])).font(.system(size: 12)).foregroundStyle(SettingsPalette.body)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(t("packs.search", [:]), text: $browser.query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Rectangle().fill(SettingsPalette.paneLine).frame(height: 1)
            Group {
                switch browser.loading {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    VStack(spacing: 8) {
                        Text(t("packs.failed", [:])).font(.system(size: 12)).foregroundStyle(SettingsPalette.muted)
                        Button(t("packs.retry", [:])) { browser.load() }.buttonStyle(SmallButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .idle:
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(browser.shown) { entry in
                                row(entry)
                                Rectangle().fill(SettingsPalette.rowLine).frame(height: 1)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
            Rectangle().fill(SettingsPalette.paneLine).frame(height: 1)
            HStack(spacing: 12) {
                Text(t("packs.note", [:])).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(t("packs.done", [:]), action: close)
                    .buttonStyle(SmallButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 520, height: 560)
        .background(SettingsPalette.pane)
        .onAppear { browser.load() }
    }

    /// The columns stay put whatever a row offers: ▶ and the action sit in
    /// fixed widths, so an installed row's two controls do not push the rest.
    static let actionWidth: CGFloat = 112

    private func row(_ entry: SoundRegistry.Entry) -> some View {
        let plays = SoundPackBrowser.plays(entry)
        let installed = browser.installed.contains(entry.name)
        return HStack(spacing: 12) {
            VoiceInitial(name: entry.displayName, key: entry.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsPalette.ink)
                    .lineLimit(1).truncationMode(.tail)
                Text(subtitle(entry, installed: installed))
                    .font(.system(size: 11.5)).foregroundStyle(SettingsPalette.muted)
                    .lineLimit(1).truncationMode(.tail)
                if browser.failed.contains(entry.name) {
                    Text(t("packs.error", [:])).font(.system(size: 11.5)).foregroundStyle(SettingsPalette.warnInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only what is an exception gets a tag: that most packs are for
            // personal use, the footer says once.
            if !plays {
                NameTag(text: t("packs.unplayable", [:]), caution: true)
                    .help(t("packs.unplayable.help", [:]))
            }
            PlayButton(label: t("settings.mascot.play", [:]), enabled: plays && !entry.previews.isEmpty) {
                browser.playPreview(entry)
            }
            action(entry, plays: plays, installed: installed)
                .frame(width: Self.actionWidth, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 8)
    }

    /// What the character is, in a line: its description where it adds to
    /// the name (most only repeat it), how many sounds, and whether it is here.
    private func subtitle(_ entry: SoundRegistry.Entry, installed: Bool) -> String {
        let name = entry.displayName.lowercased()
        let description = entry.description.lowercased().contains(name) ? "" : entry.description
        return [installed ? t("packs.installed", [:]) : "", description,
                t("packs.count", ["count": String(entry.soundCount)])]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func action(_ entry: SoundRegistry.Entry, plays: Bool, installed: Bool) -> some View {
        if browser.installing == entry.name {
            ProgressView().controlSize(.small)
        } else if installed {
            HStack(spacing: 6) {
                if plays {
                    if browser.voice() == .pack(entry.name) {
                        Text(t("packs.inUse", [:])).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsPalette.ok)
                    } else {
                        Button(t("packs.use", [:])) { browser.use(entry.name); browser.objectWillChange.send() }
                            .buttonStyle(SmallButtonStyle())
                    }
                }
                Button { browser.removeInstalled(entry.name) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t("packs.remove.help", [:]))
                .accessibilityLabel(t("packs.remove", [:]))
            }
        } else {
            Button(t("packs.install", [:])) { browser.install(entry) }
                .buttonStyle(SmallButtonStyle())
                .disabled(browser.installing != nil || !plays)
        }
    }
}

/// A character's initial in a tile of its own colour, from its name: the
/// same character is always the same colour.
struct VoiceInitial: View {
    let name: String
    let key: String

    private static let tiles: [(Color, Color)] = [
        (Color(red: 0.93, green: 0.95, blue: 0.89), Color(red: 0.36, green: 0.42, blue: 0.16)),
        (Color(red: 0.95, green: 0.93, blue: 0.90), Color(red: 0.54, green: 0.42, blue: 0.18)),
        (Color(red: 0.91, green: 0.93, blue: 0.97), Color(red: 0.18, green: 0.36, blue: 0.56)),
        (Color(red: 0.96, green: 0.91, blue: 0.91), Color(red: 0.58, green: 0.25, blue: 0.18)),
        (Color(red: 0.93, green: 0.91, blue: 0.96), Color(red: 0.35, green: 0.27, blue: 0.56)),
    ]

    var body: some View {
        let tile = Self.tiles[Int(key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) % Self.tiles.count]
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tile.1)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(tile.0))
            .accessibilityHidden(true)
    }
}

/// ▶: a small round button, "Listen" to the ear and the pointer.
struct PlayButton: View {
    let label: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(SettingsPalette.ink)
                .frame(width: 24, height: 24)
                .background(Circle().fill(SettingsPalette.button))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
    }
}
