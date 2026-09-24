import AppKit
import Carbon.HIToolbox
import Foundation

/// A key and its modifiers: what the balloon's shortcut is.
///
/// The modifiers are `NSEvent`'s flags, masked to the four a shortcut is
/// made of — the same bits `com.apple.symbolichotkeys` stores, so a
/// comparison with the system's needs no translation. The key is a virtual
/// key code, which Carbon takes as it is.
struct HotKeyCombination: Equatable {
    static let modifierMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.modifierMask)
    }

    /// ⇧⌘Space (`011`, after `phase-2`): ⌥Space is Claude.app's Quick Entry,
    /// ChatGPT's and Gemini's on this machine, and Carbon does not report
    /// another process holding a key — one press opened two apps. ⌃⌥Space is
    /// macOS's next input source (symbolic hot key 61).
    static let standard = HotKeyCombination(keyCode: UInt16(kVK_Space), modifiers: [.shift, .command])

    /// A pressed key as a shortcut, or `nil` when it cannot be one: without
    /// ⌃, ⌥ or ⌘ it would take a key from typing (⇧ alone is a capital).
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection(Self.modifierMask)
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// ⌘ (or ⇧⌘) with a character key is an app's own shortcut — ⌘V, ⌘Q,
    /// ⇧⌘Z — and a global hot key would take it from every app. With ⌘ alone
    /// only Space and the F-keys are offered; else ⌃ or ⌥ is needed.
    var takesAnAppShortcut: Bool {
        guard modifiers.contains(.command), modifiers.isSubset(of: [.command, .shift]) else { return false }
        return keyCode != UInt16(kVK_Space) && !Self.functionKeys.contains(Int(keyCode))
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    var carbonModifiers: UInt32 {
        var carbon = 0
        if modifiers.contains(.shift) { carbon |= shiftKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.command) { carbon |= cmdKey }
        return UInt32(carbon)
    }

    /// "⇧⌘Space": the modifiers in the order macOS's menus write them.
    var title: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// Keys whose name is not the character they type. "Space" is written
    /// out in both languages, as macOS's own shortcut lists do.
    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The key's name on the current keyboard layout, so a stored code reads
    /// as the key the user pressed (Turkish-Q's "Ş" is ANSI ";"'s place).
    static func keyName(_ keyCode: UInt16) -> String {
        if let name = names[Int(keyCode)] { return name }
        return typedCharacter(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    private static func typedCharacter(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                  characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: - Stored

    /// `["keyCode": Int, "modifiers": Int]`, the flags' raw value.
    var stored: [String: Int] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)]
    }

    /// `nil` for anything that is not a combination the recorder could have
    /// made: the default then stands rather than a key nobody chose.
    init?(stored: Any?) {
        guard let dictionary = stored as? [String: Any],
              let keyCode = dictionary["keyCode"] as? Int, let raw = dictionary["modifiers"] as? Int,
              (0...Int(UInt16.max)).contains(keyCode), raw >= 0 else { return nil }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(raw)).intersection(Self.modifierMask)
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
        self.init(keyCode: UInt16(keyCode), modifiers: modifiers)
    }
}

/// The shortcuts macOS itself takes (System Settings → Keyboard → Keyboard
/// Shortcuts): `com.apple.symbolichotkeys`'s `AppleSymbolicHotKeys`, read and
/// never written. Each entry is `{enabled, value: {parameters: [character,
/// keyCode, modifiers]}}`, the modifiers in `NSEvent`'s bits (arrow and
/// function keys add `.function`, masked away here as on the recorder's side).
///
/// Only the system's: other apps' shortcuts are not visible to Evlat — Carbon
/// does not report them either (measured, `phase-2`) — and nothing here
/// claims otherwise.
struct SystemHotKeys {
    /// The entries by id, as the preferences hold them; handed in by a test.
    let entries: [String: Any]

    init(entries: [String: Any]) {
        self.entries = entries
    }

