import Darwin
import Foundation
import TimeStore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["mcp"] {
    do {
        try ReportMCP.run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("工时簿本机 MCP 已断开。\n".utf8))
        exit(1)
    }
}
guard arguments.count == 3, let channel = ReportChannel(rawValue: arguments[0]),
      let cadence = ReportCadence(rawValue: arguments[1]), let period = DigestPeriod(cadence, including: arguments[2]) else {
    FileHandle.standardError.write(Data("Usage: WorkAndPlayReport mcp | work|leisure day|week YYYY-MM-DD\n".utf8))
    exit(64)
}

do {
    let data = try WorkReportShare.read(channel, period: period)
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
} catch {
    FileHandle.standardError.write(Data("该日期没有有效的共享日报。请在工时簿预览并授权本机接口。\n".utf8))
    exit(1)
}
