// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

#ifndef XSTATS_AUDIO_VOLUME_RENDERER_H
#define XSTATS_AUDIO_VOLUME_RENDERER_H

#include <CoreAudio/CoreAudio.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// 每个应用对应一条输入到输出的路由；非交错格式按声道分别映射缓冲区。
typedef struct {
    AudioStreamBasicDescription pcm;
    uint32_t sourceBufferIndex;
    uint32_t channelBufferCount;
    uint32_t destinationBufferIndex;
    float startingVolume;
    AudioStreamBasicDescription outputPCM;
    // 当前输出流内从 1 开始的左右声道；均为 0 时沿用默认映射（包括单声道合并）。
    uint32_t leftOutputChannel;
    uint32_t rightOutputChannel;
} XSVolumeRoute;

typedef struct XSVolumeRenderer *XSVolumeRendererRef;

// 在生命周期队列创建和销毁；销毁前必须停止并注销 IOProc。
XSVolumeRendererRef _Nullable XSVolumeRendererCreate(const XSVolumeRoute * _Nonnull routes, size_t count);
// 只读性能诊断：实际执行 Float32 直通快路径的帧数。
uint64_t XSVolumeRendererFastFrameCount(XSVolumeRendererRef _Nonnull renderer);
uint64_t XSVolumeRendererFrameCount(XSVolumeRendererRef _Nonnull renderer);
void XSVolumeRendererDestroy(XSVolumeRendererRef _Nullable renderer);
// 可与回调并发调用；只更新无锁原子目标音量。
void XSVolumeRendererSetVolume(XSVolumeRendererRef _Nonnull renderer, size_t route, float volume);

OSStatus XSVolumeRender(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                      const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                      AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
                      void * _Nullable renderer);

OSStatus XStatsSetAudioInputUsage(AudioObjectID device, AudioDeviceIOProcID _Nonnull ioProc,
                                uint32_t hardwareStreams, uint32_t totalStreams);

// 只用于启动权限请求的短暂 IOProc；停止并注销回调后方可释放上下文。
typedef struct XSAccessProbe *XSAccessProbeRef;
XSAccessProbeRef _Nullable XSAccessProbeCreate(void);
bool XSAccessProbeDidRun(XSAccessProbeRef _Nonnull probe);
void XSAccessProbeDestroy(XSAccessProbeRef _Nullable probe);
OSStatus XSAccessProbeRead(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                         const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                         AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
                         void * _Nullable context);
#endif
