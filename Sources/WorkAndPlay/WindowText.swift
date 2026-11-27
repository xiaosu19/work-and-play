import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

enum WindowText {
    /// The caller authorizes an exact foreground window. Raw frames and OCR strings stay in memory.
    static func matches(pid: pid_t, title: String, keyword: String) async -> Bool {
        guard !keyword.isEmpty, CGPreflightScreenCaptureAccess() else { return false }
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = shareable.windows.filter {
                $0.owningApplication?.processID == pid && $0.title == title && $0.isOnScreen && $0.windowLayer == 0
            }
            guard let window = windows.first, windows.count == 1, !Task.isCancelled else { return false }
            let isFocused = await MainActor.run { Tracker.captureWindowIsFocused(pid: pid, title: title) }
            guard isFocused, !Task.isCancelled else { return false }
            let config = SCStreamConfiguration()
            config.width = max(1, min(1800, Int(window.frame.width * 2)))
            config.height = max(1, min(1800, Int(window.frame.height * 2)))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            guard !Task.isCancelled else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.contains {
                guard let candidate = $0.topCandidates(1).first else { return false }
                return candidate.confidence >= 0.7 && candidate.string.localizedCaseInsensitiveContains(keyword)
            } == true
        } catch {
            return false
        }
    }
}
