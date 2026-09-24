import AppKit
import SwiftUI
import EvlatCore

/// The one window Evlat has: the remote machines, opened from either menu.
///
/// **The focus rule loosens here, and only here.** The bar is a
/// non-activating panel and stays one; this is an ordinary titled window the
/// user asked for, with a field to type into, so opening it brings Evlat
/// forward. Closing it hands the focus back to the app that was in front
/// before — an accessory app left active with no window would otherwise keep
/// it.
///
/// One instance: a second open brings the same window forward.
@MainActor
final class RemoteMachinesWindow: NSObject, NSWindowDelegate {
    let model: RemoteMachinesModel
    private(set) var window: RemoteWindow?
    /// The app in front when the window was opened, given the focus back on
    /// close. Kept across a second open: by then Evlat is in front.
    private var previous: NSRunningApplication?
    private let frontmost: () -> NSRunningApplication?
    private let activate: @MainActor () -> Void
    private let restore: @MainActor (NSRunningApplication) -> Void

    /// The three focus calls are handed in so a test never activates the
    /// runner or another app. The default restore does nothing unless Evlat
    /// is active — when nothing took the focus, there is nothing to give back.
    init(model: RemoteMachinesModel,
         frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         activate: @escaping @MainActor () -> Void = { NSApp.activate() },
         restore: @escaping @MainActor (NSRunningApplication) -> Void = { app in
             if NSApp.isActive { app.activate() }
         }) {
        self.model = model
        self.frontmost = frontmost
        self.activate = activate
        self.restore = restore
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        // Whoever is in front now gets the focus back — unless that is Evlat
        // itself (a second open while the window is already key), when the
        // one recorded before is kept.
        let front = frontmost()
        if let front, front.processIdentifier != getpid() {
            previous = front
        } else if !isVisible {
            previous = nil
        }
        if !isVisible { model.reload() }
        let window = self.window ?? makeWindow()
        if self.window == nil {
            self.window = window
            window.center()
        }
        activate()
        window.makeKeyAndOrderFront(nil)
    }

    func makeWindow() -> RemoteWindow {
        let window = RemoteWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.title = model.t("remote.window.title")
        // Kept for the next open; released, a second open would reach a
        // freed window.
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 420)
        window.contentViewController = NSHostingController(rootView: RemoteMachinesView(model: model))
        window.setContentSize(NSSize(width: 680, height: 500))
        window.delegate = self
        window.onCancel = { [weak self, weak window] in
            guard let self else { return }
            // Esc answers the open question first, then closes.
            if self.model.confirmingRemoval != nil {
                self.model.cancelRemoval()
            } else {
                window?.close()
            }
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelRemoval()
        guard let previous else { return }
        self.previous = nil
        restore(previous)
    }
}

