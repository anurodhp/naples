#import "NaplesSound.h"
#import "NaplesPanel.h"
#import "NaplesX.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <dlfcn.h>

/* The few CoreAudio HAL declarations used here, with the values of the public CoreAudio/AudioHardware.h and
 * AudioHardwareBase.h (Xcode 12 MacOSX SDK), which libaudiohal is built against. */
typedef uint32_t NaplesAudioObjectID;
typedef struct { uint32_t mSelector, mScope, mElement; } NaplesAudioAddress;	/* AudioObjectPropertyAddress */
typedef int32_t (*NaplesGetFn)(NaplesAudioObjectID, const NaplesAudioAddress *, uint32_t, const void *, uint32_t *, void *);
typedef int32_t (*NaplesSetFn)(NaplesAudioObjectID, const NaplesAudioAddress *, uint32_t, const void *, uint32_t, const void *);
enum {
	kSystemObject = 1,	/* kAudioObjectSystemObject */
	kDefaultOutputDevice = 'dOut',	/* kAudioHardwarePropertyDefaultOutputDevice */
	kScopeGlobal = 'glob', kScopeOutput = 'outp', kElementMaster = 0,
	kVolumeScalar = 'volm',	/* kAudioDevicePropertyVolumeScalar, Float32 0..1 */
	kMute = 'mute',	/* kAudioDevicePropertyMute, UInt32 */
};

static NaplesGetFn getProperty;
static NaplesSetFn setProperty;

static BOOL
loadHAL(void)
{
	void *h = dlopen("/usr/lib/libaudiohal.dylib", RTLD_LAZY | RTLD_LOCAL);
	if (!h) return NO;
	getProperty = (NaplesGetFn)dlsym(h, "AudioObjectGetPropertyData");
	setProperty = (NaplesSetFn)dlsym(h, "AudioObjectSetPropertyData");
	return getProperty && setProperty;
}

static NaplesAudioObjectID
outputDevice(void)
{
	NaplesAudioAddress a = { kDefaultOutputDevice, kScopeGlobal, kElementMaster };
	NaplesAudioObjectID dev = 0;
	uint32_t sz = sizeof dev;
	return getProperty(kSystemObject, &a, 0, NULL, &sz, &dev) == 0 ? dev : 0;
}

int
NaplesSpeakerWaves(float volume, BOOL muted)
{
	if (muted || volume <= 0.001f) return 0;
	return volume <= 1.0f / 3 ? 1 : volume <= 2.0f / 3 ? 2 : 3;
}

void
NaplesDrawSpeaker(NSRect r, int waves, BOOL muted, NSColor *color)
{
	CGFloat x = NSMinX(r), my = NSMidY(r);
	NSBezierPath *p = [NSBezierPath bezierPath];
	int i;
	[color set];
	/* the magnet and the cone */
	[p moveToPoint: NSMakePoint(x + 1, my - 2.5)];
	[p lineToPoint: NSMakePoint(x + 4, my - 2.5)];
	[p lineToPoint: NSMakePoint(x + 7, my - 6)];
	[p lineToPoint: NSMakePoint(x + 7, my + 6)];
	[p lineToPoint: NSMakePoint(x + 4, my + 2.5)];
	[p lineToPoint: NSMakePoint(x + 1, my + 2.5)];
	[p closePath];
	[p fill];
	if (muted) {
		NSBezierPath *c = [NSBezierPath bezierPath];
		[c setLineWidth: 1.4];
		[c moveToPoint: NSMakePoint(x + 11, my - 3)]; [c lineToPoint: NSMakePoint(x + 17, my + 3)];
		[c moveToPoint: NSMakePoint(x + 11, my + 3)]; [c lineToPoint: NSMakePoint(x + 17, my - 3)];
		[c stroke];
		return;
	}
	for (i = 0; i < waves; i++) {	/* arcs centred behind the cone's mouth, 3.5 px apart, the first 2.5 px clear of it */
		NSBezierPath *w = [NSBezierPath bezierPath];
		[w setLineWidth: 1.3];
		[w setLineCapStyle: NSRoundLineCapStyle];
		[w appendBezierPathWithArcWithCenter: NSMakePoint(x + 3.5, my) radius: 6 + 3.5 * i startAngle: -45 endAngle: 45];
		[w stroke];
	}
}

/* ---- the panel ---- */

enum { PanelW = 232, PanelH = 66, PanelRadius = 6, TrackX = 38, TrackRight = 40, KnobD = 14 };

@interface NaplesSoundWindow : NSWindow
@end
@implementation NaplesSoundWindow
- (BOOL) canBecomeKeyWindow { return NO; }
- (BOOL) canBecomeMainWindow { return NO; }
@end

@interface NaplesSoundView : NSView {
	NaplesSound *sound;
	NSImage *backdrop;
	NSTrackingRectTag trackTag;
	BOOL tracking, dragging, inside;
}
- (id) initWithSound: (NaplesSound *)s;
- (void) setBackdrop: (NSImage *)img;
@end