    /// The live table. Read each time the recorder opens: a shortcut turned
    /// on in System Settings since is seen.
    static func current() -> SystemHotKeys {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                              "com.apple.symbolichotkeys" as CFString)
        return SystemHotKeys(entries: value as? [String: Any] ?? [:])
    }

    /// The id of an **enabled** system shortcut on the same combination, the
    /// lowest when several are; `nil` when none. Entries with no key
    /// (`65535`) or no parameters are nobody's.
    func conflict(with combination: HotKeyCombination) -> Int? {
        let mask = Int(HotKeyCombination.modifierMask.rawValue)
        let ids = entries.compactMap { key, value -> Int? in
            guard let id = Int(key), let entry = value as? [String: Any],
                  (entry["enabled"] as? Bool ?? ((entry["enabled"] as? Int).map { $0 != 0 })) == true,
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int],
                  parameters.count >= 3, parameters[1] != 0xFFFF,
                  parameters[1] == Int(combination.keyCode),
                  parameters[2] & mask == Int(combination.modifiers.rawValue) else { return nil }
            return id
        }
        return ids.min()
    }

    /// What the recorder says the shortcut is for: the ids macOS ships
    /// enabled, grouped as System Settings groups them; the rest are "a
    /// system shortcut", not a guessed name.
    static func nameKey(_ id: Int) -> String {
        switch id {
        case 60, 61: return "hotkey.system.inputSource"
        case 64: return "hotkey.system.spotlight"
        case 65: return "hotkey.system.finderSearch"
        case 28, 29, 30, 31, 184: return "hotkey.system.screenshot"
        case 32, 33, 34, 35: return "hotkey.system.missionControl"
        case 36, 37: return "hotkey.system.desktop"
        case 79, 80, 81, 82, 118...133: return "hotkey.system.spaces"
        default: return "hotkey.system.other"
        }
    }

    static let nameKeys = ["hotkey.system.inputSource", "hotkey.system.spotlight", "hotkey.system.finderSearch",
                           "hotkey.system.screenshot", "hotkey.system.missionControl", "hotkey.system.desktop",
                           "hotkey.system.spaces", "hotkey.system.other"]
}

/// What the controller needs of a global shortcut; the real one is `HotKey`,
/// a test hands a fake so the suite never takes the user's shortcut.
protocol HotKeyRegistration: AnyObject {
    /// Carbon's answer; registering the registered combination again is
    /// `noErr`, a different one replaces it.
    func register(_ combination: HotKeyCombination) -> OSStatus
    func unregister()
}

/// The balloon's shortcut (`011`, Karar 6): Carbon's `RegisterEventHotKey`.
///
/// **Not `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`:** that one
/// listens to every key and needs Accessibility; this asks the system to
/// deliver one combination and needs no permission.
///
/// Measured (`phase-2`): with ⌥Space held by another process (Claude's
/// Quick Entry) the call still returns `noErr` — Carbon does not report a
/// combination another app holds. Only the same process registering it
/// twice fails (`eventHotKeyExistsErr`, -9878). The menu's line is for a
/// failure, not a guess about who else wants the key.
///
/// Main thread: the handler runs on the application's event target.
final class HotKey: HotKeyRegistration {
    /// The combination registered now; `nil` while none is.
    private(set) var combination: HotKeyCombination?
    /// Called on the main thread when the combination is pressed.
    var onPress: (() -> Void)?

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32

    /// "EVLT": the hot key's signature, so a press is known to be ours.
    static let signature: OSType = 0x4556_4C54
    private static var nextID: UInt32 = 1

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    deinit { unregister() }

    func register(_ combination: HotKeyCombination) -> OSStatus {
        if reference != nil {
            guard self.combination != combination else { return noErr }
            // Another combination: the old one goes first, the handler stays.
            if let reference { UnregisterEventHotKey(reference) }
            reference = nil
            self.combination = nil
        }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            // Unretained: `unregister` (and `deinit`) removes the handler
            // before this object can go.
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                             EventParamType(typeEventHotKeyID), nil,
                                             MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                // Every hot key of the process arrives at every handler:
                // only this one's id is taken.
                guard read == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                    return OSStatus(eventNotHandledErr)
                }
                hotKey.onPress?()
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combination.keyCode), combination.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            reference = ref
            self.combination = combination
        }
        return status
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        combination = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
