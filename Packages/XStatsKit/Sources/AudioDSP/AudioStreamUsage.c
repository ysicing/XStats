// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "AudioVolumeRenderer.h"
#include <stdlib.h>

// 仅在管线启动前配置；不在实时回调中分配内存或读写 HAL。
OSStatus XStatsSetAudioInputUsage(AudioObjectID device, AudioDeviceIOProcID ioProc,
                                uint32_t hardwareStreams, uint32_t totalStreams) {
    if (hardwareStreams == 0) return noErr;
    if (hardwareStreams > totalStreams || totalStreams > 1024) return kAudioHardwareIllegalOperationError;
    const size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + totalStreams * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (usage == NULL) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)ioProc;
    usage->mNumberStreams = totalStreams;
    for (uint32_t index = hardwareStreams; index < totalStreams; index++) usage->mStreamIsOn[index] = 1;
    AudioObjectPropertyAddress property = { kAudioDevicePropertyIOProcStreamUsage, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain };
    const OSStatus status = AudioObjectSetPropertyData(device, &property, 0, NULL, (UInt32)size, usage);
    free(usage);
    return status;
}
