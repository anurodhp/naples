#import "NaplesWifi.h"
#import "NaplesPanel.h"
#import "NaplesX.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <ctype.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach/mach.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>

/* The driver's ABI, shared with the kernel and /usr/sbin/wifi (iokit's build_naples.sh puts its directory on the
 * include path). */
#import "BCM43430WifiShared.h"

extern char **environ;

/* ---- IOKitLib, by dlopen ---- */

/* The few IOKitLib calls used, with the signatures of IOKit/IOKitLib.h (io_object_t and io_connect_t are mach ports;
 * kIOMasterPortDefault is MACH_PORT_NULL). */
typedef mach_port_t NaplesIOObject;
static CFMutableDictionaryRef (*ioServiceMatching)(const char *);
static NaplesIOObject (*ioGetMatchingService)(mach_port_t, CFDictionaryRef);
static kern_return_t (*ioServiceOpen)(NaplesIOObject, task_port_t, uint32_t, NaplesIOObject *);
static kern_return_t (*ioObjectRelease)(NaplesIOObject);
static kern_return_t (*ioServiceClose)(NaplesIOObject);
static kern_return_t (*ioCallMethod)(NaplesIOObject, uint32_t, const uint64_t *, uint32_t, const void *, size_t,
                                     uint64_t *, uint32_t *, void *, size_t *);

/* IOReturn codes used here (IOKit/IOReturn.h: iokit_common_err(x) = 0xe0000000 | x) */
enum {
	kIOReturnNotReady     = (int)0xe00002d8,	/* the driver is not up yet (still loading firmware) */
	kIOReturnNotAttached  = (int)0xe00002d9,	/* the user client went away */
	kIOReturnNotPermitted = (int)0xe00002e2,	/* BCM43430Wifi join: WPA2 handshake failed */
};

static BOOL
loadIOKit(void)
{
	void *h = dlopen("/usr/lib/libiokituser.dylib", RTLD_LAZY | RTLD_LOCAL);
	if (!h) return NO;
	ioServiceMatching = dlsym(h, "IOServiceMatching");
	ioGetMatchingService = dlsym(h, "IOServiceGetMatchingService");
	ioServiceOpen = dlsym(h, "IOServiceOpen");
	ioObjectRelease = dlsym(h, "IOObjectRelease");
	ioServiceClose = dlsym(h, "IOServiceClose");
	ioCallMethod = dlsym(h, "IOConnectCallMethod");
	return ioServiceMatching && ioGetMatchingService && ioServiceOpen && ioObjectRelease && ioServiceClose && ioCallMethod;
}

/* ---- files and helpers (run on the queue) ---- */

#define WifiConf "/etc/wifi.conf"
#define WifiOff  "/etc/wifi.off"

/* /etc/wifi.conf: the remembered network, ssid=... and psk=... lines (wifi.c readConf()) */
static NSDictionary *
savedNetwork(void)
{
	char line[256], ssid[64] = "", psk[128] = "";
	FILE *f = fopen(WifiConf, "r");
	if (!f) return nil;
	while (fgets(line, sizeof line, f)) {
		line[strcspn(line, "\r\n")] = 0;
		if (!strncmp(line, "ssid=", 5)) strlcpy(ssid, line + 5, sizeof ssid);
		else if (!strncmp(line, "psk=", 4)) strlcpy(psk, line + 4, sizeof psk);
	}
	fclose(f);
	if (!ssid[0]) return nil;
	return [NSDictionary dictionaryWithObjectsAndKeys: [NSString stringWithUTF8String: ssid], @"ssid",
	        [NSString stringWithUTF8String: psk], @"psk", nil];
}

