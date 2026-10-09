/* NaplesDockView: draws the dock and handles every interaction with it.
 * The view is non-flipped; the bar is a rounded rect somewhere inside the window (the window is larger than the bar
 * only while the long-click menu is open, because pop-up windows do not paint on this stack: the menu is an overlay
 * drawn by this view, as in Milan). */
#import <AppKit/AppKit.h>
#import "NaplesDock.h"
#import "NaplesPanel.h"

@interface NaplesDockView : NSView <NaplesPanelDelegate> {
	NaplesPanelSet *panelSet, *tipSet;
	NSInteger tipIndex;
	NaplesDock *dock;
	NSArray *items;
	NSMutableArray *slots;	/* NSValue rects in bar coordinates, parallel to items */
	int edge;
	int iconSize;
	NSSize barSize;
	NSPoint barOrigin;	/* the bar's lower left corner in view coordinates */
	/* long-click menu */
	NSArray *menuEntries;
	NSInteger menuHover;
	/* mouse state */
	NSInteger downIndex;	/* item under the button, -1 for the bar, -2 for outside the bar */
	NSPoint downPoint;	/* screen */
	NSEvent *downEvent;
	BOOL dragging, movingDock, longFired;
	NSInteger dragSource;
	NSInteger dropIndex;	/* pinned insertion index while something is dragged over the dock, else -1 */
	NSInteger dropAppIndex;	/* an app icon a document is dragged onto (opens it with that app), else -1 */
	BOOL dropOnTrash, dropHandled;
	NSTrackingRectTag trackTag;
	BOOL tracking;
	NSTimer *bounceTimer;
	NSImage *backdrop;	/* the wallpaper under the bar (pseudo-transparency), nil if unknown */
}
- (void) setBackdrop: (NSImage *)img;
- (id) initWithDock: (NaplesDock *)d;
- (void) reloadItems: (NSArray *)newItems edge: (int)e maxLength: (CGFloat)maxLen;
- (NSSize) barSize;
- (void) setBarOrigin: (NSPoint)bar;
- (BOOL) menuOpen;
- (NSRect) barRect;	/* in view coordinates */
- (void) openMenuWithEntries: (NSArray *)entries anchor: (NSRect)slot pointer: (NSPoint)p;
- (void) closeMenu;
@end