/// The window's keys. Evlat has no main menu (an accessory app), and a
/// hosted field's Cut, Copy, Paste, Select All and Undo arrive through the
/// main menu's key equivalents — without these the field would take no
/// pasted `user@host`. Esc and ⌘W go the same way.
final class RemoteWindow: NSWindow {
    var onCancel: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func sendEvent(_ event: NSEvent) {
        // A field being edited keeps Esc to itself (its completion), so the
        // key is taken before it gets there.
        // Not while an input method is composing: there Esc cancels the
        // half-typed text.
        let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
        if event.type == .keyDown, event.keyCode == 53, !composing,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onCancel()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch (key, flags == .command) {
        case ("w", true): performClose(nil); return true
        case ("x", true): action = #selector(NSText.cut(_:))
        case ("c", true): action = #selector(NSText.copy(_:))
        case ("v", true): action = #selector(NSText.paste(_:))
        case ("a", true): action = #selector(NSText.selectAll(_:))
        case ("z", true): action = Selector(("undo:"))
        case ("z", false): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - The view

/// Sidebar of machines with the target field under it; the selected
/// machine's status, its two setup paths side by side, and its removal on the
/// right. With no machine, one centred invitation instead.
struct RemoteMachinesView: View {
    @ObservedObject var model: RemoteMachinesModel

    var body: some View {
        Group {
            if model.rows.isEmpty {
                RemoteEmptyState(model: model)
            } else {
                HStack(spacing: 0) {
                    RemoteSidebar(model: model)
                        .frame(width: 220)
                    Divider()
                    if let row = model.selectedRow {
                        RemoteDetail(model: model, row: row)
                            .id(row.id)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 420)
    }
}

extension RemoteMachinesModel.Tone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return .green
        case .trouble: return .orange
        }
    }
}

/// The target field and its button. Return adds; a refusal is one line
/// under it, in words, and the field keeps what was typed.
private struct RemoteAddField: View {
    @ObservedObject var model: RemoteMachinesModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(model.t("remote.add.placeholder"), text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.add() }
                    .disableAutocorrection(true)
                Button(model.t("remote.add")) { model.add() }
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem = model.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if model.rows.isEmpty { focused = true } }
    }
}

private struct RemoteEmptyState: View {
    @ObservedObject var model: RemoteMachinesModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text(model.t("remote.empty.title"))
                .font(.title2.weight(.semibold))
            Text(model.t("remote.empty.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RemoteAddField(model: model)
                .frame(maxWidth: 360)
                .padding(.top, 6)
            Text(model.t("remote.empty.requirement"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !model.isStored {
                Text(model.t("remote.environment"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: 440)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RemoteSidebar: View {
    @ObservedObject var model: RemoteMachinesModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.status)
                            .font(.caption)
                            .foregroundStyle(row.tone == .trouble ? Color.orange : Color.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(row.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                RemoteAddField(model: model)
                if !model.isStored {
                    Text(model.t("remote.environment"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
    }
}

private struct RemoteDetail: View {
    @ObservedObject var model: RemoteMachinesModel
    let row: RemoteMachinesModel.Row

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.t("remote.setup"))
                            .font(.headline)
                        Spacer()
                        Picker("", selection: $model.mode) {
                            Text(model.t("remote.setup.automatic")).tag(RemoteMachinesModel.SetupMode.automatic)
                            Text(model.t("remote.setup.manual")).tag(RemoteMachinesModel.SetupMode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    switch model.mode {
                    case .automatic: RemoteAutomatic(model: model, row: row)
                    case .manual: RemoteManual(model: model)
                    }
                }
                Divider()
                removal
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.target != row.name {
                    Text(row.target)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(row.tone.color)
                    .frame(width: 7, height: 7)
                Text(row.status)
                    .foregroundStyle(row.tone == .trouble ? Color.orange : Color.primary)
            }
            if let advice = row.advice {
                Text(advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var removal: some View {
        if model.confirmingRemoval == row.id {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.t("remote.remove.confirm", ["name": row.name]))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(model.t("remote.remove.cancel")) { model.cancelRemoval() }
                    // Not the default button: Return must never remove.
                    Button(model.t("remote.remove.do"), role: .destructive) { model.confirmRemoval() }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
        } else {
            HStack {
                Spacer()
                Button(model.t("remote.remove"), role: .destructive) { model.askToRemove() }
            }
        }
    }
}

private struct RemoteAutomatic: View {
    @ObservedObject var model: RemoteMachinesModel
    let row: RemoteMachinesModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("remote.auto.body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    button(.installHooks)
                    button(.removeHooks)
                }
                GridRow {
                    button(.installUsage)
                    button(.removeUsage)
                }
            }
            if model.isBusy(row.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.t("remote.auto.busy", ["name": row.name]))
                        .foregroundStyle(.secondary)
                }
            } else if let outcome = model.outcomes[row.id] {
                VStack(alignment: .leading, spacing: 4) {
                    Text(outcome.line)
                        .foregroundStyle(outcome.trouble ? Color.orange : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    ForEach(outcome.hints, id: \.self) { hint in
                        Text(hint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func button(_ job: RemoteMachinesModel.Job) -> some View {
        Button { model.run(job) } label: {
            Text(model.t(job.titleKey)).frame(maxWidth: .infinity)
        }
        .disabled(!model.canRun(row.id))
    }
}

private struct RemoteManual: View {
    @ObservedObject var model: RemoteMachinesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("remote.manual.body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(RemoteMachinesModel.blocks) { block in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.t(block.captionKey, ["placeholder": RemoteSettings.Manual.placeholder]))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button(model.copied == block.id ? model.t("remote.copied") : model.t("remote.copy")) {
                            model.copy(block)
                        }
                        .controlSize(.small)
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(block.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: block.text.count > 400 ? 150 : nil)
                    .fixedSize(horizontal: false, vertical: block.text.count <= 400)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }
            Text(model.t("remote.manual.remove", ["marker": RemoteSettings.manual.marker]))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.t("remote.manual.surface"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