static void
saveNetwork(const char *ssid, const char *psk)
{
	char buf[256];
	int fd, n;
	if (strchr(ssid, '\n') || strchr(psk, '\n')) return;
	n = snprintf(buf, sizeof buf, "ssid=%s\npsk=%s\n", ssid, psk);
	if (n <= 0 || n >= (int)sizeof buf) return;
	/* a fresh file only: never follow or reuse a leftover .new (it would get the passphrase) */
	unlink(WifiConf ".new");
	fd = open(WifiConf ".new", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
	if (fd < 0) { NSLog(@"Naples: cannot write %s", WifiConf); memset(buf, 0, sizeof buf); return; }
	if (write(fd, buf, n) == n && fsync(fd) == 0) {
		close(fd);
		if (rename(WifiConf ".new", WifiConf) != 0) unlink(WifiConf ".new");
	} else {
		close(fd);
		unlink(WifiConf ".new");
	}
	memset(buf, 0, sizeof buf);
}

/* run a tool and wait for it; its exit status, or -1 if unknown. Unknown includes ECHILD: once the dock has started an
 * NSTask, gnustep-base reaps every child with waitpid(-1, WNOHANG) on SIGCHLD (Source/NSTask.m:1515), so it can take
 * this one first. No caller relies on the status. */
static int
runTool(const char *path, const char *a1, const char *a2, const char *a3)
{
	char *argv[5] = { (char *)path, (char *)a1, (char *)a2, (char *)a3, NULL };
	pid_t pid;
	int st = 0;
	if (posix_spawn(&pid, path, NULL, NULL, argv, environ) != 0) return -1;
	while (waitpid(pid, &st, 0) < 0) {
		if (errno != EINTR) return -1;
	}
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* run a tool and return the first line it prints, nil if it fails */
static NSString *
toolOutput(const char *path, const char *a1, const char *a2, const char *a3)
{
	char *argv[5] = { (char *)path, (char *)a1, (char *)a2, (char *)a3, NULL };
	posix_spawn_file_actions_t fa;
	int fds[2], st = 0;
	char buf[128];
	ssize_t n, got = 0;
	pid_t pid;
	if (pipe(fds) != 0) return nil;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
	posix_spawn_file_actions_addclose(&fa, fds[0]);
	if (posix_spawn(&pid, path, &fa, NULL, argv, environ) != 0) {
		posix_spawn_file_actions_destroy(&fa);
		close(fds[0]); close(fds[1]);
		return nil;
	}
	posix_spawn_file_actions_destroy(&fa);
	close(fds[1]);
	while (got < (ssize_t)sizeof buf - 1 && (n = read(fds[0], buf + got, sizeof buf - 1 - got)) > 0) got += n;
	close(fds[0]);
	{
		BOOL known = YES;	/* ECHILD: reaped by NSTask (see runTool); judge by the output alone */
		while (waitpid(pid, &st, 0) < 0) {
			if (errno != EINTR) { known = NO; break; }
		}
		buf[got] = 0;
		buf[strcspn(buf, "\r\n")] = 0;
		if ((known && (!WIFEXITED(st) || WEXITSTATUS(st) != 0)) || !buf[0]) return nil;
	}
	return [NSString stringWithUTF8String: buf];
}

/* en1's IPv4 address, nil if it has none */
static NSString *
interfaceAddress(const char *ifname)
{
	struct ifaddrs *ifs, *i;
	NSString *s = nil;
	if (getifaddrs(&ifs) != 0) return nil;
	for (i = ifs; i && !s; i = i->ifa_next) {
		char a[INET_ADDRSTRLEN];
		if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || strcmp(i->ifa_name, ifname)) continue;
		if (inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, a, sizeof a))
			s = [NSString stringWithUTF8String: a];
	}
	freeifaddrs(ifs);
	return s;
}

int
NaplesWifiBars(int rssi)
{
	return rssi >= -60 ? 3 : rssi >= -72 ? 2 : 1;
}

void
NaplesDrawWifi(NSRect r, int bars, BOOL off, NSColor *color)
{
	/* the macOS fan: a dot and three arcs opening upwards, centred at the bottom middle */
	NSPoint c = NSMakePoint(NSMidX(r), NSMinY(r) + 1.5);
	NSColor *faint = [color colorWithAlphaComponent: [color alphaComponent] * 0.28];
	int i;
	[(bars > 0 ? color : faint) set];
	[[NSBezierPath bezierPathWithOvalInRect: NSMakeRect(c.x - 1.6, c.y - 0.4, 3.2, 3.2)] fill];
	for (i = 0; i < 3; i++) {
		NSBezierPath *a = [NSBezierPath bezierPath];
		[(i < bars ? color : faint) set];
		[a setLineWidth: 1.7];
		[a setLineCapStyle: NSRoundLineCapStyle];
		[a appendBezierPathWithArcWithCenter: c radius: 4.6 + 3.8 * i startAngle: 45 endAngle: 135];
		[a stroke];
	}
	if (off) {
		NSBezierPath *s = [NSBezierPath bezierPath];
		[color set];
		[s setLineWidth: 1.5];
		[s setLineCapStyle: NSRoundLineCapStyle];
		[s moveToPoint: NSMakePoint(NSMinX(r) + 2, NSMinY(r) + 1)];
		[s lineToPoint: NSMakePoint(NSMaxX(r) - 2, NSMaxY(r) - 1)];
		[s stroke];
	}
}

static void
drawLock(NSPoint at, NSColor *color)
{
	NSBezierPath *shackle = [NSBezierPath bezierPath];
	[color set];
	NSRectFill(NSMakeRect(at.x, at.y, 8, 6));
	[shackle setLineWidth: 1.3];
	[shackle appendBezierPathWithArcWithCenter: NSMakePoint(at.x + 4, at.y + 6) radius: 2.6 startAngle: 0 endAngle: 180];
	[shackle stroke];
}

/* ---- the panel ---- */

enum { PanelW = 272, PanelRadius = 6, HeaderH = 40, LabelH = 22, RowH = 28, InfoH = 26, BottomPad = 8,
       SwitchW = 36, SwitchH = 20, MaxListed = 12 };

@interface NaplesWifiWindow : NSWindow
@end
@implementation NaplesWifiWindow
- (BOOL) canBecomeKeyWindow { return NO; }
- (BOOL) canBecomeMainWindow { return NO; }
@end

@interface NaplesWifiView : NSView {
	NaplesWifi *wifi;
	NSImage *backdrop;
	NSTrackingRectTag trackTag;
	BOOL tracking, inside;
	NSInteger hover;	/* index into -rows of the network row under the pointer, -1 none */
}
- (id) initWithWifi: (NaplesWifi *)w;
- (void) setBackdrop: (NSImage *)img;
- (NSArray *) rows;
- (CGFloat) heightForRows: (NSArray *)rows;
@end

@implementation NaplesWifiView

