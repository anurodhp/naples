/* NaplesBarView: the top menu bar. Hexley head at the far left (opens the system menu), the frontmost application's
 * menu titles after it, the date and time at the far right with the volume (speaker) left of it. Drop-down menus and their cascading submenus are overlays
 * drawn by this view (the window grows downward while a menu is open; see NaplesBar). */
#import <AppKit/AppKit.h>

@class NaplesBar, NaplesPanelSet;
#import "NaplesPanel.h"

@interface NaplesBarView : NSView <NaplesPanelDelegate> {
	NaplesPanelSet *panelSet;
	NaplesBar *bar;
	NSMutableArray *titleRects;	/* NSValue, top-down y, parallel to titleIdx */
	NSMutableArray *titleIdx;	/* NSNumber: index into the menu's items */
	NSRect hexleyRect;
	NSRect speakerRect;	/* top-down y; empty when there is no volume control */
	NSInteger openTop;	/* -1 closed, -2 the system (Hexley) menu, else index of the open top-level item */
	NSMutableArray *chain;	/* NSNumber row indices of the cascade, one per open submenu */
	NSInteger hoverLevel, hoverRow;
	NSTrackingRectTag trackTag;
	BOOL tracking;
	NSImage *backdrop;
}
- (void) setBackdrop: (NSImage *)img;
- (id) initWithBar: (NaplesBar *)b;
- (CGFloat) barHeight;
- (void) reload;	/* the menu or the front application changed */
- (BOOL) menuOpen;
- (void) closeMenu;
- (CGFloat) desiredHeight;	/* the bar plus the lowest open panel */
- (NSArray *) shapeRects;	/* NSValue rects, window coordinates with a top-left origin; the bar first, then the panels */
@end
