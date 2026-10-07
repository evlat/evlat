import XCTest
@testable import EvlatCore

/// The askpass helper's pure half: the mark in the environment that makes the
/// binary a helper, and the two prompt classes a stored password and a
/// silent attempt decide by. The prompts are the ones `ssh` was seen to send
/// (OpenSSH 10.2p1, `.tasks/017` → Kanıt), plus PAM's usual ones.
final class AskpassTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // MARK: - The mark

    func testAMarkIsATokenAndASocket() {
        let mark = Askpass.mark(in: [Askpass.environmentKey: "\(token):/tmp/evlat-t/evlat.sock"])
        XCTAssertEqual(mark, Askpass.Mark(socket: "/tmp/evlat-t/evlat.sock", token: token))
        XCTAssertEqual(mark.map(Askpass.value), "\(token):/tmp/evlat-t/evlat.sock", "written as it is read")
    }

    /// The token's length is fixed, so the path is everything after the
    /// first `:` — a `:` of its own, a space, included.
    func testThePathIsEverythingAfterTheToken() {
        let path = "/Users/a b/x:y/.config/evlat/run/evlat.sock"
        let mark = Askpass.mark(in: [Askpass.environmentKey: "\(token):\(path)"])
        XCTAssertEqual(mark, Askpass.Mark(socket: path, token: token))
        XCTAssertEqual(mark.map(Askpass.value), "\(token):\(path)")
    }

    func testABrokenMarkIsNoMark() {
        let socket = "/tmp/evlat-t/evlat.sock"
        let broken = [
            "", ":", token, "\(token):", ":\(socket)", "\(socket):\(token)",
            "\(token.uppercased()):\(socket)", "\(token.dropLast()):\(socket)", "\(token)0:\(socket)",
            " \(token):\(socket)", "\(token) :\(socket)", "\(token):relative/evlat.sock",
            // The old shape, `<port>:<token>`, is not read as a path.
            "48151:\(token)",
            "\(token):/" + String(repeating: "s", count: EvlatSocket.pathLimit),
        ]
        for value in broken {
            XCTAssertNil(Askpass.mark(in: [Askpass.environmentKey: value]), value)
        }
        XCTAssertNil(Askpass.mark(in: [:]))
        XCTAssertNil(Askpass.mark(in: ["SSH_ASKPASS": "/x/Evlat"]))
    }

    // MARK: - Prompt classes

    /// Exactly as `ssh` sent it: the host key question is several lines.
    private let hostKeyPrompt = """
        The authenticity of host '[127.0.0.1]:22222 ([127.0.0.1]:22222)' can't be established.
        ED25519 key fingerprint is: SHA256:Yk3e1lVVq0m2bH8X3pQ1t1vDqv6l6cJ5Ff0q3uQ0qkA.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """

    func testThePasswordPromptsArePasswords() {
        for prompt in ["nobodyx@127.0.0.1's password: ", "Password:", "password: ", "  Password:\n",
                       "(nobodyx@127.0.0.1) Password: ", "deploy@build.example.com's password:",
                       "deploy@newton's password: ", "renewal@host's password:", "(newuser@news.example) Password:"] {
            XCTAssertTrue(Askpass.isPassword(prompt), prompt)
            XCTAssertFalse(Askpass.isYesNo(prompt), prompt)
        }
    }

    /// A stored password must never answer these: a passphrase is another
    /// secret, a code is a second factor, and a new password is a change.
    func testOtherSecretsAreNotPasswords() {
        for prompt in ["Verification code:", "Enter passphrase for key '/Users/x/.ssh/id_ed25519':",
                       "New password:", "Retype new password:", "Enter new UNIX password:",
                       "(x@y) Verification code: ", "(newton@h) New password:", "x@y's new password:", "Password for x@y is about to expire", "", hostKeyPrompt] {
            XCTAssertFalse(Askpass.isPassword(prompt), prompt)
        }
    }

    func testTheHostKeyQuestionIsYesNo() {
        XCTAssertTrue(Askpass.isYesNo(hostKeyPrompt))
        XCTAssertTrue(Askpass.isYesNo("Are you sure you want to continue connecting (yes/no)? "))
        XCTAssertTrue(Askpass.isYesNo("Allow this? (YES/NO)"))
        for prompt in ["Password:", "Verification code:", "Enter passphrase for key 'k':", ""] {
            XCTAssertFalse(Askpass.isYesNo(prompt), prompt)
        }
    }
}