- (id) initWithWifi: (NaplesWifi *)w
{
	if ((self = [super initWithFrame: NSMakeRect(0, 0, PanelW, 100)])) { wifi = w; hover = -1; }
	return self;
}

- (void) dealloc { [backdrop release]; [super dealloc]; }
- (BOOL) isFlipped { return NO; }
- (BOOL) isOpaque { return NO; }
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }
- (void) setBackdrop: (NSImage *)img { if (img != backdrop) { [backdrop release]; backdrop = [img retain]; } [self setNeedsDisplay: YES]; }

static NSDictionary *
row(NSString *kind, CGFloat h, id obj)
{
	return [NSDictionary dictionaryWithObjectsAndKeys: kind, @"kind", [NSNumber numberWithDouble: h], @"h", obj, @"obj", nil];
}

/* the panel's contents, top to bottom: {kind, h, obj} */
- (NSArray *) rows
{
	NSMutableArray *r = [NSMutableArray array];
	NSArray *nets = [wifi networks];
	NSUInteger i;
	[r addObject: row(@"header", HeaderH, nil)];
	if (![wifi enabled]) {
		[r addObject: row(@"info", InfoH, [wifi message] ? [wifi message] : @"Wi-Fi is off.")];
		return r;
	}
	if ([wifi associated] && [wifi ssid]) {
		[r addObject: row(@"label", LabelH, @"Connected")];
		[r addObject: row(@"current", RowH, nil)];
		if ([wifi showsDetails]) {
			NSEnumerator *e = [[wifi details] objectEnumerator];
			NSArray *pair;
			while ((pair = [e nextObject])) [r addObject: row(@"detail", 17, pair)];
			if ([wifi remembersCurrent]) [r addObject: row(@"forget", 22, nil)];
			[r addObject: row(@"gap", 6, nil)];
		}
	}
	[r addObject: row(@"label", LabelH, [wifi associated] ? @"Other Networks" : @"Networks")];
	for (i = 0; i < [nets count] && i < MaxListed; i++) [r addObject: row(@"net", RowH, [nets objectAtIndex: i])];
	if ([wifi message]) [r addObject: row(@"info", InfoH, [wifi message])];
	else if (![nets count]) [r addObject: row(@"info", InfoH, [wifi scanning] ? @"Searching…" : @"No networks found.")];
	return r;
}

- (CGFloat) heightForRows: (NSArray *)rows
{
	CGFloat h = BottomPad;
	NSEnumerator *e = [rows objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject])) h += [[d objectForKey: @"h"] doubleValue];
	return h;
}

- (NSRect) switchRect { return NSMakeRect(PanelW - 14 - SwitchW, [self bounds].size.height - HeaderH / 2.0 - SwitchH / 2.0, SwitchW, SwitchH); }

/* the rect of row i, from the rows' heights (the view is not flipped: y counts up from the bottom) */
- (NSRect) rectOfRow: (NSUInteger)i in: (NSArray *)rows
{
	CGFloat top = [self bounds].size.height;
	NSUInteger k;
	for (k = 0; k < i; k++) top -= [[[rows objectAtIndex: k] objectForKey: @"h"] doubleValue];
	return NSMakeRect(0, top - [[[rows objectAtIndex: i] objectForKey: @"h"] doubleValue], PanelW,
	                  [[[rows objectAtIndex: i] objectForKey: @"h"] doubleValue]);
}

- (void) drawNetwork: (NSString *)name rssi: (int)rssi secure: (BOOL)secure connected: (BOOL)connected
                  in: (NSRect)r hover: (BOOL)hl
{
	NSRect circle = NSMakeRect(14, NSMidY(r) - 11, 22, 22);
	NSDictionary *ta = NaplesMenuTextAttrs(NaplesPanelLight, YES, NO, connected);
	NSColor *ink = [NSColor colorWithCalibratedWhite: 0.08 alpha: 1];
	NSString *right = [[wifi joining] isEqual: name] ? @"Connecting…" : nil;
	if (hl) {
		[[NSColor colorWithCalibratedWhite: 0 alpha: 0.08] set];
		[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(r, 6, 1) xRadius: 5 yRadius: 5] fill];
	}
	/* the signal in a circle, blue for the network in use, as macOS draws it */
	[(connected ? [NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1]
	            : [NSColor colorWithCalibratedWhite: 0 alpha: 0.1]) set];
	[[NSBezierPath bezierPathWithOvalInRect: circle] fill];
	NaplesDrawWifi(NSMakeRect(NSMidX(circle) - 7, NSMinY(circle) + 5, 14, 12), NaplesWifiBars(rssi), NO,
	               connected ? [NSColor whiteColor] : ink);
	[name drawAtPoint: NSMakePoint(44, NSMidY(r) - 8) withAttributes: ta];
	if (right) {
		NSDictionary *ga = NaplesMenuTextAttrs(NaplesPanelLight, NO, NO, NO);
		NSSize sz = [right sizeWithAttributes: ga];
		[right drawAtPoint: NSMakePoint(PanelW - 16 - sz.width, NSMidY(r) - 8) withAttributes: ga];
	} else if (secure) {
		drawLock(NSMakePoint(PanelW - 24, NSMidY(r) - 4), [NSColor colorWithCalibratedWhite: 0 alpha: 0.5]);
	}
}

