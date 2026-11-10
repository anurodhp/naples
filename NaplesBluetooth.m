#import "NaplesBluetooth.h"
#import "NaplesPanel.h"
#import "NaplesX.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define BtSetup "/usr/sbin/btsetup"

/* ---- btsetup (run on a queue) ---- */

/* Runs btsetup with up to three arguments and hands each line it prints, split at tabs, to `line` (on the calling
 * queue). *pidOut gets its pid while it runs, so a pairing can be cancelled. The exit status is not used: once the dock
 * has started an NSTask, gnustep-base can reap the child first (NaplesWifi.m's runTool), so callers judge by the lines. */
static void
runSetup(const char *a1, const char *a2, const char *a3, const char *a4, pid_t *pidOut, void (^line)(NSArray *fields))
{
	char *argv[6] = { BtSetup, (char *)a1, (char *)a2, (char *)a3, (char *)a4, NULL };
	posix_spawn_file_actions_t fa;
	int fds[2], st;
	pid_t pid;
	FILE *f;
	char buf[512];
	if (pipe(fds) != 0) return;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
	posix_spawn_file_actions_addclose(&fa, fds[0]);
	if (posix_spawn(&pid, BtSetup, &fa, NULL, argv, environ) != 0) {
		posix_spawn_file_actions_destroy(&fa);
		close(fds[0]); close(fds[1]);
		return;
	}
	posix_spawn_file_actions_destroy(&fa);
	close(fds[1]);
	if (pidOut) *pidOut = pid;
	if ((f = fdopen(fds[0], "r")) != NULL) {
		while (fgets(buf, sizeof buf, f)) {
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSString *s;
			buf[strcspn(buf, "\r\n")] = 0;
			s = [NSString stringWithUTF8String: buf];
			if (s && line) line([s componentsSeparatedByString: @"\t"]);
			[pool release];
		}
		fclose(f);
	} else {
		close(fds[0]);
	}
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR) ;
	if (pidOut) *pidOut = 0;
}

static NSString *
field(NSArray *f, NSUInteger i)
{
	return i < [f count] ? [f objectAtIndex: i] : @"";
}

static NSString *
displayName(NSDictionary *d)
{
	NSString *n = [d objectForKey: @"name"];
	return [n length] ? n : [d objectForKey: @"addr"];
}

static NSString *
kindTitle(NSString *kind)
{
	if ([kind isEqual: @"keyboard"]) return @"Keyboard";
	if ([kind isEqual: @"mouse"]) return @"Mouse";
	if ([kind isEqual: @"combo"]) return @"Keyboard and Mouse";
	if ([kind isEqual: @"phone"]) return @"Phone";
	if ([kind isEqual: @"computer"]) return @"Computer";
	if ([kind isEqual: @"audio"]) return @"Audio";
	return @"";
}

/* ---- drawing ---- */

void
NaplesDrawBluetooth(NSRect r, BOOL off, NSColor *color)
{
	/* the rune: a vertical stroke, with two arrow heads on its right that cross over to the left */
	CGFloat w = MIN(r.size.width, r.size.height * 0.62), h = r.size.height;
	CGFloat cx = NSMidX(r), l = cx - w / 2, rt = cx + w / 2, b = NSMinY(r) + 0.5, t = NSMaxY(r) - 0.5;
	NSBezierPath *p = [NSBezierPath bezierPath];
	NSColor *ink = off ? [color colorWithAlphaComponent: [color alphaComponent] * 0.4] : color;
	[ink set];
	[p setLineWidth: 1.5];
	[p setLineJoinStyle: NSRoundLineJoinStyle];
	[p setLineCapStyle: NSRoundLineCapStyle];
	[p moveToPoint: NSMakePoint(l, b + h * 0.27)];
	[p lineToPoint: NSMakePoint(rt, t - h * 0.25)];
	[p lineToPoint: NSMakePoint(cx, t)];
	[p lineToPoint: NSMakePoint(cx, b)];
	[p lineToPoint: NSMakePoint(rt, b + h * 0.25)];
	[p lineToPoint: NSMakePoint(l, t - h * 0.27)];
	[p stroke];
	if (off) {
		NSBezierPath *s = [NSBezierPath bezierPath];
		[color set];
		[s setLineWidth: 1.5];
		[s setLineCapStyle: NSRoundLineCapStyle];
		[s moveToPoint: NSMakePoint(NSMinX(r) - 1, NSMinY(r) + 1)];
		[s lineToPoint: NSMakePoint(NSMaxX(r) + 1, NSMaxY(r) - 1)];
		[s stroke];
	}
}

