import XCTest
import AppKit
import SwiftUI
@testable import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// The update window: which rows it shows and with what, "Update all"'s
/// order and what it leaves, the footer's Done, and its size — the pure rule,
/// the real window offstage, and (with `EVLAT_SHOTS` set to a folder) its
/// pictures, drawn by `ImageRenderer` without a window.
@MainActor
final class UpdatesTests: XCTestCase {
    // MARK: - A host to record

    private final class Fake {
        var cards: [SetupRow]
        var machines: [UpdatesModel.Machine]
        /// What an agent's press leaves: a refusal's line, or none.
        var refusals: [AgentID: String] = [:]
        var log: [String] = []
        /// The machines' jobs not answered yet, in the order they started.
        var pending: [(id: String, done: (UpdatesModel.MachineResult) -> Void)] = []
        /// `updates.automatic`: `nil` while never written.
        var automatic: Bool?
        var predatesSocket = false

        init(cards: [SetupRow], machines: [UpdatesModel.Machine]) {
            self.cards = cards
            self.machines = machines
        }

        var host: UpdatesModel.Host {
            UpdatesModel.Host(
                agentRows: { [unowned self] in cards },
                updateAgent: { [unowned self] source in
                    log.append("agent \(source.rawValue)")
                    guard let index = cards.firstIndex(where: { $0.item == .agent(source) }) else { return }
                    let card = cards[index]
                    let failure = refusals[source]
                    cards[index] = UpdatesTests.card(source, failure == nil ? .installed : .outdated,
                                                     enabled: card.enabled, failure: failure)
                },
                machines: { [unowned self] in machines },
                updateMachine: { [unowned self] id, done in
                    guard !pending.contains(where: { $0.id == id }) else { return false }
                    log.append("machine \(id)")
                    pending.append((id, done))
                    return true
                },
                automatic: { [unowned self] in automatic },
                setAutomatic: { [unowned self] in automatic = $0 },
                keepAgent: { [unowned self] source in
                    log.append("keep \(source.rawValue)")
                    guard let index = cards.firstIndex(where: { $0.item == .agent(source) }) else { return }
                    let card = cards[index]
                    let failure = refusals[source]
                    cards[index] = UpdatesTests.card(source, failure == nil ? .installed : .outdated,
                                                     enabled: card.enabled, failure: failure)
                },
                keepMachine: { [unowned self] id, done in
                    guard !pending.contains(where: { $0.id == id }) else { return false }
                    log.append("keep machine \(id)")
                    pending.append((id, done))
                    return true
                },
                predatesSocket: { [unowned self] in predatesSocket })
        }

        /// The oldest running job answers.
        func answer(_ result: UpdatesModel.MachineResult) {
            let job = pending.removeFirst()
            if result.failure == nil, let index = machines.firstIndex(where: { $0.id == job.id }) {
                let machine = machines[index]
                machines[index] = UpdatesModel.Machine(id: machine.id, name: machine.name, state: machine.state,
                                                       outdated: [], commandOld: false)
            }
            job.done(result)
        }
    }

    /// A card as `SetupModel` reads it: the unit's status, its hooks part
    /// first (`hooks`, the unit's own unless named).
    nonisolated static func card(_ source: AgentID, _ status: SetupStatus, hooks: SetupStatus? = nil,
                                 enabled: Bool = true, failure: String? = nil) -> SetupRow {
        let file = "~/" + source.agent.integration.hooksFile
        var row = SetupRow(item: .agent(source), status: status, name: L10n.t(source.agent.display.nameKey, in: "en"),
                           detail: file, note: nil, failure: failure)
        row.parts = [SetupPart(name: "Hooks", file: file, status: hooks ?? status)]
        row.enabled = enabled
        return row
    }

    private static let connected = RemoteTunnel.State.connected(since: Date(timeIntervalSince1970: 0))

    private static func machine(_ id: String, _ state: RemoteTunnel.State?, outdated: [AgentID]? = nil,
                                command: Bool = false) -> UpdatesModel.Machine {
        UpdatesModel.Machine(id: id, name: id, state: state, outdated: outdated, commandOld: command)
    }

    /// The mockup's first view: three agents on this Mac and two servers
    /// with old hooks, a third whose sshd forwards no socket.
    private func mockup() -> Fake {
        Fake(cards: [Self.card(.claude, .outdated), Self.card(.codex, .outdated), Self.card(.antigravity, .outdated)],
             machines: [Self.machine("rasp", Self.connected, outdated: [.claude]),
                        Self.machine("kararla_hetzner", Self.connected, outdated: [.claude]),
                        Self.machine("build-01", .waiting(retryAt: Date(timeIntervalSince1970: 0),
                                                          failure: .forwardingRefused))])
    }

