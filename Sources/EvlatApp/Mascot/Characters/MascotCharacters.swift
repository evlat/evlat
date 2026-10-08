/// Every character Evlat ships, each in its own folder beside this file.
///
/// A character enters by being listed here; the contract tests read this
/// list, so a folder that is not listed is a character nobody checks.
enum MascotCharacters {
    static let all: [MascotCharacter] = [Cube.character]

    /// Drawn until a choice of characters exists.
    static let `default` = Cube.character
}
