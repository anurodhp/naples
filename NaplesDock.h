/* NaplesDock: the model and controller of the dock.
 *
 * Layout, left to right (top to bottom on a side dock):
 *   Milan (fixed) | pinned apps ... | divider | running apps that are not pinned | minimized windows | Trash (fixed)
 * Pinned apps are the user's list (drag in, drag out, reorder) and persist in NSUserDefaults. A running app shows a
 * white dot. Running state comes from the window manager (_NET_CLIENT_LIST) and from the processes Naples started
 * (a GCD DISPATCH_SOURCE_TYPE_PROC source per child). Minimizing belongs to Naples: Window Maker is configured not to
 * draw miniwindows and the dock lists every minimized window instead. */
#import <AppKit/AppKit.h>

typedef enum { NaplesEdgeBottom = 0, NaplesEdgeLeft = 1, NaplesEdgeRight = 2 } NaplesEdge;
typedef enum { NaplesItemMilan, NaplesItemApp, NaplesItemDivider, NaplesItemWindow, NaplesItemTrash } NaplesItemKind;

extern NSString *const NaplesPboardType;	/* a dock item being dragged: payload is the bundle path */

@interface NaplesItem : NSObject {
@public
	NaplesItemKind kind;
	NSString *path;	/* app bundle (or executable) path, nil for an unidentified running program */
	NSString *name;
	NSImage *icon;
	BOOL pinned;
	NSMutableArray *pids;	/* NSNumber */
	NSMutableArray *windows;	/* NaplesWindowInfo */
	unsigned long xid;	/* NaplesItemWindow: the minimized window */
	BOOL trashFull;
	NSTimeInterval launchStart;	/* when the app was started and has no window yet (the icon bounces), else 0 */
}
- (BOOL) running;
@end

@interface NaplesMenuEntry : NSObject {
@public
	NSString *title;
	void (^action)(void);
}
@end

@class NaplesDockView;

@interface NaplesDock : NSObject {
	NSMutableArray *pinned;
	NSArray *items;
	NSMutableDictionary *launching;	/* path -> NSDate, started by us and no window yet */
	NSMutableDictionary *launched;	/* path -> NSNumber pid, started by us and not yet gone */
	NSMutableDictionary *procSources;	/* NSNumber pid -> dispatch source */
	NSMutableDictionary *icons;
	NSMutableArray *runOrder;	/* keys of running, unpinned programs, in the order they appeared */
	NSWindow *window;
	NaplesDockView *view;
	int edge;
	BOOL trashFull;
	NSString *milanPath;
	dispatch_source_t trashSource;
	BOOL layoutHold, layoutDeferred;	/* no window changes while a drag session runs in the view */
	NSRect backdropRect;	/* X coordinates of the bar the current backdrop was cut for */
}
- (void) start;
- (NSArray *) items;
- (int) edge;
- (void) setEdge: (int)e persist: (BOOL)persist;

- (void) activateItem: (NaplesItem *)item;	/* click */
- (void) openMilan;	/* start Milan, or bring it forward */
- (NSArray *) menuEntriesForItem: (NaplesItem *)item;	/* long click: nil item is the dock background */
- (NSString *) toolTipForItem: (NaplesItem *)item;

- (void) pinPath: (NSString *)path atIndex: (NSInteger)index;	/* index into the pinned list; existing entries move */
- (void) unpinPath: (NSString *)path;
- (NSInteger) pinnedIndexOfPath: (NSString *)path;
- (NSUInteger) pinnedCount;
- (void) trashPaths: (NSArray *)paths;
- (void) openFile: (NSString *)file withItem: (NaplesItem *)item;

/* Geometry hooks used by the view. */
- (void) holdLayout: (BOOL)hold;	/* defer relayout (window moves, resizes, reshapes) until released */
- (void) relayout;	/* re-measure the view and move/resize/shape the window */
@end
