import Foundation
import Darwin
import ChromeBridge

let caller = CommandLine.arguments.dropFirst().first ?? ""
guard caller.range(of: #"^chrome-extension://[a-p]{32}/$"#, options: .regularExpression) != nil else { exit(1) }

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let browser: BrowserSource = executable == "EdgeNativeHost" ? .edge : .chrome
let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var latest: ChromePacket?
defer {
    if let latest, latest.sequence < Int.max {
        let ending = ChromePacket(session: latest.session, sequence: latest.sequence + 1,
            sentAt: latest.sentAt, page: nil, focused: false, disconnect: true, browser: browser)
        if let data = try? JSONEncoder().encode(ending) { _ = LocalBridge.send(data) }
    }
}

do {
    while let data = try NativeFrame.read(input) {
        var reply = BrowserReply(connected: false)
        if let packet = ChromePacket.decode(data)?.identified(as: browser),
           let clean = try? JSONEncoder().encode(packet) {
            latest = packet
            reply = packet.workPermitRequested == true
                ? LocalBridge.exchange(clean)
                : BrowserReply(connected: LocalBridge.send(clean))
        }
        try NativeFrame.write(JSONEncoder().encode(reply), to: output)
    }
} catch {
    // The browser owns this transport. Connection state is reported by the popup and expires in the app.
}
