import Foundation
import Carbon.HIToolbox

/// System-wide keyboard shortcuts that work while another app (the deck, a
/// demo) is in front. Uses Carbon's RegisterEventHotKey, which needs no
/// Accessibility or Input Monitoring permission and works in the sandbox.
final class HotKeys {
    enum Action: UInt32 {
        case switchScreen = 1
        case cameraFullScreen = 2
        case switchCamera = 3
        case switchApp = 4
    }

    /// Control + Option + key. Rarely used by other apps.
    static let modifiers = UInt32(controlKey | optionKey)
    static let switchScreenKey = UInt32(kVK_ANSI_S)
    static let cameraKey = UInt32(kVK_ANSI_C)
    static let switchCameraKey = UInt32(kVK_ANSI_V)
    static let switchAppKey = UInt32(kVK_ANSI_A)

    static let switchScreenLabel = "⌃⌥S"
    static let cameraLabel = "⌃⌥C"
    static let switchCameraLabel = "⌃⌥V"
    static let switchAppLabel = "⌃⌥A"

    var onAction: ((Action) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4C52484B // 'LRHK'

    func register() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
                if let action = Action(rawValue: id.id) {
                    DispatchQueue.main.async { hotKeys.onAction?(action) }
                }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        for (action, key) in [(Action.switchScreen, Self.switchScreenKey), (.cameraFullScreen, Self.cameraKey), (.switchCamera, Self.switchCameraKey), (.switchApp, Self.switchAppKey)] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            if RegisterEventHotKey(key, Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }
}