    private func model(_ fake: Fake) -> UpdatesModel {
        let model = UpdatesModel(host: fake.host, lang: "en")
        model.start()
        return model
    }

    // MARK: - Rows

    /// Only what an older copy left: an agent switched on with old hooks,
    /// and every server not known to be current. A server with no tunnel, or
    /// one whose channel was refused, has nothing to press.
    func testTheRowsAndTheirStates() {
        // Codex's hooks are current and only its usage line is missing: the
        // unit reads old, the window asks nothing of it.
        let fake = Fake(cards: [Self.card(.claude, .outdated), Self.card(.codex, .outdated, hooks: .installed),
                                Self.card(.antigravity, .outdated, enabled: false)],
                        machines: [Self.machine("old", Self.connected, outdated: [.codex]),
                                   Self.machine("fine", Self.connected, outdated: []),
                                   Self.machine("command", Self.connected, outdated: [], command: true),
                                   Self.machine("asleep", .connecting),
                                   Self.machine("reading", Self.connected),
                                   Self.machine("busy", .waiting(retryAt: Date(), failure: .channelBusy)),
                                   Self.machine("password", .needsUser(rejected: false))])
        let model = model(fake)
        XCTAssertEqual(model.agents.map(\.kind), [.agent(.claude)],
                       "current hooks, a usage line alone and switched-off agents are not asked")
        XCTAssertEqual(model.agents.first?.state, .needsUpdate)
        XCTAssertEqual(model.agents.first?.action, .update)
        XCTAssertEqual(model.agents.first?.lines.map(\.text), ["~/.claude/settings.json"])

        XCTAssertEqual(model.machines.map(\.name), ["old", "command", "asleep", "reading", "busy", "password"],
                       "a current server is not listed")
        let byName = Dictionary(uniqueKeysWithValues: model.machines.map { ($0.name, $0) })
        XCTAssertEqual(byName["old"]?.state, .needsUpdate)
        XCTAssertEqual(byName["old"]?.lines.map(\.text), ["connected · Codex"])
        XCTAssertEqual(byName["command"]?.lines.map(\.text), ["connected · evlat command"])
        XCTAssertEqual(byName["asleep"]?.state, .notConnected)
        XCTAssertEqual(byName["asleep"]?.lines.map(\.text), ["not connected · checked once it connects"])
        XCTAssertEqual(byName["reading"]?.state, .checking)
        XCTAssertEqual(byName["busy"]?.state,
                       .channelFailed(L10n.t("remote.failure.channelBusy", in: "en"),
                                      advice: L10n.t("remote.failure.channelBusy.advice", in: "en")))
        XCTAssertEqual(byName["busy"]?.lines, [UpdatesModel.Line(text: "another Evlat answers this server", tone: .trouble)])
        XCTAssertEqual(byName["password"]?.advice, L10n.t("remote.state.needsPassword.advice", in: "en"))
        for name in ["asleep", "reading", "busy", "password"] {
            XCTAssertNil(byName[name]?.action, "\(name): nothing to press")
        }
        XCTAssertFalse(model.isDone)
        XCTAssertTrue(model.canUpdateAll)
    }

    /// A server that was not connected when the window opened takes its
    /// state as it connects; the row stays once it reads current.
    func testAServerTakesItsStateAsItConnects() {
        let fake = Fake(cards: [], machines: [Self.machine("rasp", .connecting), Self.machine("other", .stopped)])
        let model = model(fake)
        XCTAssertEqual(model.machines.map(\.state), [.notConnected, .notConnected])
        XCTAssertFalse(model.canUpdateAll, "nothing to press yet")

        fake.machines = [Self.machine("rasp", Self.connected, outdated: [.claude]),
                         Self.machine("other", Self.connected, outdated: [])]
        model.refresh()
        XCTAssertEqual(model.machines.map(\.state), [.needsUpdate, .current])
        XCTAssertEqual(model.machines.first?.action, .update)
    }

    // MARK: - Update all