- (void) drawRect: (NSRect)dirty
{
	NSRect b = [self bounds];
	NSArray *rows = [self rows];
	NSUInteger i;
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
		if ([kind isEqual: @"header"]) {
			NSRect s = [self switchRect], knob;
			BOOL on = [wifi enabled];
			[@"Wi-Fi" drawAtPoint: NSMakePoint(14, NSMidY(r) - 8) withAttributes: NaplesMenuTextAttrs(NaplesPanelLight, YES, NO, YES)];
			[(on ? [NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1] : [NSColor colorWithCalibratedWhite: 0 alpha: 0.18]) set];
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
		} else if ([kind isEqual: @"current"]) {
			[self drawNetwork: [wifi ssid] rssi: [wifi rssi] secure: [wifi securedNow] connected: YES in: r hover: NO];
		} else if ([kind isEqual: @"net"]) {
			NSDictionary *n = [d objectForKey: @"obj"];
			[self drawNetwork: [n objectForKey: @"ssid"] rssi: [[n objectForKey: @"rssi"] intValue]
			           secure: [[n objectForKey: @"secure"] boolValue] connected: NO in: r hover: (NSInteger)i == hover];
		} else if ([kind isEqual: @"forget"]) {
			NSDictionary *fa = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
			                    [NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1], NSForegroundColorAttributeName, nil];
			if ((NSInteger)i == hover) {
				[[NSColor colorWithCalibratedWhite: 0 alpha: 0.08] set];
				[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(r, 6, 1) xRadius: 5 yRadius: 5] fill];
			}
			[@"Forget This Network…" drawAtPoint: NSMakePoint(44, NSMinY(r) + 4) withAttributes: fa];
		} else if ([kind isEqual: @"detail"]) {
			NSArray *pair = [d objectForKey: @"obj"];
			NSDictionary *la = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
			                    [NSColor colorWithCalibratedWhite: 0 alpha: 0.5], NSForegroundColorAttributeName, nil];
			NSDictionary *va = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
			                    [NSColor colorWithCalibratedWhite: 0.08 alpha: 1], NSForegroundColorAttributeName, nil];
			NSString *label = [[pair objectAtIndex: 0] stringByAppendingString: @":"];
			[label drawAtPoint: NSMakePoint(44, NSMinY(r) + 2) withAttributes: la];
			[[pair objectAtIndex: 1] drawAtPoint: NSMakePoint(44 + [label sizeWithAttributes: la].width + 5, NSMinY(r) + 2)
			                      withAttributes: va];
		} else if ([kind isEqual: @"info"]) {
			[[d objectForKey: @"obj"] drawAtPoint: NSMakePoint(14, NSMidY(r) - 8) withAttributes: NaplesMenuTextAttrs(NaplesPanelLight, NO, NO, NO)];
		}
	}
}

- (NSInteger) rowAt: (NSPoint)p kind: (NSString **)kind
{
	NSArray *rows = [self rows];
	NSUInteger i;
	for (i = 0; i < [rows count]; i++) {
		if (NSPointInRect(p, [self rectOfRow: i in: rows])) {
			if (kind) *kind = [[rows objectAtIndex: i] objectForKey: @"kind"];
			return i;
		}
	}
	return -1;
}

- (void) mouseDown: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	NSString *kind = nil;
	NSInteger i;
	if (NSPointInRect(p, NSInsetRect([self switchRect], -6, -6))) {
		[wifi setEnabled: ![wifi enabled]];
		return;
	}
	i = [self rowAt: p kind: &kind];
	if (i >= 0 && [kind isEqual: @"forget"] && ![wifi joining]) {
		[wifi forgetCurrent];
		return;
	}
	if (i >= 0 && [kind isEqual: @"net"] && ![wifi joining])
		[wifi joinNetwork: [[[self rows] objectAtIndex: i] objectForKey: @"obj"]];
}

- (void) mouseMoved: (NSEvent *)e
{
	NSString *kind = nil;
	NSInteger i = [self rowAt: [self convertPoint: [e locationInWindow] fromView: nil] kind: &kind];
	if (![kind isEqual: @"net"] && ![kind isEqual: @"forget"]) i = -1;
	if (i != hover) { hover = i; [self setNeedsDisplay: YES]; }
}

/* like the menus and the Sound panel: leaving the panel closes it after a moment, coming back cancels that */
- (void) mouseEntered: (NSEvent *)e
{
	inside = YES;
	[NSObject cancelPreviousPerformRequestsWithTarget: wifi selector: @selector(hidePanel) object: nil];
}

