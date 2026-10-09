/* NaplesBar: the global menu bar, and the server end of Eau's menu protocol (see NaplesMenuProtocol.h).
 * GNUstep apps running the Eau theme push their menus here instead of drawing their own menu bar; the bar shows the
 * menu of the frontmost application (from _NET_ACTIVE_WINDOW -> _NET_WM_PID -> that app's MenuClient.<pid>) and sends
 * the chosen item back as an index path. */
#import <AppKit/AppKit.h>
#import "NaplesMenuProtocol.h"

@class NaplesDock, NaplesBarView;

@interface NaplesBar : NSObject <GSGNUstepMenuServer> {
	NaplesDock *dock;
	NSWindow *window;
	NaplesBarView *view;
	NSConnection *serverConnection;
	NSMutableDictionary *windowMenus;	/* client name -> { NSNumber window id -> menuData } */
	NSMutableDictionary *appMenus;	/* client name -> menuData */
	NSMutableDictionary *proxies;	/* client name -> DO proxy */
	NSNumber *frontWindowId;
	NSString *frontClient, *frontName, *frontWMClass;
	NSImage *hexleyImage;
	void *clockSource;
	BOOL loadedHexley;
}
- (id) initWithDock: (NaplesDock *)d;
- (void) start;

/* for the view */
- (NSDictionary *) menuData;	/* the frontmost application's menu, nil if it has none */
- (NSString *) frontName;
- (void) showAbout;	/* About Naples, the standard GNUstep info panel (as Milan's) */
- (NSDictionary *) systemMenu;	/* the Hexley menu; items carry a "block" */
- (NSImage *) hexley;
- (void) prepareMenu;	/* ask the application for fresh enabled/checked state before a menu opens */
- (void) activatePath: (NSArray *)path;
- (void) viewResized;	/* the view's menu opened, closed or cascaded: resize and re-shape the window */
@end