/* ---- the panel ---- */

enum { PanelW = 272, PanelRadius = 6, HeaderH = 40, LabelH = 22, RowH = 28, InfoH = 26, LinkH = 26, BottomPad = 8,
       SwitchW = 36, SwitchH = 20, MaxListed = 10 };

@interface NaplesBluetoothWindow : NSWindow
@end
@implementation NaplesBluetoothWindow
- (BOOL) canBecomeKeyWindow { return NO; }
- (BOOL) canBecomeMainWindow { return NO; }
@end

@interface NaplesBluetoothView : NSView {
	NaplesBluetooth *bt;
	NSImage *backdrop;
	NSTrackingRectTag trackTag;
	BOOL tracking;
	NSInteger hover;
}
- (id) initWithBluetooth: (NaplesBluetooth *)b;
- (void) setBackdrop: (NSImage *)img;
- (NSArray *) rows;
- (CGFloat) heightForRows: (NSArray *)rows;
@end

static NSDictionary *
row(NSString *kind, CGFloat h, id obj)
{
	return [NSDictionary dictionaryWithObjectsAndKeys: kind, @"kind", [NSNumber numberWithDouble: h], @"h", obj, @"obj", nil];
}

static BOOL
clickable(NSString *kind)
{
	return [kind isEqual: @"device"] || [kind isEqual: @"nearby"] || [kind isEqual: @"forget"] || [kind isEqual: @"settings"];
}

@implementation NaplesBluetoothView

- (id) initWithBluetooth: (NaplesBluetooth *)b
{
	if ((self = [super initWithFrame: NSMakeRect(0, 0, PanelW, 100)])) { bt = b; hover = -1; }
	return self;
}

- (void) dealloc { [backdrop release]; [super dealloc]; }
- (BOOL) isFlipped { return NO; }
- (BOOL) isOpaque { return NO; }
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }
- (void) setBackdrop: (NSImage *)img { if (img != backdrop) { [backdrop release]; backdrop = [img retain]; } [self setNeedsDisplay: YES]; }

/* top to bottom: {kind, h, obj} */
- (NSArray *) rows
{
	NSMutableArray *r = [NSMutableArray array];
	NSArray *devs = [bt devices], *near = [bt nearby];
	NSUInteger i;
	[r addObject: row(@"header", HeaderH, nil)];
	if (![bt enabled]) {
		[r addObject: row(@"info", InfoH, [bt message] ? [bt message] : @"Bluetooth is off.")];
	} else {
		if ([devs count]) {
			[r addObject: row(@"label", LabelH, @"My Devices")];
			for (i = 0; i < [devs count]; i++) {
				NSDictionary *d = [devs objectAtIndex: i];
				[r addObject: row(@"device", RowH, d)];
				if ([[bt expanded] isEqual: [d objectForKey: @"addr"]]) [r addObject: row(@"forget", 22, d)];
			}
		}
		[r addObject: row(@"label", LabelH, @"Nearby Devices")];
		for (i = 0; i < [near count] && i < MaxListed; i++) [r addObject: row(@"nearby", RowH, [near objectAtIndex: i])];
		if ([bt message]) [r addObject: row(@"info", InfoH, [bt message])];
		else if (![near count]) [r addObject: row(@"info", InfoH, [bt scanning] ? @"Searching…" : @"No devices found.")];
	}
	[r addObject: row(@"rule", 9, nil)];
	[r addObject: row(@"settings", LinkH, nil)];
	return r;
}