- (void) mouseExited: (NSEvent *)e
{
	inside = NO;
	if (hover != -1) { hover = -1; [self setNeedsDisplay: YES]; }
	[wifi performSelector: @selector(hidePanel) withObject: nil afterDelay: 1.2];
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

@interface NaplesWifi (Private)
- (void) poll;
- (void) scan;
- (void) layoutPanel;
- (void) join: (NSString *)name password: (NSString *)psk secure: (BOOL)secure prompt: (BOOL)prompt;
- (void) autoJoinFrom: (NSDictionary *)found;
- (void) askPasswordFor: (NSString *)name error: (NSString *)err;
- (NSArray *) detailsFrom: (const wifi_status *)st;
@end

@implementation NaplesWifi

- (id) initWithChangeHandler: (void (^)(void))handler
{
	if (!loadIOKit()) { [self release]; return nil; }
	if ((self = [super init])) {
		changed = Block_copy(handler);
		queue = dispatch_queue_create("naples.wifi", NULL);
		/* a global-queue timer handing over to the main thread: the GNUstep run loop does not drain the main
		 * dispatch queue (NaplesRunOnMain is performSelectorOnMainThread, as the clock's timer uses) */
		pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
		dispatch_source_set_timer(pollTimer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, NSEC_PER_SEC);
		dispatch_source_set_event_handler(pollTimer, ^{ NaplesRunOnMain(^{ [self poll]; }); });
		dispatch_resume(pollTimer);
	}
	return self;
}

- (BOOL) known { return known; }
/* while an on/off call is in flight the switch shows where it is going (firmware may still be loading) */
- (BOOL) enabled { return powerPending ? !radioOff : firmwareUp && !radioOff; }
- (BOOL) associated { return associated; }
- (NSString *) ssid { return ssid; }
- (int) rssi { return rssi; }
- (NSArray *) networks { return networks; }
- (BOOL) scanning { return scanning; }
- (NSString *) joining { return joining; }
- (NSString *) message { return message; }
- (BOOL) showsDetails { return showDetails; }
- (BOOL) securedNow { return securedNow; }
- (NSArray *) details { return details; }

- (void) setMessage: (NSString *)m { if (m != message) { [message release]; message = [m copy]; } }

- (void) notify
{
	if (showing) [self layoutPanel];
	[panelView setNeedsDisplay: YES];
	if (changed) changed();
}

/* on the queue: the connection to the driver, opened on first use; NO if there is no BCM43430Wifi (no wifi=1) */
- (BOOL) connected
{
	NaplesIOObject svc;
	if (conn) return YES;
	svc = ioGetMatchingService(MACH_PORT_NULL, (CFDictionaryRef)ioServiceMatching(kBCM43430WifiClass));
	if (!svc) return NO;
	if (ioServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) conn = 0;
	ioObjectRelease(svc);
	return conn != 0;
}

- (kern_return_t) call: (uint32_t)sel scalar: (const uint64_t *)in count: (uint32_t)n
                 input: (const void *)is size: (size_t)isz output: (void *)os size: (size_t)osz
{
	size_t outSize = osz;
	kern_return_t kr = ioCallMethod(conn, sel, in, n, is, isz, NULL, NULL, os, os ? &outSize : NULL);
	if (kr == MACH_SEND_INVALID_DEST || kr == kIOReturnNotAttached) {	/* the user client is gone: open a new one next time */
		ioServiceClose(conn);
		conn = 0;
	}
	return kr;
}

- (void) poll
{
	BOOL wantAddresses = showing && showDetails;
	dispatch_async(queue, ^{
		/* the queue has no autorelease pool, and gnustep-base drops objects autoreleased without one
		 * (Source/NSAutoreleasePool.m:404-428); the blocks handed to the main thread retain what they use */
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		wifi_status st;
		BOOL ok;
		NSString *ip = nil, *gw = nil, *mem = [savedNetwork() objectForKey: @"ssid"];
		memset(&st, 0, sizeof st);
		ok = [self connected] && [self call: kWifiMethodStatus scalar: NULL count: 0 input: NULL size: 0
		                                    output: &st size: sizeof st] == KERN_SUCCESS;
		if (ok && st.associated && wantAddresses) {
			ip = interfaceAddress("en1");
			gw = toolOutput("/usr/sbin/ipconfig", "getoption", "en1", "router");
		}
		NaplesRunOnMain(^{
			BOOL wasAssociated = associated;
			if (!ok) return;	/* no driver: no icon; it does not appear later (wifi=1 is a boot-arg) */
			known = YES;
			fwState = st.state;
			[remembered release];
			remembered = [mem copy];
			firmwareUp = st.state == kWifiStateUp;
			securedNow = (st.security & kWifiSecWPA2) != 0;
			/* a status read before a pending on/off would move the switch back */
			if (!powerPending) radioOff = firmwareUp ? st.radio_off != 0 : YES;
			associated = st.associated != 0;
			[ssid release];
			ssid = associated ? [[NSString alloc] initWithUTF8String: st.ssid] : nil;
			rssi = st.rssi;
			if (wantAddresses) {
				[ipAddress release]; ipAddress = [ip retain];
				[router release]; router = [gw retain];
			}
			[details release];
			details = associated ? [[self detailsFrom: &st] retain] : nil;
			if (associated != wasAssociated && showing) [self scan];	/* the lists swap the network over */
			if (showing && [self enabled] && [NSDate timeIntervalSinceReferenceDate] - lastScan > 15) [self scan];
			[self notify];
		});
		[pool release];
	});
}

/* the Option-click list, macOS's order and wording */
- (NSArray *) detailsFrom: (const wifi_status *)st
{
	NSMutableArray *d = [NSMutableArray array];
#define PAIR(l, v) [d addObject: [NSArray arrayWithObjects: (l), (v), nil]]
	PAIR(@"IP Address", ipAddress ? ipAddress : @"–");
	PAIR(@"Router", router ? router : @"–");
	PAIR(@"BSSID", ([NSString stringWithFormat: @"%02x:%02x:%02x:%02x:%02x:%02x", st->bssid[0], st->bssid[1], st->bssid[2],
	                 st->bssid[3], st->bssid[4], st->bssid[5]]));
	if (st->channel)	/* the 43430 is a 2.4 GHz-only radio; channels above 14 are 5 GHz */
		PAIR(@"Channel", ([NSString stringWithFormat: @"%u (%@)", st->channel, st->channel <= 14 ? @"2.4 GHz" : @"5 GHz"]));
	PAIR(@"Security", (st->security & kWifiSecWPA2) ? @"WPA2 Personal" : @"None");
	PAIR(@"802.11 Protocol", st->ht ? @"Wi-Fi 4 (802.11n)" : @"802.11g");
	PAIR(@"RSSI", ([NSString stringWithFormat: @"%d dBm", st->rssi]));
	if (st->noise) PAIR(@"Noise", ([NSString stringWithFormat: @"%d dBm", st->noise]));
	if (st->rate_kbps) PAIR(@"Tx Rate", ([NSString stringWithFormat: @"%u Mbps", st->rate_kbps / 1000]));
#undef PAIR
	return d;
}

- (void) scan
{
	if (scanning || ![self enabled]) return;
	scanning = YES;
	lastScan = [NSDate timeIntervalSinceReferenceDate];
	dispatch_async(queue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		wifi_scan_results *res = calloc(1, sizeof *res);
		BOOL ok = res && [self connected] && [self call: kWifiMethodScan scalar: NULL count: 0 input: NULL size: 0
		                                          output: res size: sizeof *res] == KERN_SUCCESS;
		NSMutableDictionary *best = [NSMutableDictionary dictionary];
		uint32_t i;
		for (i = 0; ok && i < res->count && i < kWifiMaxScan; i++) {
			wifi_scan_entry *e = &res->entries[i];
			NSString *name;
			NSDictionary *have;
			if (!e->ssid[0]) continue;	/* hidden networks are not listed */
			name = [NSString stringWithUTF8String: e->ssid];
			if (!name) continue;
			have = [best objectForKey: name];
			if (have && [[have objectForKey: @"rssi"] intValue] >= e->rssi) continue;
			[best setObject: [NSDictionary dictionaryWithObjectsAndKeys: name, @"ssid",
			                  [NSNumber numberWithInt: e->rssi], @"rssi",
			                  [NSNumber numberWithBool: e->security != 0], @"secure", nil] forKey: name];
		}
		free(res);
		NaplesRunOnMain(^{
			NSMutableArray *list = [NSMutableArray arrayWithArray: [best allValues]];
			scanning = NO;
			if (ok && [self enabled]) {	/* a scan that finishes after Wi-Fi was turned off is dropped */
				if (ssid) {
					NSUInteger k;
					for (k = 0; k < [list count]; k++)
						if ([[[list objectAtIndex: k] objectForKey: @"ssid"] isEqual: ssid]) { [list removeObjectAtIndex: k]; break; }
				}
				[list sortUsingComparator: ^NSComparisonResult(id a, id b) {
					return [[b objectForKey: @"rssi"] compare: [a objectForKey: @"rssi"]];
				}];
				[networks release];
				networks = [list copy];
				[self autoJoinFrom: best];
			}
			[self notify];
		});
		[pool release];
	});
}

