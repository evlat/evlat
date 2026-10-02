import XCTest
@testable import EvlatCore

/// The CESP pack's pure parts: reading a pack and picking its lines. No
/// audio is opened here. From PR #8 (gabeperez), without its hook-event
/// mapping: Evlat speaks at its own moments.
final class SoundPackTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/packs/fairy")
    private let size: (URL) -> Int? = { _ in 1000 }

    private func manifest(_ categories: [String: Any], extra: [String: Any] = [:]) -> [String: Any] {
        ["cesp_version": "1.0", "name": "fairy", "display_name": "Fairy", "version": "1.0.0",
         "categories": categories].merging(extra) { $1 }
    }

    private func sounds(_ files: String...) -> [String: Any] {
        ["sounds": files.map { ["file": $0, "label": $0] }]
    }

    // MARK: - Reading

    func testAPackKeepsItsCategoriesAndNames() throws {
        let pack = try XCTUnwrap(SoundPack.parse(manifest([
            "session.start": sounds("sounds/Hey.wav", "sounds/Hello.wav"),
            "task.complete": sounds("sounds/Listen.wav"),
        ]), directory: root, fileSize: size))
        XCTAssertEqual(pack.name, "fairy")
        XCTAssertEqual(pack.displayName, "Fairy")
        XCTAssertEqual(pack.sounds[.sessionStart]?.map(\.label), ["sounds/Hey.wav", "sounds/Hello.wav"])
        XCTAssertEqual(pack.sounds[.taskComplete]?.first?.file.path, "/packs/fairy/sounds/Listen.wav")
        XCTAssertNil(pack.sounds[.taskError], "a pack fills any subset")
    }

    /// The spec's file rules (3.1, 4.2, 4.3): nothing outside the pack, no
    /// odd names, nothing empty or over 1 MB. The rest still plays.
    func testFilesThatBreakTheRulesAreLeftOut() throws {
        let sizes: [String: Int] = ["/packs/fairy/sounds/big.wav": 2_000_000, "/packs/fairy/sounds/empty.wav": 0]
        let pack = try XCTUnwrap(SoundPack.parse(manifest([
            "task.complete": sounds("../secrets.wav", "/etc/passwd", "sounds/a b.wav", "sounds/big.wav",
                                    "sounds/empty.wav", "sounds/ok.wav"),
        ]), directory: root, fileSize: { sizes[$0.path] ?? 1000 }))
        XCTAssertEqual(pack.sounds[.taskComplete]?.map(\.label), ["sounds/ok.wav"])
    }

    func testOnlyCESPOneWithAValidNameIsAPack() {
        XCTAssertNil(SoundPack.parse(manifest([:], extra: ["cesp_version": "2.0"]), directory: root, fileSize: size))
        XCTAssertNil(SoundPack.parse(manifest([:], extra: ["name": "Bad Name"]), directory: root, fileSize: size))
        XCTAssertNil(SoundPack.parse(["name": "x"], directory: root, fileSize: size))
        XCTAssertEqual(SoundPack.parse(manifest([:], extra: ["display_name": ""]), directory: root,
                                       fileSize: size)?.displayName, "fairy", "no display name: its name")
    }

    /// Legacy names a pack maps (section 6) land on the spec's category;
    /// unknown categories are ignored, never invented.
    func testAliasesAreFollowedAndUnknownCategoriesIgnored() throws {
        let pack = try XCTUnwrap(SoundPack.parse(manifest([
            "greeting": sounds("sounds/Hey.wav"), "dance.party": sounds("sounds/x.wav"),
        ], extra: ["category_aliases": ["greeting": "session.start"]]), directory: root, fileSize: size))
        XCTAssertEqual(pack.sounds.keys.map(\.rawValue), ["session.start"])
    }

    func testPacksLiveWhereTheSpecSays() {
        XCTAssertEqual(SoundPack.directory(home: URL(fileURLWithPath: "/h")).path, "/h/.openpeon/packs")
    }

    // MARK: - Picking and pacing

    private func pack(_ counts: [SoundPack.Category: Int]) -> SoundPack {
        var sounds: [SoundPack.Category: [SoundPack.Sound]] = [:]
        for (category, count) in counts {
            sounds[category] = (0..<count).map {
                SoundPack.Sound(file: root.appendingPathComponent("\(category.rawValue)-\($0).wav"), label: "\($0)")
            }
        }
        return SoundPack(name: "fairy", displayName: "Fairy", directory: root, sounds: sounds)
    }

    /// Never the same file twice in a row (8.1), with more than one to choose.
    func testTheSameLineDoesNotPlayTwiceInARow() {
        var picker = SoundPicker()
        let pack = pack([.taskComplete: 2])
        var last: URL?
        for _ in 0..<6 {
            let sound = picker.pick(.taskComplete, from: pack, random: { _ in 0 })
            XCTAssertNotNil(sound)
            XCTAssertNotEqual(sound?.file, last)
            last = sound?.file
        }
    }

    func testAOneLineMomentRepeatsItsLine() {
        var picker = SoundPicker()
        let pack = pack([.taskError: 1])
        XCTAssertEqual(picker.pick(.taskError, from: pack)?.label, "0")
        XCTAssertEqual(picker.pick(.taskError, from: pack)?.label, "0")
    }

    func testAMissingCategoryIsSilent() {
        var picker = SoundPicker()
        XCTAssertNil(picker.pick(.taskError, from: pack([.taskComplete: 1])))
    }

    /// A line's label is what it says; without one the file's name stands
    /// in, and says so.
    func testALineWithoutALabelIsMarked() throws {
        let pack = try XCTUnwrap(SoundPack.parse(manifest([
            "task.complete": ["sounds": [["file": "sounds/Done.wav", "label": "Jobs done!"],
                                         ["file": "sounds/Peon2.wav"]]],
        ]), directory: root, fileSize: size))
        XCTAssertEqual(pack.sounds[.taskComplete]?.map(\.label), ["Jobs done!", "Peon2.wav"])
        XCTAssertEqual(pack.sounds[.taskComplete]?.map(\.hasLabel), [true, false])
    }
}