- (CGFloat) heightForRows: (NSArray *)rows
{
	CGFloat h = BottomPad;
	NSDictionary *d;
	for (d in rows) h += [[d objectForKey: @"h"] doubleValue];
	return h;
}

- (NSRect) switchRect { return NSMakeRect(PanelW - 14 - SwitchW, [self bounds].size.height - HeaderH / 2.0 - SwitchH / 2.0, SwitchW, SwitchH); }

- (NSRect) rectOfRow: (NSUInteger)i in: (NSArray *)rows
{
	CGFloat top = [self bounds].size.height, h;
	NSUInteger k;
	for (k = 0; k < i; k++) top -= [[[rows objectAtIndex: k] objectForKey: @"h"] doubleValue];
	h = [[[rows objectAtIndex: i] objectForKey: @"h"] doubleValue];
	return NSMakeRect(0, top - h, PanelW, h);
}

- (void) drawDevice: (NSString *)name right: (NSString *)right active: (BOOL)active in: (NSRect)r hover: (BOOL)hl
{
	NSRect circle = NSMakeRect(14, NSMidY(r) - 11, 22, 22);
	NSDictionary *ga = NaplesMenuTextAttrs(NaplesPanelLight, NO, NO, NO);
	if (hl) {
		[[NSColor colorWithCalibratedWhite: 0 alpha: 0.08] set];
		[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(r, 6, 1) xRadius: 5 yRadius: 5] fill];
	}
	/* blue for a device in use, as macOS draws it */
	[(active ? [NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1] : [NSColor colorWithCalibratedWhite: 0 alpha: 0.1]) set];
	[[NSBezierPath bezierPathWithOvalInRect: circle] fill];
	NaplesDrawBluetooth(NSMakeRect(NSMidX(circle) - 4, NSMinY(circle) + 4.5, 8, 13), NO,
	                    active ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: 0.08 alpha: 1]);
	[name drawAtPoint: NSMakePoint(44, NSMidY(r) - 8) withAttributes: NaplesMenuTextAttrs(NaplesPanelLight, YES, NO, NO)];
	if ([right length]) {
		NSSize sz = [right sizeWithAttributes: ga];
		[right drawAtPoint: NSMakePoint(PanelW - 16 - sz.width, NSMidY(r) - 8) withAttributes: ga];
	}
}

