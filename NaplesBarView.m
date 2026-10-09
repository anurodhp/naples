#import "NaplesBarView.h"
#import "NaplesBar.h"
#import "NaplesPanel.h"
#include <time.h>

enum { BarH = 22, Radius = 5, TitlesX = 44 };

static BOOL
isSep(NSDictionary *item)
{
	return NaplesIsSeparator(item);
}

static NSDictionary *
textAttrs(BOOL enabled, BOOL selected, BOOL bold)
{
	return NaplesMenuTextAttrs(NaplesPanelLight, enabled, selected, bold);
}

@implementation NaplesBarView

- (id) initWithBar: (NaplesBar *)b
{
	if ((self = [super initWithFrame: NSMakeRect(0, 0, 100, BarH)])) {
		bar = b;
		titleRects = [[NSMutableArray alloc] init];
		titleIdx = [[NSMutableArray alloc] init];
		chain = [[NSMutableArray alloc] init];
		openTop = -1; hoverLevel = hoverRow = -1;
	}
	return self;
}

- (void) setBackdrop: (NSImage *)img
{
	if (img == backdrop) return;
	[backdrop release]; backdrop = [img retain];
	[self setNeedsDisplay: YES];
}

- (void) dealloc { [panelSet release]; [backdrop release]; [titleRects release]; [titleIdx release]; [chain release]; [super dealloc]; }

- (BOOL) isFlipped { return NO; }
- (BOOL) isOpaque { return NO; }
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }
- (CGFloat) barHeight { return BarH; }
- (BOOL) menuOpen { return openTop != -1; }

/* ---- layout (top-down coordinates) ---- */

- (NSArray *) topItems { return [[bar menuData] objectForKey: @"items"]; }

- (void) reload
{
	NSArray *items = [self topItems];
	NSUInteger i;
	CGFloat x = TitlesX;
	NSImage *h = [bar hexley];
	CGFloat hw = h ? [h size].width * 16.0 / [h size].height : 16;
	hexleyRect = NSMakeRect(6, 0, hw + 14, BarH);
	[titleRects removeAllObjects]; [titleIdx removeAllObjects];
	for (i = 0; i < [items count]; i++) {
		NSDictionary *it = [items objectAtIndex: i];
		CGFloat w;
		if (isSep(it)) continue;
		w = [[it objectForKey: @"title"] sizeWithAttributes: textAttrs(YES, NO, NO)].width + 18;
		[titleRects addObject: [NSValue valueWithRect: NSMakeRect(x, 0, w, BarH)]];
		[titleIdx addObject: [NSNumber numberWithUnsignedInteger: i]];
		x += w;
	}
	if (openTop >= 0 && (NSUInteger)openTop >= [items count]) { openTop = -1; [chain removeAllObjects]; }
	[self setNeedsDisplay: YES];
	[bar viewResized];
}

- (NSRect) titleRectForIndex: (NSInteger)idx
{
	NSUInteger k = [titleIdx indexOfObject: [NSNumber numberWithInteger: idx]];
	return k == NSNotFound ? NSZeroRect : [[titleRects objectAtIndex: k] rectValue];
}

- (NSDictionary *) rootMenu
{
	if (openTop == -2) return [bar systemMenu];
	if (openTop >= 0 && (NSUInteger)openTop < [[self topItems] count])
		return [[[self topItems] objectAtIndex: openTop] objectForKey: @"submenu"];
	return nil;
}

/* ---- the drop-down and its cascades: one window per panel (NaplesPanel), placed from the open state ---- */

- (NSArray *) buildPanels
{
	NSMutableArray *out = [NSMutableArray array];
	NSArray *items = [[self rootMenu] objectForKey: @"items"];
	NaplesPanel *p, *prev;
	CGFloat W = [[NSScreen mainScreen] frame].size.width, x;
	NSUInteger level;
	if (![items count] || openTop == -1) return out;
	x = openTop == -2 ? hexleyRect.origin.x : [self titleRectForIndex: openTop].origin.x;
	p = [NaplesPanel panelWithItems: items x: x top: BarH style: NaplesPanelLight];
	if (p->x + p->w > W) p->x = W - p->w;
	[out addObject: p];
	for (level = 0; level < [chain count]; level++) {
		NSInteger row = [[chain objectAtIndex: level] integerValue];
		NSDictionary *it = row < (NSInteger)[p->items count] ? [p->items objectAtIndex: row] : nil;
		NSArray *sub = [[it objectForKey: @"submenu"] objectForKey: @"items"];
		NaplesPanel *n;
		if (![sub count]) break;
		prev = p;
		prev->openRow = row;
		n = [NaplesPanel panelWithItems: sub x: prev->x + prev->w - 2 top: prev->top + [[prev->rowTops objectAtIndex: row] doubleValue] style: NaplesPanelLight];
		if (n->x + n->w > W) n->x = prev->x - n->w + 2;
		[out addObject: n];
		p = n;
	}
	if (hoverLevel >= 0 && hoverLevel < (NSInteger)[out count]) ((NaplesPanel *)[out objectAtIndex: hoverLevel])->hoverRow = hoverRow;
	return out;
}

