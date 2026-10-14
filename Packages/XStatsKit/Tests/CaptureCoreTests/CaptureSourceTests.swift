// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import CoreGraphics
import ScreenCaptureKit
@testable import CaptureCore

@Suite struct CaptureSourceTests {
    @Test func missingMicrophoneOffersDeviceRecovery() async {
        let microphone = MicrophoneCapture(device: { nil })
        let writer = RecordingWriter { _ in }
        await #expect(throws: CaptureError.microphoneFailed) { try await microphone.start(writer: writer) }
        try? await microphone.stop()
    }
    @Test(arguments: [SCStreamError.Code.userDeclined, .noCaptureSource, .internalError])
    func screenshotCallbackPreservesRecoveryMeaning(_ code: SCStreamError.Code) async {
        let expected: CaptureError = code == .userDeclined ? .screenPermission : (code == .noCaptureSource ? .unavailableTarget : .captureFailed)
        await #expect(throws: expected) {
            _ = try await ScreenCaptureSource.screenshot { completion in
                completion(nil, NSError(domain: SCStreamErrorDomain, code: code.rawValue))
            }
        }
    }
    @Test func screenshotCallbackRequiresAnImageAndKeepsOtherErrors() async {
        await #expect(throws: CaptureError.captureFailed) {
            _ = try await ScreenCaptureSource.screenshot { $0(nil, nil) }
        }
        await #expect(throws: CocoaError(.fileReadNoPermission)) {
            _ = try await ScreenCaptureSource.screenshot { $0(nil, CocoaError(.fileReadNoPermission)) }
        }
    }
    @Test func screenshotCallbackReturnsTheCapturedImage() async throws {
        let context = try #require(CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let result = try await ScreenCaptureSource.screenshot { $0(image, nil) }
        #expect(result === image)
    }
}