- (void) drawRect: (NSRect)dirty
{
	NSRect b = [self bounds];
	NSArray *rows = [self rows];
	NSUInteger i;
	NSColor *blue = [NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1];
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

	for (i = 0; i < [rows count]; i++) {
		NSDictionary *d = [rows objectAtIndex: i];
		NSString *kind = [d objectForKey: @"kind"];
		NSRect r = [self rectOfRow: i in: rows];
		BOOL hl = (NSInteger)i == hover;
		if ([kind isEqual: @"header"]) {
			NSRect s = [self switchRect], knob;
			BOOL on = [bt enabled];
			[@"Bluetooth" drawAtPoint: NSMakePoint(14, NSMidY(r) - 8) withAttributes: NaplesMenuTextAttrs(NaplesPanelLight, YES, NO, YES)];
			[(on ? blue : [NSColor colorWithCalibratedWhite: 0 alpha: 0.18]) set];
			[[NSBezierPath bezierPathWithRoundedRect: s xRadius: SwitchH / 2.0 yRadius: SwitchH / 2.0] fill];
			knob = NSMakeRect(on ? NSMaxX(s) - SwitchH + 2 : NSMinX(s) + 2, NSMinY(s) + 2, SwitchH - 4, SwitchH - 4);
			[[NSColor whiteColor] set];
			[[NSBezierPath bezierPathWithOvalInRect: knob] fill];
			[[NSColor colorWithCalibratedWhite: 0 alpha: 0.25] set];
			[[NSBezierPath bezierPathWithOvalInRect: NSInsetRect(knob, 0.5, 0.5)] stroke];
			[[NSColor colorWithCalibratedWhite: 0 alpha: 0.12] set];
			NSRectFill(NSMakeRect(12, NSMinY(r), PanelW - 24, 1));
		} else if ([kind isEqual: @"label"]) {
			NSDictionary *la = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 10], NSFontAttributeName,
			                    [NSColor colorWithCalibratedWhite: 0 alpha: 0.5], NSForegroundColorAttributeName, nil];
			[[d objectForKey: @"obj"] drawAtPoint: NSMakePoint(14, NSMinY(r) + 4) withAttributes: la];
		} else if ([kind isEqual: @"device"]) {
			NSDictionary *dev = [d objectForKey: @"obj"];
			NSString *st = [dev objectForKey: @"state"];
			NSString *right = [st isEqual: @"connected"] ? @"Connected" : [st isEqual: @"connecting"] ? @"Connecting…" : @"Not Connected";
			[self drawDevice: displayName(dev) right: right active: [st isEqual: @"connected"] in: r hover: hl];
		} else if ([kind isEqual: @"nearby"]) {
			NSDictionary *dev = [d objectForKey: @"obj"];
			BOOL busy = [[bt pairing] isEqual: [dev objectForKey: @"addr"]];
			[self drawDevice: displayName(dev) right: busy ? @"Pairing…" : kindTitle([dev objectForKey: @"kind"]) active: NO in: r
			           hover: hl && ![bt pairing]];
		} else if ([kind isEqual: @"forget"]) {
			NSDictionary *fa = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
			                    blue, NSForegroundColorAttributeName, nil];
			if (hl) {
				[[NSColor colorWithCalibratedWhite: 0 alpha: 0.08] set];
				[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(r, 6, 1) xRadius: 5 yRadius: 5] fill];
			}
			[@"Forget This Device…" drawAtPoint: NSMakePoint(44, NSMinY(r) + 4) withAttributes: fa];
		} else if ([kind isEqual: @"info"]) {
			[[d objectForKey: @"obj"] drawAtPoint: NSMakePoint(14, NSMidY(r) - 8) withAttributes: NaplesMenuTextAttrs(NaplesPanelLight, NO, NO, NO)];
		} else if ([kind isEqual: @"rule"]) {
			[[NSColor colorWithCalibratedWhite: 0 alpha: 0.12] set];
			NSRectFill(NSMakeRect(12, NSMidY(r), PanelW - 24, 1));
		} else if ([kind isEqual: @"settings"]) {
			if (hl) {
				[[NSColor colorWithCalibratedWhite: 0 alpha: 0.08] set];
				[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(r, 6, 1) xRadius: 5 yRadius: 5] fill];
			}
			[@"Bluetooth Settings…" drawAtPoint: NSMakePoint(14, NSMidY(r) - 8) withAttributes: NaplesMenuTextAttrs(NaplesPanelLight, YES, NO, NO)];
		}
	}
}

- (NSInteger) rowAt: (NSPoint)p kind: (NSString **)kind
{
	NSArray *rows = [self rows];
	NSUInteger i;
	for (i = 0; i < [rows count]; i++)
		if (NSPointInRect(p, [self rectOfRow: i in: rows])) {
			if (kind) *kind = [[rows objectAtIndex: i] objectForKey: @"kind"];
			return i;
		}
	return -1;
}

