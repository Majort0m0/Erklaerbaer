import Carbon.HIToolbox
import Foundation

/// System-wide keyboard shortcut via Carbon (works without Accessibility permission).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Default: ⌘⇧2 starts/stops a recording.
    static let defaultKeyCode = UInt32(kVK_ANSI_2)
    static let defaultModifiers = UInt32(cmdKey | shiftKey)
    static let defaultDisplay = "⌘⇧2"

    /// ⌘⇧1 takes a screenshot of an area.
    static let screenshotKeyCode = UInt32(kVK_ANSI_1)
    static let screenshotDisplay = "⌘⇧1"

    private let id: UInt32

    init?(keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers, id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.id = id
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Every hot key handler sees every hot key: only react to our own.
            var pressed = EventHotKeyID()
            let r = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard r == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x534B_4B54), id: id) // 'SKKT'
        let reg = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard reg == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
