#import "NaplesBarView.h"
#import "NaplesBar.h"
#include <time.h>

enum { BarH = 22, RowH = 20, SepH = 9, PanelPad = 4, Radius = 5, MinPanelW = 150, TitlesX = 44 };

static NSBezierPath *
rounded(NSRect r)
{
	return [NSBezierPath bezierPathWithRoundedRect: r xRadius: Radius yRadius: Radius];
}

static BOOL
isSep(NSDictionary *item)
{
	return [[item objectForKey: @"isSeparator"] boolValue];
}

static NSDictionary *
textAttrs(BOOL enabled, BOOL selected, BOOL bold)
{
	NSColor *c = selected ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: 0.08 alpha: enabled ? 1.0 : 0.38];
	return [NSDictionary dictionaryWithObjectsAndKeys: bold ? [NSFont boldSystemFontOfSize: 12] : [NSFont systemFontOfSize: 12], NSFontAttributeName,
	        c, NSForegroundColorAttributeName, nil];
}

/* "⌘C": modifier glyphs then the key */
static NSString *
keyString(NSDictionary *item)
{
	NSString *k = [item objectForKey: @"keyEquivalent"];
	NSUInteger m = [[item objectForKey: @"keyEquivalentModifierMask"] unsignedIntegerValue];
	NSMutableString *s = [NSMutableString string];
	if (![k length]) return nil;
	if (m & (1 << 18)) [s appendString: @"⌃"];
	if (m & (1 << 19)) [s appendString: @"⌥"];
	if (m & (1 << 17)) [s appendString: @"⇧"];
	if (m & (1 << 20)) [s appendString: @"⌘"];
	[s appendString: [k uppercaseString]];
	return s;
}

/* one open drop-down or cascade level, in top-down coordinates (y measured from the top of the screen) */
@interface NaplesPanel : NSObject {
@public
	NSArray *items;
	CGFloat x, top, w, h;
	NSMutableArray *rowTops;	/* NSNumber offsets from the panel's top, per item */
}
@end
@implementation NaplesPanel
- (void) dealloc { [items release]; [rowTops release]; [super dealloc]; }
@end

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

- (void) dealloc { [backdrop release]; [titleRects release]; [titleIdx release]; [chain release]; [super dealloc]; }

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

- (NaplesPanel *) panelForItems: (NSArray *)items x: (CGFloat)x top: (CGFloat)top
{
	NaplesPanel *p = [[[NaplesPanel alloc] init] autorelease];
	CGFloat y = PanelPad, w = MinPanelW;
	NSDictionary *it;
	p->items = [items retain];
	p->rowTops = [[NSMutableArray alloc] init];
	for (it in items) {
		[p->rowTops addObject: [NSNumber numberWithDouble: y]];
		if (isSep(it)) { y += SepH; continue; }
		{
			CGFloat tw = [[it objectForKey: @"title"] sizeWithAttributes: textAttrs(YES, NO, NO)].width + 36;
			NSString *k = keyString(it);
			if (k) tw += [k sizeWithAttributes: textAttrs(YES, NO, NO)].width + 24;
			if (tw > w) w = tw;
		}
		y += RowH;
	}
	p->x = x; p->top = top; p->w = w; p->h = y + PanelPad;
	return p;
}

- (NSArray *) panels
{
	NSMutableArray *out = [NSMutableArray array];
	NSDictionary *root = [self rootMenu];
	NSArray *items = [root objectForKey: @"items"];
	NaplesPanel *p, *prev = nil;
	CGFloat W = [self bounds].size.width, x;
	NSUInteger level;
	if (!items || ![items count] || openTop == -1) return out;
	x = openTop == -2 ? hexleyRect.origin.x : [self titleRectForIndex: openTop].origin.x;
	p = [self panelForItems: items x: x top: BarH];
	if (p->x + p->w > W) p->x = W - p->w;
	[out addObject: p];
	for (level = 0; level < [chain count]; level++) {
		NSInteger row = [[chain objectAtIndex: level] integerValue];
		NSDictionary *it = row < (NSInteger)[p->items count] ? [p->items objectAtIndex: row] : nil;
		NSArray *sub = [[it objectForKey: @"submenu"] objectForKey: @"items"];
		NaplesPanel *n;
		if (![sub count]) break;
		prev = p;
		n = [self panelForItems: sub x: prev->x + prev->w - 2 top: prev->top + [[prev->rowTops objectAtIndex: row] doubleValue]];
		if (n->x + n->w > W) n->x = prev->x - n->w + 2;
		[out addObject: n];
		p = n;
	}
	return out;
}

- (CGFloat) desiredHeight
{
	CGFloat h = BarH;
	NaplesPanel *p;
	for (p in [self panels]) if (p->top + p->h > h) h = p->top + p->h;
	return h;
}

