#import <AppKit/AppKit.h>
#import "NaplesX.h"
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <math.h>

@interface NaplesBlockBox : NSObject { void (^block)(void); }
- (id) initWithBlock: (void (^)(void))b;
- (void) fire;
@end

@implementation NaplesBlockBox
- (id) initWithBlock: (void (^)(void))b { if ((self = [super init])) block = Block_copy(b); return self; }
- (void) fire { block(); }
- (void) dealloc { Block_release(block); [super dealloc]; }
@end

void
NaplesRunOnMain(void (^block)(void))
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NaplesBlockBox *b = [[NaplesBlockBox alloc] initWithBlock: block];
	[b performSelectorOnMainThread: @selector(fire) withObject: nil waitUntilDone: NO];
	[b release];
	[pool release];
}

@implementation NaplesWindowInfo
- (void) dealloc { [title release]; [wmClass release]; [super dealloc]; }
@end

/* windows vanish between a request and its reply; that is not an error for a dock */
static int
ignoreXError(Display *d, XErrorEvent *e)
{
	return 0;
}

@implementation NaplesX {
	Display *dpy;
	Window root;
	dispatch_source_t readSource;
	void (^changeHandler)(void);
	void (^activeHandler)(void);
	int (^pidResolver)(unsigned long);
	NSMutableArray *backgroundHandlers;
	NSMutableSet *selected;	/* windows we already listen to */
	NSMutableSet *own;	/* Naples' own windows */
	NSMutableDictionary *hinted;	/* own window -> the strut last written */
	struct {
		Atom clientList, wmState, netWmState, name, netName, utf8, pid, windowType, typeNormal, typeDialog,
		     activeWindow, rootPmap, closeWindow, strutPartial, strut, opacity, skipTaskbar, sticky, above, desktop, cm;
	} a;
}

+ (NaplesX *) shared
{
	static NaplesX *x;
	if (!x) x = [[NaplesX alloc] init];
	return x;
}

- (BOOL) connect
{
	if (dpy) return YES;
	XSetErrorHandler(ignoreXError);
	if (!(dpy = XOpenDisplay(NULL))) return NO;
	root = DefaultRootWindow(dpy);
	selected = [[NSMutableSet alloc] init];
	own = [[NSMutableSet alloc] init];
	hinted = [[NSMutableDictionary alloc] init];
#define ATOM(f, n) a.f = XInternAtom(dpy, n, False)
	ATOM(clientList, "_NET_CLIENT_LIST"); ATOM(wmState, "WM_STATE"); ATOM(netWmState, "_NET_WM_STATE");
	ATOM(name, "WM_NAME"); ATOM(netName, "_NET_WM_NAME"); ATOM(utf8, "UTF8_STRING"); ATOM(pid, "_NET_WM_PID");
	ATOM(windowType, "_NET_WM_WINDOW_TYPE"); ATOM(typeNormal, "_NET_WM_WINDOW_TYPE_NORMAL");
	ATOM(typeDialog, "_NET_WM_WINDOW_TYPE_DIALOG"); ATOM(activeWindow, "_NET_ACTIVE_WINDOW");
	ATOM(closeWindow, "_NET_CLOSE_WINDOW"); ATOM(strutPartial, "_NET_WM_STRUT_PARTIAL"); ATOM(strut, "_NET_WM_STRUT");
	ATOM(opacity, "_NET_WM_WINDOW_OPACITY"); ATOM(skipTaskbar, "_NET_WM_STATE_SKIP_TASKBAR");
	ATOM(sticky, "_NET_WM_STATE_STICKY"); ATOM(above, "_NET_WM_STATE_ABOVE"); ATOM(desktop, "_NET_WM_DESKTOP");
	ATOM(cm, "_NET_WM_CM_S0"); ATOM(rootPmap, "_XROOTPMAP_ID");
#undef ATOM
	XSelectInput(dpy, root, PropertyChangeMask);

	/* X events arrive on the connection's fd: a GCD read source wakes the main thread, which drains them (Xlib
	 * is only ever touched from the main thread). The source is suspended until the drain has run. */
	readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, ConnectionNumber(dpy), 0,
	                                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
	dispatch_source_set_event_handler(readSource, ^{
		dispatch_suspend(readSource);
		NaplesRunOnMain(^{
			[self drain];
			dispatch_resume(readSource);
		});
	});
	dispatch_resume(readSource);
	return YES;
}

