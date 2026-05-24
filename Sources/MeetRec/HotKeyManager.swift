import Foundation
import Carbon.HIToolbox

/// Minimal Carbon hot key registration. No external deps.
final class HotKeyManager {

    struct Combo: Hashable {
        let keyCode: UInt32   // virtual key code, e.g. kVK_ANSI_M
        let modifiers: UInt32 // Carbon modifiers, e.g. cmdKey | optionKey
    }

    private struct Registered {
        let id: EventHotKeyID
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var entries: [UInt32: Registered] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() { installHandler() }
    deinit { uninstallHandler() }

    @discardableResult
    func register(_ combo: Combo, handler: @escaping () -> Void) -> Bool {
        let signature: OSType = OSType(0x4D544B59) // 'MTKY'
        let id = EventHotKeyID(signature: signature, id: nextID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers,
            id, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        entries[nextID] = Registered(id: id, ref: ref, handler: handler)
        nextID += 1
        return true
    }

    func unregisterAll() {
        for (_, entry) in entries {
            UnregisterEventHotKey(entry.ref)
        }
        entries.removeAll()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let entry = mgr.entries[hkID.id] {
                DispatchQueue.main.async { entry.handler() }
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    private func uninstallHandler() {
        unregisterAll()
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
    }
}

extension HotKeyManager.Combo {
    static let optCmdM = HotKeyManager.Combo(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(cmdKey | optionKey)
    )
    static let optCmdS = HotKeyManager.Combo(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(cmdKey | optionKey)
    )
    static let optCmdR = HotKeyManager.Combo(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(cmdKey | optionKey)
    )
}
