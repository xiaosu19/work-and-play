import ChromeBridge
import Foundation

final class BridgeTests {
    func testRejectsPrivateURLAndUnsupportedFrames() throws {
        let session = UUID()
        for path in ["/docs?token=secret", "/docs#secret", "https://example.com/docs", "/docs\nsecret"] {
            let page = ChromePage(tab: 1, document: UUID(), host: "example.com", path: path, readingAt: nil, videoPlaying: false)
            let packet = ChromePacket(session: session, sequence: 1, sentAt: 1000, page: page)
            expect(ChromePacket.decode(try JSONEncoder().encode(packet)) == nil)
        }
        expect(ChromePacket.decode(Data(repeating: 0, count: ChromePacket.maxBytes + 1)) == nil)
        let unsupported = ChromePacket(version: 2, session: session, sequence: 1, sentAt: 1000, page: nil)
        expect(ChromePacket.decode(try JSONEncoder().encode(unsupported)) == nil)
        for timestamp in [999.0, 1001.0] {
            let page = ChromePage(tab: 1, document: UUID(), host: "example.com", path: "/docs",
                                  readingAt: nil, videoPlaying: false, interactionAt: timestamp)
            let packet = ChromePacket(session: session, sequence: 1, sentAt: 1000, page: page)
            let decoded = ChromePacket.decode(try JSONEncoder().encode(packet))
            expect(decoded?.page?.interactionAt == (timestamp <= 1000 ? timestamp : nil))
        }
    }

    func testLeaseAndReplay() {
        let start = Date(timeIntervalSince1970: 100)
        let session = UUID()
        let page = ChromePage(tab: 1, document: UUID(), host: "example.com", path: "/docs", readingAt: nil, videoPlaying: false)
        let live = ChromePacket(session: session, sequence: 1, sentAt: 100_000, page: page)
        var feed = ChromeFeed()
        expect(feed.receive(live, at: start))
        expect(!feed.receive(live, at: start.addingTimeInterval(1)))
        expect(feed.isConnected(at: start.addingTimeInterval(2)))
        expect(!feed.isConnected(at: start.addingTimeInterval(3)))
        expect(!feed.receive(live, at: start.addingTimeInterval(4)))
        let unavailable = ChromePacket(session: session, sequence: 2, sentAt: 104_000, page: nil)
        expect(feed.receive(unavailable, at: start.addingTimeInterval(4)))
        expect(feed.latest?.page == nil)
    }

    func testBackgroundProfileCannotReplaceActiveProfile() {
        let start = Date(timeIntervalSince1970: 100)
        let active = UUID()
        let page = ChromePage(tab: 1, document: UUID(), host: "example.com", path: "/", readingAt: nil, videoPlaying: true)
        var feed = ChromeFeed()
        expect(feed.receive(ChromePacket(session: active, sequence: 1, sentAt: 100_000, page: page), at: start))
        let other = ChromePacket(session: UUID(), sequence: 1, sentAt: 101_000, page: nil, focused: false)
        expect(!feed.receive(other, at: start.addingTimeInterval(1)))
        expect(feed.latest?.page == page)
        let end = ChromePacket(session: active, sequence: 2, sentAt: 100_000, page: nil, focused: false, disconnect: true)
        expect(feed.receive(end, at: start.addingTimeInterval(2)))
        expect(!feed.isConnected(at: start.addingTimeInterval(2)))
    }

    func testHostBrowserIdentificationAndLegacyCompatibility() throws {
        let packet = ChromePacket(session: UUID(), sequence: 1, sentAt: 1000, page: nil)
        expect(ChromePacket.decode(try JSONEncoder().encode(packet))?.source == .chrome)
        let edgePacket = packet.identified(as: .edge)
        expect(ChromePacket.decode(try JSONEncoder().encode(edgePacket))?.source == .edge)
        expect(edgePacket.identified(as: .chrome).source == .chrome)
        expect(BrowserSource(rawValue: "com.microsoft.edgemac") == .edge)
    }

    func testNativeFramesRoundTrip() throws {
        let pipe = Pipe()
        let value = Data(#"{"hello":true}"#.utf8)
        try NativeFrame.write(value, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        expect(try NativeFrame.read(pipe.fileHandleForReading) == value)
        expect(try NativeFrame.read(pipe.fileHandleForReading) == nil)
    }
}