- (void) setChangeHandler: (void (^)(void))h
{
	Block_release(changeHandler);
	changeHandler = h ? Block_copy(h) : nil;
}

- (void) addBackgroundHandler: (void (^)(void))h
{
	if (!backgroundHandlers) backgroundHandlers = [[NSMutableArray alloc] init];
	[backgroundHandlers addObject: [[h copy] autorelease]];
}

- (NSImage *) backgroundForRect: (NSRect)r
{
	unsigned long n, *v;
	Pixmap pix;
	XImage *xi;
	NSBitmapImageRep *rep;
	NSImage *img;
	int x = (int)r.origin.x, y = (int)r.origin.y, w = (int)r.size.width, h = (int)r.size.height, row, col;
	if (!dpy || w <= 0 || h <= 0 || !(v = [self longs: a.rootPmap of: root type: XA_PIXMAP count: &n])) return nil;
	pix = v[0];
	XFree(v);
	if (!pix || !(xi = XGetImage(dpy, pix, x, y, w, h, AllPlanes, ZPixmap))) return nil;
	/* a Pixmap's XImage has no colour masks (they are zero); Milan stores 0x00RRGGBB, little-endian, 24 or 32 bits */
	if ((xi->bits_per_pixel != 32 && xi->bits_per_pixel != 24) || xi->byte_order != LSBFirst ||
	    (xi->red_mask && (xi->red_mask != 0xff0000 || xi->green_mask != 0xff00 || xi->blue_mask != 0xff))) {
		XDestroyImage(xi);
		return nil;
	}
	rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: w pixelsHigh: h bitsPerSample: 8 samplesPerPixel: 3
	                                                 hasAlpha: NO isPlanar: NO colorSpaceName: NSCalibratedRGBColorSpace
	                                              bytesPerRow: 0 bitsPerPixel: 24] autorelease];
	int bytes = xi->bits_per_pixel / 8;
	for (row = 0; row < h; row++) {
		const unsigned char *s = (const unsigned char *)xi->data + (size_t)row * xi->bytes_per_line;
		unsigned char *d = [rep bitmapData] + (size_t)row * [rep bytesPerRow];
		for (col = 0; col < w; col++, s += bytes, d += 3) { d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; }
	}
	XDestroyImage(xi);
	img = [[[NSImage alloc] initWithSize: NSMakeSize(w, h)] autorelease];
	[img addRepresentation: rep];
	return img;
}

- (void) setPidResolver: (int (^)(unsigned long))r
{
	Block_release(pidResolver);
	pidResolver = r ? Block_copy(r) : nil;
}

- (void) noteWindowsChanged { if (changeHandler) changeHandler(); }

- (void) setActiveHandler: (void (^)(void))h
{
	Block_release(activeHandler);
	activeHandler = h ? Block_copy(h) : nil;
}

- (void) drain
{
	BOOL changed = NO, activeChanged = NO, bgChanged = NO;
	XEvent ev;
	while (XPending(dpy)) {
		XNextEvent(dpy, &ev);
		if (ev.type != PropertyNotify) continue;
		if ([own containsObject: [NSNumber numberWithUnsignedLong: ev.xproperty.window]]) continue;
		if ([[NSUserDefaults standardUserDefaults] boolForKey: @"NaplesDebug"]) {
			char *an = XGetAtomName(dpy, ev.xproperty.atom);
			NSLog(@"Naples X: PropertyNotify win 0x%lx %s", ev.xproperty.window, an ? an : "?");
			if (an) XFree(an);
		}
		if (ev.xproperty.window == root) {
			if (ev.xproperty.atom == a.clientList) changed = YES;
			if (ev.xproperty.atom == a.activeWindow) activeChanged = YES;
			if (ev.xproperty.atom == a.rootPmap) bgChanged = YES;
		} else if (ev.xproperty.atom == a.wmState || ev.xproperty.atom == a.netWmState ||
		           ev.xproperty.atom == a.name || ev.xproperty.atom == a.netName || ev.xproperty.atom == a.pid) {
			changed = YES;
		}
	}
	if (changed && changeHandler) changeHandler();
	if (activeChanged && activeHandler) activeHandler();
	if (bgChanged) {
		void (^h)(void);
		for (h in backgroundHandlers) h();
	}
}