- (void) refreshPanels
{
	NSArray *panels = [self buildPanels];
	if (![panels count]) { [panelSet hide]; return; }
	if (!panelSet) panelSet = [[NaplesPanelSet alloc] initWithDelegate: self];
	[panelSet showPanels: panels];
}

- (CGFloat) desiredHeight { return BarH; }	/* the bar window never grows: menus have their own windows */

- (NSArray *) shapeRects
{
	return [NSArray arrayWithObject: [NSValue valueWithRect: NSMakeRect(0, 0, [self bounds].size.width, BarH)]];
}

/* ---- drawing ---- */

- (void) drawRect: (NSRect)dirty
{
	NSRect bounds = [self bounds];
	NSRect barR = NSMakeRect(0, bounds.size.height - BarH, bounds.size.width, BarH);
	NSArray *items = [self topItems];
	NSImage *h = [bar hexley];
	NSUInteger k;
	time_t t = time(NULL);
	struct tm tm;
	char buf[64];
	NSString *clock;
	NSDictionary *ca = textAttrs(YES, NO, NO);
	NSSize cs;
	NSRectFillUsingOperation(dirty, NSCompositeClear);

	if (backdrop) {	/* translucent: the wallpaper under the bar, washed with white */
		NSRect src = NSZeroRect;
		src.size = [backdrop size];
		[backdrop drawInRect: barR fromRect: src operation: NSCompositeSourceOver fraction: 1.0];
		[[NSColor colorWithCalibratedWhite: 1 alpha: 0.62] set];
	} else {
		[[NSColor colorWithCalibratedWhite: 0.96 alpha: 0.94] set];
	}
	NSRectFillUsingOperation(barR, NSCompositeSourceOver);
	[[NSColor colorWithCalibratedWhite: 0 alpha: 0.28] set];
	NSRectFill(NSMakeRect(0, barR.origin.y, barR.size.width, 1));

	{	/* Hexley, where the Apple logo would be */
		NSRect hr = NSMakeRect(hexleyRect.origin.x, barR.origin.y, hexleyRect.size.width, BarH);
		if (openTop == -2) { [[NSColor colorWithCalibratedWhite: 0 alpha: 0.14] set]; NSRectFill(hr); }
		if (h) {
			CGFloat hh = 16, hw = [h size].width * hh / [h size].height;
			NSRect src = NSZeroRect;
			src.size = [h size];
			[h drawInRect: NSMakeRect(NSMidX(hr) - hw / 2, NSMidY(hr) - hh / 2, hw, hh) fromRect: src operation: NSCompositeSourceOver fraction: 1];
		}
	}

	if (![items count]) {	/* no menu from this program (not a GNUstep app, or it has not sent one yet) */
		[[bar frontName] drawAtPoint: NSMakePoint(TitlesX, barR.origin.y + 4) withAttributes: textAttrs(YES, NO, YES)];
	}
	for (k = 0; k < [titleRects count]; k++) {
		NSInteger idx = [[titleIdx objectAtIndex: k] integerValue];
		NSDictionary *it = [items objectAtIndex: idx];
		NSRect r = [[titleRects objectAtIndex: k] rectValue];
		BOOL sel = idx == openTop;
		NSRect vr = NSMakeRect(r.origin.x, barR.origin.y, r.size.width, BarH);
		if (sel) { [[NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1] set]; NSRectFill(vr); }
		[[it objectForKey: @"title"] drawAtPoint: NSMakePoint(vr.origin.x + 9, vr.origin.y + 4)
		                          withAttributes: textAttrs([[it objectForKey: @"enabled"] boolValue], sel, NO)];
	}

	localtime_r(&t, &tm);
	strftime(buf, sizeof buf, "%a %b %e  %l:%M %p", &tm);
	clock = [NSString stringWithUTF8String: buf];
	cs = [clock sizeWithAttributes: ca];
	[clock drawAtPoint: NSMakePoint(bounds.size.width - cs.width - 12, barR.origin.y + 4) withAttributes: ca];
}

/* ---- the bar's own mouse handling ---- */