/* after turning on: join the remembered network, but only once a scan has seen it, so being away from it is quiet */
- (void) autoJoinFrom: (NSDictionary *)found
{
	NSDictionary *a = [autoJoin autorelease];
	autoJoin = nil;
	if (!a || associated || joining || ![self enabled] || ![found objectForKey: [a objectForKey: @"ssid"]]) return;
	[self join: [a objectForKey: @"ssid"] password: [a objectForKey: @"psk"]
	    secure: [[a objectForKey: @"psk"] length] > 0 prompt: NO];
}

- (void) setEnabled: (BOOL)on
{
	/* only the chip waiting for firmware needs `wifi up`; while the boot job is loading it, leave it alone */
	BOOL needFirmware = fwState == kWifiStateProbed;
	if (powerPending) return;	/* one on/off at a time; the switch already shows where it is going */
	radioOff = !on;	/* the switch moves at once; the poll after the call reports what the driver did */
	powerPending++;
	[self setMessage: nil];
	[autoJoin release];
	autoJoin = nil;
	if (!on) { [networks release]; networks = nil; }
	[self notify];
	dispatch_async(queue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		uint64_t arg = on;
		NSDictionary *saved;
		kern_return_t kr;
		int fd;
		if (![self connected]) { NaplesRunOnMain(^{ powerPending--; [self poll]; }); [pool release]; return; }
		if (on && needFirmware) runTool("/usr/sbin/wifi", "up", NULL, NULL);	/* reads the firmware from /usr/share/firmware/wifi */
		kr = [self call: kWifiMethodPower scalar: &arg count: 1 input: NULL size: 0 output: NULL size: 0];
		if (kr == KERN_SUCCESS) {
			if (on) unlink(WifiOff);
			else if ((fd = open(WifiOff, O_WRONLY | O_CREAT, 0644)) >= 0) close(fd);	/* the boot job keeps the radio off */
		}
		saved = on && kr == KERN_SUCCESS ? savedNetwork() : nil;
		NaplesRunOnMain(^{
			powerPending--;
			if (kr == kIOReturnNotReady) [self setMessage: @"Wi-Fi is still starting. Try again in a moment."];
			else if (kr != KERN_SUCCESS) [self setMessage: on ? @"Wi-Fi could not be turned on." : @"Wi-Fi could not be turned off."];
			if (saved && !radioOff) { [autoJoin release]; autoJoin = [saved retain]; }
			[self notify];
			[self poll];
			if (on && kr == KERN_SUCCESS) [self performSelector: @selector(scan) withObject: nil afterDelay: 0.5];
		});
		[pool release];
	});
}