- (void) mouseDown: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	NSString *kind = nil;
	NSInteger i;
	NSDictionary *obj;
	if (NSPointInRect(p, NSInsetRect([self switchRect], -6, -6))) {
		[bt setEnabled: ![bt enabled]];
		return;
	}
	if ((i = [self rowAt: p kind: &kind]) < 0) return;
	obj = [[[self rows] objectAtIndex: i] objectForKey: @"obj"];
	if ([kind isEqual: @"device"]) [bt toggleExpanded: [obj objectForKey: @"addr"]];
	else if ([kind isEqual: @"forget"]) [bt forget: obj];
	else if ([kind isEqual: @"nearby"] && ![bt pairing]) [bt pair: obj];
	else if ([kind isEqual: @"settings"]) [bt showSettings];
}

- (void) mouseMoved: (NSEvent *)e
{
	NSString *kind = nil;
	NSInteger i = [self rowAt: [self convertPoint: [e locationInWindow] fromView: nil] kind: &kind];
	if (!clickable(kind)) i = -1;
	if (i != hover) { hover = i; [self setNeedsDisplay: YES]; }
}

/* like the menus and the Wi-Fi panel: leaving the panel closes it after a moment, coming back cancels that */
- (void) mouseEntered: (NSEvent *)e
{
	[NSObject cancelPreviousPerformRequestsWithTarget: bt selector: @selector(hidePanel) object: nil];
}

- (void) mouseExited: (NSEvent *)e
{
	if (hover != -1) { hover = -1; [self setNeedsDisplay: YES]; }
	[bt performSelector: @selector(hidePanel) withObject: nil afterDelay: 1.2];
}

- (void) retrack
{
	if (tracking) [self removeTrackingRect: trackTag];
	trackTag = [self addTrackingRect: [self bounds] owner: self userData: NULL assumeInside: NO];
	tracking = YES;
}

- (void) viewDidMoveToWindow { if ([self window]) [self retrack]; }
- (void) setFrameSize: (NSSize)s { [super setFrameSize: s]; if ([self window]) [self retrack]; }

@end

/* ---- the model ---- */

@interface NaplesBluetooth (Private)
- (void) poll;
- (void) scan;
- (void) layoutPanel;
- (void) showCode: (NSString *)text;
- (void) closeCode;
@end

@implementation NaplesBluetooth

- (id) initWithChangeHandler: (void (^)(void))handler openSettings: (void (^)(void))settings
{
	if (access(BtSetup, X_OK) != 0) { [self release]; return nil; }
	if ((self = [super init])) {
		changed = Block_copy(handler);
		openSettings = settings ? Block_copy(settings) : NULL;
		queue = dispatch_queue_create("naples.bluetooth", NULL);
		scanQueue = dispatch_queue_create("naples.bluetooth.scan", NULL);
		/* a global-queue timer handing over to the main thread (the GNUstep run loop does not drain the main queue) */
		pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
		dispatch_source_set_timer(pollTimer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, NSEC_PER_SEC);
		dispatch_source_set_event_handler(pollTimer, ^{ NaplesRunOnMain(^{ [self poll]; }); });
		dispatch_resume(pollTimer);
	}
	return self;
}

- (BOOL) known { return known; }
- (BOOL) enabled { return on; }
- (NSArray *) devices { return devices; }
- (NSArray *) nearby { return nearby; }
- (BOOL) scanning { return scanning; }
- (NSString *) pairing { return pairing; }
- (NSString *) message { return message; }
- (NSString *) expanded { return expanded; }
- (BOOL) panelShowing { return showing; }

- (BOOL) anyConnected
{
	NSDictionary *d;
	for (d in devices) if ([[d objectForKey: @"state"] isEqual: @"connected"]) return YES;
	return NO;
}

- (void) setMessage: (NSString *)m { if (m != message) { [message release]; message = [m copy]; } }

- (void) notify
{
	if (showing) [self layoutPanel];
	[panelView setNeedsDisplay: YES];
	if (changed) changed();
}