/* ---- properties ---- */

- (unsigned long *) longs: (Atom)prop of: (Window)w type: (Atom)type count: (unsigned long *)n
{
	Atom actual; int fmt; unsigned long nitems, after; unsigned char *data = NULL;
	*n = 0;
	if (XGetWindowProperty(dpy, w, prop, 0, 4096, False, type, &actual, &fmt, &nitems, &after, &data) != Success || !data)
		return NULL;
	if (fmt != 32 || !nitems) { XFree(data); return NULL; }
	*n = nitems;
	return (unsigned long *)data;
}

- (NSString *) text: (Atom)prop of: (Window)w
{
	Atom actual; int fmt; unsigned long nitems, after; unsigned char *data = NULL;
	NSString *s = nil;
	if (XGetWindowProperty(dpy, w, prop, 0, 1024, False, AnyPropertyType, &actual, &fmt, &nitems, &after, &data) != Success || !data)
		return nil;
	if (fmt == 8 && nitems)
		s = [[[NSString alloc] initWithBytes: data length: nitems encoding: actual == a.utf8 ? NSUTF8StringEncoding : NSISOLatin1StringEncoding] autorelease];
	XFree(data);
	return s;
}

- (BOOL) wantsWindow: (Window)w
{
	unsigned long n, i, *v = [self longs: a.windowType of: w type: XA_ATOM count: &n];
	BOOL ok = YES;
	if (v) {	/* only ordinary windows and dialogs; menus, docks, the desktop, tooltips and so on are not */
		ok = NO;
		for (i = 0; i < n; i++) if (v[i] == a.typeNormal || v[i] == a.typeDialog) ok = YES;
		XFree(v);
	}
	if (ok && (v = [self longs: a.netWmState of: w type: XA_ATOM count: &n])) {
		for (i = 0; i < n; i++) if (v[i] == a.skipTaskbar) ok = NO;
		XFree(v);
	}
	return ok;
}

- (NaplesWindowInfo *) infoForWindow: (unsigned long)xid
{
	Window w = xid;
	NaplesWindowInfo *info;
	unsigned long m, *v;
	XClassHint ch = { NULL, NULL };
	Window owner = None;
	XWindowAttributes attr;
	if (!dpy || !w || !XGetWindowAttributes(dpy, w, &attr)) return nil;
	info = [[[NaplesWindowInfo alloc] init] autorelease];
	info->xid = w;
	if ((v = [self longs: a.pid of: w type: XA_CARDINAL count: &m])) { info->pid = (int)v[0]; XFree(v); }
	if ((v = [self longs: a.wmState of: w type: AnyPropertyType count: &m])) { info->minimized = (v[0] == IconicState); XFree(v); }
	if (info->pid <= 0 && pidResolver) info->pid = pidResolver(w);
	info->title = [[self text: a.netName of: w] retain];
	if (!info->title) info->title = [[self text: a.name of: w] retain];
	if (XGetClassHint(dpy, w, &ch)) {
		if (ch.res_name) info->wmClass = [[NSString stringWithUTF8String: ch.res_name] retain];
		XFree(ch.res_name); XFree(ch.res_class);
	}
	if (XGetTransientForHint(dpy, w, &owner) && owner != None) info->transient = YES;
	return info;
}

- (NaplesWindowInfo *) activeWindow
{
	unsigned long n, *v;
	Window w;
	if (!dpy || !(v = [self longs: a.activeWindow of: root type: XA_WINDOW count: &n])) return nil;
	w = v[0];
	XFree(v);
	return w ? [self infoForWindow: w] : nil;
}

