import AppKit
import SwiftUI

/// A window Evlat opens because the user asked for one — the settings and
/// the setup. The focus pattern of the remote machines' own window, since
/// folded into the settings, made general.
///
/// **The focus rule loosens here, and only here.** The bar is a
/// non-activating panel and stays one; this is an ordinary titled window
/// with fields and a shortcut recorder, so opening it brings Evlat forward.
/// Closing it hands the focus back to the app that was in front before —
/// by activating that app: `NSApp.deactivate()` is not synchronous
/// (`AGENTS.md` → Pitfalls), and an accessory app left active with no
/// window would otherwise keep it.
///
/// One instance: a second open brings the same window forward.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {
    private(set) var window: AppKeyWindow?
    /// The app in front when the window was opened, given the focus back on
    /// close. Kept across a second open: by then Evlat is in front.
    private var previous: NSRunningApplication?
    private let frontmost: () -> NSRunningApplication?
    private let activate: @MainActor () -> Void
    private let restore: @MainActor (NSRunningApplication) -> Void
    private let make: @MainActor () -> AppKeyWindow

    /// Before each open that finds the window hidden: fresh reads.
    var onOpen: () -> Void = {}
    /// Esc and the window's cancel: `true` when something open inside took
    /// it (a question, a recording); `false` closes the window.
    var onCancel: () -> Bool = { false }
    /// Lost the keyboard (a click in another app): a recording stops.
    var onResignKey: () -> Void = {}
    /// Every key, before the window's own handling; `true` takes it.
    var keyInterceptor: (NSEvent) -> Bool = { _ in false }
    var onClose: () -> Void = {}

    /// The three focus calls are handed in so a test never activates the
    /// runner or another app. The default restore does nothing unless Evlat
    /// is active — when nothing took the focus, there is nothing to give back.
    init(make: @escaping @MainActor () -> AppKeyWindow,
         frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         activate: @escaping @MainActor () -> Void = { WindowStage.activate() },
         restore: @escaping @MainActor (NSRunningApplication) -> Void = { app in
             if NSApp.isActive { WindowStage.activate(app) }
         }) {
        self.make = make
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
        if !isVisible { onOpen() }
        let window = self.window ?? build()
        activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The window, made once; its keys go through this object's closures.
    @discardableResult
    func build() -> AppKeyWindow {
        if let window { return window }
        let window = make()
        WindowStage.stage(window)
        // Kept for the next open; released, a second open would reach a
        // freed window.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onCancel = { [weak self, weak window] in
            guard let self else { return }
            if !self.onCancel() { window?.close() }
        }
        window.onResignKey = { [weak self] in self?.onResignKey() }
        window.keyInterceptor = { [weak self] in self?.keyInterceptor($0) ?? false }
        window.center()
        self.window = window
        return window
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        onClose()
        guard let previous else { return }
        self.previous = nil
        restore(previous)
    }
}

/// The window's keys. Evlat has no main menu (an accessory app), and a
/// hosted field's Cut, Copy, Paste, Select All and Undo arrive through the
/// main menu's key equivalents — without these a field would take no pasted
/// `user@host`. Esc and ⌘W go the same way.
final class AppKeyWindow: NSWindow {
    var onCancel: () -> Void = {}
    var onResignKey: () -> Void = {}
    /// Sees each key first: the shortcut recorder takes every key while it
    /// records, Esc included, before a field or the window's close does.
    var keyInterceptor: (NSEvent) -> Bool = { _ in false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyInterceptor(event) { return }
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
        // A shortcut being recorded is not a key equivalent (⌥⌘W, ⌘J…).
        if event.type == .keyDown, keyInterceptor(event) { return true }
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
