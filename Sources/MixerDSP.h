#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct VMRenderBuffer VMRenderBuffer;

VMRenderBuffer * _Nullable vm_buffer_create(void);
void vm_buffer_destroy(VMRenderBuffer * _Nonnull buffer);
void vm_buffer_set_gain(VMRenderBuffer * _Nonnull buffer, float gain);
void vm_buffer_arm(VMRenderBuffer * _Nonnull buffer);
bool vm_buffer_heard_signal(const VMRenderBuffer * _Nonnull buffer);
uint64_t vm_buffer_frames_played(const VMRenderBuffer * _Nonnull buffer);
bool vm_buffer_format_failed(const VMRenderBuffer * _Nonnull buffer);

OSStatus vm_capture(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
                    void * _Nullable context);

OSStatus vm_render(void * _Nonnull context, AudioUnitRenderActionFlags * _Nonnull flags,
                   const AudioTimeStamp * _Nonnull timestamp, UInt32 bus,
                   UInt32 frames, AudioBufferList * _Nullable output);
