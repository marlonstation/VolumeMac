#include "MixerDSP.h"
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { frameCapacity = 8192 };

struct VMRenderBuffer {
    _Atomic(uint64_t) written;
    _Atomic(uint64_t) consumed;
    _Atomic(uint64_t) played;
    _Atomic(float) gain;
    _Atomic(bool) formatFailed;
    _Atomic(bool) armed;
    _Atomic(bool) heardSignal;
    float samples[frameCapacity * 2];
};

VMRenderBuffer *vm_buffer_create(void) {
    VMRenderBuffer *buffer = calloc(1, sizeof(*buffer));
    if (buffer) {
        atomic_init(&buffer->written, 0);
        atomic_init(&buffer->consumed, 0);
        atomic_init(&buffer->played, 0);
        atomic_init(&buffer->gain, 1);
        atomic_init(&buffer->formatFailed, false);
        atomic_init(&buffer->armed, false);
        atomic_init(&buffer->heardSignal, false);
    }
    return buffer;
}

void vm_buffer_destroy(VMRenderBuffer *buffer) { free(buffer); }

void vm_buffer_set_gain(VMRenderBuffer *buffer, float gain) {
    atomic_store_explicit(&buffer->gain, gain, memory_order_relaxed);
}

void vm_buffer_arm(VMRenderBuffer *buffer) {
    atomic_store_explicit(&buffer->armed, true, memory_order_relaxed);
}

bool vm_buffer_heard_signal(const VMRenderBuffer *buffer) {
    return atomic_load_explicit(&buffer->heardSignal, memory_order_relaxed);
}

uint64_t vm_buffer_frames_played(const VMRenderBuffer *buffer) {
    return atomic_load_explicit(&buffer->played, memory_order_relaxed);
}

bool vm_buffer_format_failed(const VMRenderBuffer *buffer) {
    return atomic_load_explicit(&buffer->formatFailed, memory_order_relaxed);
}

OSStatus vm_capture(AudioObjectID device, const AudioTimeStamp *now,
                    const AudioBufferList *input, const AudioTimeStamp *inputTime,
                    AudioBufferList *output, const AudioTimeStamp *outputTime,
                    void *context) {
    VMRenderBuffer *buffer = context;
    if (!input || !input->mNumberBuffers || !input->mBuffers[0].mData) return noErr;
    const AudioBuffer *channels = input->mBuffers;
    const bool interleaved = input->mNumberBuffers == 1 && channels[0].mNumberChannels == 2;
    const bool planar = input->mNumberBuffers == 2 && channels[0].mNumberChannels == 1
                     && channels[1].mNumberChannels == 1;
    if (!interleaved && !planar) {
        atomic_store_explicit(&buffer->formatFailed, true, memory_order_relaxed);
        return noErr;
    }
    if (planar && !channels[1].mData) return noErr;
    UInt32 frames = channels[0].mDataByteSize / (sizeof(float) * (interleaved ? 2 : 1));
    if (planar && channels[1].mDataByteSize / sizeof(float) < frames) {
        frames = channels[1].mDataByteSize / sizeof(float);
    }
    const uint64_t written = atomic_load_explicit(&buffer->written, memory_order_relaxed);
    const uint64_t consumed = atomic_load_explicit(&buffer->consumed, memory_order_acquire);
    const uint64_t available = frameCapacity - (written - consumed);
    if (frames > available) frames = (UInt32)available;
    const float *left = channels[0].mData;
    const float *right = interleaved ? left + 1 : channels[1].mData;
    for (UInt32 frame = 0; frame < frames; ++frame) {
        const size_t slot = ((written + frame) % frameCapacity) * 2;
        const UInt32 index = interleaved ? frame * 2 : frame;
        buffer->samples[slot] = left[index];
        buffer->samples[slot + 1] = right[index];
    }
    atomic_store_explicit(&buffer->written, written + frames, memory_order_release);
    return noErr;
}

OSStatus vm_render(void *context, AudioUnitRenderActionFlags *flags,
                   const AudioTimeStamp *timestamp, UInt32 bus,
                   UInt32 frames, AudioBufferList *output) {
    VMRenderBuffer *buffer = context;
    if (!output || output->mNumberBuffers != 1 || !output->mBuffers[0].mData
        || output->mBuffers[0].mNumberChannels != 2
        || output->mBuffers[0].mDataByteSize < (size_t)frames * 2 * sizeof(float)) {
        if (output) {
            for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
                if (output->mBuffers[i].mData) {
                    memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
                }
            }
        }
        atomic_store_explicit(&buffer->formatFailed, true, memory_order_relaxed);
        return noErr;
    }
    float *samples = output->mBuffers[0].mData;
    const uint64_t consumed = atomic_load_explicit(&buffer->consumed, memory_order_relaxed);
    const uint64_t written = atomic_load_explicit(&buffer->written, memory_order_acquire);
    const UInt32 count = written - consumed < frames ? (UInt32)(written - consumed) : frames;
    const bool armed = atomic_load_explicit(&buffer->armed, memory_order_relaxed);
    const float gain = armed ? atomic_load_explicit(&buffer->gain, memory_order_relaxed) : 0;
    bool heardSignal = false;
    for (UInt32 frame = 0; frame < count; ++frame) {
        const size_t slot = ((consumed + frame) % frameCapacity) * 2;
        const float left = buffer->samples[slot];
        const float right = buffer->samples[slot + 1];
        if (!armed && (fabsf(left) > 0.000001f || fabsf(right) > 0.000001f)) heardSignal = true;
        samples[frame * 2] = left * gain;
        samples[frame * 2 + 1] = right * gain;
    }
    memset(samples + count * 2, 0, (size_t)(frames - count) * 2 * sizeof(float));
    atomic_store_explicit(&buffer->consumed, consumed + count, memory_order_release);
    atomic_fetch_add_explicit(&buffer->played, count, memory_order_relaxed);
    if (heardSignal) atomic_store_explicit(&buffer->heardSignal, true, memory_order_relaxed);
    return noErr;
}
