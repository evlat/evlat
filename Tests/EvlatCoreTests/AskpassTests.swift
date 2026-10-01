import XCTest
@testable import EvlatCore

/// The askpass helper's pure half: the mark in the environment that makes the
/// binary a helper, and the two prompt classes a stored password and a
/// silent attempt decide by. The prompts are the ones `ssh` was seen to send
/// (OpenSSH 10.2p1, `.tasks/017` → Kanıt), plus PAM's usual ones.
final class AskpassTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // MARK: - The mark

    func testAMarkIsAPortAndAToken() {
        let mark = Askpass.mark(in: [Askpass.environmentKey: "48151:\(token)"])
        XCTAssertEqual(mark, Askpass.Mark(port: 48151, token: token))
        XCTAssertEqual(mark.map(Askpass.value), "48151:\(token)", "written as it is read")
    }

    func testABrokenMarkIsNoMark() {
        let broken = [
            "", ":", "48151", "48151:", ":\(token)", "0:\(token)", "70000:\(token)", "-1:\(token)",
            "x:\(token)", "48151:\(token.uppercased())", "48151:\(token.dropLast())", "48151:\(token)0",
            "48151:\(token):1", " 48151:\(token)", "48151 :\(token)",
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
