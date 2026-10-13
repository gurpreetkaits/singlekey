import Foundation

/// Everything that travels between two SingleKey instances.
enum Message: Codable {
    /// First message on every connection; identifies the sender.
    case hello(id: String, name: String)
    /// The sender has started (true) or stopped (false) driving this Mac.
    case control(active: Bool)
    case key(code: UInt16, down: Bool, flags: UInt64, autorepeat: Bool)
    case flags(code: UInt16, flags: UInt64)
    case mouseMove(dx: Double, dy: Double)
    case mouseButton(button: Int, down: Bool, clicks: Int64)
    case scroll(dy: Double, dx: Double, continuous: Bool)
    /// Release every key and button the receiver is holding down.
    case releaseAll
}

/// Length-prefixed JSON framing.
enum Wire {
    static func encode(_ message: Message) -> Data? {
        guard let body = try? JSONEncoder().encode(message) else { return nil }
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    static func length(of header: Data) -> Int {
        header.reduce(0) { ($0 << 8) | Int($1) }
    }

    static func decode(_ body: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: body)
    }
}
