import AppKit
import CoreGraphics

/// Marks events SingleKey injects so its own event tap lets them through untouched.
let injectedEventMarker: Int64 = 0x53_4B_45_59 // "SKEY"

/// Watches this Mac's keyboard and mouse through a HID-level event tap. Detects the switch
/// hotkey, and while `isCapturing` is on, swallows local input and hands it to `forward`.
final class InputCapture {
    var hotkey = Settings.hotkey
    var onHotkey: (() -> Void)?
    var onHotkeyRecorded: ((Hotkey) -> Void)?
    var isRecordingHotkey = false
    var forward: ((Message) -> Void)?
    private(set) var isCapturing = false
    /// When false only the keyboard is sent; the mouse keeps working on this Mac.
    var forwardMouse = Settings.forwardMouse {
        didSet { if isCapturing { freezeMouse(forwardMouse) } }
    }

    private var tap: CFMachPort?
    private var swallowKeyUp: UInt16?

    var isRunning: Bool { tap != nil }

    /// Returns false when Accessibility / Input Monitoring permission is missing.
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // The HID-level tap sees keys before system shortcuts (⌘Tab, Spotlight); fall back to
        // the session tap where the HID one isn't allowed.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let created = [CGEventTapLocation.cghidEventTap, .cgSessionEventTap].lazy.compactMap { location in
            CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                              eventsOfInterest: mask, callback: tapCallback, userInfo: userInfo)
        }.first
        guard let tap = created else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    func setCapturing(_ on: Bool) {
        guard on != isCapturing else { return }
        isCapturing = on
        freezeMouse(on && forwardMouse)
    }

    /// Freezes the local pointer: mouse deltas still arrive but the cursor stays put.
    private func freezeMouse(_ frozen: Bool) {
        CGAssociateMouseAndMouseCursorPosition(frozen ? 0 : 1)
        CursorVisibility.set(visible: !frozen)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == injectedEventMarker { return pass }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            if isRecordingHotkey {
                isRecordingHotkey = false
                swallowKeyUp = keyCode
                if keyCode != 53 { // Esc cancels
                    let mods = event.flags.intersection(Hotkey.relevantModifiers).rawValue
                    hotkey = Hotkey(keyCode: keyCode, modifiers: mods)
                }
                let recorded = hotkey
                DispatchQueue.main.async { self.onHotkeyRecorded?(recorded) }
                return nil
            }
            if hotkey.matches(keyCode: keyCode, flags: event.flags) {
                swallowKeyUp = keyCode
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { self.onHotkey?() }
                }
                return nil
            }
        }
        if type == .keyUp, keyCode == swallowKeyUp {
            swallowKeyUp = nil
            return nil
        }

        guard isCapturing, let forward else { return pass }
        let isKeyboard = type == .keyDown || type == .keyUp || type == .flagsChanged
        if !isKeyboard && !forwardMouse { return pass }

        switch type {
        case .keyDown, .keyUp:
            forward(.key(
                code: keyCode,
                down: type == .keyDown,
                flags: event.flags.rawValue,
                autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            ))
            return nil

        case .flagsChanged:
            // Modifiers are forwarded *and* delivered locally, so both Macs always agree
            // on which modifiers are physically held (e.g. while pressing the hotkey).
            forward(.flags(code: keyCode, flags: event.flags.rawValue))
            return pass

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            forward(.mouseMove(
                dx: event.getDoubleValueField(.mouseEventDeltaX),
                dy: event.getDoubleValueField(.mouseEventDeltaY)
            ))
            return nil

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            forward(.mouseButton(
                button: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                down: down,
                clicks: event.getIntegerValueField(.mouseEventClickState)
            ))
            return nil

        case .scrollWheel:
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            if continuous {
                forward(.scroll(
                    dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                    dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                    continuous: true
                ))
            } else {
                forward(.scroll(
                    dy: event.getDoubleValueField(.scrollWheelEventDeltaAxis1),
                    dx: event.getDoubleValueField(.scrollWheelEventDeltaAxis2),
                    continuous: false
                ))
            }
            return nil

        default:
            return pass
        }
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()
    return capture.handle(type: type, event: event)
}

/// Hiding the cursor from a background (menu-bar) app needs the window server's
/// "SetsCursorInBackground" connection property. Looked up dynamically; if it is
/// unavailable the cursor simply stays visible (but frozen).
enum CursorVisibility {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static var hidden = false

    static func set(visible: Bool) {
        if !visible && !hidden {
            allowBackgroundCursorChanges()
            CGDisplayHideCursor(CGMainDisplayID())
            hidden = true
        } else if visible && hidden {
            CGDisplayShowCursor(CGMainDisplayID())
            hidden = false
        }
    }

    private static func allowBackgroundCursorChanges() {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let conn = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setSym, to: SetProperty.self)
        _ = setProperty(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
