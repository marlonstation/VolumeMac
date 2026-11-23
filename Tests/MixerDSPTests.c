#include "../Sources/MixerDSP.h"
#include <assert.h>
#include <stdio.h>

static void expect(float first, float second, float *samples) {
    assert(samples[0] == first && samples[1] == second);
}

int main(void) {
    VMRenderBuffer *buffer = vm_buffer_create();
    assert(buffer && !vm_buffer_heard_signal(buffer));

    const AudioTimeStamp timestamp = {0};
    AudioUnitRenderActionFlags flags = 0;
    float source[] = {0.5f, -0.5f};
    float destination[] = {1.0f, 1.0f, 1.0f, 1.0f};
    AudioBufferList input = {1, {{2, sizeof(source), source}}};
    AudioBufferList output = {1, {{2, sizeof(destination), destination}}};

    assert(vm_capture(0, &timestamp, &input, &timestamp, &output, &timestamp, buffer) == noErr);
    assert(vm_render(buffer, &flags, &timestamp, 0, 2, &output) == noErr);
    expect(0, 0, destination);
    expect(0, 0, destination + 2);
    assert(vm_buffer_heard_signal(buffer));
    assert(vm_buffer_frames_played(buffer) == 1);

    vm_buffer_set_gain(buffer, 0.5f);
    vm_buffer_arm(buffer);
    assert(vm_capture(0, &timestamp, &input, &timestamp, &output, &timestamp, buffer) == noErr);
    assert(vm_render(buffer, &flags, &timestamp, 0, 2, &output) == noErr);
    expect(0.25f, -0.25f, destination);
    expect(0, 0, destination + 2);

    vm_buffer_set_gain(buffer, 0);
    assert(vm_capture(0, &timestamp, &input, &timestamp, &output, &timestamp, buffer) == noErr);
    assert(vm_render(buffer, &flags, &timestamp, 0, 2, &output) == noErr);
    expect(0, 0, destination);
    assert(vm_buffer_frames_played(buffer) == 3);
    assert(!vm_buffer_format_failed(buffer));

    vm_buffer_destroy(buffer);
    puts("Pass: probe silence, stereo attenuation, mute, and underrun.");
}
