/* NaplesPanel: pop-up menu panels, one small borderless window each (the menu bar's drop-downs and cascades, the dock's
 * long-click menu). Growing the bar or dock window to hold a menu left the unused part of the window painted black on
 * this server, so a panel is exactly the size of its menu. Items are dictionaries in Eau's menu format
 * ({title, enabled, state, keyEquivalent, keyEquivalentModifierMask, submenu} or {isSeparator}), plus an optional "block"
 * run by the owner for local menus.
 *
 * Positions are in screen coordinates with a top-left origin (x, top); the window is placed from them. */
#import <AppKit/AppKit.h>

typedef enum { NaplesPanelLight, NaplesPanelDark } NaplesPanelStyle;

BOOL NaplesIsSeparator(NSDictionary *item);
NSString *NaplesKeyString(NSDictionary *item);	/* "⌘C", nil if the item has no key equivalent */
NSDictionary *NaplesMenuTextAttrs(NaplesPanelStyle style, BOOL enabled, BOOL selected, BOOL bold);
void NaplesDrawCheck(NSRect r, NSInteger state, BOOL selected, NaplesPanelStyle style);

@interface NaplesPanel : NSObject {
@public
	NSArray *items;
	CGFloat x, top, w, h;	/* screen, top-left origin */
	NSMutableArray *rowTops;	/* NSNumber offsets from the panel's top, per item */
	NSInteger hoverRow;	/* highlighted row, -1 none */
	NSInteger openRow;	/* row whose submenu is open, -1 none */
	NaplesPanelStyle style;
}
+ (NaplesPanel *) panelWithItems: (NSArray *)items x: (CGFloat)x top: (CGFloat)top style: (NaplesPanelStyle)style;
- (CGFloat) rowHeightAt: (NSUInteger)i;
@end

@protocol NaplesPanelDelegate <NSObject>
- (void) panelSet: (id)set level: (NSInteger)level hoverRow: (NSInteger)row;
- (void) panelSet: (id)set level: (NSInteger)level clickedRow: (NSInteger)row;
- (void) panelSetPointerEntered: (id)set;
- (void) panelSetPointerExited: (id)set;
@end

/* The windows for a stack of panels (level 0 is the drop-down, deeper levels are its cascades). */
@interface NaplesPanelSet : NSObject {
	id <NaplesPanelDelegate> delegate;
	NSMutableArray *windows;
	NSMutableArray *shown;	/* NaplesPanel, parallel to the visible windows */
}
- (id) initWithDelegate: (id <NaplesPanelDelegate>)d;
- (void) showPanels: (NSArray *)panels;	/* replaces what is shown; windows are reused */
- (void) hide;
- (BOOL) isShowing;
- (NSArray *) panels;
@end
