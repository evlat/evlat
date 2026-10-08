import XCTest
import AppKit
import SwiftUI
import EvlatCore
@testable import EvlatAgents
@testable import EvlatApp

/// The setup's fixed frame: every step fits its body in every language in the
/// most crowded place it can be, and the footer's primary button is the same
/// size in the same place on every step. A text that does not fit is cut off
/// on screen and nowhere else, so these are the only place it is seen.
///
/// `EVLAT_SHOTS=<folder> swift test --filter SetupViewTests/testThePictures`
/// draws the four steps and three more places as PNGs for looking beside the
/// design.
@MainActor
final class SetupViewTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var controllers: [AppController] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.view.\(UUID().uuidString)", isDirectory: true)
        suiteName = "evlat.tests.view.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        for controller in controllers { controller.panel?.close() }
        controllers = []
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A place the setup can open in.
    private enum Place: CaseIterable {
        /// Three agents, none connected, sessions open, a window over the
        /// edge, an updater: the most the first step, the bar and the last
        /// step have to say.
        case crowded
        /// Something connected, something old, something not yet.
        case reopened
        /// No agent on this Mac.
        case empty
        /// Three connected agents on the second step, one heard.
        case listening
        /// ... and all of them.
        case heard
    }

    private func flow(_ place: Place, step: SetupFlowModel.Step, covered: Bool = true, language: String = "en") throws
        -> SetupFlowModel {
        let fresh = root.appendingPathComponent("\(UUID().uuidString)", isDirectory: true)
        let dirs: [String] = place == .empty ? [] : [".claude", ".codex", ".gemini/antigravity-cli"]
        for directory in dirs {
            try FileManager.default.createDirectory(at: fresh.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
        }
        switch place {
        case .reopened:
            try AgentIntegration.install(home: fresh, for: .codex)
            try JSONSerialization.data(withJSONObject: [
                "hooks": ["Stop": [["hooks": [["type": "command", "command": "curl http://127.0.0.1:48151/hook"]]]]]])
                .write(to: Claude().hooksFile(home: fresh))
        case .listening, .heard:
            for source in Agents.all.ids { try AgentIntegration.install(home: fresh, for: source.agent) }
        case .crowded, .empty:
            break
        }
        let controller = AppController(defaults: defaults, home: fresh, loginItem: LoginItem(service: LoginItem.inMemory()))
        controller.installPanel()
        controllers.append(controller)
        let contents = fresh.appendingPathComponent("Evlat.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let binary = contents.appendingPathComponent("MacOS/Evlat")
        try Data().write(to: binary)
        controller.executable = binary
        var settings = controller.settingsHost
        settings.openSessions = { [.claude: 3, .codex: 2, .antigravity: 1] }
        settings.edgeCovered = { covered }
        settings.hasUpdater = { true }
        let flow = SetupFlowModel(settings: settings, setup: SetupModel(host: controller.setupHost, lang: language),
                                  close: {}, lang: language)
        flow.start(at: step, firstRun: place == .crowded)
        switch place {
        case .listening:
            flow.heard(event(.claude, cwd: "/Users/me/a-rather-long-project-folder-name"))
        case .heard:
            for source in Agents.all.ids { flow.heard(event(source, cwd: "/Users/me/a-rather-long-project-folder-name")) }
        default:
            break
        }
        return flow
    }

    private func event(_ source: AgentID, cwd: String) -> HookEvent {
        HookEvent(json: ["hook_event_name": "UserPromptSubmit", "session_id": "s-\(source.rawValue)", "cwd": cwd],
                  source: source)
    }

    /// The places and steps that are the fullest: the body at its natural
    /// height must stay within the frame's.
    private static let cases: [(Place, SetupFlowModel.Step)] = [
        (.crowded, .agents), (.reopened, .agents), (.empty, .agents),
        (.listening, .connected), (.heard, .connected),
        (.crowded, .bar), (.crowded, .finish), (.reopened, .finish),
    ]

    private func naturalHeight(_ flow: SetupFlowModel, _ step: SetupFlowModel.Step) -> CGFloat {
        NSHostingView(rootView: SetupStepBody(model: flow, setup: flow.setup, step: step)
            .environment(\.colorScheme, .dark)).fittingSize.height
    }

    /// Every step, in every language, in its fullest place, fits the body
    /// the frame leaves above the footer: a step that does not is named with
    /// its language, so the translation can be shortened.
    func testEveryStepFitsItsFrameInEveryLanguage() throws {
        var overflows: [String] = []
        var tightest: (String, CGFloat) = ("", 0)
        for language in L10nTests.languages {
            for (place, step) in Self.cases {
                for covered in [true, false] where step == .bar || covered {
                    let flow = try flow(place, step: step, covered: covered, language: language)
                    let height = naturalHeight(flow, step)
                    if ProcessInfo.processInfo.environment["EVLAT_SHOW_HEIGHTS"] != nil {
                        print("setup height \(language) \(step.rawValue) \(place) covered=\(covered): \(height)")
                    }
                    if height > SetupLayout.bodyHeight {
                        overflows.append("\(language) \(step.rawValue) \(place) covered=\(covered): "
                            + "\(Int(height.rounded(.up))) pt > \(Int(SetupLayout.bodyHeight)) pt")
                    }
                    if height > tightest.1 { tightest = ("\(language) \(step.rawValue) \(place)", height) }
                }
            }
        }
        print("setup: the fullest body is \(tightest.0) at \(tightest.1) of \(SetupLayout.bodyHeight) pt")
        XCTAssertEqual(overflows, [], "these do not fit the frame")
    }

    /// The window the steps live in is 380 × 460 whatever step it is on.
    func testTheViewIsTheSameSizeOnEveryStep() throws {
        for step in SetupFlowModel.Step.allCases {
            let flow = try flow(.crowded, step: step)
            let size = NSHostingView(rootView: SetupView(model: flow)).fittingSize
            XCTAssertEqual(size.width, SetupLayout.size.width, accuracy: 0.5, "\(step)")
            XCTAssertEqual(size.height, SetupLayout.size.height, accuracy: 0.5, "\(step)")
        }
    }

    /// "Continue", "Connect", "Update" and "Finish" fit the button, and the
    /// whole footer fits the frame, in every language: nothing is squeezed.
    /// The first step's footer is the widest it gets ("Not now" and the
    /// progress); the others carry "Back" instead.
    func testTheFooterFitsTheFrameInEveryLanguage() throws {
        var overflows: [String] = []
        for language in L10nTests.languages {
            for step in [SetupFlowModel.Step.agents, .bar] {
                let model = try flow(.crowded, step: step, language: language)
                let width = NSHostingView(rootView: SetupFooter(model: model).environment(\.colorScheme, .dark))
                    .fittingSize.width
                if width > SetupLayout.size.width { overflows.append("\(language) \(step): footer \(Int(width.rounded(.up))) pt") }
            }
            let model = try flow(.crowded, step: .agents, language: language)
            for key in ["setup.flow.continue", "setup.flow.connect", "setup.flow.update", "setup.flow.finish"] {
                let label = NSHostingView(rootView: SetupPrimaryLabel(text: model.t(key))
                    .font(.system(size: 14, weight: .semibold)).environment(\.colorScheme, .dark)).fittingSize.width
                if label > SetupLayout.primary.width - 16 {
                    overflows.append("\(language) \(key): \(Int(label.rounded(.up))) pt in \(Int(SetupLayout.primary.width)) pt")
                }
            }
        }
        XCTAssertEqual(overflows, [])
    }

    /// The primary button is one rectangle on all four steps, in every
    /// language: found by its light fill in a picture of the footer.
    func testThePrimaryButtonIsTheSameRectangleOnEveryStep() throws {
        var boxes: [String: CGRect] = [:]
        for language in ["en", "tr", "de", "ru", "ja"] {
            for step in SetupFlowModel.Step.allCases {
                let place: Place = step == .connected ? .listening : .crowded
                let flow = try flow(place, step: step, language: language)
                let footer = SetupFooter(model: flow).frame(width: SetupLayout.size.width, height: SetupLayout.footerHeight)
                    .background(SetupPalette.groundBottom).environment(\.colorScheme, .dark)
                boxes["\(language) \(step.rawValue)"] = try lightBox(of: footer, size: CGSize(width: 380, height: 72), fromX: 200)
            }
        }
        let first = try XCTUnwrap(boxes.values.first)
        XCTAssertEqual(first.width, SetupLayout.primary.width, accuracy: 1.5)
        XCTAssertEqual(first.height, SetupLayout.primary.height, accuracy: 1.5)
        XCTAssertEqual(first.maxX, SetupLayout.size.width - 20, accuracy: 1.5, "the footer's right padding")
        for (name, box) in boxes {
            XCTAssertEqual(box.minX, first.minX, accuracy: 1, name)
            XCTAssertEqual(box.minY, first.minY, accuracy: 1, name)
            XCTAssertEqual(box.width, first.width, accuracy: 1, name)
            XCTAssertEqual(box.height, first.height, accuracy: 1, name)
        }
    }

    // MARK: - Pictures

    /// The box of the pixels lighter than the footer's text from `fromX` on.
    private func lightBox(of view: some View, size: CGSize, fromX: Int) throws -> CGRect {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "nothing drawn")
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in fromX..<width {
                let index = (y * width + x) * 4
                if (Int(data[index]) + Int(data[index + 1]) + Int(data[index + 2])) / 3 > 200 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, 0, "no primary button in the picture")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The four steps as PNGs, drawn by `ImageRenderer` — no window, no
    /// screen — and three more places for the first step's range.
    func testThePictures() throws {
        guard let folder = ProcessInfo.processInfo.environment["EVLAT_SHOTS"] else {
            throw XCTSkip("EVLAT_SHOTS names no folder")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let language = ProcessInfo.processInfo.environment["EVLAT_SHOTS_LANGUAGE"] ?? "tr"
        func draw(_ place: Place, _ step: SetupFlowModel.Step, as name: String) throws {
            let flow = try flow(place, step: step, language: language)
            let view = SetupView(model: flow, still: true)
                .frame(width: SetupLayout.size.width, height: SetupLayout.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "nothing drawn")
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: out.appendingPathComponent(name + ".png"))
        }
        // The panel as the window holds it: the tail toward the bar, the
        // shadow in the transparent room, the tail's height as set.
        func drawPanel(_ edge: BarPanel.Edge, center: CGFloat, as name: String) throws {
            let tail = SetupTail()
            tail.set(edge: edge, center: center)
            let view = SetupPanelView(model: try flow(.crowded, step: .bar, language: language), tail: tail)
                .frame(width: SetupPanel.size.width, height: SetupPanel.size.height)
                .background(Color.gray.opacity(0.5))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "nothing drawn")
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: out.appendingPathComponent(name + ".png"))
        }
        try drawPanel(.right, center: 230, as: "8-panel-right")
        try drawPanel(.left, center: SetupPanel.tailReach, as: "9-panel-left-high")
        try draw(.crowded, .agents, as: "1-agents")
        try draw(.listening, .connected, as: "2-connected")
        try draw(.crowded, .bar, as: "3-bar")
        try draw(.crowded, .finish, as: "4-finish")
        try draw(.reopened, .agents, as: "5-reopened")
        try draw(.empty, .agents, as: "6-none")
        try draw(.heard, .connected, as: "7-heard")
    }
}