- (NSRect) viewRectForTopDown: (CGFloat)x top: (CGFloat)top w: (CGFloat)w h: (CGFloat)h
{
	return NSMakeRect(x, [self bounds].size.height - top - h, w, h);
}

- (NSArray *) shapeRects
{
	NSMutableArray *out = [NSMutableArray array];
	NaplesPanel *p;
	[out addObject: [NSValue valueWithRect: NSMakeRect(0, 0, [self bounds].size.width, BarH)]];
	for (p in [self panels]) [out addObject: [NSValue valueWithRect: NSMakeRect(p->x, p->top, p->w, p->h)]];
	return out;
}

/* ---- drawing ---- */

static void
drawCheck(NSRect r, NSInteger state, BOOL selected)
{
	NSBezierPath *p = [NSBezierPath bezierPath];
	[(selected ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: 0.08 alpha: 0.9]) set];
	[p setLineWidth: 1.6];
	if (state == 1) {
		[p moveToPoint: NSMakePoint(NSMinX(r) + 1, NSMidY(r))];
		[p lineToPoint: NSMakePoint(NSMinX(r) + 4, NSMidY(r) - 3)];
		[p lineToPoint: NSMakePoint(NSMinX(r) + 10, NSMidY(r) + 4)];
	} else {
		[p moveToPoint: NSMakePoint(NSMinX(r) + 2, NSMidY(r))];
		[p lineToPoint: NSMakePoint(NSMinX(r) + 9, NSMidY(r))];
	}
	[p stroke];
}

- (void) drawRect: (NSRect)dirty
{
	NSRect bounds = [self bounds];
	NSRect barR = NSMakeRect(0, bounds.size.height - BarH, bounds.size.width, BarH);
	NSArray *items = [self topItems], *panels = [self panels];
	NSImage *h = [bar hexley];
	NSUInteger k;
	NaplesPanel *p;
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
		NSRect hr = [self viewRectForTopDown: hexleyRect.origin.x top: 0 w: hexleyRect.size.width h: BarH];
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
		NSRect vr = [self viewRectForTopDown: r.origin.x top: 0 w: r.size.width h: BarH];
		if (sel) { [[NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1] set]; NSRectFill(vr); }
		[[it objectForKey: @"title"] drawAtPoint: NSMakePoint(vr.origin.x + 9, vr.origin.y + 4)
		                          withAttributes: textAttrs([[it objectForKey: @"enabled"] boolValue], sel, k == 0 && NO)];
	}

	localtime_r(&t, &tm);
	strftime(buf, sizeof buf, "%a %b %e  %l:%M %p", &tm);
	clock = [NSString stringWithUTF8String: buf];
	cs = [clock sizeWithAttributes: ca];
	[clock drawAtPoint: NSMakePoint(bounds.size.width - cs.width - 12, barR.origin.y + 4) withAttributes: ca];

	for (p in panels) {
		NSRect pr = [self viewRectForTopDown: p->x top: p->top w: p->w h: p->h];
		NSUInteger lvl = [panels indexOfObject: p], i;
		[[NSColor colorWithCalibratedWhite: 0.97 alpha: 0.98] set];
		[rounded(pr) fill];
		[[NSColor colorWithCalibratedWhite: 0 alpha: 0.35] set];
		[rounded(NSInsetRect(pr, 0.5, 0.5)) stroke];
		for (i = 0; i < [p->items count]; i++) {
			NSDictionary *it = [p->items objectAtIndex: i];
			CGFloat rt = [[p->rowTops objectAtIndex: i] doubleValue];
			NSRect rr = [self viewRectForTopDown: p->x + 4 top: p->top + rt w: p->w - 8 h: isSep(it) ? SepH : RowH];
			BOOL enabled = [[it objectForKey: @"enabled"] boolValue], sel;
			NSString *ks;
			if (isSep(it)) {
				[[NSColor colorWithCalibratedWhite: 0 alpha: 0.2] set];
				NSRectFill(NSMakeRect(rr.origin.x + 4, NSMidY(rr), rr.size.width - 8, 1));
				continue;
			}
			sel = enabled && ((NSInteger)lvl == hoverLevel && (NSInteger)i == hoverRow);
			if (!sel && lvl < [chain count] && (NSInteger)i == [[chain objectAtIndex: lvl] integerValue]) sel = enabled;
			if (sel) {
				[[NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1] set];
				[[NSBezierPath bezierPathWithRoundedRect: rr xRadius: 3 yRadius: 3] fill];
			}
			if ([[it objectForKey: @"state"] integerValue] != 0) drawCheck(NSMakeRect(rr.origin.x + 5, rr.origin.y, 12, rr.size.height), [[it objectForKey: @"state"] integerValue], sel);
			[[it objectForKey: @"title"] drawAtPoint: NSMakePoint(rr.origin.x + 20, rr.origin.y + 3) withAttributes: textAttrs(enabled, sel, NO)];
			if ((ks = keyString(it))) {
				NSDictionary *a = textAttrs(enabled, sel, NO);
				[ks drawAtPoint: NSMakePoint(NSMaxX(rr) - [ks sizeWithAttributes: a].width - 10, rr.origin.y + 3) withAttributes: a];
			}
			if ([it objectForKey: @"submenu"]) {	/* cascade arrow */
				NSBezierPath *ar = [NSBezierPath bezierPath];
				[(sel ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: 0.08 alpha: enabled ? 0.8 : 0.35]) set];
				[ar moveToPoint: NSMakePoint(NSMaxX(rr) - 12, NSMidY(rr) + 4)];
				[ar lineToPoint: NSMakePoint(NSMaxX(rr) - 7, NSMidY(rr))];
				[ar lineToPoint: NSMakePoint(NSMaxX(rr) - 12, NSMidY(rr) - 4)];
				[ar fill];
			}
		}
	}
}

