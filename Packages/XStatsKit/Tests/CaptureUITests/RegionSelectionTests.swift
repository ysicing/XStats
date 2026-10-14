// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import CaptureUI

@Suite struct RegionSelectionTests {
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)

    @Test func drawingBackwardsClipsToOneScreenAndRequiresMouseRelease() {
        var selection = RegionSelection()
        selection.begin(at: CGPoint(x: 300, y: 200), in: bounds)
        selection.update(to: CGPoint(x: -30, y: -20), in: bounds)
        #expect(selection.rect == CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(!selection.isReady)
        selection.end(at: CGPoint(x: -30, y: -20), in: bounds)
        #expect(selection.isReady)
    }
    @Test func movingPreservesTheGrabOffsetAndSizeAtScreenEdges() {
        var selection = makeSelection()
        selection.begin(at: CGPoint(x: 130, y: 120), in: bounds)
        selection.update(to: CGPoint(x: 150, y: 150), in: bounds)
        #expect(selection.rect == CGRect(x: 120, y: 130, width: 200, height: 160))
        selection.end(at: CGPoint(x: 900, y: 900), in: bounds)
        #expect(selection.rect == CGRect(x: 300, y: 240, width: 200, height: 160))
    }
    @Test(arguments: RegionSelection.Handle.allCases)
    func everyHandleResizesWithoutMovingTheOppositeEdge(_ handle: RegionSelection.Handle) throws {
        var selection = makeSelection()
        let original = try #require(selection.rect)
        let anchor = handle.point(in: original)
        selection.begin(at: anchor, in: bounds)
        selection.end(at: CGPoint(x: anchor.x + 30, y: anchor.y + 20), in: bounds)
        let updated = try #require(selection.rect)
        switch handle {
        case .left, .bottomLeft, .topLeft: #expect(updated.minX == original.minX + 30); #expect(updated.maxX == original.maxX)
        case .right, .bottomRight, .topRight: #expect(updated.maxX == original.maxX + 30); #expect(updated.minX == original.minX)
        case .bottom, .top: #expect(updated.minX == original.minX); #expect(updated.maxX == original.maxX)
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: #expect(updated.minY == original.minY + 20); #expect(updated.maxY == original.maxY)
        case .top, .topLeft, .topRight: #expect(updated.maxY == original.maxY + 20); #expect(updated.minY == original.minY)
        case .left, .right: #expect(updated.minY == original.minY); #expect(updated.maxY == original.maxY)
        }
    }
    @Test func wholeEdgesCanResizeAndCrossingKeepsAPositiveMinimum() throws {
        var selection = makeSelection()
        #expect(selection.handle(at: CGPoint(x: 100, y: 130)) == .left)
        selection.begin(at: CGPoint(x: 100, y: 130), in: bounds)
        selection.end(at: CGPoint(x: 490, y: 130), in: bounds)
        #expect(selection.rect == CGRect(x: 298, y: 100, width: 2, height: 160))
    }
    @Test func outsideDragReplacesTheDraftAndResetDropsAllInteraction() {
        var selection = makeSelection()
        selection.begin(at: CGPoint(x: 20, y: 20), in: bounds)
        selection.end(at: CGPoint(x: 80, y: 90), in: bounds)
        #expect(selection.rect == CGRect(x: 20, y: 20, width: 60, height: 70))
        selection.begin(at: CGPoint(x: 45, y: 45), in: bounds)
        selection.reset()
        selection.end(at: CGPoint(x: 100, y: 100), in: bounds)
        #expect(selection.rect == nil)
        #expect(!selection.isReady)
        #expect(!selection.isDragging)
    }
    @Test func clickWithoutAValidAreaCannotBeConfirmed() {
        var selection = RegionSelection()
        selection.begin(at: CGPoint(x: 20, y: 20), in: bounds)
        selection.end(at: CGPoint(x: 21, y: 40), in: bounds)
        #expect(!selection.isReady)
        #expect(selection.rect == nil)
    }
    private func makeSelection() -> RegionSelection {
        var selection = RegionSelection()
        selection.begin(at: CGPoint(x: 100, y: 100), in: bounds)
        selection.end(at: CGPoint(x: 300, y: 260), in: bounds)
        return selection
    }
}