- (void) poll
{
	dispatch_async(queue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSMutableArray *devs = [NSMutableArray array];
		__block NSString *power = nil;
		runSetup("status", NULL, NULL, NULL, NULL, ^(NSArray *f) {
			if ([field(f, 0) isEqual: @"power"]) power = [field(f, 1) retain];
			else if ([field(f, 0) isEqual: @"device"])
				[devs addObject: [NSDictionary dictionaryWithObjectsAndKeys: field(f, 1), @"addr", field(f, 2), @"state",
				                  field(f, 3), @"name", nil]];
		});
		/* a plain local, which the block retains: a __block one it does not (MRC), and the pool frees it */
		NSString *pw = [power autorelease];
		NaplesRunOnMain(^{
			NSString *power = pw;
			if (!power || [power isEqual: @"none"]) return;	/* no controller: no icon (bt=1 is a boot-arg) */
			known = YES;
			if (!powerPending) on = [power isEqual: @"on"];
			[devices release];
			devices = [devs copy];
			if (expanded) {
				NSDictionary *d;
				BOOL still = NO;
				for (d in devices) if ([[d objectForKey: @"addr"] isEqual: expanded]) still = YES;
				if (!still) { [expanded release]; expanded = nil; }
			}
			if (showing && on && !pairing && [NSDate timeIntervalSinceReferenceDate] - lastScan > 30) [self scan];
			[self notify];
		});
		[pool release];
	});
}

- (void) scan
{
	if (scanning || !on) return;
	scanning = YES;
	lastScan = [NSDate timeIntervalSinceReferenceDate];
	[self notify];
	dispatch_async(scanQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSMutableArray *found = [NSMutableArray array];
		runSetup("scan", NULL, NULL, NULL, NULL, ^(NSArray *f) {
			if ([field(f, 0) isEqual: @"found"])
				[found addObject: [NSDictionary dictionaryWithObjectsAndKeys: field(f, 1), @"addr", field(f, 2), @"kind",
				                   field(f, 3), @"name", nil]];
		});
		NaplesRunOnMain(^{
			NSMutableArray *list = [NSMutableArray array];
			NSDictionary *n, *d;
			scanning = NO;
			for (n in found) {
				BOOL paired = NO;
				for (d in devices)
					if ([[d objectForKey: @"addr"] caseInsensitiveCompare: [n objectForKey: @"addr"]] == NSOrderedSame) paired = YES;
				if (!paired) [list addObject: n];
			}
			if (on) { [nearby release]; nearby = [list copy]; }	/* a scan that ends after Bluetooth was turned off is dropped */
			[self notify];
		});
		[pool release];
	});
}

- (void) setEnabled: (BOOL)v
{
	if (powerPending || pairing) return;
	on = v;	/* the switch moves at once; the poll after the call reports what happened */
	powerPending++;
	[self setMessage: nil];
	if (!v) { [nearby release]; nearby = nil; }
	[self notify];
	dispatch_async(queue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		__block NSString *err = nil;
		runSetup("power", v ? "on" : "off", NULL, NULL, NULL, ^(NSArray *f) {
			if ([field(f, 0) isEqual: @"error"]) err = [field(f, 1) retain];
		});
		NSString *failure = [err autorelease];
		NaplesRunOnMain(^{
			NSString *err = failure;
			powerPending--;
			if (err) { [self setMessage: err]; on = !v; }
			[self poll];
			if (v && !err && showing) [self performSelector: @selector(scan) withObject: nil afterDelay: 0.5];
			[self notify];
		});
		[pool release];
	});
}

- (void) toggleExpanded: (NSString *)addr
{
	NSString *e = [expanded isEqual: addr] ? nil : [addr copy];
	[expanded release];
	expanded = e;
	[self notify];
}