/* ---- hit testing and mouse ---- */

/* returns the panel level and row under p (view coordinates), or level -1 */
- (void) panelHit: (NSPoint)p level: (NSInteger *)level row: (NSInteger *)row
{
	NSArray *panels = [self panels];
	NSInteger l;
	*level = -1; *row = -1;
	for (l = (NSInteger)[panels count] - 1; l >= 0; l--) {
		NaplesPanel *pn = [panels objectAtIndex: l];
		NSUInteger i;
		if (!NSPointInRect(p, [self viewRectForTopDown: pn->x top: pn->top w: pn->w h: pn->h])) continue;
		*level = l;
		for (i = 0; i < [pn->items count]; i++) {
			CGFloat rt = [[pn->rowTops objectAtIndex: i] doubleValue], hgt = isSep([pn->items objectAtIndex: i]) ? SepH : RowH;
			if (NSPointInRect(p, [self viewRectForTopDown: pn->x top: pn->top + rt w: pn->w h: hgt])) { *row = i; break; }
		}
		return;
	}
}

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
	[bar viewResized];
	[self setNeedsDisplay: YES];
}

- (void) closeMenu
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil];
	if (openTop == -1) return;
	openTop = -1; [chain removeAllObjects]; hoverLevel = hoverRow = -1;
	[bar viewResized];
	[self setNeedsDisplay: YES];
}

- (void) mouseDown: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	NSInteger level, row, b;
	[self panelHit: p level: &level row: &row];
	if (level >= 0) {
		NaplesPanel *pn = [[self panels] objectAtIndex: level];
		NSDictionary *it;
		NSMutableArray *path;
		NSInteger i;
		if (row < 0) return;
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
		return;
	}
	b = [self barHit: p];
	if (b == -1) { [self closeMenu]; return; }
	if (b == openTop) [self closeMenu];
	else [self openTopItem: b];
}

- (void) mouseMoved: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	NSInteger level, row, b;
	if (openTop == -1) return;
	[self panelHit: p level: &level row: &row];
	if (level >= 0) {
		NaplesPanel *pn = [[self panels] objectAtIndex: level];
		NSDictionary *it = row >= 0 ? [pn->items objectAtIndex: row] : nil;
		if (level != hoverLevel || row != hoverRow) {
			hoverLevel = level; hoverRow = row;
			while ((NSInteger)[chain count] > level) [chain removeLastObject];	/* close deeper cascades */
			if (it && !isSep(it) && [it objectForKey: @"submenu"] && [[it objectForKey: @"enabled"] boolValue])
				[chain addObject: [NSNumber numberWithInteger: row]];
			[bar viewResized];
			[self setNeedsDisplay: YES];
		}
		return;
	}
	b = [self barHit: p];
	if (b != -1 && b != openTop) [self openTopItem: b];	/* sliding along the bar switches menus */
}

- (void) mouseEntered: (NSEvent *)e { [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil]; }
- (void) mouseExited: (NSEvent *)e { if (openTop != -1) [self performSelector: @selector(closeMenu) withObject: nil afterDelay: 1.2]; }

- (void) retrack
{
	if (tracking) [self removeTrackingRect: trackTag];
	trackTag = [self addTrackingRect: [self bounds] owner: self userData: NULL assumeInside: NO];
	tracking = YES;
}

- (void) setFrameSize: (NSSize)s { [super setFrameSize: s]; if ([self window]) [self retrack]; }
- (void) viewDidMoveToWindow { if ([self window]) { [[self window] setAcceptsMouseMovedEvents: YES]; [self retrack]; } }

@end
