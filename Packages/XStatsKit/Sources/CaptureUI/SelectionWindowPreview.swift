// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore

/// A single bounded snapshot per click, never a second live capture stream.
@MainActor final class SelectionWindowPreview {
    private(set) var image: CGImage?
    private(set) var loading = false
    private(set) var error: CaptureError?
    var onChange: () -> Void = {}
    private var task: Task<Void, Never>?
    private var generation = UUID()

    @discardableResult func load(capture: @escaping @MainActor () async throws -> CGImage) -> Task<Void, Never> {
        reset()
        loading = true
        let generation = generation
        onChange()
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let image = try await capture()
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.image = image; self.loading = false; self.task = nil
                self.onChange()
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.error = (error as? CaptureError) ?? .captureFailed
                self.loading = false; self.task = nil
                self.onChange()
            }
        }
        self.task = task
        return task
    }
    func reset() {
        generation = UUID()
        task?.cancel(); task = nil
        image = nil; error = nil; loading = false
        onChange()
    }
    static func fittedFrame(target: CGRect, in bounds: CGRect) -> CGRect {
        let available = bounds.insetBy(dx: 24, dy: 96)
        guard available.width > 0, available.height > 0, target.width > 0, target.height > 0 else { return .zero }
        let scale = min(1, available.width / target.width, available.height / target.height)
        let size = CGSize(width: target.width * scale, height: target.height * scale)
        let center = scale < 1 ? CGPoint(x: available.midX, y: available.midY) : CGPoint(x: target.midX, y: target.midY)
        return CGRect(x: min(max(center.x - size.width / 2, available.minX), available.maxX - size.width),
                      y: min(max(center.y - size.height / 2, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
