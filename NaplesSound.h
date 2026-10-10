/* NaplesSound: the menu bar's volume control. A speaker left of the clock whose waves follow the volume; clicking it opens a
 * small "Sound" panel with a horizontal slider.
 *
 * The volume is the device volume of iokit's audiod (coreaudio/), reached through the public CoreAudio HAL calls that
 * /usr/lib/libaudiohal.dylib exports (AudioObjectGetPropertyData / SetPropertyData, kAudioDevicePropertyVolumeScalar and
 * kAudioDevicePropertyMute on the default output device). The library is opened with dlopen, so Naples builds without the
 * CoreAudio headers and runs on an image without audio: no library, no speaker. Every call is a Mach RPC to audiod (and
 * the first one starts it through launchd), so they run on a serial queue, never on the main thread.
 *
 * libaudiohal has no property listeners, so a volume changed by another program shows when the panel is next opened. */
#import <AppKit/AppKit.h>

/* number of waves to draw: 0 (silent or muted) to 3 */
int NaplesSpeakerWaves(float volume, BOOL muted);
/* a speaker in r (about 20 x 14), with 0-3 waves; muted adds a small cross instead of waves */
void NaplesDrawSpeaker(NSRect r, int waves, BOOL muted, NSColor *color);

@interface NaplesSound : NSObject {
	void (^changed)(void);
	dispatch_queue_t queue;
	float volume;
	BOOL muted, known, showing;
	volatile int generation;	/* bumped by every local change; a read issued before one is stale */
	NSWindow *panelWindow;
	NSView *panelView;
}
/* nil when /usr/lib/libaudiohal.dylib is not there. `handler` runs on the main thread when the volume, the mute state or
 * the panel's visibility changes. */
- (id) initWithChangeHandler: (void (^)(void))handler;
- (BOOL) known;	/* a volume has been read from audiod (until then the bar draws no speaker) */
- (float) volume;
- (BOOL) muted;
- (void) refresh;	/* read the volume again */
- (void) setVolume: (float)v;	/* 0..1; also unmutes when v > 0 */
/* the panel, hanging under icon (screen coordinates, top-left origin) */
- (void) togglePanelUnder: (NSRect)icon;
- (void) hidePanel;
- (BOOL) panelShowing;
@end