- (void) joinNetwork: (NSDictionary *)net
{
	NSString *name = [net objectForKey: @"ssid"];
	BOOL secure = [[net objectForKey: @"secure"] boolValue];
	if (secure) {
		NSDictionary *saved = savedNetwork();
		if ([[saved objectForKey: @"ssid"] isEqual: name] && [[saved objectForKey: @"psk"] length])
			[self join: name password: [saved objectForKey: @"psk"] secure: YES prompt: YES];
		else
			[self askPasswordFor: name error: nil];
		return;
	}
	[self join: name password: @"" secure: NO prompt: NO];
}

- (BOOL) remembersCurrent
{
	return associated && ssid && [remembered isEqual: ssid];
}

/* macOS's "Forget This Network": confirm, then leave it, drop it from /etc/wifi.conf (so neither the boot job nor
 * turning Wi-Fi on joins it again) and give en1's address back */
- (void) forgetCurrent
{
	NSString *name = [[ssid copy] autorelease];
	if (!name) return;
	[self hidePanel];
	[NaplesConfirm askTitle: [NSString stringWithFormat: @"Forget “%@”?", name]
	                message: @"The Pi will leave this network and no longer join it automatically. You will need its password to join it again."
	                confirm: @"Forget"
	                   then: ^{
		[autoJoin release];
		autoJoin = nil;
		dispatch_async(queue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSDictionary *saved = savedNetwork();
			if ([self connected]) [self call: kWifiMethodLeave scalar: NULL count: 0 input: NULL size: 0 output: NULL size: 0];
			if ([[saved objectForKey: @"ssid"] isEqual: name]) unlink(WifiConf);	/* only if it is still that one */
			runTool("/usr/sbin/ipconfig", "set", "en1", "NONE");
			NaplesRunOnMain(^{ [self poll]; });
			[pool release];
		});
	}];
}

/* join on the queue; remember the network and start DHCP when it works. `prompt`: ask for the password again when the
 * driver reports a failed WPA2 handshake (kIOReturnNotPermitted); other failures only leave a message. */
- (void) join: (NSString *)name password: (NSString *)psk secure: (BOOL)secure prompt: (BOOL)prompt
{
	NSString *n = [[name copy] autorelease], *p = [[psk copy] autorelease];
	[joining release];
	joining = [n copy];
	[self setMessage: nil];
	[self notify];
	dispatch_async(queue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		wifi_join j;
		kern_return_t kr;
		memset(&j, 0, sizeof j);
		strlcpy(j.ssid, [n UTF8String], sizeof j.ssid);
		strlcpy(j.passphrase, [p UTF8String], sizeof j.passphrase);
		kr = [self connected] ? [self call: kWifiMethodJoin scalar: NULL count: 0 input: &j size: sizeof j output: NULL size: 0]
		                      : KERN_FAILURE;
		if (kr == KERN_SUCCESS) {
			saveNetwork(j.ssid, j.passphrase);
			runTool("/sbin/ifconfig", "en1", "up", NULL);
			runTool("/usr/sbin/ipconfig", "set", "en1", "DHCP");
		}
		memset(&j, 0, sizeof j);
		NaplesRunOnMain(^{
			[joining release];
			joining = nil;
			if (kr == kIOReturnNotPermitted && secure && prompt)
				[self askPasswordFor: n error: @"The password was not accepted."];
			else if (kr == kIOReturnNotPermitted)
				[self setMessage: [NSString stringWithFormat: @"The password for “%@” was not accepted.", n]];
			else if (kr != KERN_SUCCESS)
				[self setMessage: [NSString stringWithFormat: @"Could not join “%@”.", n]];
			[self notify];
			[self poll];
		});
		[pool release];
	});
}

/* ---- the password dialog ---- */