@implementation NaplesSoundView

- (id) initWithSound: (NaplesSound *)s
{
	if ((self = [super initWithFrame: NSMakeRect(0, 0, PanelW, PanelH)])) sound = s;
	return self;
}

- (void) dealloc { [backdrop release]; [super dealloc]; }
- (BOOL) isFlipped { return NO; }
- (BOOL) isOpaque { return NO; }
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }
- (void) setBackdrop: (NSImage *)img { if (img != backdrop) { [backdrop release]; backdrop = [img retain]; } [self setNeedsDisplay: YES]; }

- (NSRect) trackRect { return NSMakeRect(TrackX, 18, [self bounds].size.width - TrackX - TrackRight, 4); }

- (void) drawRect: (NSRect)dirty
{
	NSRect b = [self bounds], t = [self trackRect];
	NSDictionary *ta = NaplesMenuTextAttrs(NaplesPanelLight, YES, NO, YES);
	CGFloat v = [sound volume], kx = NSMinX(t) + v * NSWidth(t);
	NSRect knob = NSMakeRect(kx - KnobD / 2.0, NSMidY(t) - KnobD / 2.0, KnobD, KnobD);
	NSRectFillUsingOperation(dirty, NSCompositeClear);
	if (backdrop) {	/* the wallpaper fills the corners the rounding leaves (no compositor) */
		NSRect src = NSZeroRect;
		src.size = [backdrop size];
		[backdrop drawInRect: b fromRect: src operation: NSCompositeSourceOver fraction: 1.0];
	}
	[[NSColor colorWithCalibratedWhite: 0.97 alpha: 0.98] set];
	[[NSBezierPath bezierPathWithRoundedRect: b xRadius: PanelRadius yRadius: PanelRadius] fill];
	[[NSColor colorWithCalibratedWhite: 0 alpha: 0.35] set];
	[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(b, 0.5, 0.5) xRadius: PanelRadius yRadius: PanelRadius] stroke];

	[@"Sound" drawAtPoint: NSMakePoint(14, b.size.height - 24) withAttributes: ta];

	NaplesDrawSpeaker(NSMakeRect(12, NSMidY(t) - 7, 20, 14), 0, NO, [NSColor colorWithCalibratedWhite: 0.08 alpha: 0.55]);
	NaplesDrawSpeaker(NSMakeRect(NSMaxX(t) + 10, NSMidY(t) - 7, 20, 14), 3, NO, [NSColor colorWithCalibratedWhite: 0.08 alpha: 0.55]);
	[[NSColor colorWithCalibratedWhite: 0 alpha: 0.18] set];
	[[NSBezierPath bezierPathWithRoundedRect: t xRadius: 2 yRadius: 2] fill];
	[[NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: [sound muted] ? 0.35 : 1] set];
	[[NSBezierPath bezierPathWithRoundedRect: NSMakeRect(NSMinX(t), NSMinY(t), kx - NSMinX(t), NSHeight(t)) xRadius: 2 yRadius: 2] fill];
	[[NSColor whiteColor] set];
	[[NSBezierPath bezierPathWithOvalInRect: knob] fill];
	[[NSColor colorWithCalibratedWhite: 0 alpha: dragging ? 0.55 : 0.35] set];
	[[NSBezierPath bezierPathWithOvalInRect: NSInsetRect(knob, 0.5, 0.5)] stroke];
}

- (void) setFromEvent: (NSEvent *)e
{
	NSRect t = [self trackRect];
	CGFloat x = [self convertPoint: [e locationInWindow] fromView: nil].x;
	CGFloat v = (x - NSMinX(t)) / NSWidth(t);
	[sound setVolume: v < 0 ? 0 : v > 1 ? 1 : v];
}

- (void) mouseDown: (NSEvent *)e
{
	NSRect t = [self trackRect];
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	if (p.y < NSMidY(t) - 12 || p.y > NSMidY(t) + 12 || p.x < NSMinX(t) - KnobD || p.x > NSMaxX(t) + KnobD) return;
	dragging = YES;
	[self setFromEvent: e];
}

- (void) mouseDragged: (NSEvent *)e { if (dragging) [self setFromEvent: e]; }

- (void) mouseUp: (NSEvent *)e
{
	dragging = NO;
	[self setNeedsDisplay: YES];
	if (!inside) [self mouseExited: nil];
}

/* like the menus: leaving the panel closes it after a moment, coming back cancels that */
- (void) mouseEntered: (NSEvent *)e
{
	inside = YES;
	[NSObject cancelPreviousPerformRequestsWithTarget: sound selector: @selector(hidePanel) object: nil];
}

- (void) mouseExited: (NSEvent *)e
{
	inside = NO;
	if (!dragging) [sound performSelector: @selector(hidePanel) withObject: nil afterDelay: 1.2];
}

