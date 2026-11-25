import Carbon
import Foundation

/// Registers system-wide hotkeys using Carbon's RegisterEventHotKey.
/// This works in every app and does NOT require Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    /// - Parameters:
    ///   - keyCode: virtual key code, e.g. `kVK_Space`
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey | shiftKey`
    /// - Returns: false if the shortcut could not be registered (usually: already taken by another app).
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4752_4F51) /* 'GROQ' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }

        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handlers[id]?()
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            if err == noErr {
                HotKeyManager.shared.fire(id: hotKeyID.id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
