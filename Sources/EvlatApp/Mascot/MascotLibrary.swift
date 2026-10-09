import Foundation
import EvlatCore
import EvlatAgents

/// The characters found on disk, offered beside the ones Evlat ships
/// (`MascotCharacters`).
///
/// Read from two kinds of folder, one character a subfolder: Evlat's own,
/// `~/.config/evlat/mascots/`, where the user puts what they want drawn, and
/// each agent's pets folder (`Agent.pets`), whose pets appear without being
/// copied. A subfolder is a character written as a file (`CharacterFile`,
/// `character.json`) or a pet (`PetAtlas`, `pet.json`); the file first when
/// both are there. Every one found is held
/// to the contract (`MascotContract`); one that cannot be read or breaks it
/// is left out and said why (`failures`), never drawn half-right.
///
/// Read when asked — at launch and when Settings → Mascot opens — never
/// watched, and only the folders and the pictures' sizes: a picture's
/// pixels wait until it is drawn (`MascotSheet`). Evlat writes nothing in
/// these folders; the one it makes is its own, empty, when the user asks to
/// open it.
struct MascotLibrary: Equatable {
    /// One folder of characters, and the prefix its characters' ids carry
    /// (`<prefix>:<subfolder>`), so a found one never takes a shipped
    /// character's id, nor one of another folder's.
    struct Source: Equatable {
        let prefix: String
        let folder: URL
    }

    /// A subfolder that is not offered, and why.
    struct Failure: Hashable {
        let source: String
        let folder: String
        let reason: Reason
    }

    enum Reason: Hashable {
        /// Neither a `character.json` nor a `pet.json`.
        case empty
        case file(CharacterFile.Failure)
        case pet(PetAtlas.Failure)
        /// Read, but it breaks the contract: the first rule it breaks.
        case contract(String)
    }

    private(set) var characters: [MascotCharacter] = []
    private(set) var failures: [Failure] = []

    /// Evlat's own folder under `home`.
    static func folder(home: URL) -> URL {
        home.appendingPathComponent(".config/evlat/mascots", isDirectory: true)
    }

    /// The prefix of Evlat's own folder's characters.
    static let ownPrefix = "evlat"

    /// Evlat's own folder, then each agent's pets, under `home`.
    static func sources(home: URL, agents: [any Agent] = Agents.all) -> [Source] {
        [Source(prefix: ownPrefix, folder: folder(home: home))]
            + agents.compactMap { agent in
                agent.pets.map { Source(prefix: agent.id.rawValue, folder: home.appendingPathComponent($0)) }
            }
    }

    /// What the sources hold now, in their order and each folder's by name.
    /// A source that is not there holds nothing.
    static func read(_ sources: [Source]) -> MascotLibrary {
        var library = MascotLibrary()
        for source in sources {
            let found = (try? FileManager.default.contentsOfDirectory(
                at: source.folder, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            let folders = found.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for folder in folders {
                let name = folder.lastPathComponent
                switch character(in: folder, id: source.prefix + ":" + name) {
                case .success(let character): library.characters.append(character)
                case .failure(let reason):
                    library.failures.append(Failure(source: source.prefix, folder: name, reason: reason))
                }
            }
        }
        return library
    }

    /// The character in one folder, held to the contract, or why not.
    static func character(in folder: URL, id: String) -> Result<MascotCharacter, Reason> {
        switch read(in: folder, id: id) {
        case .failure(let reason): return .failure(reason)
        case .success(var character):
            if let broken = MascotContract.violations(of: character).first { return .failure(.contract(broken)) }
            // A found character is in no string table: a file that names
            // nobody is called by its folder.
            if character.name?.isEmpty != false { character.name = folder.lastPathComponent }
            return .success(character)
        }
    }

    /// The character in one folder as its file says, before the contract:
    /// what `MascotCheck` holds to every rule at once.
    static func read(in folder: URL, id: String) -> Result<MascotCharacter, Reason> {
        let exists = { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let character: MascotCharacter
        do {
            if exists(CharacterFile.name) {
                character = try CharacterFile.character(in: folder, id: id)
            } else if exists(PetAtlas.manifestName) {
                character = try PetAtlas.character(in: folder, id: id)
            } else {
                return .failure(.empty)
            }
        } catch let failure as CharacterFile.Failure {
            return .failure(.file(failure))
        } catch let failure as PetAtlas.Failure {
            return .failure(.pet(failure))
        } catch {
            return .failure(.empty)
        }
        return .success(character)
    }
}

extension MascotLibrary.Reason: Error {}
