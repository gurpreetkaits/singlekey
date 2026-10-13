import CoreGraphics

/// Replays input received from the controlling Mac as if it came from local hardware.
final class InputInjector {
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = injectedEventMarker
        // By default posting events briefly suppresses real local input; we don't want that.
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    private var flags: CGEventFlags = []
    private var downKeys = Set<UInt16>()
    private var downModifiers = Set<UInt16>()
    private var downButtons = Set<Int>()

    private static let modifierMasks: [UInt16: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        63: .maskSecondaryFn,
    ]

    func handle(_ message: Message) {
        switch message {
        case .key(let code, let down, let rawFlags, let autorepeat):
            flags = CGEventFlags(rawValue: rawFlags)
            if down { downKeys.insert(code) } else { downKeys.remove(code) }
            postKey(code, down: down, autorepeat: autorepeat)

        case .flags(let code, let rawFlags):
            flags = CGEventFlags(rawValue: rawFlags)
            if let mask = Self.modifierMasks[code] {
                if flags.contains(mask) { downModifiers.insert(code) } else { downModifiers.remove(code) }
            }
            postFlagsChanged(code)

        case .mouseMove(let dx, let dy):
            moveMouse(dx: dx, dy: dy)

        case .mouseButton(let button, let down, let clicks):
            if down { downButtons.insert(button) } else { downButtons.remove(button) }
            postButton(button, down: down, clicks: clicks)

        case .scroll(let dy, let dx, let continuous):
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: continuous ? .pixel : .line,
                wheelCount: 2,
                wheel1: Int32(dy.rounded()),
                wheel2: Int32(dx.rounded()),
                wheel3: 0
            )
            if continuous {
                event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event?.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
                event?.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)

        case .releaseAll:
            releaseAll()

        case .hello, .control:
            break
        }
    }

    func releaseAll() {
        for button in downButtons { postButton(button, down: false, clicks: 1) }
        downButtons.removeAll()
        for code in downKeys { postKey(code, down: false, autorepeat: false) }
        downKeys.removeAll()
        flags = []
        for code in downModifiers { postFlagsChanged(code) }
        downModifiers.removeAll()
    }

    // MARK: - Posting

    private func postKey(_ code: UInt16, down: Bool, autorepeat: Bool) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        if autorepeat { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event?.post(tap: .cghidEventTap)
    }

    private func postFlagsChanged(_ code: UInt16) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        event?.type = .flagsChanged
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func moveMouse(dx: Double, dy: Double) {
        let from = cursor
        let to = Self.clampToDisplays(CGPoint(x: from.x + dx, y: from.y + dy), from: from)
        let type: CGEventType
        let button: CGMouseButton
        if downButtons.contains(0) { (type, button) = (.leftMouseDragged, .left) }
        else if downButtons.contains(1) { (type, button) = (.rightMouseDragged, .right) }
        else if let other = downButtons.first { (type, button) = (.otherMouseDragged, CGMouseButton(rawValue: UInt32(other)) ?? .center) }
        else { (type, button) = (.mouseMoved, .left) }

        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: button)
        event?.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event?.setDoubleValueField(.mouseEventDeltaY, value: dy)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func postButton(_ button: Int, down: Bool, clicks: Int64) {
        let type: CGEventType
        switch (button, down) {
        case (0, true): type = .leftMouseDown
        case (0, false): type = .leftMouseUp
        case (1, true): type = .rightMouseDown
        case (1, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: cursor,
            mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left
        )
        event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event?.setIntegerValueField(.mouseEventClickState, value: max(clicks, 1))
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// Keeps the pointer on a real display. Moving into a gap between monitors clamps
    /// each axis to the display the pointer is leaving.
    private static func clampToDisplays(_ point: CGPoint, from: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(point) }) { return point }
        guard let current = bounds.first(where: { $0.contains(from) }) ?? bounds.first else { return from }
        return CGPoint(
            x: min(max(point.x, current.minX), current.maxX - 1),
            y: min(max(point.y, current.minY), current.maxY - 1)
        )
    }
}