- (void) forget: (NSDictionary *)device
{
	NSString *addr = [[[device objectForKey: @"addr"] copy] autorelease];
	[self hidePanel];
	[NaplesConfirm askTitle: [NSString stringWithFormat: @"Forget “%@”?", displayName(device)]
	                message: @"The Pi will disconnect this device and remove its pairing. To use it again, pair it again."
	                confirm: @"Forget"
	                   then: ^{
		dispatch_async(queue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			runSetup("forget", [addr UTF8String], NULL, NULL, NULL, NULL);
			NaplesRunOnMain(^{ [self poll]; });
			[pool release];
		});
	}];
}

- (void) pair: (NSDictionary *)device
{
	NSString *addr = [[[device objectForKey: @"addr"] copy] autorelease];
	NSString *kind = [[[device objectForKey: @"kind"] copy] autorelease];
	NSString *name = [[[device objectForKey: @"name"] copy] autorelease];
	NSString *shown = [[displayName(device) copy] autorelease];
	if (pairing || !on) return;
	pairing = [addr copy];
	[self setMessage: nil];
	[self notify];
	/* its own queue: a status poll must not wait behind the 90 s a pairing can take */
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		__block BOOL paired = NO;
		__block NSString *err = nil;
		runSetup("pair", [addr UTF8String], [kind UTF8String], [name UTF8String], &pairPid, ^(NSArray *f) {
			NSString *what = field(f, 0), *val = field(f, 1);
			if ([what isEqual: @"pin"] || [what isEqual: @"passkey"]) {
				NSString *s = [NSString stringWithFormat: @"Type %@ on “%@”, then press Return.", val, shown];
				NaplesRunOnMain(^{ if ([pairing isEqual: addr]) [self showCode: s]; });
			} else if ([what isEqual: @"paired"]) {
				paired = YES;
			} else if ([what isEqual: @"error"]) {
				[err release];
				err = [val retain];
			}
		});
		NSString *failure = [err autorelease];
		NaplesRunOnMain(^{
			NSString *err = failure;
			BOOL cancelled = ![pairing isEqual: addr];	/* Cancel cleared it (and a new pairing may have started) */
			if (!cancelled) {
				[self closeCode];
				[pairing release];
				pairing = nil;
			}
			if (!cancelled && !paired) [self setMessage: err ? err : @"Pairing did not finish."];
			if (paired) { [nearby release]; nearby = nil; lastScan = 0; }
			[self poll];
			[self notify];
		});
		[pool release];
	});
}

- (void) cancelPairing: (id)sender
{
	NSString *addr = [[pairing copy] autorelease];
	pid_t pid = pairPid;
	[self closeCode];
	if (!addr) return;
	[pairing release];
	pairing = nil;
	if (pid > 0) kill(pid, SIGTERM);
	dispatch_async(queue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		runSetup("forget", [addr UTF8String], NULL, NULL, NULL, NULL);	/* leaves nothing half-paired */
		NaplesRunOnMain(^{ [self poll]; });
		[pool release];
	});
	[self notify];
}

- (void) showSettings
{
	[self hidePanel];
	if (openSettings) openSettings();
}

/* ---- the code dialog ---- */

- (void) showCode: (NSString *)text
{
	NSRect scr = [[NSScreen mainScreen] frame];
	if (!codePanel) {
		NSView *cv;
		NSButton *cancel;
		codePanel = [[NSPanel alloc] initWithContentRect: NSMakeRect(NSMidX(scr) - 190, NSMidY(scr) - 60, 380, 120)
		                                       styleMask: NSTitledWindowMask backing: NSBackingStoreBuffered defer: NO];
		[codePanel setTitle: @"Bluetooth Pairing"];
		[codePanel setReleasedWhenClosed: NO];
		[codePanel setHidesOnDeactivate: NO];
		[[NaplesX shared] registerOwnWindow: (unsigned long)[GSCurrentServer() windowDevice: [codePanel windowNumber]]];
		cv = [codePanel contentView];
		codeLabel = [[NSTextField alloc] initWithFrame: NSMakeRect(20, 50, 340, 54)];
		[codeLabel setEditable: NO];
		[codeLabel setSelectable: NO];
		[codeLabel setBezeled: NO];
		[codeLabel setDrawsBackground: NO];
		[codeLabel setFont: [NSFont systemFontOfSize: 13]];
		[cv addSubview: codeLabel];
		cancel = [[[NSButton alloc] initWithFrame: NSMakeRect(270, 12, 90, 26)] autorelease];
		[cancel setTitle: @"Cancel"];
		[cancel setKeyEquivalent: @"\e"];
		[cancel setTarget: self];
		[cancel setAction: @selector(cancelPairing:)];
		[cv addSubview: cancel];
	}
	[codeLabel setStringValue: text];
	[self hidePanel];
	[codePanel orderFrontRegardless];
}

