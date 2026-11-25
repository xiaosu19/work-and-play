import Darwin
import Foundation

public enum BrowserSource: String, CaseIterable, Codable, Sendable {
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"

    public var label: String { self == .chrome ? "Chrome" : "Edge" }
}

public struct ChromePage: Codable, Equatable {
    public let tab: Int
    public let document: UUID
    public let host: String
    public let path: String
    public let readingAt: Double?
    public let interactionAt: Double?
    public let videoPlaying: Bool

    public init(tab: Int, document: UUID, host: String, path: String, readingAt: Double?, videoPlaying: Bool,
                interactionAt: Double? = nil) {
        self.tab = tab; self.document = document; self.host = host; self.path = path
        self.readingAt = readingAt; self.interactionAt = interactionAt; self.videoPlaying = videoPlaying
    }
}

public struct ChromePacket: Codable, Equatable {
    public static let maxBytes = 8192
    public let version: Int
    public let session: UUID
    public let sequence: Int
    public let sentAt: Double
    public let page: ChromePage?
    public let focused: Bool
    public let disconnect: Bool?
    public let browser: BrowserSource?
    public var source: BrowserSource { browser ?? .chrome }

    public init(version: Int = 1, session: UUID, sequence: Int, sentAt: Double, page: ChromePage?,
                focused: Bool = true, disconnect: Bool? = nil, browser: BrowserSource? = nil) {
        self.version = version; self.session = session; self.sequence = sequence; self.sentAt = sentAt; self.page = page
        self.focused = focused; self.disconnect = disconnect; self.browser = browser
    }

    public func identified(as browser: BrowserSource) -> Self {
        Self(version: version, session: session, sequence: sequence, sentAt: sentAt, page: page,
             focused: focused, disconnect: disconnect, browser: browser)
    }

    public var valid: Bool {
        guard version == 1, sequence > 0, sentAt.isFinite else { return false }
        guard let page else { return true }
        return focused && disconnect != true && page.tab >= 0 && page.host.utf8.count <= 253
            && page.host.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil
            && page.path.utf8.count <= 2048 && page.path.hasPrefix("/")
            && page.path.rangeOfCharacter(from: CharacterSet(charactersIn: "?#").union(.controlCharacters)) == nil
            && (page.readingAt.map { $0.isFinite && $0 <= sentAt } ?? true)
            && (page.interactionAt.map { $0.isFinite && $0 <= sentAt } ?? true)
    }

    public static func decode(_ data: Data) -> Self? {
        guard data.count <= maxBytes, let packet = try? JSONDecoder().decode(Self.self, from: data),
              packet.valid else { return nil }
        return packet
    }
}

public struct ChromeFeed {
    public static let lease: TimeInterval = 3
    public private(set) var latest: ChromePacket?
    public private(set) var receivedAt: Date?

    public init() {}

    @discardableResult
    public mutating func receive(_ packet: ChromePacket, at date: Date) -> Bool {
        guard packet.valid, abs(date.timeIntervalSince1970 - packet.sentAt / 1000) <= Self.lease else { return false }
        if let latest {
            if latest.session == packet.session {
                guard packet.sequence > latest.sequence else { return false }
            } else {
                guard packet.disconnect != true, packet.sentAt > latest.sentAt else { return false }
                if !packet.focused && latest.focused && isConnected(at: date) { return false }
            }
        }
        latest = packet
        receivedAt = date
        return true
    }

    public func isConnected(at date: Date) -> Bool {
        guard let receivedAt, latest?.disconnect != true else { return false }
        return (0..<Self.lease).contains(date.timeIntervalSince(receivedAt))
    }

    public mutating func clear() {
        latest = nil
        receivedAt = nil
    }
}

public enum NativeFrame {
    public static func read(_ handle: FileHandle) throws -> Data? {
        guard let header = try readExactly(4, from: handle), header.count == 4 else { return nil }
        let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard (1...ChromePacket.maxBytes).contains(length) else { return nil }
        return try readExactly(length, from: handle)
    }

    public static func write(_ data: Data, to handle: FileHandle) throws {
        var length = UInt32(data.count).littleEndian
        try handle.write(contentsOf: Data(bytes: &length, count: 4) + data)
    }

    private static func readExactly(_ length: Int, from handle: FileHandle) throws -> Data? {
        var result = Data()
        while result.count < length {
            guard let part = try handle.read(upToCount: length - result.count), !part.isEmpty else { return nil }
            result.append(part)
        }
        return result
    }
}

public enum LocalBridge {
    private static var path: String? {
        var directory = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &directory, directory.count)
        guard length > 0 && length <= directory.count else { return nil }
        return String(cString: directory) + "workandplay.sock"
    }

    public static func send(_ data: Data) -> Bool {
        guard let address = address(), data.count <= ChromePacket.maxBytes else { return false }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return withAddress(address) { ptr, length in
            data.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, ptr, length) == $0.count }
        }
    }

    public final class Receiver {
        private let source: DispatchSourceRead

        /// The application holds its single-instance lock before creating this receiver.
        public init?(receive: @escaping (ChromePacket) -> Void) {
            guard let address = LocalBridge.address(), let path = LocalBridge.path else { return nil }
            var attributes = stat()
            if lstat(path, &attributes) == 0 {
                guard attributes.st_uid == getuid(), (attributes.st_mode & S_IFMT) == S_IFSOCK,
                      unlink(path) == 0 else { return nil }
            }
            let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard fd >= 0 else { return nil }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let bound = LocalBridge.withAddress(address) { bind(fd, $0, $1) } == 0
            guard bound, chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                close(fd)
                if bound { unlink(path) }
                return nil
            }
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: ChromePacket.maxBytes + 1)
                for _ in 0..<32 {
                    let count = recv(fd, &buffer, buffer.count, 0)
                    guard count > 0 else { break }
                    if let packet = ChromePacket.decode(Data(buffer.prefix(count))) { receive(packet) }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
        }

        deinit { source.cancel() }
    }

    private static func address() -> sockaddr_un? {
        guard let path else { return nil }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private static func withAddress<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(address.sun_len)) }
        }
    }
}