/* -1 nothing, -2 Hexley, else the item index of the title under p */
- (NSInteger) barHit: (NSPoint)p
{
	NSUInteger k;
	if (p.y < [self bounds].size.height - BarH) return -1;
	if (p.x >= hexleyRect.origin.x && p.x < NSMaxX(hexleyRect)) return -2;
	for (k = 0; k < [titleRects count]; k++) {
		NSRect r = [[titleRects objectAtIndex: k] rectValue];
		if (p.x >= r.origin.x && p.x < NSMaxX(r)) return [[titleIdx objectAtIndex: k] integerValue];
	}
	return -1;
}

- (void) openTopItem: (NSInteger)t
{
	if (t == openTop) return;
	[chain removeAllObjects];
	hoverLevel = hoverRow = -1;
	openTop = t;
	if (t != -1) [bar prepareMenu];	/* fresh enabled/checked state from the application, as it is about to be shown */
	[self refreshPanels];
	[self setNeedsDisplay: YES];
}

- (void) closeMenu
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil];
	if (openTop == -1) return;
	openTop = -1; [chain removeAllObjects]; hoverLevel = hoverRow = -1;
	[panelSet hide];
	[self setNeedsDisplay: YES];
}

- (void) mouseDown: (NSEvent *)e
{
	NSInteger b = [self barHit: [self convertPoint: [e locationInWindow] fromView: nil]];
	if (b == -1) { [self closeMenu]; return; }
	if (b == openTop) [self closeMenu];
	else [self openTopItem: b];
}

- (void) mouseMoved: (NSEvent *)e
{
	NSInteger b;
	if (openTop == -1) return;
	b = [self barHit: [self convertPoint: [e locationInWindow] fromView: nil]];
	if (b != -1 && b != openTop) [self openTopItem: b];	/* sliding along the bar switches menus */
}

- (void) mouseEntered: (NSEvent *)e { [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil]; }
- (void) mouseExited: (NSEvent *)e { if (openTop != -1) [self performSelector: @selector(closeMenu) withObject: nil afterDelay: 1.2]; }

/* ---- the panels' mouse handling (NaplesPanelDelegate) ---- */

- (void) panelSet: (id)set level: (NSInteger)level hoverRow: (NSInteger)row
{
	NSArray *panels = [panelSet panels];
	NaplesPanel *pn;
	NSDictionary *it;
	if (level < 0 || level >= (NSInteger)[panels count]) return;
	if (level == hoverLevel && row == hoverRow) return;
	pn = [panels objectAtIndex: level];
	it = row >= 0 && row < (NSInteger)[pn->items count] ? [pn->items objectAtIndex: row] : nil;
	hoverLevel = level; hoverRow = row;
	while ((NSInteger)[chain count] > level) [chain removeLastObject];	/* close deeper cascades */
	if (it && !isSep(it) && [it objectForKey: @"submenu"] && [[it objectForKey: @"enabled"] boolValue])
		[chain addObject: [NSNumber numberWithInteger: row]];
	[self refreshPanels];
}

- (void) panelSet: (id)set level: (NSInteger)level clickedRow: (NSInteger)row
{
	NSArray *panels = [panelSet panels];
	NaplesPanel *pn;
	NSDictionary *it;
	NSMutableArray *path;
	NSInteger i;
	if (level < 0 || level >= (NSInteger)[panels count] || row < 0) return;
	pn = [panels objectAtIndex: level];
	it = [pn->items objectAtIndex: row];
	if (isSep(it) || ![[it objectForKey: @"enabled"] boolValue] || [it objectForKey: @"submenu"]) return;
	if (openTop == -2) {
		void (^blk)(void) = [it objectForKey: @"block"];
		[self closeMenu];
		if (blk) blk();
		return;
	}
	path = [NSMutableArray arrayWithObject: [NSNumber numberWithInteger: openTop]];
	for (i = 0; i < level; i++) [path addObject: [chain objectAtIndex: i]];
	[path addObject: [NSNumber numberWithInteger: row]];
	[self closeMenu];
	[bar activatePath: path];
}

- (void) panelSetPointerEntered: (id)set { [self mouseEntered: nil]; }
- (void) panelSetPointerExited: (id)set { [self mouseExited: nil]; }

- (void) retrack
{
	if (tracking) [self removeTrackingRect: trackTag];
	trackTag = [self addTrackingRect: [self bounds] owner: self userData: NULL assumeInside: NO];
	tracking = YES;
}

- (void) setFrameSize: (NSSize)s { [super setFrameSize: s]; if ([self window]) [self retrack]; }
- (void) viewDidMoveToWindow { if ([self window]) { [[self window] setAcceptsMouseMovedEvents: YES]; [self retrack]; } }

@end
