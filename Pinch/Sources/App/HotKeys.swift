import Carbon
import AppKit

/// System-wide shortcuts through Carbon's hot keys: no permission needed, and the keys never
/// reach the app in front.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var releases: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    struct Combo: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32       // Carbon: cmdKey, optionKey, controlKey, shiftKey
    }

    static let preference = "copyTextShortcut"
    static var copyTextKey: KitHotKey? {
        guard let data = UserDefaults.standard.data(forKey: preference) else {
            return KitHotKey(keyCode: UInt16(kVK_ANSI_T), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, display: "⌃⌥T")
        }
        return try? JSONDecoder().decode(KitHotKey.self, from: data)
    }

    func registerCopyText(_ key: KitHotKey?) -> Bool {
        guard let key else { unregister(1); return true }
        let flags = NSEvent.ModifierFlags(rawValue: key.modifiers)
        var modifiers = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] where flags.contains(flag) { modifiers |= carbon }
        return register(1, Combo(keyCode: UInt32(key.keyCode), modifiers: UInt32(modifiers))) { Core.shared.copyText() }
    }

    @discardableResult func register(_ id: UInt32, _ combo: Combo, release: (@MainActor () -> Void)? = nil, _ handler: @escaping @MainActor () -> Void) -> Bool {
        installIfNeeded()
        unregister(id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x50494E43), id: id)   // "PINC"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        releases[id] = release
        return true
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
        releases.removeValue(forKey: id)
    }

    func isRegistered(_ id: UInt32) -> Bool { refs[id] != nil }

    fileprivate func fire(_ id: UInt32, released: Bool) { if released { releases[id]?() } else { handlers[id]?() } }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id, released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { HotKeys.shared.fire(id, released: released) }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
