import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// The remote machines window (`010/phase-5`): its model apart from the view
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
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!
    private var controllers: [AppController] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-remote-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "evlat.tests.remote-window.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("evlat.tests.\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        // Every fake started here ends here, even when an assertion failed.
        for controller in controllers {
            controller.remote?.stopAll()
            controller.remoteWindow?.window?.close()
            controller.panel?.close()
        }
        controllers = []
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
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
            sshPath: ssh, confirmAfter: 0.2)
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
            isStored: { stored })
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

    // MARK: - Signal keys (`013`)

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

        model.run(.installHooks)
        XCTAssertFalse(model.canRun(id), "one job per machine")
        XCTAssertTrue(model.isBusy(id))
        model.run(.removeHooks)   // refused, not queued
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
        XCTAssertEqual(installed.hints, [L10n.t("menu.hooks.hint.claude", in: "tr")],
                       "the local entry's hint: open /hooks once")
        XCTAssertFalse(installed.trouble, "Codex not being there is not a failure")

        let again = RemoteMachinesModel.outcome(
            [(.hooks(.claude), .success(.unchanged)), (.hooks(.codex), .success(.unchanged))], .install, in: "en")
        XCTAssertEqual(again.line, "Claude Code: already up to date · Codex: already up to date")
        XCTAssertEqual(again.hints, [], "nothing written, nothing to reload")

        let raced = RemoteMachinesModel.outcome([(.statusLine, .failure(.file(.changedUnderneath)))],
                                                .install, in: "en")
        XCTAssertEqual(raced.line, "Usage line: the file changed while writing; try again")
        XCTAssertTrue(raced.trouble)
    }

    func testTheJobsAreTheFixedChanges() {
        XCTAssertEqual(RemoteMachinesModel.Job.installHooks.changes, [.hooks(.claude), .hooks(.codex)])
        XCTAssertEqual(RemoteMachinesModel.Job.removeHooks.changes, [.hooks(.claude), .hooks(.codex)])
        XCTAssertEqual(RemoteMachinesModel.Job.installUsage.changes, [.statusLine])
        XCTAssertEqual(RemoteMachinesModel.Job.removeUsage.changes, [.statusLine])
        XCTAssertEqual(RemoteMachinesModel.Job.allCases.map(\.action), [.install, .remove, .install, .remove])
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

    func testEveryTunnelFailureHasALineAndAdvice() {
        let failures: [RemoteTunnel.Failure] = [.authentication, .portBusy, .hostKey, .hostName, .unreachable, .other]
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
        let manual = RemoteSettings.manual
        let blocks = RemoteMachinesModel.blocks
        XCTAssertEqual(blocks.map(\.id), ["claude", "codex", "statusLine", "wrapping"])
        XCTAssertEqual(blocks[0].text, manual.claudeHooks)
        XCTAssertEqual(blocks[1].text, manual.codexHooks)
        XCTAssertEqual(blocks[2].text, manual.statusLine)
        // The wrapper goes inside a JSON string: shown as one, it decodes to
        // the writer's command byte for byte.
        let decoded = try JSONSerialization.jsonObject(with: Data(blocks[3].text.utf8), options: .fragmentsAllowed)
        XCTAssertEqual(decoded as? String, manual.wrapping)
    }

    func testCopyPutsTheBlockOnThePasteboard() throws {
        let model = RemoteMachinesModel(host: host(Recorder()), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        let block = try XCTUnwrap(RemoteMachinesModel.blocks.first)
        model.copy(block)
        XCTAssertEqual(pasteboard.string(forType: .string), block.text)
        XCTAssertEqual(model.copied, block.id, "the button says it was copied")
    }

    // MARK: - The menu

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    func testBothMenusOpenTheWindow() throws {
        let controller = AppController(defaults: defaults)
        controllers.append(controller)
        controller.installPanel()
        for diagnostics in [false, true] {
            let menu = controller.makeMenu(diagnostics: diagnostics, in: "en")
            let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Remote Machines…" })
            let entry = menu.items[index]
            XCTAssertEqual(entry.action, #selector(AppController.openRemoteMachines(_:)))
            XCTAssertTrue(entry.target === controller)
            XCTAssertTrue(menu.items[index + 1].isSeparatorItem, "no machine, no line under it")
        }
        XCTAssertTrue(titles(controller.makeMenu(diagnostics: false, in: "tr")).contains("Uzak makineler…"))
    }

    func testAFailingMachineIsADimLineUnderTheEntry() throws {
        let ssh = try fakeSSH(.fail("me@devbox: Permission denied (publickey)."))
        let machine = try XCTUnwrap(RemoteMachine(id: "m1", target: "me@devbox"))
        let controller = controller(ssh: ssh, machines: [machine])
        controller.installPanel()
        waitUntil("failed") {
            if case .waiting? = controller.remote?.state(of: "m1") { return true }
            return false
        }
        let menu = controller.makeMenu(diagnostics: false, in: "tr")
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Uzak makineler…" })
        let line = menu.items[index + 1]
        XCTAssertEqual(line.title, "devbox: kimlik doğrulama başarısız")
        XCTAssertFalse(line.isEnabled)
        XCTAssertNil(line.action, "the line does nothing; the window does")
        XCTAssertEqual(line.indentationLevel, 1)
    }

    func testOpeningTheWindowTwiceShowsTheSameOne() throws {
        let controller = AppController(defaults: defaults)
        controllers.append(controller)
        controller.installPanel()
        controller.remoteWindowActivation = { }
        controller.openRemoteMachines(nil)
        let first = try XCTUnwrap(controller.remoteWindow?.window)
        XCTAssertTrue(first.isVisible)
        controller.openRemoteMachines(nil)
        XCTAssertTrue(controller.remoteWindow?.window === first)
    }

    // MARK: - Focus

    func testTheWindowTakesKeyAndTheBarStillDoesNot() throws {
        let window = RemoteMachinesWindow(model: RemoteMachinesModel(
            host: host(Recorder()), installer: RemoteInstaller(sshPath: "/nonexistent"),
            pasteboard: pasteboard, lang: "en"))
        let made = window.makeWindow()
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
        let window = RemoteMachinesWindow(
            model: RemoteMachinesModel(host: host(Recorder()), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                       pasteboard: pasteboard, lang: "en"),
            frontmost: { other },
            activate: { activations += 1 },
            restore: { restored.append($0) })
        window.show()
        XCTAssertEqual(activations, 1, "opening is the user's act: Evlat comes forward")
        window.show()
        XCTAssertEqual(activations, 2)
        window.window?.close()
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
        let window = RemoteMachinesWindow(
            model: RemoteMachinesModel(host: host(Recorder()), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                       pasteboard: pasteboard, lang: "en"),
            frontmost: { front }, activate: {}, restore: { restored.append($0) })
        window.show()
        front = others[1]
        window.show()
        window.window?.close()
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
                // An outside row of a machine (`013`) is not a session.
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
        let recorder = Recorder()
        let model = RemoteMachinesModel(host: host(recorder), installer: RemoteInstaller(sshPath: "/nonexistent"),
                                        pasteboard: pasteboard, lang: "en")
        model.draft = "devbox"
        model.add()
        let window = RemoteMachinesWindow(model: model, frontmost: { nil }, activate: {}, restore: { _ in })
        window.show()
        model.askToRemove()
        window.window?.cancelOperation(nil)
        XCTAssertNil(model.confirmingRemoval, "Esc answers the question first")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(recorder.removed, [])
        window.window?.cancelOperation(nil)
        XCTAssertFalse(window.isVisible)
    }
}
