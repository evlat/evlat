/// Every character Evlat ships, each in its own folder beside this file.
///
/// A character enters by being listed here; the contract tests read this
/// list, so a folder that is not listed is a character nobody checks.
enum MascotCharacters {
    /// In the order the picker shows them.
    static let all: [MascotCharacter] = [Cube.character, Pati.character, Bit.character, Puf.character]

    /// Drawn when nothing is chosen.
    static let `default` = Cube.character

    /// The character with this id; the default for none, or for one no
    /// longer shipped — a stored choice outlives a character.
    static func character(id: String?) -> MascotCharacter {
        all.first { $0.id == id } ?? `default`
    }
}
