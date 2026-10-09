/* NaplesX: the dock's side of the X server (EWMH client, not a toolkit).
 * Its own Display connection, read through a GCD source so X events wake the main run loop.
 * Tracks the top-level windows (_NET_CLIENT_LIST, WM_STATE), activates / closes them, and sets the dock hints
 * (window type, strut, XShape mask for the 5px rounded corners) on Naples' own window.
 * Window Maker is told to leave minimizing to us by DisableMiniwindows (see NaplesEnsureWMTakeover). */
#import <Foundation/Foundation.h>

@interface NaplesWindowInfo : NSObject {
@public
	unsigned long xid;
	int pid;
	NSString *title;
	NSString *wmClass;	/* WM_CLASS res_name; GNUstep sets it to the application name */
	BOOL minimized;	/* WM_STATE is IconicState (minimized or hidden) */
	BOOL transient;	/* a dialog / sheet of another window */
}
@end

@interface NaplesX : NSObject
+ (NaplesX *) shared;
- (BOOL) connect;
/* Called (on the main thread, once per burst) when the window list or any window's state/title changed. */
- (void) setChangeHandler: (void (^)(void))handler;
- (NaplesWindowInfo *) infoForWindow: (unsigned long)xid;	/* any window, no filtering; nil if it is gone */
- (NaplesWindowInfo *) activeWindow;	/* _NET_ACTIVE_WINDOW, nil if none */
/* Called (main thread) when _NET_ACTIVE_WINDOW changes. */
- (void) setActiveHandler: (void (^)(void))handler;
- (NSArray *) clientWindows;	/* NaplesWindowInfo, in _NET_CLIENT_LIST (map) order, Naples' own windows left out */
- (void) activateWindow: (unsigned long)xid;	/* also un-minimizes */
- (void) closeWindow: (unsigned long)xid;
/* Hints for Naples' window; call before it is mapped. edge: 0 bottom, 1 left, 2 right, 3 top; barRect is the bar in screen pixels, top-left origin. */
- (void) setDockHints: (unsigned long)xid edge: (int)edge barRect: (NSRect)bar reserve: (BOOL)reserve opacity: (double)opacity;
/* XShape bounding mask: union of rects (window coordinates, top-left origin), each with rounded corners;
 * the first `square` rects are left square (the top bar). */
- (void) setShape: (unsigned long)xid rects: (NSArray *)rects radius: (int)radius;
- (void) setShape: (unsigned long)xid rects: (NSArray *)rects radius: (int)radius square: (NSUInteger)square;
- (BOOL) hasCompositor;
@end

/* Window Maker draws a miniwindow icon for every minimized window unless told not to. Writes DisableMiniwindows = YES
 * into its defaults domain (WM re-reads the file by itself). Returns YES if it changed the file. */
BOOL NaplesEnsureWMTakeover(void);

void NaplesRunOnMain(void (^block)(void));
