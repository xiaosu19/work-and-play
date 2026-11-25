import AppKit
import ApplicationServices

struct DesktopInput {
    private static let eventTypes: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .mouseMoved
    ]
    private static let readingTypes: Set<CGEventType> = [.leftMouseDown, .scrollWheel]
    private static let openingTypes: Set<CGEventType> = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
    private var counters: [CGEventType: UInt32] = [:]

    mutating func sample(at now: Date) -> (input: Date?, reading: Date?, opening: Date?) {
        var input: Date?
        var reading: Date?
        var opening: Date?
        for type in Self.eventTypes {
            let count = CGEventSource.counterForEventType(.hidSystemState, eventType: type)
            let previous = counters.updateValue(count, forKey: type)
            guard let previous, previous != count else { continue }
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            guard idle >= 0 && idle <= 4 else { continue }
            let timestamp = now.addingTimeInterval(-idle)
            input = max(input ?? timestamp, timestamp)
            if Self.readingTypes.contains(type) { reading = max(reading ?? timestamp, timestamp) }
            if Self.openingTypes.contains(type) { opening = max(opening ?? timestamp, timestamp) }
        }
        return (input, reading, opening)
    }
}

struct DesktopWindow {
    let title: String?
    let identifier: CFHashCode

    init?(process: pid_t) {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        let window = result as! AXUIElement
        var titleValue: CFTypeRef?
        AXUIElementSetMessagingTimeout(window, 0.15)
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
        title = (titleValue as? String).map { String($0.prefix(4096)) }
        identifier = CFHash(window)
    }
}