- (void) retrack
{
	if (tracking) [self removeTrackingRect: trackTag];
	trackTag = [self addTrackingRect: [self bounds] owner: self userData: NULL assumeInside: NO];
	tracking = YES;
}

- (void) viewDidMoveToWindow { if ([self window]) [self retrack]; }

@end

/* ---- the volume ---- */

@implementation NaplesSound

- (id) initWithChangeHandler: (void (^)(void))handler
{
	if (!loadHAL()) { [self release]; return nil; }
	if ((self = [super init])) {
		changed = Block_copy(handler);
		queue = dispatch_queue_create("naples.sound", NULL);
		volume = 1;
		[self refresh];
	}
	return self;
}

- (BOOL) known { return known; }
- (float) volume { return volume; }
- (BOOL) muted { return muted; }

- (void) notify
{
	[panelView setNeedsDisplay: YES];
	if (changed) changed();
}

- (void) refresh
{
	int gen = generation;
	dispatch_async(queue, ^{
		NaplesAudioObjectID dev = outputDevice();
		NaplesAudioAddress va = { kVolumeScalar, kScopeOutput, kElementMaster }, ma = { kMute, kScopeOutput, kElementMaster };
		float v = 0;
		uint32_t m = 0, vs = sizeof v, ms = sizeof m;
		BOOL ok = dev && getProperty(dev, &va, 0, NULL, &vs, &v) == 0;
		if (ok && getProperty(dev, &ma, 0, NULL, &ms, &m) != 0) m = 0;
		NaplesRunOnMain(^{
			if (!ok) {	/* audiod not reachable yet: no speaker, try again later */
				if (!known) [self performSelector: @selector(refresh) withObject: nil afterDelay: 30];
				return;
			}
			if (gen != generation) return;	/* the slider moved since this was read */
			volume = v; muted = m != 0; known = YES;
			[self notify];
		});
	});
}

- (void) setVolume: (float)v
{
	int gen = ++generation;
	BOOL unmute = muted && v > 0;
	volume = v;
	if (unmute) muted = NO;
	[self notify];
	dispatch_async(queue, ^{
		NaplesAudioObjectID dev;
		NaplesAudioAddress va = { kVolumeScalar, kScopeOutput, kElementMaster }, ma = { kMute, kScopeOutput, kElementMaster };
		uint32_t zero = 0;
		if (gen != __atomic_load_n(&generation, __ATOMIC_RELAXED) && !unmute) return;	/* a newer position is queued */
		if (!(dev = outputDevice())) return;
		if (setProperty(dev, &va, 0, NULL, sizeof v, &v) != 0) NSLog(@"Naples: could not set the volume (audiod)");
		if (unmute) setProperty(dev, &ma, 0, NULL, sizeof zero, &zero);
	});
}

/* ---- the panel ---- */

/* our own flag: after orderOut: GNUstep can still report the window as visible (see NaplesPanelSet) */
- (BOOL) panelShowing { return showing; }

- (void) togglePanelUnder: (NSRect)icon
{
	NSRect scr = [[NSScreen mainScreen] frame];
	CGFloat x = NSMidX(icon) - PanelW / 2.0, top = NSMaxY(icon);
	NSRect xr, frame;
	if ([self panelShowing]) { [self hidePanel]; return; }
	if (x + PanelW > scr.size.width - 4) x = scr.size.width - 4 - PanelW;
	if (x < 4) x = 4;
	xr = NSMakeRect(x, top, PanelW, PanelH);
	frame = NSMakeRect(NSMinX(scr) + x, NSMaxY(scr) - top - PanelH, PanelW, PanelH);
	if (!panelWindow) {
		panelWindow = [[NaplesSoundWindow alloc] initWithContentRect: frame styleMask: NSBorderlessWindowMask backing: NSBackingStoreBuffered defer: NO];
		/* a dock-type window like the menus' panels, so the window manager neither focuses nor lists it */
		[panelWindow setLevel: NSStatusWindowLevel];
		[panelWindow setOpaque: NO];
		[panelWindow setBackgroundColor: [NSColor clearColor]];
		[panelWindow setHasShadow: NO];
		[panelWindow setReleasedWhenClosed: NO];
		[panelWindow setCanHide: NO];
		panelView = [[NaplesSoundView alloc] initWithSound: self];
		[panelWindow setContentView: panelView];
		[[NaplesX shared] registerOwnWindow: (unsigned long)[GSCurrentServer() windowDevice: [panelWindow windowNumber]]];
	}
	[panelWindow setFrame: frame display: NO];
	[(NaplesSoundView *)panelView setBackdrop: [[NaplesX shared] backgroundForRect: xr]];
	[panelWindow orderFrontRegardless];
	[panelWindow display];
	showing = YES;
	[self refresh];	/* pick up a volume another program set */
	[self notify];
}

- (void) hidePanel
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(hidePanel) object: nil];
	if (![self panelShowing]) return;
	[panelWindow orderOut: nil];
	showing = NO;
	[self notify];
}

@end