    /// This Mac's rows first, then each server in turn: the next server's
    /// job starts once the one before answered. Done replaces Later and
    /// Update all at the press.
    func testUpdateAllRunsThisMacThenEachServerInTurn() {
        let fake = mockup()
        let failure = "Hooks: The settings file could not be written"
        fake.refusals[.antigravity] = failure
        let model = model(fake)
        XCTAssertFalse(model.isDone)

        model.updateAll()
        XCTAssertTrue(model.isDone, "Done from the press on, as the mockup draws it")
        XCTAssertEqual(fake.log, ["agent claude", "agent codex", "agent antigravity", "machine rasp"])
        XCTAssertEqual(model.agents.map(\.state), [.updated, .updated, .failed(failure)])
        XCTAssertEqual(model.agents[0].lines, [UpdatesModel.Line(text: "Open sessions pick it up with their next message.",
                                                                 tone: .neutral)])
        XCTAssertEqual(model.agents[1].lines, [UpdatesModel.Line(
            text: "One more step: in Codex, open /hooks and trust Evlat’s hooks.", tone: .step)])
        XCTAssertEqual(model.agents[2].lines, [UpdatesModel.Line(text: failure, tone: .trouble)])
        XCTAssertEqual(model.agents[2].action, .retry)
        XCTAssertEqual(model.machines.map(\.state), [.updating, .needsUpdate, model.machines[2].state])
        XCTAssertEqual(model.running, .machine("rasp"))
        XCTAssertFalse(model.canUpdateAll, "every button waits while a job runs")

        fake.answer(UpdatesModel.MachineResult(failure: nil, agents: [.claude]))
        XCTAssertEqual(fake.log.last, "machine kararla_hetzner", "the next server, once the first answered")
        XCTAssertEqual(model.machines[0].state, .updated)
        XCTAssertEqual(model.machines[0].lines.map(\.text), ["Its permissions and questions now come to the bar."])
        XCTAssertEqual(model.machines[1].state, .updating)

        fake.answer(UpdatesModel.MachineResult(failure: "Claude Code: could not reach the server", agents: [.claude]))
        XCTAssertEqual(model.machines[1].state, .failed("Claude Code: could not reach the server"))
        XCTAssertEqual(model.machines[1].action, .retry)
        XCTAssertNil(model.machines[2].action, "the refused channel was never pressed")
        XCTAssertEqual(fake.log.count, 5, "nothing more ran")
        XCTAssertNil(model.running)

        // Try again: the same press, alone.
        model.press(.machine("kararla_hetzner"))
        XCTAssertEqual(fake.log.last, "machine kararla_hetzner")
        fake.answer(UpdatesModel.MachineResult(failure: nil, agents: [.codex]))
        XCTAssertEqual(model.machines[1].state, .updated)
        XCTAssertEqual(model.machines[1].lines.map(\.tone), [.neutral, .step],
                       "Codex takes approvals there too, and asks for its /hooks")
    }

    /// Single presses: Done once nothing old is left.
    func testSinglePressesEndInDone() {
        let fake = Fake(cards: [Self.card(.claude, .outdated)],
                        machines: [Self.machine("rasp", Self.connected, outdated: [.claude])])
        let model = model(fake)
        model.press(.agent(.claude))
        XCTAssertEqual(model.agents.first?.state, .updated)
        XCTAssertFalse(model.isDone, "a server is still old")
        model.press(.machine("rasp"))
        XCTAssertFalse(model.isDone, "running")
        fake.answer(UpdatesModel.MachineResult(failure: nil, agents: [.claude]))
        XCTAssertTrue(model.isDone)
        XCTAssertFalse(model.canUpdateAll)
    }

    /// Reopened while a server's job runs, the window keeps that row
    /// running and its buttons waiting; the job's late answer ends only
    /// its own run.
    func testReopeningKeepsARunningJob() {
        let fake = Fake(cards: [], machines: [Self.machine("a", Self.connected, outdated: [.claude]),
                                              Self.machine("b", Self.connected, outdated: [.claude])])
        let model = model(fake)
        model.press(.machine("a"))
        model.start()
        XCTAssertEqual(model.running, .machine("a"))
        XCTAssertEqual(model.machines.map(\.state), [.updating, .needsUpdate])
        XCTAssertFalse(model.canUpdateAll)
        fake.answer(UpdatesModel.MachineResult(failure: nil, agents: [.claude]))
        XCTAssertEqual(model.machines.first?.state, .updated)
        model.press(.machine("b"))
        XCTAssertEqual(model.running, .machine("b"))
    }

    /// An agent whose hooks are taken out while the window is open leaves
    /// it: "Up to date" would be untrue.
    func testAnAgentNoLongerOldLeavesOrReadsCurrent() {
        let fake = Fake(cards: [Self.card(.claude, .outdated), Self.card(.codex, .outdated)], machines: [])
        let model = model(fake)
        fake.cards = [Self.card(.claude, .missing), Self.card(.codex, .installed)]
        model.agentsChanged()
        XCTAssertEqual(model.agents.map(\.kind), [.agent(.codex)])
        XCTAssertEqual(model.agents.first?.state, .current)
    }