- (void) askPasswordFor: (NSString *)name error: (NSString *)err
{
	NSRect scr = [[NSScreen mainScreen] frame];
	NSView *cv;
	NSButton *ok, *cancel;
	if (!passwordPanel) {
		passwordPanel = [[NSPanel alloc] initWithContentRect: NSMakeRect(NSMidX(scr) - 190, NSMidY(scr) - 70, 380, 140)
		                                           styleMask: NSTitledWindowMask | NSClosableWindowMask
		                                             backing: NSBackingStoreBuffered defer: NO];
		[passwordPanel setTitle: @"Wi-Fi"];
		[passwordPanel setReleasedWhenClosed: NO];
		[passwordPanel setHidesOnDeactivate: NO];
		/* one of Naples' own windows: not listed in the dock */
		[[NaplesX shared] registerOwnWindow: (unsigned long)[GSCurrentServer() windowDevice: [passwordPanel windowNumber]]];
		cv = [passwordPanel contentView];
		passwordLabel = [[NSTextField alloc] initWithFrame: NSMakeRect(20, 76, 340, 44)];
		[passwordLabel setEditable: NO];
		[passwordLabel setSelectable: NO];
		[passwordLabel setBezeled: NO];
		[passwordLabel setDrawsBackground: NO];
		[cv addSubview: passwordLabel];
		passwordField = [[NSSecureTextField alloc] initWithFrame: NSMakeRect(20, 50, 340, 22)];
		[passwordField setTarget: self];
		[passwordField setAction: @selector(passwordJoin:)];
		[cv addSubview: passwordField];
		ok = [[[NSButton alloc] initWithFrame: NSMakeRect(270, 12, 90, 26)] autorelease];
		[ok setTitle: @"Join"];
		[ok setKeyEquivalent: @"\r"];
		[ok setTarget: self];
		[ok setAction: @selector(passwordJoin:)];
		[cv addSubview: ok];
		cancel = [[[NSButton alloc] initWithFrame: NSMakeRect(170, 12, 90, 26)] autorelease];
		[cancel setTitle: @"Cancel"];
		[cancel setKeyEquivalent: @"\e"];
		[cancel setTarget: self];
		[cancel setAction: @selector(passwordCancel:)];
		[cv addSubview: cancel];
	}
	[passwordFor release];
	passwordFor = [name copy];
	[passwordLabel setStringValue: err ? [NSString stringWithFormat: @"%@ Enter the password for “%@”.", err, name]
	                                   : [NSString stringWithFormat: @"The Wi-Fi network “%@” needs a password.", name]];
	[passwordField setStringValue: @""];
	[self hidePanel];
	[NSApp activateIgnoringOtherApps: YES];
	[passwordPanel makeKeyAndOrderFront: nil];
	[passwordPanel makeFirstResponder: passwordField];
}

- (void) passwordJoin: (id)sender
{
	NSString *psk = [passwordField stringValue];
	NSUInteger len = [psk lengthOfBytesUsingEncoding: NSUTF8StringEncoding];
	BOOL hex = len == 64;
	NSUInteger i;
	for (i = 0; hex && i < len; i++) hex = isxdigit([psk characterAtIndex: i]) != 0;
	if (len < 8 || len > 64 || (len == 64 && !hex)) {
		[passwordLabel setStringValue: [NSString stringWithFormat: @"A Wi-Fi password has 8 to 63 characters, or 64 hex digits. Enter the password for “%@”.", passwordFor]];
		return;
	}
	[passwordPanel orderOut: nil];
	[self join: passwordFor password: psk secure: YES prompt: YES];
	[passwordField setStringValue: @""];
}

- (void) passwordCancel: (id)sender
{
	[passwordField setStringValue: @""];
	[passwordPanel orderOut: nil];
}

/* ---- the panel ---- */

- (BOOL) panelShowing { return showing; }

/* size the panel to its rows, keeping its top where it is */
- (void) layoutPanel
{
	NaplesWifiView *v = (NaplesWifiView *)panelView;
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

- (void) togglePanelUnder: (NSRect)icon { [self togglePanelUnder: icon details: NO]; }

- (void) togglePanelUnder: (NSRect)icon details: (BOOL)withDetails
{
	NSRect scr = [[NSScreen mainScreen] frame];
	CGFloat x = NSMidX(icon) - PanelW / 2.0, top = NSMaxY(icon), h;
	NSRect frame;
	if (showing) { [self hidePanel]; return; }
	showDetails = withDetails;
	if (x + PanelW > scr.size.width - 4) x = scr.size.width - 4 - PanelW;
	if (x < 4) x = 4;
	if (!panelWindow) {
		panelWindow = [[NaplesWifiWindow alloc] initWithContentRect: NSMakeRect(0, 0, PanelW, 100) styleMask: NSBorderlessWindowMask
		                                                    backing: NSBackingStoreBuffered defer: NO];
		/* a dock-type window like the menus' panels, so the window manager neither focuses nor lists it */
		[panelWindow setLevel: NSStatusWindowLevel];
		[panelWindow setOpaque: NO];
		[panelWindow setBackgroundColor: [NSColor clearColor]];
		[panelWindow setHasShadow: NO];
		[panelWindow setReleasedWhenClosed: NO];
		[panelWindow setCanHide: NO];
		[panelWindow setAcceptsMouseMovedEvents: YES];
		panelView = [[NaplesWifiView alloc] initWithWifi: self];
		[panelWindow setContentView: panelView];
		[[NaplesX shared] registerOwnWindow: (unsigned long)[GSCurrentServer() windowDevice: [panelWindow windowNumber]]];
	}
	h = [(NaplesWifiView *)panelView heightForRows: [(NaplesWifiView *)panelView rows]];
	frame = NSMakeRect(NSMinX(scr) + x, NSMaxY(scr) - top - h, PanelW, h);
	[panelWindow setFrame: frame display: NO];
	[panelView setFrame: NSMakeRect(0, 0, PanelW, h)];
	[(NaplesWifiView *)panelView setBackdrop: [[NaplesX shared] backgroundForRect: NSMakeRect(x, top, PanelW, h)]];
	[panelWindow orderFrontRegardless];
	[panelWindow display];
	showing = YES;
	dispatch_source_set_timer(pollTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC);	/* quicker while it shows */
	[self poll];	/* the details (address, router) are read only while they show */
	[self scan];
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
