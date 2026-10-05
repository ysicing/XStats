// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
#include "AudioVolumeRenderer.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct XSAccessProbe { atomic_bool didRun; };

XSAccessProbeRef XSAccessProbeCreate(void) {
    XSAccessProbeRef probe = calloc(1, sizeof(*probe));
    if (probe == NULL) return NULL;
    atomic_init(&probe->didRun, false);
    if (!atomic_is_lock_free(&probe->didRun)) { free(probe); return NULL; }
    return probe;
}

bool XSAccessProbeDidRun(XSAccessProbeRef probe) {
    return atomic_load_explicit(&probe->didRun, memory_order_relaxed);
}

void XSAccessProbeDestroy(XSAccessProbeRef probe) { free(probe); }

// 不访问输入声音，只确认输入回调确实启动；输出清零，不向设备播放任何捕获内容。
OSStatus XSAccessProbeRead(AudioObjectID device, const AudioTimeStamp *now,
                          const AudioBufferList *input, const AudioTimeStamp *inputTime,
                          AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    if (output != NULL) {
        for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
            if (output->mBuffers[index].mData != NULL) memset(output->mBuffers[index].mData, 0, output->mBuffers[index].mDataByteSize);
        }
    }
    if (context != NULL && input != NULL && input->mNumberBuffers > 0) {
        atomic_store_explicit(&((XSAccessProbeRef)context)->didRun, true, memory_order_relaxed);
    }
    return noErr;
}
