// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "AudioVolumeRenderer.h"
#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>

typedef enum { PCMFloat32, PCMFloat64, PCMInteger } PCMEncoding;

typedef struct {
    uint32_t source, destination, buffers, channels, sampleBytes, significantBits, highPadding;
    bool bigEndian;
    PCMEncoding encoding;
    double sampleRate;
    _Atomic(float) requestedVolume;
    // 以下状态仅由 IOProc 修改。每条路由的所有声道共用同一条 40ms 音量包络。
    double audibleVolume, envelopeStep;
    float envelopeTarget;
    uint32_t envelopeFrames;
} VolumeRouteState;

struct XSVolumeRenderer {
    size_t routeCount;
    VolumeRouteState routes[];
};

static float boundedVolume(float value) {
    if (!isfinite(value) || value < 0) return 0;
    return value > 1 ? 1 : value;
}

static bool configureRoute(VolumeRouteState *state, XSVolumeRoute route) {
    const AudioStreamBasicDescription pcm = route.pcm;
    const bool planar = (pcm.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool floating = (pcm.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool signedInteger = (pcm.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    if (pcm.mFormatID != kAudioFormatLinearPCM || !isfinite(pcm.mSampleRate) || pcm.mSampleRate <= 0
        || pcm.mChannelsPerFrame == 0 || pcm.mChannelsPerFrame > 32 || floating == signedInteger
        || pcm.mFramesPerPacket != 1 || pcm.mBytesPerPacket != pcm.mBytesPerFrame) return false;
    const uint32_t channels = planar ? 1 : pcm.mChannelsPerFrame;
    if (pcm.mBytesPerFrame % channels != 0 || route.channelBufferCount != (planar ? pcm.mChannelsPerFrame : 1)) return false;
    const uint32_t width = pcm.mBytesPerFrame / channels;
    const bool bigEndian = (pcm.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    if (floating) {
        if (bigEndian || !((pcm.mBitsPerChannel == 32 && width == 4) || (pcm.mBitsPerChannel == 64 && width == 8))) return false;
        state->encoding = pcm.mBitsPerChannel == 32 ? PCMFloat32 : PCMFloat64;
    } else {
        if (!(pcm.mBitsPerChannel == 16 || pcm.mBitsPerChannel == 24 || pcm.mBitsPerChannel == 32)) return false;
        if (pcm.mBitsPerChannel == 24 ? !(width == 3 || width == 4) : width != pcm.mBitsPerChannel / 8) return false;
        state->encoding = PCMInteger;
    }
    state->source = route.sourceBufferIndex;
    state->destination = route.destinationBufferIndex;
    state->buffers = route.channelBufferCount;
    state->channels = channels;
    state->sampleBytes = width;
    state->significantBits = pcm.mBitsPerChannel;
    state->highPadding = (pcm.mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0 ? width * 8 - pcm.mBitsPerChannel : 0;
    state->bigEndian = bigEndian;
    state->sampleRate = pcm.mSampleRate;
    state->audibleVolume = boundedVolume(route.startingVolume);
    state->envelopeTarget = (float)state->audibleVolume;
    atomic_init(&state->requestedVolume, state->envelopeTarget);
    // 无锁要求在启动阶段确认，实时线程不允许退化为库内部互斥锁。
    return atomic_is_lock_free(&state->requestedVolume);
}

XSVolumeRendererRef XSVolumeRendererCreate(const XSVolumeRoute *routes, size_t count) {
    if (routes == NULL || count == 0 || count > 256) return NULL;
    XSVolumeRendererRef renderer = calloc(1, sizeof(*renderer) + count * sizeof(VolumeRouteState));
    if (renderer == NULL) return NULL;
    renderer->routeCount = count;
    for (size_t index = 0; index < count; index++) {
        if (!configureRoute(&renderer->routes[index], routes[index])) { free(renderer); return NULL; }
    }
    return renderer;
}

void XSVolumeRendererDestroy(XSVolumeRendererRef renderer) { free(renderer); }

void XSVolumeRendererSetVolume(XSVolumeRendererRef renderer, size_t route, float volume) {
    if (renderer != NULL && route < renderer->routeCount) {
        atomic_store_explicit(&renderer->routes[route].requestedVolume, boundedVolume(volume), memory_order_relaxed);
    }
}

static void updateEnvelope(VolumeRouteState *route) {
    const float target = atomic_load_explicit(&route->requestedVolume, memory_order_relaxed);
    if (target == route->envelopeTarget) return;
    route->envelopeTarget = target;
    route->envelopeFrames = (uint32_t)fmin(UINT32_MAX, fmax(1, ceil(route->sampleRate * 0.04)));
    route->envelopeStep = ((double)target - route->audibleVolume) / route->envelopeFrames;
}

static float volumeAtFrame(const VolumeRouteState *route, size_t frame) {
    if (frame >= route->envelopeFrames) return route->envelopeTarget;
    return (float)(route->audibleVolume + route->envelopeStep * frame);
}

static void advanceEnvelope(VolumeRouteState *route, size_t frames) {
    if (frames >= route->envelopeFrames) {
        route->audibleVolume = route->envelopeTarget;
        route->envelopeFrames = 0;
    } else {
        route->audibleVolume += route->envelopeStep * frames;
        route->envelopeFrames -= (uint32_t)frames;
    }
}

// 逐字节读取整数 PCM，不依赖地址对齐；24 位样本可为紧凑或 32 位容器。
static int64_t decodeInteger(const uint8_t *bytes, const VolumeRouteState *route) {
    uint32_t raw = 0;
    for (uint32_t index = 0; index < route->sampleBytes; index++) {
        const uint32_t byte = route->bigEndian ? route->sampleBytes - 1 - index : index;
        raw |= (uint32_t)bytes[byte] << (index * 8);
    }
    const uint64_t modulus = UINT64_C(1) << route->significantBits;
    const uint64_t value = (raw >> route->highPadding) & (modulus - 1);
    return value >= modulus / 2 ? (int64_t)value - (int64_t)modulus : (int64_t)value;
}

static void encodeInteger(uint8_t *bytes, const VolumeRouteState *route, double value) {
    const int64_t limit = INT64_C(1) << (route->significantBits - 1);
    const int64_t sample = (int64_t)round(fmax(-(double)limit, fmin((double)(limit - 1), value)));
    const uint64_t mask = (UINT64_C(1) << route->significantBits) - 1;
    const uint32_t raw = (uint32_t)(((uint64_t)sample & mask) << route->highPadding);
    for (uint32_t index = 0; index < route->sampleBytes; index++) {
        const uint32_t byte = route->bigEndian ? route->sampleBytes - 1 - index : index;
        bytes[byte] = (uint8_t)(raw >> (index * 8));
    }
}

static size_t mixBuffer(const AudioBuffer *source, AudioBuffer *destination, const VolumeRouteState *route) {
    if (source->mData == NULL || destination->mData == NULL || source->mNumberChannels != route->channels
        || destination->mNumberChannels != route->channels) return 0;
    const size_t length = source->mDataByteSize < destination->mDataByteSize ? source->mDataByteSize : destination->mDataByteSize;
    const size_t frames = length / (route->sampleBytes * route->channels);
    const size_t samples = frames * route->channels;
    const float fixedVolume = route->envelopeTarget;
    // 静音时不读取源样本；即使驱动提供 NaN/Inf，也不能污染静音输出。
    if (route->envelopeFrames == 0 && fixedVolume == 0) return frames;
    if (route->encoding == PCMFloat32) {
        const float *input = source->mData;
        float *output = destination->mData;
        if (route->envelopeFrames == 0) {
            if (fixedVolume != 0) for (size_t index = 0; index < samples; index++) output[index] += input[index] * fixedVolume;
        } else {
            for (size_t index = 0; index < samples; index++) {
                const float volume = volumeAtFrame(route, index / route->channels);
                if (volume != 0) output[index] += input[index] * volume;
            }
        }
    } else if (route->encoding == PCMFloat64) {
        const double *input = source->mData;
        double *output = destination->mData;
        for (size_t index = 0; index < samples; index++) {
            const float volume = volumeAtFrame(route, index / route->channels);
            if (volume != 0) output[index] += input[index] * volume;
        }
    } else {
        const uint8_t *input = source->mData;
        uint8_t *output = destination->mData;
        for (size_t index = 0; index < samples; index++) {
            const size_t offset = index * route->sampleBytes;
            const double value = decodeInteger(output + offset, route)
                + decodeInteger(input + offset, route) * (double)volumeAtFrame(route, index / route->channels);
            encodeInteger(output + offset, route, value);
        }
    }
    return frames;
}

OSStatus XSVolumeRender(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                      const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *state) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    // IOProc 独占本次输出；全部清零，未映射的设备流也不能带入上次内容。
    for (uint32_t index = 0; index < output->mNumberBuffers; index++) {
        AudioBuffer *buffer = &output->mBuffers[index];
        if (buffer->mData != NULL) memset(buffer->mData, 0, buffer->mDataByteSize);
    }
    XSVolumeRendererRef renderer = state;
    if (renderer == NULL) return noErr;
    for (size_t index = 0; index < renderer->routeCount; index++) {
        VolumeRouteState *route = &renderer->routes[index];
        updateEnvelope(route);
        size_t renderedFrames = 0;
        for (uint32_t channelBuffer = 0; channelBuffer < route->buffers; channelBuffer++) {
            const uint64_t source = (uint64_t)route->source + channelBuffer;
            const uint64_t destination = (uint64_t)route->destination + channelBuffer;
            if (source >= input->mNumberBuffers || destination >= output->mNumberBuffers) continue;
            const size_t frames = mixBuffer(&input->mBuffers[source], &output->mBuffers[destination], route);
            if (frames > renderedFrames) renderedFrames = frames;
        }
        advanceEnvelope(route, renderedFrames);
    }
    return noErr;
}