    /// "Why?" opens the advice under its row, and closes it.
    func testWhyOpensTheAdvice() {
        let model = model(mockup())
        let kind = UpdatesModel.Kind.machine("build-01")
        XCTAssertEqual(model.machines.last?.advice, L10n.t("remote.failure.forwardingRefused.advice", in: "en"))
        model.toggleWhy(kind)
        XCTAssertEqual(model.expanded, [kind])
        model.toggleWhy(kind)
        XCTAssertEqual(model.expanded, [])
    }

    /// A machine's press is the settings' job: the old agents as one write
    /// of `Change.agent` each, in the catalogue's order, and the command
    /// when it is old — what `needsUpdate` counts.
    func testTheMachinesOldPartsAreWhatNeedsUpdateCounts() throws {
        let tcp = "curl -s -m 2 -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:48151/hook >/dev/null 2>&1 || true"
        let old = try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [["type": "command", "command": tcp]]]]]])
        let current = try JSONSerialization.data(withJSONObject: LocalHooks.installing(into: [:], for: .codex, target: .server))
        let reading = RemoteSettings.Reading(
            files: [.claude: .success(RemoteSettings.Snapshot(bytes: old, checksum: "1 1")),
                    .codex: .success(RemoteSettings.Snapshot(bytes: current, checksum: "1 1")),
                    .antigravity: .failure(.noDirectory)],
            command: .installed(version: 1))
        XCTAssertEqual(RemoteMachinesModel.outdatedAgents(reading, enabled: nil), [.claude])
        XCTAssertEqual(RemoteMachinesModel.outdatedAgents(reading, enabled: [.codex]), [], "Claude is off there")
        XCTAssertTrue(RemoteMachinesModel.commandIsOld(reading))
        XCTAssertTrue(RemoteMachinesModel.needsUpdate(reading, enabled: [.codex]), "the command alone")
    }

    // MARK: - Automatic updates

    /// The window's heading and paragraph: the general one, or the socket's
    /// while an agent still holds the bytes from before it.
    func testTheParagraphFollowsTheCause() {
        let fake = mockup()
        let model = model(fake)
        XCTAssertEqual(model.title, "Evlat needs an update from you")
        XCTAssertEqual(model.body, L10n.t("updates.body.general", in: "en"))
        fake.predatesSocket = true
        model.start()
        XCTAssertEqual(model.body, L10n.t("updates.body", in: "en"))
    }

    /// The box comes checked; "Update all" with it checked turns automatic
    /// updates on, unchecked it writes nothing, and Later never writes.
    func testTheBoxAndUpdateAll() {
        let later = mockup()
        let first = model(later)
        XCTAssertTrue(first.keepCurrent, "checked by default")
        XCTAssertEqual(first.keepDetail, L10n.t("updates.keep.detail", in: "en"))
        first.close()
        XCTAssertNil(later.automatic, "Later writes nothing")

        let checked = mockup()
        let second = model(checked)
        second.updateAll()
        XCTAssertEqual(checked.automatic, true)
        XCTAssertEqual(second.keepDetail, L10n.t("updates.keep.on", in: "en"), "now it is the setting")

        let unchecked = mockup()
        let third = model(unchecked)
        third.setKeepCurrent(false)
        XCTAssertNil(unchecked.automatic, "a choice, not yet a write")
        third.updateAll()
        XCTAssertNil(unchecked.automatic, "unchecked: nothing written")

        // Turned off in Settings: the box comes unchecked, and "Update
        // all" leaves the choice alone.
        let off = mockup()
        off.automatic = false
        let fourth = model(off)
        XCTAssertFalse(fourth.keepCurrent)
        fourth.updateAll()
        XCTAssertEqual(off.automatic, false)
    }

    /// While automatic updates are on, the box is their switch: unchecking
    /// writes at once.
    func testWithAutomaticOnTheBoxIsTheSwitch() {
        let fake = mockup()
        fake.automatic = true
        let model = model(fake)
        XCTAssertTrue(model.keepCurrent)
        XCTAssertEqual(model.keepDetail, L10n.t("updates.keep.on", in: "en"))
        model.setKeepCurrent(false)
        XCTAssertEqual(fake.automatic, false)
        model.setKeepCurrent(true)
        XCTAssertEqual(fake.automatic, true)
    }

    /// At launch with automatic updates on: this Mac's old agents are
    /// updated with the automatic write, and the window is asked for only
    /// when something is left to the user.
    func testAutomaticUpdatesAreSilentUnlessSomethingIsLeft() {
        let quiet = Fake(cards: [Self.card(.claude, .outdated), Self.card(.antigravity, .outdated, enabled: false)],
                         machines: [])
        quiet.automatic = true
        let model = UpdatesModel(host: quiet.host, lang: "en")
        var asked = 0
        model.onNeedsUser = { asked += 1 }
        model.keepAgentsCurrent()
        XCTAssertEqual(quiet.log, ["keep claude"], "only an agent switched on with old hooks")
        XCTAssertEqual(asked, 0, "nothing left to the user: silent")

        let step = Fake(cards: [Self.card(.claude, .outdated), Self.card(.codex, .outdated)], machines: [])
        step.automatic = true
        let stepModel = UpdatesModel(host: step.host, lang: "en")
        stepModel.onNeedsUser = { asked += 1 }
        stepModel.keepAgentsCurrent()
        XCTAssertEqual(asked, 1, "Codex's /hooks")
        stepModel.opened()
        XCTAssertEqual(stepModel.agents.map(\.state), [.updated, .updated], "opened on its results, not afresh")
        XCTAssertEqual(stepModel.title, "Evlat updated its parts")
        XCTAssertEqual(stepModel.body, "Evlat kept its parts up to date, as you asked. One of them needs a step from you.")
        XCTAssertTrue(stepModel.isDone)
        XCTAssertEqual(stepModel.keepDetail, L10n.t("updates.keep.on", in: "en"))

        let refused = Fake(cards: [Self.card(.claude, .outdated)], machines: [])
        refused.refusals[.claude] = "Hooks: could not be written"
        let refusedModel = UpdatesModel(host: refused.host, lang: "en")
        asked = 0
        refusedModel.onNeedsUser = { asked += 1 }
        refusedModel.keepAgentsCurrent()
        XCTAssertEqual(asked, 1, "a refused write")
        XCTAssertEqual(refusedModel.body, L10n.t("updates.auto.body.failed", in: "en"))
    }

    /// A server is updated as it connects, with the automatic write; the
    /// window is asked for only for a step there or a failure.
    func testAServerIsUpdatedAsItConnects() {
        let fake = Fake(cards: [], machines: [Self.machine("rasp", Self.connected, outdated: [.claude]),
                                              Self.machine("box", Self.connected, outdated: [.codex])])
        fake.automatic = true
        let model = UpdatesModel(host: fake.host, lang: "en")
        var asked = 0
        model.onNeedsUser = { asked += 1 }
        model.keepMachineCurrent("rasp")
        XCTAssertEqual(fake.log, ["keep machine rasp"])
        fake.answer(UpdatesModel.MachineResult(failure: nil, agents: [.claude]))
        XCTAssertEqual(asked, 0, "Claude's hooks went in: silent")

        model.keepMachineCurrent("box")
        fake.answer(UpdatesModel.MachineResult(failure: nil, agents: [.codex]))
        XCTAssertEqual(asked, 1, "Codex there wants its /hooks")
        model.opened()
        XCTAssertEqual(model.machines.map(\.name), ["box"], "this result alone")
        XCTAssertEqual(model.machines.first?.state, .updated)
    }

    /// A server that joins results already told, and is refused, is told
    /// too; one whose job cannot start says so to its caller.
    func testAJoiningServerIsToldAndARefusedStartIsNotKept() {
        let fake = Fake(cards: [Self.card(.codex, .outdated)],
                        machines: [Self.machine("rasp", Self.connected, outdated: [.claude]),
                                   Self.machine("box", Self.connected, outdated: [.claude])])
        fake.automatic = true
        let model = UpdatesModel(host: fake.host, lang: "en")
        var asked = 0
        model.onNeedsUser = { asked += 1 }
        model.keepAgentsCurrent()
        XCTAssertEqual(asked, 1, "Codex's step")
        XCTAssertTrue(model.keepMachineCurrent("rasp"))
        XCTAssertTrue(model.keepMachineCurrent("box"), "waits its turn")
        fake.answer(UpdatesModel.MachineResult(failure: nil, agents: [.claude]))
        fake.answer(UpdatesModel.MachineResult(failure: "Claude Code: could not reach the server", agents: [.claude]))
        XCTAssertEqual(asked, 2, "the refusal is told though the set was")

        fake.pending.append(("other", { _ in }))
        fake.machines.append(Self.machine("other", Self.connected, outdated: [.claude]))
        XCTAssertFalse(model.keepMachineCurrent("other"), "another job runs there")
        XCTAssertFalse(model.machines.map(\.name).contains("other"))
    }

    func testEveryKeyIsInEveryTable() {
        for lang in L10nTests.languages {
            for key in UpdatesModel.keys + ["menu.updates", "updates.after.claude", "updates.step.codex",
                                            "settings.general.keepParts", "settings.general.keepParts.detail"] {
                XCTAssertNotNil(L10n.catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }

    // MARK: - Size

    /// A laptop's screen: 1440 × 900, the menu bar and a Dock left out.
    private static let laptop = CGRect(x: 0, y: 70, width: 1440, height: 805)

    func testOneRowIsAsTallAsItsContent() {
        let fit = UpdatesWindow.fit(fixed: 236, lists: 90, visible: CGSize(width: 1512, height: 949))
        XCTAssertEqual(fit, UpdatesWindow.Fit(size: CGSize(width: 740, height: 326), listsHeight: 90, scrolls: false))
    }

    func testThreeAgentsAndTwoServersFitWhole() {
        let fit = UpdatesWindow.fit(fixed: 236, lists: 3 * 53 + 2 * 53 + 2 * 34 + 22, visible: Self.laptop.size)
        XCTAssertFalse(fit.scrolls)
        XCTAssertEqual(fit.size.height, 236 + 355)
    }

    /// Past the screen only the lists give way: the heading and the footer
    /// keep their height, the lists scroll in what is left.
    func testFifteenServersOnANineHundredPointScreenScroll() {
        let lists: CGFloat = 18 * 53 + 2 * 34 + 22
        let fit = UpdatesWindow.fit(fixed: 236, lists: lists, visible: Self.laptop.size)
        XCTAssertTrue(fit.scrolls)
        XCTAssertEqual(fit.size.height, 805 - 2 * UpdatesWindow.margin)
        XCTAssertEqual(fit.listsHeight, fit.size.height - 236)
        let frame = UpdatesWindow.frame(fit.size, in: Self.laptop)
        XCTAssertTrue(Self.laptop.insetBy(dx: UpdatesWindow.margin, dy: UpdatesWindow.margin).contains(frame))
        XCTAssertEqual(frame.midX, Self.laptop.midX, accuracy: 1, "centred")
        XCTAssertEqual(frame.midY, Self.laptop.midY, accuracy: 1)
    }

    func testANarrowScreenNarrowsTheWindow() {
        let narrow = CGRect(x: 0, y: 0, width: 640, height: 480)
        let fit = UpdatesWindow.fit(fixed: 300, lists: 400, visible: narrow.size)
        XCTAssertEqual(fit.size, CGSize(width: 560, height: 400))
        XCTAssertEqual(fit.listsHeight, 100)
        XCTAssertTrue(fit.scrolls)
        XCTAssertTrue(narrow.contains(UpdatesWindow.frame(fit.size, in: narrow)))
    }

    /// Grown after it opened, the window keeps its top left corner while
    /// that fits, and moves just enough when it would not.
    func testGrowingKeepsTheTopUnlessTheScreenEnds() {
        let first = UpdatesWindow.frame(CGSize(width: 740, height: 300), in: Self.laptop)
        let grown = UpdatesWindow.frame(CGSize(width: 740, height: 400), in: Self.laptop, current: first)
        XCTAssertEqual(grown.maxY, first.maxY)
        XCTAssertEqual(grown.minX, first.minX)
        let low = CGRect(x: 100, y: 120, width: 740, height: 300)
        let tall = UpdatesWindow.frame(CGSize(width: 740, height: 600), in: Self.laptop, current: low)
        XCTAssertEqual(tall.minY, Self.laptop.minY + UpdatesWindow.margin, "pushed up off the Dock")
        XCTAssertTrue(Self.laptop.contains(tall))
    }

    /// Never off the screen, whatever the content and the screen.
    func testTheWindowNeverLeavesTheScreen() {
        let screens = [Self.laptop, CGRect(x: -1920, y: 0, width: 1920, height: 1055),
                       CGRect(x: 0, y: 0, width: 800, height: 560), CGRect(x: 0, y: 0, width: 300, height: 200)]
        for screen in screens {
            for fixed in stride(from: 0.0, through: 900, by: 150) {
                for lists in stride(from: 0.0, through: 3000, by: 250) {
                    let fit = UpdatesWindow.fit(fixed: fixed, lists: lists, visible: screen.size)
                    for current in [nil, CGRect(x: screen.maxX - 10, y: screen.minY - 50, width: 740, height: 300)] {
                        let frame = UpdatesWindow.frame(fit.size, in: screen, current: current)
                        XCTAssertTrue(screen.contains(frame), "\(frame) leaves \(screen)")
                    }
                    XCTAssertEqual(fit.scrolls, fit.listsHeight < lists.rounded(.up))
                }
            }
        }
    }

    // MARK: - The real window, offstage

    /// Built as the app builds it: the content measured, the rule applied.
    /// Long content scrolls inside a window that stays inside the screen;
    /// short content does not scroll.
    func testTheWindowFitsItsContentToTheScreen() throws {
        for (machines, scrolls) in [(15, true), (1, false)] {
            let fake = mockup()
            fake.machines = (1...machines).map { Self.machine("server-\($0)", Self.connected, outdated: [.claude]) }
            let model = model(fake)
            let window = UpdatesWindow.make(model: model, visible: { _ in Self.laptop })
            WindowStage.stage(window)
            window.orderFront(nil)
            defer { window.close() }
            var last = CGRect.zero
            for _ in 0..<40 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if window.frame == last, last.height > 0 { break }
                last = window.frame
            }
            XCTAssertTrue(Self.laptop.insetBy(dx: UpdatesWindow.margin, dy: UpdatesWindow.margin).contains(window.frame),
                          "\(window.frame)")
            let scroll = try XCTUnwrap(Self.scrollView(in: window.contentView), "the lists are in a scroll view")
            let document = try XCTUnwrap(scroll.documentView).frame.height
            XCTAssertEqual(document > scroll.contentView.bounds.height + 1, scrolls,
                           "\(machines) servers: \(document) in \(scroll.contentView.bounds.height)")
            if !scrolls {
                XCTAssertLessThan(window.frame.height, Self.laptop.height - 2 * UpdatesWindow.margin,
                                  "short content, a short window")
            }
        }
    }

    private static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    // MARK: - Pictures

    /// `EVLAT_SHOTS=<folder> swift test --filter UpdatesTests/testThePictures`:
    /// the four states as PNGs, drawn by `ImageRenderer` — no window, no
    /// screen. The lists are drawn clipped to the viewport the rule gives
    /// (`still`): a renderer draws no scroll view.
    func testThePictures() throws {
        guard let folder = ProcessInfo.processInfo.environment["EVLAT_SHOTS"] else {
            throw XCTSkip("EVLAT_SHOTS names no folder")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let big = CGRect(x: 0, y: 0, width: 1512, height: 949)

        // 1 · the mockup's first view.
        try draw(model(mockup()), on: big, to: out.appendingPathComponent("1-first.png"))

        // 2 · after "Update all": Claude Code and Codex written, Antigravity
        // refused, rasp written, kararla_hetzner still running.
        let results = mockup()
        results.refusals[.antigravity] = L10n.t("setup.agent.failure",
                                                ["part": L10n.t("setup.agent.part.hooks", in: "en"),
                                                 "reason": L10n.t("menu.hooks.error.unwritable", in: "en")], in: "en")
        let resultsModel = model(results)
        resultsModel.updateAll()
        results.answer(UpdatesModel.MachineResult(failure: nil, agents: [.claude]))
        try draw(resultsModel, on: big, to: out.appendingPathComponent("2-results.png"))

        // 3 · three agents and fifteen servers on a 900 pt screen with a Dock.
        let many = mockup()
        many.machines = (1...15).map { index in
            Self.machine(["rasp", "kararla_hetzner", "build", "staging-eu-west", "gpu-box"][index % 5] + "-\(index)",
                         Self.connected, outdated: index % 3 == 0 ? [.claude, .codex] : [.claude])
        }
        let fit = try draw(model(many), on: Self.laptop, to: out.appendingPathComponent("3-fifteen-servers.png"))
        XCTAssertTrue(fit.scrolls)
        try drawScreen(model(many), fit: fit, to: out.appendingPathComponent("3-fifteen-servers-on-screen.png"))

        // 4 · "Why?" open, and a long refusal that wraps.
        let why = mockup()
        why.cards[2] = Self.card(.antigravity, .outdated, failure: "Hooks: The settings file could not be written: "
            + "~/.gemini/config/hooks.json belongs to another user and its folder is read-only, so Evlat left it "
            + "as it was. Give your account write access to the folder, or remove the file, then try again.")
        why.machines.append(Self.machine("a-build-server-with-a-rather-long-name.internal.example.com",
                                         .waiting(retryAt: Date(), failure: .channelBusy)))
        let whyModel = model(why)
        whyModel.toggleWhy(.machine("build-01"))
        whyModel.toggleWhy(.machine("a-build-server-with-a-rather-long-name.internal.example.com"))
        try draw(whyModel, on: big, to: out.appendingPathComponent("4-why.png"))
    }

    /// `EVLAT_WINDOW_SHOTS=<folder> EVLAT_TEST_DESKTOP=1 swift test --filter
    /// UpdatesTests/testTheRealWindow`: the mockups' states c and d in the
    /// real window on the real screen, captured by `screencapture -l` — what
    /// a picture drawn without a window cannot show (the title bar's safe
    /// area, the footer's last points).
    func testTheRealWindow() throws {
        guard let folder = ProcessInfo.processInfo.environment["EVLAT_WINDOW_SHOTS"], !WindowStage.isOffstage else {
            throw XCTSkip("EVLAT_WINDOW_SHOTS names no folder, or the windows are offstage")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // c · automatic updates off: two agents and a server old, one not
        // connected yet.
        let open = Fake(cards: [Self.card(.claude, .outdated), Self.card(.codex, .outdated)],
                        machines: [Self.machine("rasp", Self.connected, outdated: [.claude], command: true),
                                   Self.machine("kararla_hetzner", .connecting)])
        try capture(model(open), to: out.appendingPathComponent("c-automatic-off.png"))

        // d · automatic updates on: what they did, Codex's step left.
        let done = Fake(cards: [Self.card(.claude, .outdated), Self.card(.codex, .outdated)],
                        machines: [Self.machine("rasp", Self.connected, outdated: [.claude])])
        done.automatic = true
        let results = UpdatesModel(host: done.host, lang: "en")
        results.keepAgentsCurrent()
        results.isShown = { true }
        results.keepMachineCurrent("rasp")
        done.answer(UpdatesModel.MachineResult(failure: nil, agents: [.claude]))
        results.isShown = { false }
        try capture(results, to: out.appendingPathComponent("d-results.png"))
    }

    private func capture(_ model: UpdatesModel, to url: URL) throws {
        let window = UpdatesWindow.make(model: model)
        defer { window.close() }
        window.center()
        window.orderFrontRegardless()
        var last = CGRect.zero
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if window.frame == last, last.height > 0 { break }
            last = window.frame
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// The window's content as the rule sizes it on `screen`, at 2×.
    @discardableResult
    private func draw(_ model: UpdatesModel, on screen: CGRect, to url: URL) throws -> UpdatesWindow.Fit {
        let width = UpdatesWindow.width(visible: screen.width)
        let probe = UpdatesView(model: model, measure: UpdatesMeasure(width: width), still: true)
        let fixed = height(probe.header, width) + height(probe.footer, width)
        let fit = UpdatesWindow.fit(fixed: fixed, lists: height(probe.lists, width), visible: screen.size)
        let view = UpdatesView(model: model, measure: UpdatesMeasure(width: width, listsHeight: fit.listsHeight), still: true)
            .frame(width: fit.size.width, height: fit.size.height)
            .environment(\.colorScheme, .light)
        try write(view, scale: 2, to: url)
        return fit
    }

    /// The same, placed on a 1440 × 900 screen with its menu bar and Dock.
    private func drawScreen(_ model: UpdatesModel, fit: UpdatesWindow.Fit, to url: URL) throws {
        let frame = UpdatesWindow.frame(fit.size, in: Self.laptop)
        let width = UpdatesWindow.width(visible: Self.laptop.width)
        let window = UpdatesView(model: model, measure: UpdatesMeasure(width: width, listsHeight: fit.listsHeight),
                                 still: true)
            .frame(width: fit.size.width, height: fit.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .compositingGroup()
            .shadow(radius: 12)
        let screen = ZStack(alignment: .topLeading) {
            Color(white: 0.78)
            Color(white: 0.95).frame(height: 25)
            Color(white: 0.6).frame(height: 70).offset(y: 900 - 70)
            window.offset(x: frame.minX, y: 900 - frame.maxY)
        }
        .frame(width: 1440, height: 900, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        try write(screen, scale: 1, to: url)
    }

    private func height(_ view: some View, _ width: CGFloat) -> CGFloat {
        NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .light)).fittingSize.height
    }

    private func write(_ view: some View, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "nothing drawn")
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
