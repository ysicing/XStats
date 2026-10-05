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
    uint32_t channels, buffers, sampleBytes, significantBits, highPadding;
    bool bigEndian;
    PCMEncoding encoding;
} OutputPCM;

typedef struct {
    OutputPCM output;
    bool usedFastPath;
    double limiterVolume, limiterRelease;
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
    _Atomic(uint64_t) renderedFrames;
    _Atomic(uint64_t) fastFrames;
    VolumeRouteState routes[];
};

static float boundedVolume(float value) {
    if (!isfinite(value) || value < 0) return 0;
    return value > 2 ? 2 : value;
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
    const AudioStreamBasicDescription output = route.outputPCM.mFormatID == 0 ? pcm : route.outputPCM;
    const bool outputPlanar = (output.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool outputFloat = (output.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool outputSigned = (output.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    if (output.mFormatID != kAudioFormatLinearPCM || output.mSampleRate != pcm.mSampleRate
        || output.mChannelsPerFrame == 0 || output.mChannelsPerFrame > 32 || outputFloat == outputSigned
        || output.mFramesPerPacket != 1 || output.mBytesPerPacket != output.mBytesPerFrame) return false;
    const uint32_t outputChannels = outputPlanar ? 1 : output.mChannelsPerFrame;
    if (output.mBytesPerFrame % outputChannels != 0) return false;
    const uint32_t outputWidth = output.mBytesPerFrame / outputChannels;
    const bool outputBigEndian = (output.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    if (outputFloat) {
        if (outputBigEndian || !((output.mBitsPerChannel == 32 && outputWidth == 4) || (output.mBitsPerChannel == 64 && outputWidth == 8))) return false;
    } else {
        if (!(output.mBitsPerChannel == 16 || output.mBitsPerChannel == 24 || output.mBitsPerChannel == 32)) return false;
        if (output.mBitsPerChannel == 24 ? !(outputWidth == 3 || outputWidth == 4) : outputWidth != output.mBitsPerChannel / 8) return false;
    }
    state->output = (OutputPCM){outputChannels, outputPlanar ? output.mChannelsPerFrame : 1,
        outputWidth, output.mBitsPerChannel,
        (output.mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0 ? outputWidth * 8 - output.mBitsPerChannel : 0,
        outputBigEndian, outputFloat ? (output.mBitsPerChannel == 32 ? PCMFloat32 : PCMFloat64) : PCMInteger};
    state->limiterVolume = 1;
    state->limiterRelease = 1 - exp(-1 / (pcm.mSampleRate * 0.08));
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
    atomic_init(&renderer->renderedFrames, 0);
    atomic_init(&renderer->fastFrames, 0);
    if (!atomic_is_lock_free(&renderer->renderedFrames)) { free(renderer); return NULL; }
    for (size_t index = 0; index < count; index++) {
        if (!configureRoute(&renderer->routes[index], routes[index])) { free(renderer); return NULL; }
    }
    return renderer;
}

uint64_t XSVolumeRendererFastFrameCount(XSVolumeRendererRef renderer) {
    return atomic_load_explicit(&renderer->fastFrames, memory_order_relaxed);
}
uint64_t XSVolumeRendererFrameCount(XSVolumeRendererRef renderer) {
    return atomic_load_explicit(&renderer->renderedFrames, memory_order_relaxed);
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

static double readSample(const uint8_t *data, PCMEncoding encoding, const VolumeRouteState *integerFormat) {
    if (encoding == PCMFloat32) { float value; memcpy(&value, data, 4); return isfinite(value) ? value : 0; }
    if (encoding == PCMFloat64) { double value; memcpy(&value, data, 8); return isfinite(value) ? value : 0; }
    return (double)decodeInteger(data, integerFormat) / (double)(UINT64_C(1) << (integerFormat->significantBits - 1));
}

static size_t mixRoute(const AudioBufferList *input, AudioBufferList *output, VolumeRouteState *route) {
    route->usedFastPath = false;
    size_t frames = SIZE_MAX;
    for (uint32_t index = 0; index < route->buffers; index++) {
        const uint64_t offset = (uint64_t)route->source + index;
        if (offset >= input->mNumberBuffers) return 0;
        const AudioBuffer buffer = input->mBuffers[offset];
        if (buffer.mData == NULL || buffer.mNumberChannels != route->channels) return 0;
        const size_t available = buffer.mDataByteSize / (route->channels * route->sampleBytes);
        if (available < frames) frames = available;
    }
    for (uint32_t index = 0; index < route->output.buffers; index++) {
        const uint64_t offset = (uint64_t)route->destination + index;
        if (offset >= output->mNumberBuffers) return 0;
        const AudioBuffer buffer = output->mBuffers[offset];
        if (buffer.mData == NULL || buffer.mNumberChannels != route->output.channels) return 0;
        const size_t available = buffer.mDataByteSize / (route->output.channels * route->output.sampleBytes);
        if (available < frames) frames = available;
    }
    if (frames == 0 || frames == SIZE_MAX) return 0;
    if (route->envelopeFrames == 0 && route->envelopeTarget == 0) return frames;
    // 0–100% 的常见 Float32 同形状路径保持向量化，额外映射与限制仅在需要时执行。
    if (route->encoding == PCMFloat32 && route->output.encoding == PCMFloat32 && route->buffers == route->output.buffers
        && route->channels == route->output.channels && route->envelopeFrames == 0
        && route->envelopeTarget <= 1 && route->limiterVolume == 1) {
        route->usedFastPath = true;
        for (uint32_t buffer = 0; buffer < route->buffers; buffer++) {
            const float *source = input->mBuffers[route->source + buffer].mData;
            float *destination = output->mBuffers[route->destination + buffer].mData;
            const float volume = route->envelopeTarget;
            for (size_t sample = 0; sample < frames * route->channels; sample++) destination[sample] += source[sample] * volume;
        }
        return frames;
    }
    VolumeRouteState outputFormat = {0};
    outputFormat.sampleBytes = route->output.sampleBytes; outputFormat.significantBits = route->output.significantBits;
    outputFormat.highPadding = route->output.highPadding; outputFormat.bigEndian = route->output.bigEndian;
    const uint32_t sourceChannels = route->channels * route->buffers;
    const uint32_t destinationChannels = route->output.channels * route->output.buffers;
    for (size_t frame = 0; frame < frames; frame++) {
        double source[32] = {0}, mapped[32] = {0};
        const float volume = volumeAtFrame(route, frame);
        if (volume != 0) for (uint32_t channel = 0; channel < sourceChannels; channel++) {
            const uint8_t *buffer = input->mBuffers[route->source + channel / route->channels].mData;
            const size_t offset = (frame * route->channels + channel % route->channels) * route->sampleBytes;
            source[channel] = readSample(buffer + offset, route->encoding, route) * volume;
        }
        double peak = 0;
        for (uint32_t channel = 0; channel < destinationChannels; channel++) {
            if (destinationChannels == 1 && sourceChannels > 1) {
                for (uint32_t index = 0; index < sourceChannels; index++) mapped[channel] += source[index] / sourceChannels;
            } else if (channel < sourceChannels) mapped[channel] = source[channel];
            else if (sourceChannels == 1 && channel == 1) mapped[channel] = source[0];
            peak = fmax(peak, fabs(mapped[channel]));
        }
        // 每个样本帧的声道共用限制量：峰值即时压低，80ms 平滑恢复，避免增益削波与声像漂移。
        const double ceiling = volume > 1 ? 0.98 : 1;
        const double allowed = peak > ceiling ? ceiling / peak : 1;
        if (allowed < route->limiterVolume) route->limiterVolume = allowed;
        else route->limiterVolume = fmin(allowed, route->limiterVolume + (1 - route->limiterVolume) * route->limiterRelease);
        // 渐近释放不会自然达到精确的 1；峰值允许完全释放时，归一到 unity 以恢复快路径。
        if (allowed == 1 && route->limiterVolume >= 1 - 1e-6) route->limiterVolume = 1;
        for (uint32_t channel = 0; channel < destinationChannels; channel++) {
            uint8_t *buffer = output->mBuffers[route->destination + channel / route->output.channels].mData;
            const size_t offset = (frame * route->output.channels + channel % route->output.channels) * route->output.sampleBytes;
            const double existing = readSample(buffer + offset, route->output.encoding, &outputFormat);
            const double value = existing + mapped[channel] * route->limiterVolume;
            if (route->output.encoding == PCMFloat32) { const float sample = (float)value; memcpy(buffer + offset, &sample, 4); }
            else if (route->output.encoding == PCMFloat64) { memcpy(buffer + offset, &value, 8); }
            else encodeInteger(buffer + offset, &outputFormat, value * (double)(UINT64_C(1) << (outputFormat.significantBits - 1)));
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
    size_t completed = 0, fast = 0;
    for (size_t index = 0; index < renderer->routeCount; index++) {
        VolumeRouteState *route = &renderer->routes[index];
        updateEnvelope(route);
        const size_t frames = mixRoute(input, output, route);
        advanceEnvelope(route, frames);
        if (frames > completed) completed = frames;
        if (route->usedFastPath && frames > fast) fast = frames;
    }
    if (fast > 0) atomic_fetch_add_explicit(&renderer->fastFrames, fast, memory_order_relaxed);
    if (completed > 0) atomic_fetch_add_explicit(&renderer->renderedFrames, completed, memory_order_relaxed);
    return noErr;
}
