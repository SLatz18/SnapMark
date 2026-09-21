import Carbon
import Foundation

/// System-wide hotkeys via the Carbon API:
/// Ctrl+Shift+5 captures a region, Ctrl+Shift+6 OCRs a region to the clipboard.
/// Unlike NSEvent global monitors this needs no Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    var onHotKey: (() -> Void)?
    var onOCRHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var ocrHotKeyRef: EventHotKeyRef?
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

        // 'SMRK', id 1 — Ctrl+Shift+5 (capture region)
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D524B), id: UInt32(1))
        RegisterEventHotKey(UInt32(kVK_ANSI_5), UInt32(controlKey | shiftKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        // 'SMRK', id 2 — Ctrl+Shift+6 (OCR region to clipboard)
        let ocrHotKeyID = EventHotKeyID(signature: OSType(0x534D524B), id: UInt32(2))
        RegisterEventHotKey(UInt32(kVK_ANSI_6), UInt32(controlKey | shiftKey),
                            ocrHotKeyID, GetApplicationEventTarget(), 0, &ocrHotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = ocrHotKeyRef { UnregisterEventHotKey(ref) }
    }
}

private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ theEvent: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hkID = EventHotKeyID()
    let status = GetEventParameter(
        theEvent,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    if status == noErr {
        switch hkID.id {
        case 1: HotKeyManager.shared.onHotKey?()
        case 2: HotKeyManager.shared.onOCRHotKey?()
        default: break
        }
    }
    return noErr
}