- (NSArray *) clientWindows
{
	NSMutableArray *out = [NSMutableArray array];
	unsigned long n, i, *list;
	if (!dpy) return out;
	list = [self longs: a.clientList of: root type: XA_WINDOW count: &n];
	for (i = 0; list && i < n; i++) {
		Window w = list[i];
		NaplesWindowInfo *info;
		if ([own containsObject: [NSNumber numberWithUnsignedLong: w]]) continue;
		if (![selected containsObject: [NSNumber numberWithUnsignedLong: w]]) {
			XSelectInput(dpy, w, PropertyChangeMask);
			[selected addObject: [NSNumber numberWithUnsignedLong: w]];
		}
		if (![self wantsWindow: w]) continue;
		info = [self infoForWindow: w];
		if (!info || info->pid == getpid()) continue;
		[out addObject: info];
	}
	if (list) XFree(list);
	return out;
}

/* ---- requests to the window manager ---- */

- (void) sendMessage: (Atom)type to: (Window)w l0: (long)l0 l1: (long)l1
{
	XEvent e;
	memset(&e, 0, sizeof e);
	e.xclient.type = ClientMessage;
	e.xclient.window = w;
	e.xclient.message_type = type;
	e.xclient.format = 32;
	e.xclient.data.l[0] = l0;
	e.xclient.data.l[1] = l1;
	XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
	XFlush(dpy);
}

- (void) activateWindow: (unsigned long)xid
{
	if (dpy) [self sendMessage: a.activeWindow to: xid l0: 2 l1: CurrentTime];	/* source 2: as a pager would */
}

- (void) closeWindow: (unsigned long)xid
{
	if (dpy) [self sendMessage: a.closeWindow to: xid l0: CurrentTime l1: 2];
}

/* ---- Naples' own window ---- */

- (BOOL) hasCompositor
{
	return dpy && XGetSelectionOwner(dpy, a.cm) != None;
}

- (void) registerOwnWindow: (unsigned long)xid
{
	NSNumber *k = [NSNumber numberWithUnsignedLong: xid];
	[own addObject: k];
	if ([selected containsObject: k]) { XSelectInput(dpy, xid, 0); [selected removeObject: k]; }
}

- (void) setDockHints: (unsigned long)xid edge: (int)edge barRect: (NSRect)bar reserve: (BOOL)reserve opacity: (double)opacity
{
	Window w = xid;
	Atom dock = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
	Atom states[2] = { a.sticky, a.above };
	unsigned long strut[12] = { 0 };
	unsigned long all = 0xFFFFFFFFul;
	int sw = DisplayWidth(dpy, DefaultScreen(dpy)), sh = DisplayHeight(dpy, DefaultScreen(dpy));
	NSNumber *key = [NSNumber numberWithUnsignedLong: xid];
	if (!dpy || !w) return;
	[self registerOwnWindow: xid];
	if (![hinted objectForKey: key]) {	/* the type, state and desktop once: the window manager reacts to every change of them */
		XChangeProperty(dpy, w, a.windowType, XA_ATOM, 32, PropModeReplace, (unsigned char *)&dock, 1);
		XChangeProperty(dpy, w, a.netWmState, XA_ATOM, 32, PropModeReplace, (unsigned char *)states, 2);
		XChangeProperty(dpy, w, a.desktop, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&all, 1);
		if (opacity < 1.0) {
			unsigned long o = (unsigned long)(opacity * 0xFFFFFFFFul);
			XChangeProperty(dpy, w, a.opacity, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&o, 1);
		}
	}
	if (reserve) {	/* left, right, top, bottom, then the start/end of each strip */
		if (edge == 3) { strut[2] = bar.origin.y + bar.size.height; strut[8] = bar.origin.x; strut[9] = bar.origin.x + bar.size.width; }
		else if (edge == 1) { strut[0] = bar.size.width + bar.origin.x; strut[4] = bar.origin.y; strut[5] = bar.origin.y + bar.size.height; }
		else if (edge == 2) { strut[1] = sw - bar.origin.x; strut[6] = bar.origin.y; strut[7] = bar.origin.y + bar.size.height; }
		else { strut[3] = sh - bar.origin.y; strut[10] = bar.origin.x; strut[11] = bar.origin.x + bar.size.width; }
	}
	{	/* the strut only when it changed */
		NSData *sd = [NSData dataWithBytes: strut length: sizeof strut];
		if (![[hinted objectForKey: key] isEqual: sd]) {
			XChangeProperty(dpy, w, a.strutPartial, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)strut, 12);
			XChangeProperty(dpy, w, a.strut, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)strut, 4);
			[hinted setObject: sd forKey: key];
		}
	}
	XFlush(dpy);
}

