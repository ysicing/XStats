// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import XStatsUI

struct AudioDeviceVolumeDraftTests {
    @Test func finishingClearsAQuantizedReadbackThatArrivedDuringDragging() {
        var draft = AudioDeviceVolumeDraft()
        draft.beginEditing(); draft.update(0.456)
        draft.readbackChanged()
        #expect(draft.value == 0.456)
        let token = draft.endEditing()
        let completed = draft.complete(token)
        #expect(completed)
        #expect(draft.value == nil)
    }

    @Test func pendingFinalWriteKeepsTheRequestedValueUntilCompletion() {
        var draft = AudioDeviceVolumeDraft()
        draft.beginEditing(); draft.update(0.8)
        let token = draft.endEditing()
        draft.readbackChanged()
        #expect(draft.value == 0.8)
        let completed = draft.complete(token)
        #expect(completed)
        #expect(draft.value == nil)
    }

    @Test func anOldCompletionCannotClearANewDrag() {
        var draft = AudioDeviceVolumeDraft()
        draft.beginEditing(); draft.update(0.4)
        let old = draft.endEditing()
        draft.beginEditing(); draft.update(0.9)
        let completed = draft.complete(old)
        #expect(!completed)
        #expect(draft.value == 0.9)
    }

    @Test func deviceChangesInvalidatePendingCompletionAndDiscardTheDraft() {
        var draft = AudioDeviceVolumeDraft()
        draft.beginEditing(); draft.update(0.4)
        let old = draft.endEditing()
        draft.reset()
        let completed = draft.complete(old)
        #expect(!completed)
        #expect(draft.value == nil)
    }
}
