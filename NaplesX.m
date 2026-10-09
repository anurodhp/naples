#import "NaplesX.h"
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <unistd.h>
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
	NSMutableSet *selected;	/* windows we already listen to */
	struct {
		Atom clientList, wmState, netWmState, name, netName, utf8, pid, windowType, typeNormal, typeDialog,
		     activeWindow, closeWindow, strutPartial, strut, opacity, skipTaskbar, sticky, above, desktop, cm;
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
#define ATOM(f, n) a.f = XInternAtom(dpy, n, False)
	ATOM(clientList, "_NET_CLIENT_LIST"); ATOM(wmState, "WM_STATE"); ATOM(netWmState, "_NET_WM_STATE");
	ATOM(name, "WM_NAME"); ATOM(netName, "_NET_WM_NAME"); ATOM(utf8, "UTF8_STRING"); ATOM(pid, "_NET_WM_PID");
	ATOM(windowType, "_NET_WM_WINDOW_TYPE"); ATOM(typeNormal, "_NET_WM_WINDOW_TYPE_NORMAL");
	ATOM(typeDialog, "_NET_WM_WINDOW_TYPE_DIALOG"); ATOM(activeWindow, "_NET_ACTIVE_WINDOW");
	ATOM(closeWindow, "_NET_CLOSE_WINDOW"); ATOM(strutPartial, "_NET_WM_STRUT_PARTIAL"); ATOM(strut, "_NET_WM_STRUT");
	ATOM(opacity, "_NET_WM_WINDOW_OPACITY"); ATOM(skipTaskbar, "_NET_WM_STATE_SKIP_TASKBAR");
	ATOM(sticky, "_NET_WM_STATE_STICKY"); ATOM(above, "_NET_WM_STATE_ABOVE"); ATOM(desktop, "_NET_WM_DESKTOP");
	ATOM(cm, "_NET_WM_CM_S0");
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

- (void) drain
{
	BOOL changed = NO;
	XEvent ev;
	while (XPending(dpy)) {
		XNextEvent(dpy, &ev);
		if (ev.type != PropertyNotify) continue;
		if (ev.xproperty.window == root) {
			if (ev.xproperty.atom == a.clientList) changed = YES;
		} else if (ev.xproperty.atom == a.wmState || ev.xproperty.atom == a.netWmState ||
		           ev.xproperty.atom == a.name || ev.xproperty.atom == a.netName || ev.xproperty.atom == a.pid) {
			changed = YES;
		}
	}
	if (changed && changeHandler) changeHandler();
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

- (NSArray *) clientWindows
{
	NSMutableArray *out = [NSMutableArray array];
	unsigned long n, i, *list;
	if (!dpy) return out;
	list = [self longs: a.clientList of: root type: XA_WINDOW count: &n];
	for (i = 0; list && i < n; i++) {
		Window w = list[i];
		NaplesWindowInfo *info;
		unsigned long m, *v;
		XClassHint ch = { NULL, NULL };
		Window owner = None;
		if (![selected containsObject: [NSNumber numberWithUnsignedLong: w]]) {
			XSelectInput(dpy, w, PropertyChangeMask);
			[selected addObject: [NSNumber numberWithUnsignedLong: w]];
		}
		if (![self wantsWindow: w]) continue;
		info = [[[NaplesWindowInfo alloc] init] autorelease];
		info->xid = w;
		if ((v = [self longs: a.pid of: w type: XA_CARDINAL count: &m])) { info->pid = (int)v[0]; XFree(v); }
		if (info->pid == getpid()) continue;
		if ((v = [self longs: a.wmState of: w type: AnyPropertyType count: &m])) { info->minimized = (v[0] == IconicState); XFree(v); }
		info->title = [[self text: a.netName of: w] retain];
		if (!info->title) info->title = [[self text: a.name of: w] retain];
		if (XGetClassHint(dpy, w, &ch)) {
			if (ch.res_name) info->wmClass = [[NSString stringWithUTF8String: ch.res_name] retain];
			XFree(ch.res_name); XFree(ch.res_class);
		}
		if (XGetTransientForHint(dpy, w, &owner) && owner != None) info->transient = YES;
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

- (void) setDockHints: (unsigned long)xid edge: (int)edge barRect: (NSRect)bar reserve: (BOOL)reserve opacity: (double)opacity
{
	Window w = xid;
	Atom dock = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
	Atom states[2] = { a.sticky, a.above };
	unsigned long strut[12] = { 0 };
	unsigned long all = 0xFFFFFFFFul;
	int sw = DisplayWidth(dpy, DefaultScreen(dpy)), sh = DisplayHeight(dpy, DefaultScreen(dpy));
	if (!dpy || !w) return;
	XChangeProperty(dpy, w, a.windowType, XA_ATOM, 32, PropModeReplace, (unsigned char *)&dock, 1);
	XChangeProperty(dpy, w, a.netWmState, XA_ATOM, 32, PropModeReplace, (unsigned char *)states, 2);
	XChangeProperty(dpy, w, a.desktop, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&all, 1);
	if (opacity < 1.0) {
		unsigned long o = (unsigned long)(opacity * 0xFFFFFFFFul);
		XChangeProperty(dpy, w, a.opacity, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&o, 1);
	}
	if (reserve) {	/* left, right, top, bottom, then the start/end of each strip */
		if (edge == 1) { strut[0] = bar.size.width + bar.origin.x; strut[4] = bar.origin.y; strut[5] = bar.origin.y + bar.size.height; }
		else if (edge == 2) { strut[1] = sw - bar.origin.x; strut[6] = bar.origin.y; strut[7] = bar.origin.y + bar.size.height; }
		else { strut[3] = sh - bar.origin.y; strut[10] = bar.origin.x; strut[11] = bar.origin.x + bar.size.width; }
	}
	XChangeProperty(dpy, w, a.strutPartial, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)strut, 12);
	XChangeProperty(dpy, w, a.strut, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)strut, 4);
	XFlush(dpy);
}

- (void) setShape: (unsigned long)xid rects: (NSArray *)rects radius: (int)r
{
	NSMutableData *buf = [NSMutableData data];
	NSValue *v;
	if (!dpy || !xid) return;
	for (v in rects) {
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
