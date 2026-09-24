import Carbon.HIToolbox
import Foundation

/// What the controller needs of a global shortcut; the real one is `HotKey`,
/// a test hands a fake so the suite never takes the user's ⌥Space.
protocol HotKeyRegistration: AnyObject {
    /// Carbon's answer; registering an already registered key is `noErr`.
    func register() -> OSStatus
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
    let keyCode: UInt32
    let modifiers: UInt32
    /// Called on the main thread when the combination is pressed.
    var onPress: (() -> Void)?

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32

    /// "EVLT": the hot key's signature, so a press is known to be ours.
    static let signature: OSType = 0x4556_4C54
    private static var nextID: UInt32 = 1

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        id = Self.nextID
        Self.nextID += 1
    }

    deinit { unregister() }

    func register() -> OSStatus {
        guard reference == nil else { return noErr }
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
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { reference = ref }
        return status
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