- (void) setShape: (unsigned long)xid rects: (NSArray *)rects radius: (int)r
{
	[self setShape: xid rects: rects radius: r square: 0];
}

- (void) setShape: (unsigned long)xid rects: (NSArray *)rects radius: (int)radius square: (NSUInteger)square
{
	NSMutableData *buf = [NSMutableData data];
	NSValue *v;
	NSUInteger k = 0;
	if (!dpy || !xid) return;
	for (v in rects) {
		int r = k++ < square ? 0 : radius;
		NSRect f = [v rectValue];
		int x = (int)f.origin.x, y = (int)f.origin.y, w = (int)f.size.width, h = (int)f.size.height, i, run = 0, runInset = -1;
		for (i = 0; i <= h; i++) {
			int inset = -1;
			if (i < h) {
				int d = i < h - 1 - i ? i : h - 1 - i;	/* rows from the nearest horizontal edge */
				inset = 0;
				if (d < r) {
					double dy = r - d - 0.5;
					inset = r - (int)floor(sqrt((double)r * r - dy * dy) + 0.5);
				}
			}
			if (inset != runInset) {	/* close the previous run of equal rows */
				if (run) {
					XRectangle xr = { x + runInset, y + i - run, w - 2 * runInset, run };
					[buf appendBytes: &xr length: sizeof xr];
				}
				run = 0; runInset = inset;
			}
			if (i < h) run++;
		}
	}
	XShapeCombineRectangles(dpy, xid, ShapeBounding, 0, 0, (XRectangle *)[buf bytes],
	                        (int)([buf length] / sizeof(XRectangle)), ShapeSet, Unsorted);
	XFlush(dpy);
}

@end

/* ---- Window Maker takeover ---- */

BOOL
NaplesEnsureWMTakeover(void)
{
	NSString *root = [[[NSProcessInfo processInfo] environment] objectForKey: @"GNUSTEP_USER_ROOT"];
	NSString *file, *dir;
	NSMutableDictionary *d;
	if (![root length]) root = [NSHomeDirectory() stringByAppendingPathComponent: @"GNUstep"];
	dir = [root stringByAppendingPathComponent: @"Defaults"];
	file = [dir stringByAppendingPathComponent: @"WindowMaker"];
	d = [NSMutableDictionary dictionaryWithContentsOfFile: file];
	if (!d) d = [NSMutableDictionary dictionary];
	if ([[d objectForKey: @"DisableMiniwindows"] isEqual: @"YES"]) return NO;
	[d setObject: @"YES" forKey: @"DisableMiniwindows"];
	[[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: NULL];
	return [d writeToFile: file atomically: YES];
}

/* the executable path of a process: KERN_PROCARGS2 starts with argc, then the exec path (libproc is not in this port) */
NSString *
NaplesExecutableOfPid(int pid)
{
	int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
	size_t len = 0;
	char *buf;
	NSString *s = nil;
	if (pid <= 0 || sysctl(mib, 3, NULL, &len, NULL, 0) < 0 || len <= sizeof(int)) return nil;
	buf = malloc(len);
	if (sysctl(mib, 3, buf, &len, NULL, 0) == 0 && len > sizeof(int))
		s = [NSString stringWithUTF8String: buf + sizeof(int)];
	free(buf);
	return s;
}
