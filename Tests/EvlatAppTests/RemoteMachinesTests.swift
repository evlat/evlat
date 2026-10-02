import XCTest
import AppKit
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// The remote machines window: its model apart from the view
/// — adding, the duplicate refusal, removing, what is stored, the busy
/// buttons, the result and status lines, the blocks to paste — the menu's
/// entry and its failure lines, and the window's focus rules.
///
/// The real `ssh` is never run: every controller and installer here is handed
/// a fake written into a temporary directory. The user's defaults domain and
/// clipboard are never touched — each test has its own suite and its own
/// named pasteboard.
@MainActor
final class RemoteMachinesTests: XCTestCase {
    private var directory: URL!
    /// The masters' sockets: short, and never the app's `$TMPDIR/evlat`.
    private var sockets = ""
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!
    private var controllers: [AppController] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-remote-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sockets = "/tmp/e-" + UUID().uuidString.prefix(6)
        suiteName = "evlat.tests.remote-window.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("evlat.tests.\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        // Every fake started here ends here, even when an assertion failed.
        for controller in controllers {
            controller.remote?.stopAll()
            controller.settingsWindow?.close()
            controller.panel?.close()
        }
        controllers = []
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(atPath: sockets)
    }

    // MARK: - Helpers

    private enum Mode {
        /// `exec cat >/dev/null`: up until its stdin closes.
        case connect
        /// One stderr line, then exit 255 — how `ssh` fails.
        case fail(String)
    }

    private func fakeSSH(_ mode: Mode, name: String = "fake-ssh") throws -> String {
        let script = directory.appendingPathComponent(name)
        let tail: String
        switch mode {
        case .connect: tail = "exec cat >/dev/null"
        case .fail(let line): tail = "echo '\(line)' >&2\nexit 255"
        }
        try "#!/bin/sh\n\(FreshExecutable.warmLine)\n\(tail)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        FreshExecutable.warm(script.path)
        return script.path
    }

    /// A controller whose tunnels run the fake; `stored` says whether its
    /// machines are written back (`false` is `EVLAT_MACHINES`).
    private func controller(ssh: String, stored: Bool = true,
                            machines: [RemoteMachine] = []) -> AppController {
        let controller = AppController(defaults: defaults)
        controller.startRemoteTunnels(
            configuration: RemoteMachine.Configuration(machines: machines, fromEnvironment: !stored, rejected: []),
            sshPath: ssh, socketDirectory: sockets, confirmAfter: 0.2)
        controllers.append(controller)
        return controller
    }

    private func model(_ controller: AppController, ssh: String, lang: String = "en") -> RemoteMachinesModel {
        RemoteMachinesModel(host: controller.remoteMachinesHost,
                            installer: RemoteInstaller(sshPath: ssh),
                            pasteboard: pasteboard, lang: lang)
    }

    /// A host that holds nothing and records what it was asked.
    private final class Recorder {
        var added: [String] = []
        var removed: [String] = []
        var machines: [RemoteMachine] = []
        var states: [String: RemoteTunnel.State] = [:]
        var counts: [String: Int] = [:]
        var keys: [String: String] = [:]
        var retried: [String] = []
        var password: Set<String> = []
        var sockets: [String: String] = [:]
    }

    private func host(_ recorder: Recorder, stored: Bool = true) -> RemoteMachinesModel.Host {
        RemoteMachinesModel.Host(
            machines: { recorder.machines },
            state: { recorder.states[$0] },
            sessionCounts: { recorder.counts },
            add: { target in
                recorder.added.append(target)
                guard let machine = RemoteMachine(id: "id-\(target)", target: target) else { return .failure(.empty) }
                recorder.machines.append(machine)
                return .success(machine)
            },
            remove: { id in
                recorder.removed.append(id)
                recorder.machines.removeAll { $0.id == id }
            },
            isStored: { stored },
            signalKey: { recorder.keys[$0] },
            controlPath: { recorder.sockets[$0] },
            retryByUser: { recorder.retried.append($0) },
            asksForPassword: { recorder.password.contains($0) })
    }

    private func stored() -> [RemoteMachine] {
        RemoteMachine.decode(defaults.data(forKey: RemoteMachine.storageKey))
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        done.expectationDescription = description
        wait(for: [done], timeout: timeout)
    }

    // MARK: - Adding

    func testATargetIsValidatedBeforeAnythingIsAdded() {
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        for (draft, key) in [("", "remote.add.empty"), ("   ", "remote.add.empty"),
                             ("-oProxyCommand=x", "remote.add.option"),
                             ("me@my server", "remote.add.invalidCharacter")] {
            model.draft = draft
            model.add()
            XCTAssertEqual(model.problem, L10n.t(key, in: "en"), "'\(draft)'")
            XCTAssertEqual(model.draft, draft, "a refused target stays in the field to be fixed")
        }
        XCTAssertEqual(recorder.added, [], "nothing refused reaches the app")
        model.draft = "devbox"
        XCTAssertNil(model.problem, "typing clears the line")
    }

    func testAnAddedMachineIsSelectedAndTheFieldEmpties() {
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        model.draft = "  me@devbox \n"
        model.add()
        XCTAssertEqual(recorder.added, ["me@devbox"], "the field's edges are trimmed")
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.rows.map(\.name), ["devbox"])
        XCTAssertEqual(model.selection, "id-me@devbox")
    }

    func testTheSameTargetTwiceIsRefusedAndSelected() throws {
        let ssh = try fakeSSH(.connect)
        let controller = controller(ssh: ssh)
        let model = model(controller, ssh: ssh, lang: "tr")
        model.draft = "devbox"
        model.add()
        let first = try XCTUnwrap(model.selection)
        model.draft = "me@other"
        model.add()
        XCTAssertNotEqual(model.selection, first)

        model.draft = "devbox"
        model.add()
        XCTAssertEqual(model.problem, "devbox zaten ekli.")
        XCTAssertEqual(model.selection, first, "the machine already there is shown")
        XCTAssertEqual(controller.remote?.machines.count, 2, "no second tunnel to the same target")
        XCTAssertEqual(stored().count, 2)
    }

    // MARK: - Removing

    func testRemovingAsksFirstThenClosesTheTunnelAndForgetsIt() throws {
        let ssh = try fakeSSH(.connect)
        let controller = controller(ssh: ssh)
        let model = model(controller, ssh: ssh)
        model.draft = "devbox"
        model.add()
        let id = try XCTUnwrap(model.selection)
        XCTAssertEqual(stored().map(\.target), ["devbox"])
        waitUntil("connected") { controller.remote?.state(of: id)?.isConnected == true }
        let pid = try XCTUnwrap(controller.remote?.processIdentifier(of: id))

        model.askToRemove()
        XCTAssertEqual(model.confirmingRemoval, id)
        XCTAssertEqual(controller.remote?.machines.count, 1, "asking removes nothing")
        model.cancelRemoval()
        XCTAssertNil(model.confirmingRemoval)
        XCTAssertEqual(controller.remote?.machines.count, 1)

        model.askToRemove()
        model.confirmRemoval()
        XCTAssertNil(model.confirmingRemoval)
        XCTAssertEqual(controller.remote?.machines, [])
        XCTAssertEqual(stored(), [], "the stored list follows")
        XCTAssertEqual(model.rows, [])
        XCTAssertNil(model.selection)
        waitUntil("ssh gone") { kill(pid, 0) != 0 }
    }

    func testMachinesFromTheEnvironmentAreNeverStored() throws {
        let ssh = try fakeSSH(.connect)
        let controller = controller(ssh: ssh, stored: false)
        let model = model(controller, ssh: ssh)
        XCTAssertFalse(model.isStored, "the window says the changes will not last")
        model.draft = "devbox"
        model.add()
        XCTAssertEqual(controller.remote?.machines.count, 1, "the tunnel still opens")
        XCTAssertNil(defaults.data(forKey: RemoteMachine.storageKey))
        model.askToRemove()
        model.confirmRemoval()
        XCTAssertEqual(controller.remote?.machines, [])
        XCTAssertNil(defaults.data(forKey: RemoteMachine.storageKey))
    }

    // MARK: - Signal keys

    private func storedKeys() -> [String: String]? {
        defaults.dictionary(forKey: RemoteMachine.signalKeysStorageKey) as? [String: String]
    }

    func testAnAddedMachineGetsAKeyAndRemovingItDropsTheKey() throws {
        let ssh = try fakeSSH(.connect)
        let controller = controller(ssh: ssh)
        let model = model(controller, ssh: ssh)
        model.draft = "devbox"
        model.add()
        let id = try XCTUnwrap(model.selection)
        let key = try XCTUnwrap(storedKeys()?[id])
        XCTAssertTrue(RemoteMachine.isSignalKey(key), "64 hex digits")
        XCTAssertEqual(controller.remote?.signalKey(of: id), key, "the listener has the stored key")

        model.draft = "devbox"
        model.add()
        XCTAssertEqual(storedKeys()?[id], key, "the same target again makes no new key")

        model.askToRemove()
        model.confirmRemoval()
        XCTAssertEqual(storedKeys(), [:])
    }

    func testAStoredMachineWithoutAKeyGetsOneAtLaunchAndAKeptKeyStays() throws {
        let ssh = try fakeSSH(.connect)
        let old = try XCTUnwrap(RemoteMachine(id: "old", target: "old"))
        let keyed = try XCTUnwrap(RemoteMachine(id: "keyed", target: "keyed"))
        let kept = String(repeating: "d", count: 64)
        defaults.set(["keyed": kept, "gone": kept], forKey: RemoteMachine.signalKeysStorageKey)
        let controller = controller(ssh: ssh, machines: [old, keyed])
        let keys = try XCTUnwrap(storedKeys())
        XCTAssertEqual(Set(keys.keys), ["old", "keyed"], "made for the old machine, dropped for the gone one")
        XCTAssertEqual(keys["keyed"], kept)
        XCTAssertTrue(RemoteMachine.isSignalKey(try XCTUnwrap(keys["old"])))
        XCTAssertEqual(controller.remote?.signalKey(of: "old"), keys["old"])
    }

    func testTheEnvironmentsMachineKeysStayInMemory() throws {
        let ssh = try fakeSSH(.connect)
        let machine = try XCTUnwrap(RemoteMachine(id: "fake", target: "fake"))
        let controller = controller(ssh: ssh, stored: false, machines: [machine])
        XCTAssertTrue(RemoteMachine.isSignalKey(try XCTUnwrap(controller.remote?.signalKey(of: "fake"))))
        let model = model(controller, ssh: ssh)
        model.draft = "devbox"
        model.add()
        let id = try XCTUnwrap(model.selection)
        XCTAssertNotNil(controller.remote?.signalKey(of: id))
        XCTAssertNil(defaults.object(forKey: RemoteMachine.signalKeysStorageKey), "never written")
    }

    /// A machine's switches are stored on its entry with the list; the
    /// environment's machines keep theirs for the run alone.
    func testAMachinesSwitchesAreStoredOnlyWithAStoredList() throws {
        let ssh = try fakeSSH(.connect)
        let machine = try XCTUnwrap(RemoteMachine(id: "fake", target: "fake"))
        let environment = controller(ssh: ssh, stored: false, machines: [machine])
        environment.setMachineAgents(id: "fake", ["codex"])
        XCTAssertEqual(environment.remote?.enabledAgents(of: "fake"), [.codex])
        XCTAssertNil(defaults.object(forKey: RemoteMachine.storageKey), "EVLAT_MACHINES: never written")

        let stored = controller(ssh: ssh, machines: [machine])
        stored.setMachineAgents(id: "fake", ["claude"])
        let saved = RemoteMachine.decode(defaults.data(forKey: RemoteMachine.storageKey))
        XCTAssertEqual(saved.first?.agents, ["claude"])
    }

    // MARK: - The setup buttons

    func testWhileAJobRunsItsMachinesButtonsAreOff() throws {
        let unreachable = try fakeSSH(.fail("ssh: connect to host devbox port 22: Connection refused"))
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: unreachable),
                                        pasteboard: pasteboard, lang: "en")
        model.draft = "devbox"
        model.add()
        let id = try XCTUnwrap(model.selection)
        XCTAssertTrue(model.canRun(id))

        model.run(.install(.claude))
        XCTAssertFalse(model.canRun(id), "one job per machine")
        XCTAssertTrue(model.isBusy(id))
        model.run(.remove(.codex))   // refused, not queued
        waitUntil("done") { !model.isBusy(id) }
        XCTAssertTrue(model.canRun(id))
        XCTAssertEqual(model.outcomes[id]?.line, L10n.t("remote.result.unreachable", in: "en"),
                       "an unreachable server is said once, not per file")
        XCTAssertEqual(model.outcomes[id]?.trouble, true)
    }

    func testEveryResultHasItsOwnLine() {
        let results: [RemoteInstaller.Result] = [
            .success(.written), .success(.unchanged),
            .failure(.file(.unreadable)), .failure(.file(.malformed)), .failure(.file(.noDirectory)),
            .failure(.file(.changedUnderneath)), .failure(.file(.unwritable)), .failure(.unreachable),
        ]
        for action in [RemoteSettings.Action.install, .remove] {
            let keys = results.map { RemoteMachinesModel.resultKey($0, action) }
            XCTAssertEqual(Set(keys).count, results.count, "one line per result")
            XCTAssertTrue(Set(keys).isSubset(of: Set(RemoteMachinesModel.keys)))
        }
    }

    func testTheResultLineNamesEachFileAndTheHintFollows() {
        let installed = RemoteMachinesModel.outcome(
            [(.hooks(.claude), .success(.written)), (.hooks(.codex), .failure(.file(.noDirectory)))],
            .install, in: "tr")
        XCTAssertEqual(installed.line, "Claude Code: kuruldu · Codex: kurulu değil (klasör yok)")
        XCTAssertEqual(installed.hints, [L10n.t("remote.hint.install.claude", in: "tr")],
                       "the agent's own hint: open /hooks once")
        XCTAssertFalse(installed.trouble, "Codex not being there is not a failure")

        let again = RemoteMachinesModel.outcome(
            [(.hooks(.claude), .success(.unchanged)), (.hooks(.codex), .success(.unchanged))], .install, in: "en")
        XCTAssertEqual(again.line, "Claude Code: already up to date · Codex: already up to date")
        XCTAssertEqual(again.hints, [], "nothing written, nothing to reload")

        let raced = RemoteMachinesModel.outcome([(.statusLine(.claude), .failure(.file(.changedUnderneath)))],
                                                .install, in: "en")
        XCTAssertEqual(raced.line, "Usage line: the file changed while writing; try again")
        XCTAssertTrue(raced.trouble)
    }

    /// A card's write names its agent; the hints come from the catalogue
    /// by the agent's name, and the usage line's from the agent whose
    /// status line the server gets.
    func testAUnitsLineNamesItsAgentAndItsHints() {
        let claude = RemoteMachinesModel.outcome([(.agent(.claude), .success(.written))], .install, in: "en")
        XCTAssertEqual(claude.line, "Claude Code: installed")
        XCTAssertEqual(claude.hints, [L10n.t("remote.hint.install.claude", in: "en"),
                                      L10n.t("remote.hint.usage", ["agent": "Claude Code"], in: "en")])
        let antigravity = RemoteMachinesModel.outcome([(.agent(.antigravity), .success(.written))], .install,
                                                      in: "en")
        XCTAssertEqual(antigravity.hints, [], "nothing measured, nothing said; no usage line on a server")
        let codex = RemoteMachinesModel.outcome([(.agent(.codex), .success(.written))], .remove, in: "tr")
        XCTAssertEqual(codex.hints, [L10n.t("remote.hint.remove.codex", in: "tr")])
    }

    // MARK: - The command line

    func testTheCommandButtonsShareTheMachinesLock() throws {
        let unreachable = try fakeSSH(.fail("ssh: connect to host devbox port 22: Connection refused"))
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: unreachable),
                                        pasteboard: pasteboard, lang: "en")
        model.draft = "devbox"
        model.add()
        let id = try XCTUnwrap(model.selection)
        model.runCommand(.install)
        XCTAssertFalse(model.isBusy(id), "no key, no job")
        recorder.keys[id] = String(repeating: "ab", count: 32)

        model.run(.install(.claude))
        model.runCommand(.install)   // refused: the machine has a job
        waitUntil("hooks done") { !model.isBusy(id) }
        XCTAssertEqual(model.outcomes[id]?.line, L10n.t("remote.result.unreachable", in: "en"))

        model.runCommand(.install)
        XCTAssertFalse(model.canRun(id), "the command's job holds the same lock")
        model.run(.install(.codex))
        waitUntil("command done") { !model.isBusy(id) }
        XCTAssertEqual(model.outcomes[id]?.line, L10n.t("remote.command.result.unreachable", in: "en"))
        XCTAssertEqual(model.outcomes[id]?.trouble, true)
    }

    func testEveryCommandResultHasItsOwnLine() {
        let results: [RemoteInstaller.CommandResult] = [
            .success(.init(wrote: true, curl: true)), .success(.init(wrote: false, curl: true)),
            .failure(.foreign), .failure(.unwritable), .failure(.unreachable),
        ]
        for action in [RemoteSettings.Action.install, .remove] {
            let keys = results.map { RemoteMachinesModel.commandResultKey($0, action) }
            XCTAssertEqual(Set(keys).count, results.count, "one line per result")
            XCTAssertTrue(Set(keys).isSubset(of: Set(RemoteMachinesModel.keys)))
        }
    }

    func testTheCommandLineSaysWhatWasDoneAndHowToTryIt() {
        let tryIt = L10n.t("remote.command.try", in: "en")
        let installed = RemoteMachinesModel.commandOutcome(.success(.init(wrote: true, curl: true)), .install, in: "en")
        XCTAssertEqual(installed.line, L10n.t("remote.command.result.installed", in: "en"))
        XCTAssertEqual(installed.hints, [tryIt])
        XCTAssertFalse(installed.trouble)

        let noCurl = RemoteMachinesModel.commandOutcome(.success(.init(wrote: false, curl: false)), .install, in: "tr")
        XCTAssertEqual(noCurl.line, L10n.t("remote.command.result.current", in: "tr"))
        XCTAssertEqual(noCurl.hints, [L10n.t("remote.command.noCurl", in: "tr"), L10n.t("remote.command.try", in: "tr")])
        XCTAssertTrue(noCurl.trouble, "installed, but nothing will be sent")

        let foreign = RemoteMachinesModel.commandOutcome(.failure(.foreign), .install, in: "en")
        XCTAssertTrue(foreign.trouble)
        XCTAssertEqual(foreign.hints, [])

        let removed = RemoteMachinesModel.commandOutcome(.success(.init(wrote: true, curl: true)), .remove, in: "en")
        XCTAssertEqual(removed.line, L10n.t("remote.command.result.removed", in: "en"))
        XCTAssertEqual(removed.hints, [])
    }

    func testTheKeyBlockIsMaskedAndCopiesTheRealKey() throws {
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        model.draft = "devbox"
        model.add()
        let id = try XCTUnwrap(model.selection)
        XCTAssertEqual(model.commandBlocks(for: id), [], "no key, nothing to paste")
        let key = String(repeating: "5f", count: 32)
        recorder.keys[id] = key

        let blocks = model.commandBlocks(for: id)
        let manual = RemoteCommand.manual(key: key)
        XCTAssertEqual(blocks.map(\.id), ["command.script", "command.key", "command.remove"])
        XCTAssertEqual(blocks.map(\.text), [manual.script, manual.key, manual.remove])
        XCTAssertEqual(blocks[0].shown, blocks[0].text)
        XCTAssertFalse(blocks[1].shown.contains(key), "the key is not drawn")
        XCTAssertFalse(blocks[1].shown.contains(String(key.prefix(8))))
        XCTAssertTrue(blocks[1].shown.contains(RemoteCommand.keyPath), "the rest of the line is")

        model.copy(blocks[1])
        XCTAssertEqual(pasteboard.string(forType: .string), manual.key, "the real key is copied")
        XCTAssertNotNil(pasteboard.data(forType: RemoteMachinesModel.concealedType),
                        "marked concealed: clipboard managers keep no history of the key")
        model.copy(blocks[0])
        XCTAssertNil(pasteboard.data(forType: RemoteMachinesModel.concealedType), "the script is no secret")
        model.copy(blocks[1])
        XCTAssertEqual(model.copied, "command.key")
    }

    func testAJobIsOneAgentsUnit() {
        // One change per press: the agent's one file, its hooks and — where
        // the server gets one — its usage line in the same write.
        for source in Agents.all {
            XCTAssertEqual(RemoteMachinesModel.Job.install(source.id).changes, [.agent(source)])
            XCTAssertEqual(RemoteMachinesModel.Job.remove(source.id).changes, [.agent(source)])
            XCTAssertEqual(RemoteMachinesModel.Job.install(source.id).action, .install)
            XCTAssertEqual(RemoteMachinesModel.Job.remove(source.id).action, .remove)
        }
    }

    // MARK: - Status

    func testTheStatusLineSaysWhereTheTunnelIs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func text(_ state: RemoteTunnel.State?, sessions: Int = 0, _ lang: String = "en") -> String {
            RemoteMachinesModel.status(state, sessions: sessions, now: now, in: lang).text
        }
        XCTAssertEqual(text(.connecting), "connecting…")
        XCTAssertEqual(text(.connected(since: now)), "connected")
        XCTAssertEqual(text(.connected(since: now), sessions: 2, "tr"), "bağlı · 2 oturum")
        XCTAssertEqual(text(.connected(since: now), sessions: 1), "connected · 1 session")
        XCTAssertEqual(text(.stopped), "not connected")
        XCTAssertEqual(text(nil), "not connected")
        XCTAssertEqual(text(.waiting(retryAt: now.addingTimeInterval(150), failure: .authentication), "tr"),
                       "kimlik doğrulama başarısız · 2 dk sonra yeniden denenecek")
        XCTAssertEqual(text(.waiting(retryAt: now.addingTimeInterval(20), failure: .portBusy)),
                       "port 48151 is taken on the server · retrying shortly")

        let failing = RemoteMachinesModel.status(.waiting(retryAt: now, failure: .hostKey),
                                                 sessions: 0, now: now, in: "en", target: "me@devbox")
        XCTAssertEqual(failing.tone, .trouble)
        XCTAssertEqual(failing.advice, "Connect once from Terminal with “ssh me@devbox” and accept the host key.")
        XCTAssertNil(RemoteMachinesModel.status(.connecting, sessions: 0, now: now, in: "en").advice)
    }

    /// A password the server wants: the row says which of the three it is,
    /// in words, and offers "Enter Password…" — never for another failure.
    func testThePasswordStatesHaveTheirOwnLines() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func status(_ state: RemoteTunnel.State, _ lang: String = "en")
            -> (text: String, advice: String?, tone: RemoteMachinesModel.Tone) {
            RemoteMachinesModel.status(state, sessions: 0, now: now, in: lang)
        }
        XCTAssertEqual(status(.needsUser(rejected: false)).text, "waiting for your password")
        XCTAssertEqual(status(.needsUser(rejected: false), "tr").text, "şifre bekliyor")
        XCTAssertEqual(status(.needsUser(rejected: true)).text, "password refused")
        XCTAssertEqual(status(.needsUser(rejected: true), "tr").text, "şifre reddedildi")
        XCTAssertTrue(status(.waiting(retryAt: now.addingTimeInterval(20), failure: .passwordNeeded), "tr").text
            .hasPrefix("şifre gerekiyor · "))
        XCTAssertEqual(status(.needsUser(rejected: true)).tone, .trouble)
        XCTAssertNotNil(status(.needsUser(rejected: true)).advice)
        XCTAssertFalse(status(.waiting(retryAt: now, failure: .authentication)).advice?.contains("passwordless") ?? true,
                       "a password is a way in now")

        XCTAssertTrue(RemoteMachinesModel.offersPassword(.needsUser(rejected: true)))
        XCTAssertTrue(RemoteMachinesModel.offersPassword(.needsUser(rejected: false)))
        XCTAssertTrue(RemoteMachinesModel.offersPassword(.waiting(retryAt: now, failure: .passwordNeeded)))
        XCTAssertFalse(RemoteMachinesModel.offersPassword(.waiting(retryAt: now, failure: .authentication)))
        XCTAssertFalse(RemoteMachinesModel.offersPassword(.connected(since: now)))
        XCTAssertFalse(RemoteMachinesModel.offersPassword(nil))
    }

    /// "Enter Password…" tries the machine interactively, through the
    /// tunnels; and a password server with no tunnel up says to connect
    /// first — the setup rides the tunnel's connection.
    func testEnterPasswordTriesAndAPasswordServerWithoutATunnelSaysConnectFirst() {
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        model.draft = "devbox"
        model.add()
        let id = "id-devbox"
        recorder.states[id] = .needsUser(rejected: true)
        model.reload()
        XCTAssertEqual(model.rows.first?.enterPassword, true)
        model.enterPassword(id)
        XCTAssertEqual(recorder.retried, [id])

        XCTAssertFalse(model.needsConnectionFirst(id), "not known to want a password")
        recorder.password.insert(id)
        XCTAssertTrue(model.needsConnectionFirst(id))
        recorder.sockets[id] = "/tmp/e/1"
        XCTAssertTrue(model.needsConnectionFirst(id), "an ssh still at its prompt has no master yet")
        recorder.states[id] = .connected(since: Date())
        XCTAssertFalse(model.needsConnectionFirst(id), "the tunnel's master is up: the setup rides it")
        recorder.sockets[id] = nil
        XCTAssertFalse(model.needsConnectionFirst(id), "up without a master: no press would change it")

        model.reload()
        XCTAssertEqual(model.rows.first?.enterPassword, false)
    }

    func testEveryTunnelFailureHasALineAndAdvice() {
        let failures: [RemoteTunnel.Failure] = [.authentication, .portBusy, .hostKey, .hostName, .unreachable,
                                                .passwordNeeded, .other]
        let lines = Set(failures.map(RemoteMachinesModel.failureKey))
        let advice = Set(failures.map(RemoteMachinesModel.adviceKey))
        XCTAssertEqual(lines.count, failures.count)
        XCTAssertEqual(advice.count, failures.count)
        XCTAssertTrue(lines.union(advice).isSubset(of: Set(RemoteMachinesModel.keys)))
    }

    func testTheRowsFollowTheTunnels() {
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        model.draft = "devbox"
        model.add()
        let id = "id-devbox"
        recorder.states[id] = .connected(since: Date())
        recorder.counts[id] = 3
        model.reload()
        XCTAssertEqual(model.rows.first?.status, "connected · 3 sessions")
        XCTAssertEqual(model.rows.first?.tone, .good)
    }

    func testEveryKeyIsInBothTables() {
        for lang in ["en", "tr"] {
            for key in RemoteMachinesModel.keys {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }

    // MARK: - By hand

    func testTheBlocksToPasteAreTheWritersOwn() throws {
        let manual = RemoteSettings.manual(agents: Agents.all)
        for source in Agents.all {
            let card = RemoteMachinesModel.manual(source.id, in: "en")
            XCTAssertEqual(card.text, manual.hooks(for: source))
            XCTAssertEqual(card.lead, L10n.t("remote.manual.agent", ["file": "~/" + source.integration.hooksFile], in: "en"))
            // The usage line is a part on a server for one agent alone.
            XCTAssertEqual(card.statusLine != nil, RemoteSettings.relays(source), source.id.rawValue)
        }
        let claude = RemoteMachinesModel.manual(.claude, in: "en")
        XCTAssertEqual(claude.statusLine, manual.statusLine)
        // The wrapper goes inside a JSON string: shown as one, it decodes to
        // the writer's command byte for byte.
        let wrapping = try XCTUnwrap(claude.wrapping)
        let decoded = try JSONSerialization.jsonObject(with: Data(wrapping.utf8), options: .fragmentsAllowed)
        XCTAssertEqual(decoded as? String, manual.wrapping)
    }

    func testCopyPutsTheBlockOnThePasteboard() throws {
        let model = RemoteMachinesModel(host: host(Recorder()), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        let block = RemoteMachinesModel.pathBlock
        model.copy(block)
        XCTAssertEqual(pasteboard.string(forType: .string), block.text)
        XCTAssertEqual(model.copied, block.id, "the button says it was copied")
    }

    // MARK: - The menu

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// The window has no menu entry of its own; a failing machine
    /// is an attention line that opens the settings at the remote section.
    func testAFailingMachineIsAnAttentionLine() throws {
        let ssh = try fakeSSH(.fail("me@devbox: Permission denied (publickey)."))
        let machine = try XCTUnwrap(RemoteMachine(id: "m1", target: "me@devbox"))
        let controller = controller(ssh: ssh, machines: [machine])
        controller.installPanel()
        controller.settingsActivation = { }
        XCTAssertFalse(titles(controller.makeMenu(diagnostics: true, in: "tr")).contains("Uzak makineler…"))
        waitUntil("failed") {
            if case .waiting? = controller.remote?.state(of: "m1") { return true }
            return false
        }
        let menu = controller.makeMenu(diagnostics: false, in: "tr")
        let index = try XCTUnwrap(menu.items.firstIndex { $0.representedObject is SetupAttention })
        let line = menu.items[index]
        XCTAssertEqual(line.title, "devbox: sunucuya ulaşılamıyor")
        XCTAssertTrue(line.isEnabled, "dim, but it can be clicked")
        menu.performActionForItem(at: index)
        XCTAssertEqual(controller.settings?.section, .remote)
    }

    func testOpeningTheWindowTwiceShowsTheSameOne() throws {
        let controller = AppController(defaults: defaults)
        controllers.append(controller)
        controller.installPanel()
        controller.settingsActivation = { }
        controller.openSettings(section: .remote)
        let first = try XCTUnwrap(controller.settingsWindow?.window)
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(controller.settings?.section, .remote)
        controller.openSettings(section: .remote)
        XCTAssertTrue(controller.settingsWindow?.window === first)
    }

    // MARK: - Focus (the settings window)

    private func appWindow(frontmost: @escaping () -> NSRunningApplication? = { nil },
                           activate: @escaping () -> Void = {},
                           restore: @escaping (NSRunningApplication) -> Void = { _ in }) -> AppWindow {
        AppWindow(make: {
            AppKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        }, frontmost: frontmost, activate: activate, restore: restore)
    }

    func testTheWindowTakesKeyAndTheBarStillDoesNot() throws {
        let window = appWindow()
        let made = window.build()
        defer { made.close() }
        XCTAssertTrue(made.canBecomeKey, "a field to type into")
        XCTAssertFalse(made.isReleasedWhenClosed, "a second open reuses it")
        let bar = AppController(defaults: nil).installPanel()
        defer { bar.close() }
        XCTAssertFalse(bar.canBecomeKey, "the bar is still a non-activating panel")
        XCTAssertTrue(bar.styleMask.contains(.nonactivatingPanel))
    }

    func testShowingActivatesAndClosingGivesFocusBack() throws {
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != getpid() && $0.activationPolicy == .regular
        }, "some other app runs")
        var activations = 0
        var restored: [NSRunningApplication] = []
        let window = appWindow(frontmost: { other }, activate: { activations += 1 },
                               restore: { restored.append($0) })
        window.show()
        XCTAssertEqual(activations, 1, "opening is the user's act: Evlat comes forward")
        window.show()
        XCTAssertEqual(activations, 2)
        window.close()
        XCTAssertEqual(restored, [other], "the app that was in front before the first open, once")
        XCTAssertFalse(window.isVisible)
    }

    /// Opened from A, left behind B, opened again from the status item
    /// while B is in front: closing gives the focus to B.
    func testASecondOpenFromAnotherAppGivesTheFocusToThatApp() throws {
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid() && $0.activationPolicy == .regular
        }
        guard others.count >= 2 else { throw XCTSkip("needs two other apps running") }
        var front = others[0]
        var restored: [NSRunningApplication] = []
        let window = appWindow(frontmost: { front }, restore: { restored.append($0) })
        window.show()
        front = others[1]
        window.show()
        window.close()
        XCTAssertEqual(restored, [others[1]])
    }

    func testTheSessionCountFollowsEachMachinesOwnPrefix() throws {
        let ssh = try fakeSSH(.connect)
        // `EVLAT_MACHINES`' ids are their targets, and a target may hold a colon.
        let machines = try ["a", "a:b"].map { try XCTUnwrap(RemoteMachine(id: $0, target: $0)) }
        let controller = controller(ssh: ssh, stored: false, machines: machines)
        final class Rows: Provider {
            let id = "rows"
            func currentSignals() -> [Signal] {
                // An outside row of a machine is not a session.
                ["remote:a:s1", "remote:a:b:s2", "remote:a:b:s3", "signal:a:x"].map {
                    Signal(provider: "rows", entity: $0, phase: .idle, label: "x",
                           fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))
                }
            }
        }
        controller.registry.register(Rows())
        XCTAssertEqual(controller.remoteMachinesHost.sessionCounts(), ["a": 1, "a:b": 2])
    }

    func testEscapeCancelsTheQuestionThenCloses() throws {
        let controller = AppController(defaults: defaults)
        controllers.append(controller)
        controller.installPanel()
        controller.settingsActivation = { }
        let ssh = try fakeSSH(.connect)
        controller.startRemoteTunnels(configuration: RemoteMachine.Configuration(
            machines: [try XCTUnwrap(RemoteMachine(id: "m1", target: "devbox"))], fromEnvironment: true, rejected: []),
            sshPath: ssh, socketDirectory: sockets, confirmAfter: 0.2)
        controller.openSettings(section: .remote)
        let window = try XCTUnwrap(controller.settingsWindow)
        let model = try XCTUnwrap(controller.settings?.remote)
        model.askToRemove("m1")
        window.window?.cancelOperation(nil)
        XCTAssertNil(model.confirmingRemoval, "Esc answers the question first")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(controller.remote?.machines.map(\.id), ["m1"])
        window.window?.cancelOperation(nil)
        XCTAssertFalse(window.isVisible)
    }
}
