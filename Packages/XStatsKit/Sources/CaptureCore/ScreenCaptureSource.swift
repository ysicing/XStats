// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
@preconcurrency import ScreenCaptureKit

/// The stored SCContentFilter has a read-only API; geometry and identity are immutable values.
public struct ScreenCaptureSource: @unchecked Sendable {
    public private(set) var filter: SCContentFilter
    private let display: SCDisplay?
    public let sourceRect: CGRect?
    public let pixelSize: CGSize
    public let displayID: CGDirectDisplayID
    public let windowID: CGWindowID?
    private let windowFrame: CGRect?
    public var captureFrame: CGRect {
        if let windowFrame { return windowFrame }
        let displayFrame = CGDisplayBounds(displayID)
        return sourceRect?.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY) ?? displayFrame
    }
    public let targetName: String?
    public init(display: SCDisplay, excludedApps: [SCRunningApplication] = [], excludedWindows: [SCWindow] = [], region: CaptureGeometry.Region? = nil) {
        self.display = display
        filter = excludedApps.isEmpty
            ? SCContentFilter(display: display, excludingWindows: excludedWindows)
            : SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        sourceRect = region?.sourceRect
        let scale = CGFloat(filter.pointPixelScale)
        pixelSize = region?.pixelSize ?? CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
        displayID = display.displayID; windowID = nil
        windowFrame = nil
        targetName = nil
    }
    public init(window: SCWindow, displayID: CGDirectDisplayID) {
        display = nil
        filter = SCContentFilter(desktopIndependentWindow: window)
        sourceRect = nil
        let scale = CGFloat(filter.pointPixelScale)
        pixelSize = CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
        self.displayID = displayID; windowID = window.windowID
        windowFrame = window.frame
        targetName = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.owningApplication?.applicationName
    }
    /// Only display/region filters need window exclusions; an independent window
    /// filter already limits capture to the selected target.
    public func excludingWindows(_ windows: [SCWindow]) -> ScreenCaptureSource {
        guard let display else { return self }
        var source = self
        source.filter = SCContentFilter(display: display, excludingWindows: windows)
        return source
    }
    public func configuration(recording: Bool, systemAudio: Bool = false) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = recording ? CaptureGeometry.recordingSize(pixelSize) : pixelSize
        configuration.width = Int(size.width); configuration.height = Int(size.height)
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.showsCursor = recording
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }
    public func screenshot(maximumDimension: CGFloat? = nil) async throws -> CGImage {
        let configuration = configuration(recording: false)
        if let maximumDimension, maximumDimension > 0 {
            let ratio = min(1, maximumDimension / max(pixelSize.width, pixelSize.height))
            configuration.width = max(1, Int(pixelSize.width * ratio))
            configuration.height = max(1, Int(pixelSize.height * ratio))
        }
        return try await Self.screenshot { completion in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration, completionHandler: completion)
        }
    }
    static func screenshot(capture: @Sendable (@escaping @Sendable (CGImage?, (any Error)?) -> Void) -> Void) async throws -> CGImage {
        return try await CaptureCallback<CGImage>().wait { completion in
            capture { image, error in
                if let error {
                    // 选择期间权限也可能被撤销；只有系统捕获错误按对应恢复语义转换。
                    let failure: any Error = (error as NSError).domain == SCStreamErrorDomain ? CaptureError.recordingFailure(error) : error
                    completion.finish(.failure(failure))
                }
                else if let image { completion.finish(.success(image)) }
                else { completion.finish(.failure(CaptureError.captureFailed)) }
            }
        }
    }
    public static func content(onScreenWindowsOnly: Bool = true) async throws -> SCShareableContent {
        // Let ScreenCaptureKit request authorization. A false CoreGraphics preflight
        // result must not prevent the framework from presenting its first-use prompt.
        do {
            return try await CaptureCallback<SCShareableContent>().wait { completion in
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: onScreenWindowsOnly) { content, error in
                    if let error { completion.finish(.failure(error)) }
                    else if let content { completion.finish(.success(content)) }
                    else { completion.finish(.failure(CaptureError.captureFailed)) }
                }
            }
        } catch {
            let failure = error as NSError
            if failure.domain == SCStreamErrorDomain, failure.code == SCStreamError.Code.userDeclined.rawValue {
                throw CaptureError.screenPermission
            }
            throw error
        }
    }
}