- (void) closeCode { [codePanel orderOut: nil]; }

/* ---- the panel ---- */

- (void) layoutPanel
{
	NaplesBluetoothView *v = (NaplesBluetoothView *)panelView;
	NSRect f = [panelWindow frame];
	CGFloat h = [v heightForRows: [v rows]];
	if (h == f.size.height) return;
	f.origin.y += f.size.height - h;
	f.size.height = h;
	[panelWindow setFrame: f display: NO];
	[v setFrame: NSMakeRect(0, 0, PanelW, h)];
	[v setBackdrop: [[NaplesX shared] backgroundForRect: NSMakeRect(f.origin.x - NSMinX([[NSScreen mainScreen] frame]),
	                                                                 NSMaxY([[NSScreen mainScreen] frame]) - NSMaxY(f), PanelW, h)]];
	[panelWindow display];
}

- (void) togglePanelUnder: (NSRect)icon
{
	NSRect scr = [[NSScreen mainScreen] frame];
	CGFloat x = NSMidX(icon) - PanelW / 2.0, top = NSMaxY(icon), h;
	if (showing) { [self hidePanel]; return; }
	if (x + PanelW > scr.size.width - 4) x = scr.size.width - 4 - PanelW;
	if (x < 4) x = 4;
	if (!panelWindow) {
		panelWindow = [[NaplesBluetoothWindow alloc] initWithContentRect: NSMakeRect(0, 0, PanelW, 100) styleMask: NSBorderlessWindowMask
		                                                         backing: NSBackingStoreBuffered defer: NO];
		[panelWindow setLevel: NSStatusWindowLevel];
		[panelWindow setOpaque: NO];
		[panelWindow setBackgroundColor: [NSColor clearColor]];
		[panelWindow setHasShadow: NO];
		[panelWindow setReleasedWhenClosed: NO];
		[panelWindow setCanHide: NO];
		[panelWindow setAcceptsMouseMovedEvents: YES];
		panelView = [[NaplesBluetoothView alloc] initWithBluetooth: self];
		[panelWindow setContentView: panelView];
		[[NaplesX shared] registerOwnWindow: (unsigned long)[GSCurrentServer() windowDevice: [panelWindow windowNumber]]];
	}
	[self setMessage: nil];
	h = [(NaplesBluetoothView *)panelView heightForRows: [(NaplesBluetoothView *)panelView rows]];
	[panelWindow setFrame: NSMakeRect(NSMinX(scr) + x, NSMaxY(scr) - top - h, PanelW, h) display: NO];
	[panelView setFrame: NSMakeRect(0, 0, PanelW, h)];
	[(NaplesBluetoothView *)panelView setBackdrop: [[NaplesX shared] backgroundForRect: NSMakeRect(x, top, PanelW, h)]];
	[panelWindow orderFrontRegardless];
	[panelWindow display];
	showing = YES;
	dispatch_source_set_timer(pollTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC);
	[self poll];
	if (!pairing) [self scan];
	[self notify];
}

- (void) hidePanel
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(hidePanel) object: nil];
	if (!showing) return;
	[panelWindow orderOut: nil];
	showing = NO;
	dispatch_source_set_timer(pollTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
	[self notify];
}

@end