/// The OpenPeon registry's index, and the URLs a pack is fetched from.
final class SoundRegistryTests: XCTestCase {
    private func index(_ packs: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "packs": packs])
    }

    private func pack(_ name: String, tier: String = "community", repo: String = "Someone/packs",
                      path: String = "fairy", sha: String = String(repeating: "a", count: 64)) -> [String: Any] {
        ["name": name, "display_name": name.capitalized, "description": "A \(name) pack",
         "author": ["name": "Someone"], "license": "CC-BY-NC-4.0", "tags": ["gaming"],
         "sound_count": 3, "total_size_bytes": 1000, "trust_tier": tier,
         "source_repo": repo, "source_ref": "v1.0.0", "source_path": path,
         "manifest_sha256": sha, "preview_sounds": ["Hey.wav"]]
    }

    func testTheIndexIsReadOfficialFirst() {
        let entries = SoundRegistry.entries(from: index([pack("zelda"), pack("bravo", tier: "official"), pack("alpha")]))
        XCTAssertEqual(entries.map(\.name), ["bravo", "alpha", "zelda"])
        XCTAssertEqual(entries.first?.author, "Someone")
        XCTAssertEqual(entries.first?.license, "CC-BY-NC-4.0")
    }

    /// An entry that could point a download elsewhere is not a pack.
    func testAnEntryThatLeavesItsPackIsDropped() {
        let bad = [pack("one", repo: "../evil"), pack("two", repo: "a/b/c"), pack("three", path: "../x"),
                   pack("four", path: "/etc"), pack("five", sha: "nothex"), pack("Six Bad")]
        XCTAssertEqual(SoundRegistry.entries(from: index(bad)), [])
        XCTAssertEqual(SoundRegistry.entries(from: Data("nope".utf8)), [])
    }

    func testFilesAreFetchedRawFromThePinnedRef() throws {
        let entry = try XCTUnwrap(SoundRegistry.entries(from: index([pack("fairy")])).first)
        XCTAssertEqual(SoundRegistry.manifestURL(entry)?.absoluteString,
                       "https://raw.githubusercontent.com/Someone/packs/v1.0.0/fairy/openpeon.json")
        XCTAssertEqual(SoundRegistry.previewURL(entry)?.absoluteString,
                       "https://raw.githubusercontent.com/Someone/packs/v1.0.0/fairy/sounds/Hey.wav")
        XCTAssertNil(SoundRegistry.url(of: "../secret", in: entry))
        XCTAssertNil(SoundRegistry.url(of: "/etc/passwd", in: entry))
    }

    func testSearchFindsEveryWord() {
        let entries = SoundRegistry.entries(from: index([pack("navi"), pack("peon")]))
        XCTAssertEqual(SoundRegistry.search(entries, "NAVI").map(\.name), ["navi"])
        XCTAssertEqual(SoundRegistry.search(entries, "pack gaming").count, 2)
        XCTAssertEqual(SoundRegistry.search(entries, "  ").count, 2)
        XCTAssertEqual(SoundRegistry.search(entries, "navi peon").count, 0)
    }

    /// The files a manifest names, each once, none outside the pack.
    func testAManifestsFilesAreItsOwn() {
        let sha = String(repeating: "b", count: 64)
        let manifest: [String: Any] = ["categories": [
            "task.complete": ["sounds": [["file": "sounds/Done.wav", "sha256": sha], ["file": "../x.wav"]]],
            "session.start": ["sounds": [["file": "sounds/Done.wav"], ["file": "sounds/Hi.mp3", "sha256": "short"]]],
        ]]
        let files = SoundRegistry.files(in: manifest)
        XCTAssertEqual(files.map(\.path), ["sounds/Done.wav", "sounds/Hi.mp3"])
        XCTAssertEqual(files.first?.sha256, sha)
        XCTAssertNil(files.last?.sha256, "a malformed sum is no sum")
    }
}
