import Carbon
import Foundation

/// System-wide hotkey (Ctrl+Shift+5) via the Carbon API.
/// Unlike NSEvent global monitors this needs no Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var installed = false

    func register() {
        guard !installed else { return }
        installed = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            nil
        )
        guard status == noErr else { return }

        // 'SMRK', id 1 — Ctrl+Shift+5
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D524B), id: UInt32(1))
        let keyCode = UInt32(kVK_ANSI_5)
        let modifiers = UInt32(controlKey | shiftKey)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }
}

private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ theEvent: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    HotKeyManager.shared.onHotKey?()
    return noErr
}
