#import "NaplesDockView.h"
#import "NaplesX.h"
#import "NaplesPanel.h"

enum { Pad = 6, Gap = 4, DividerLen = 10, OuterMargin = 13, InnerMargin = 11, BounceH = 9, Radius = 5, EntryH = 22, LongClickMs = 500 };

static NSBezierPath *
rounded(NSRect r)
{
	return [NSBezierPath bezierPathWithRoundedRect: r xRadius: Radius yRadius: Radius];
}

static BOOL
draggable(NaplesItem *it)
{
	return it->kind == NaplesItemApp && [it->path length];
}

@implementation NaplesDockView

- (id) initWithDock: (NaplesDock *)d
{
	if ((self = [super initWithFrame: NSMakeRect(0, 0, 100, 60)])) {
		dock = d;
		slots = [[NSMutableArray alloc] init];
		iconSize = 44;
		downIndex = -2; dropIndex = -1; dropAppIndex = -1; menuHover = -1; tipIndex = -2;
		[self registerForDraggedTypes: [NSArray arrayWithObjects: NaplesPboardType, NSFilenamesPboardType, nil]];
	}
	return self;
}

- (void) setBackdrop: (NSImage *)img
{
	if (img == backdrop) return;
	[backdrop release]; backdrop = [img retain];
	[self setNeedsDisplay: YES];
}

- (void) dealloc
{
	[backdrop release]; [items release]; [slots release]; [tipSet release]; [panelSet release]; [menuEntries release]; [downEvent release];
	[super dealloc];
}

- (BOOL) isFlipped { return NO; }
- (BOOL) isOpaque { return NO; }
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }

- (BOOL) horizontal { return edge == NaplesEdgeBottom; }

/* ---- layout ---- */

- (void) reloadItems: (NSArray *)newItems edge: (int)e maxLength: (CGFloat)maxLen
{
	NSInteger want = [[NSUserDefaults standardUserDefaults] integerForKey: @"NaplesIconSize"], total, i;
	NaplesItem *it;
	CGFloat pos;
	if (tipIndex >= (NSInteger)[newItems count]) [self hideTip];	/* not on every reload: a rebuild must not take the label away */
	[items release]; items = [newItems retain];
	edge = e;
	iconSize = want >= 24 && want <= 128 ? (int)want : 44;
	for (;;) {	/* shrink the icons until the bar fits on the screen */
		total = 2 * Pad - Gap;
		for (it in items) total += (it->kind == NaplesItemDivider ? DividerLen : iconSize) + Gap;
		if (total <= maxLen || iconSize <= 24) break;
		iconSize -= 2;
	}
	barSize = [self horizontal] ? NSMakeSize(total, iconSize + OuterMargin + InnerMargin)
	                            : NSMakeSize(iconSize + OuterMargin + InnerMargin, total);
	[slots removeAllObjects];
	pos = Pad;
	for (i = 0; i < (NSInteger)[items count]; i++) {
		CGFloat len;
		NSRect r;
		it = [items objectAtIndex: i];
		len = it->kind == NaplesItemDivider ? DividerLen : iconSize;
		if ([self horizontal]) r = NSMakeRect(pos, OuterMargin, len, iconSize);
		else r = NSMakeRect(edge == NaplesEdgeLeft ? OuterMargin : InnerMargin, total - pos - len, iconSize, len);
		[slots addObject: [NSValue valueWithRect: r]];
		pos += len + Gap;
	}
	{	/* the launch bounce runs on a 30 fps timer for as long as any icon is launching */
		BOOL any = NO;
		for (it in items) if (it->launchStart > 0) any = YES;
		if (any && !bounceTimer)
			bounceTimer = [NSTimer scheduledTimerWithTimeInterval: 1.0 / 30 target: self selector: @selector(bounceTick:) userInfo: nil repeats: YES];
		if (!any && bounceTimer) { [bounceTimer invalidate]; bounceTimer = nil; }
	}
	[self setNeedsDisplay: YES];
}

- (void) bounceTick: (NSTimer *)t
{
	NaplesItem *it;
	BOOL any = NO;
	for (it in items)
		if (it->launchStart > 0 && [NSDate timeIntervalSinceReferenceDate] - it->launchStart < 30) any = YES;
	if (!any) { [bounceTimer invalidate]; bounceTimer = nil; }
	[self setNeedsDisplay: YES];
}

- (NSSize) barSize { return barSize; }
- (BOOL) menuOpen { return [panelSet isShowing]; }
- (NSRect) barRect { return NSMakeRect(barOrigin.x, barOrigin.y, barSize.width, barSize.height); }

- (NSRect) slotRect: (NSInteger)i
{
	NSRect r = [[slots objectAtIndex: i] rectValue];
	r.origin.x += barOrigin.x; r.origin.y += barOrigin.y;
	return r;
}

- (void) setBarOrigin: (NSPoint)bar
{
	barOrigin = bar;
	[self setNeedsDisplay: YES];
}

/* index of the item under p (view coordinates); -1 the bar itself, -2 outside the bar */
- (NSInteger) hitIndex: (NSPoint)p
{
	NSInteger i;
	NSRect bar = [self barRect];
	if (!NSPointInRect(p, bar)) return -2;
	for (i = 0; i < (NSInteger)[items count]; i++) {
		NSRect r = [self slotRect: i];
		if (((NaplesItem *)[items objectAtIndex: i])->kind == NaplesItemDivider) continue;
		if ([self horizontal]) { r.origin.x -= Gap / 2.0; r.size.width += Gap; r.origin.y = bar.origin.y; r.size.height = bar.size.height; }
		else { r.origin.y -= Gap / 2.0; r.size.height += Gap; r.origin.x = bar.origin.x; r.size.width = bar.size.width; }
		if (NSPointInRect(p, r)) return i;
	}
	return -1;
}

/* where in the pinned list a drop at p would insert: after Milan, before the divider */
- (NSInteger) pinnedInsertionIndexForPoint: (NSPoint)p
{
	NSInteger i, idx = 0;
	for (i = 0; i < (NSInteger)[items count]; i++) {
		NaplesItem *it = [items objectAtIndex: i];
		NSRect r = [self slotRect: i];
		CGFloat before;
		if (it->kind != NaplesItemApp || !it->pinned) continue;
		before = [self horizontal] ? p.x - NSMidX(r) : NSMidY(r) - p.y;	/* > 0: the pointer is past this item */
		if (before > 0) idx = (NSInteger)[dock pinnedIndexOfPath: it->path] + 1;
		else break;
	}
	return idx;
}

/* ---- drawing ---- */

static void
drawTrash(NSRect r, BOOL full, CGFloat alpha)
{
	NSRect b = NSInsetRect(r, r.size.width * 0.22, r.size.height * 0.12);
	NSBezierPath *can = [NSBezierPath bezierPath];
	CGFloat x0 = NSMinX(b), x1 = NSMaxX(b), y0 = NSMinY(b), y1 = NSMaxY(b) - b.size.height * 0.2, i;
	[[NSColor colorWithCalibratedWhite: 1 alpha: alpha * 0.92] set];
	[can setLineWidth: 2];
	[can moveToPoint: NSMakePoint(x0 + 2, y1)];
	[can lineToPoint: NSMakePoint(x0 + b.size.width * 0.1, y0)];
	[can lineToPoint: NSMakePoint(x1 - b.size.width * 0.1, y0)];
	[can lineToPoint: NSMakePoint(x1 - 2, y1)];
	[can stroke];
	[can removeAllPoints];
	[can setLineWidth: 2.5];
	[can moveToPoint: NSMakePoint(x0 - 2, y1 + 2)]; [can lineToPoint: NSMakePoint(x1 + 2, y1 + 2)];
	[can moveToPoint: NSMakePoint(NSMidX(b) - b.size.width * 0.18, y1 + 2)];
	[can lineToPoint: NSMakePoint(NSMidX(b) - b.size.width * 0.18, NSMaxY(b))];
	[can lineToPoint: NSMakePoint(NSMidX(b) + b.size.width * 0.18, NSMaxY(b))];
	[can lineToPoint: NSMakePoint(NSMidX(b) + b.size.width * 0.18, y1 + 2)];
	[can stroke];
	[can removeAllPoints];
	[can setLineWidth: 1.5];
	for (i = 0.3; i < 0.8; i += 0.2) {	/* ribs */
		[can moveToPoint: NSMakePoint(x0 + b.size.width * i, y0 + 5)];
		[can lineToPoint: NSMakePoint(x0 + b.size.width * i, y1 - 4)];
	}
	[can stroke];
	if (full) {	/* paper sticking out of the top */
		NSBezierPath *p = [NSBezierPath bezierPath];
		[p setLineWidth: 2];
		[p moveToPoint: NSMakePoint(x0 + b.size.width * 0.25, y1 + 3)];
		[p lineToPoint: NSMakePoint(x0 + b.size.width * 0.15, NSMaxY(b) + 3)];
		[p moveToPoint: NSMakePoint(x1 - b.size.width * 0.25, y1 + 3)];
		[p lineToPoint: NSMakePoint(x1 - b.size.width * 0.05, NSMaxY(b) + 1)];
		[p stroke];
	}
}

static void
drawGeneric(NSRect r, NSString *name, CGFloat alpha)
{
	NSDictionary *attrs;
	NSString *s = [name length] ? [[name substringToIndex: 1] uppercaseString] : @"?";
	NSSize sz;
	[[NSColor colorWithCalibratedWhite: 0.78 alpha: alpha] set];
	[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(r, 2, 2) xRadius: 9 yRadius: 9] fill];
	attrs = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: r.size.height * 0.5], NSFontAttributeName,
	         [NSColor colorWithCalibratedWhite: 0.2 alpha: alpha], NSForegroundColorAttributeName, nil];
	sz = [s sizeWithAttributes: attrs];
	[s drawAtPoint: NSMakePoint(NSMidX(r) - sz.width / 2, NSMidY(r) - sz.height / 2) withAttributes: attrs];
}

- (void) drawIconOf: (NaplesItem *)it inRect: (NSRect)r alpha: (CGFloat)alpha
{
	if (it->kind == NaplesItemTrash) {	/* the same artwork Milan uses: the theme's empty / full recycler */
		NSImage *ti = [NSImage imageNamed: it->trashFull ? @"common_RecyclerFull" : @"common_RecyclerEmpty"];
		if (ti) {
			NSRect src = NSZeroRect;
			src.size = [ti size];
			[ti drawInRect: r fromRect: src operation: NSCompositeSourceOver fraction: alpha];
		} else {
			drawTrash(r, it->trashFull, alpha);	/* no theme image: the drawn can, with paper when full */
		}
		return;
	}
	if (it->icon) {
		NSRect src = NSZeroRect;
		src.size = [it->icon size];
		[it->icon drawInRect: r fromRect: src operation: NSCompositeSourceOver fraction: alpha];
	} else {
		drawGeneric(r, it->name, alpha);
	}
}

- (void) drawRect: (NSRect)dirty
{
	NSRect bar = [self barRect];
	NSInteger i;
	NSRectFillUsingOperation(dirty, NSCompositeClear);

	/* the bar: translucent, 5px corners (XShape cuts the window to the same outline) */
	if (backdrop) {	/* translucent: the wallpaper under the bar, darkened */
		NSRect src = NSZeroRect;
		src.size = [backdrop size];
		/* the wallpaper over the whole window first: what the rounded corners leave outside the bar is then the desktop's
		 * own picture, not the black this server leaves where a shaped window is cut */
		[backdrop drawInRect: bar fromRect: src operation: NSCompositeSourceOver fraction: 1.0];
		[NSGraphicsContext saveGraphicsState];
		[rounded(bar) addClip];
		[[NSColor colorWithCalibratedWhite: 0.05 alpha: 0.38] set];
		NSRectFillUsingOperation(bar, NSCompositeSourceOver);
		[NSGraphicsContext restoreGraphicsState];
	} else {
		[[NSColor colorWithCalibratedWhite: 0.10 alpha: 0.45] set];
		[rounded(bar) fill];
	}
	[[NSColor colorWithCalibratedWhite: 1.0 alpha: 0.28] set];
	[rounded(NSInsetRect(bar, 0.5, 0.5)) stroke];

	for (i = 0; i < (NSInteger)[items count]; i++) {
		NaplesItem *it = [items objectAtIndex: i];
		NSRect r = [self slotRect: i];
		CGFloat alpha = (dragging && i == dragSource) ? 0.35 : 1.0;
		if (it->kind == NaplesItemDivider) {
			[[NSColor colorWithCalibratedWhite: 1 alpha: 0.35] set];
			if ([self horizontal]) NSRectFill(NSMakeRect(NSMidX(r), NSMinY(r) + 4, 1, r.size.height - 8));
			else NSRectFill(NSMakeRect(NSMinX(r) + 4, NSMidY(r), r.size.width - 8, 1));
			continue;
		}
		if ((it->kind == NaplesItemTrash && dropOnTrash) || i == dropAppIndex || (i == downIndex && !dragging && !movingDock)) {
			[[NSColor colorWithCalibratedWhite: 1 alpha: i == downIndex ? 0.12 : 0.28] set];
			[rounded(NSInsetRect(r, -2, -2)) fill];
		}
		if (it->kind == NaplesItemWindow) {	/* a minimized window: the app's icon with a small window glyph */
			NSRect small = NSInsetRect(r, r.size.width * 0.08, r.size.height * 0.08), g;
			[self drawIconOf: it inRect: small alpha: 0.85];
			g = NSMakeRect(NSMaxX(r) - 17, NSMinY(r) - 1, 16, 11);
			[[NSColor colorWithCalibratedWhite: 0.1 alpha: 0.85] set]; NSRectFill(g);
			[[NSColor whiteColor] set]; NSFrameRect(g);
			NSRectFill(NSMakeRect(g.origin.x, NSMaxY(g) - 3, g.size.width, 3));
		} else {
			if (it->launchStart > 0 && [NSDate timeIntervalSinceReferenceDate] - it->launchStart < 30) {	/* hop away from the screen edge, one hop every 0.6 s */
				CGFloat t = [NSDate timeIntervalSinceReferenceDate] - it->launchStart, off = BounceH * fabs(sin(t * M_PI / 0.6));
				if ([self horizontal]) r.origin.y += off;
				else if (edge == NaplesEdgeLeft) r.origin.x += off;
				else r.origin.x -= off;
			}
			[self drawIconOf: it inRect: r alpha: alpha];
		}
		if ([it running]) {	/* the white dot sits between the icon and the screen edge */
			NSRect d;
			if ([self horizontal]) d = NSMakeRect(NSMidX(r) - 2, bar.origin.y + 4, 4, 4);
			else if (edge == NaplesEdgeLeft) d = NSMakeRect(bar.origin.x + 4, NSMidY(r) - 2, 4, 4);
			else d = NSMakeRect(NSMaxX(bar) - 8, NSMidY(r) - 2, 4, 4);
			[[NSColor whiteColor] set];
			[[NSBezierPath bezierPathWithOvalInRect: d] fill];
		}
	}

	if (dropIndex >= 0 && [items count] > (NSUInteger)dropIndex + 1) {	/* insertion marker before the slot at items[1 + dropIndex] */
		NSRect r = [self slotRect: 1 + dropIndex];
		[[NSColor colorWithCalibratedRed: 0.35 green: 0.65 blue: 1 alpha: 1] set];
		if ([self horizontal]) NSRectFill(NSMakeRect(NSMinX(r) - Gap / 2.0 - 1, NSMinY(r), 2, r.size.height));
		else NSRectFill(NSMakeRect(NSMinX(r), NSMaxY(r) + Gap / 2.0 - 1, r.size.width, 2));
	}
}

/* ---- the long-click menu: a panel window next to the item (NaplesPanel), actions run from the entries ---- */

/* puts a panel next to a slot (or the pointer when the slot is zero), on the side away from the screen edge, inside the screen */
- (void) place: (NaplesPanel *)panel besideSlot: (NSRect)slot pointer: (NSPoint)p gap: (CGFloat)gap
{
	NSRect scr = [[NSScreen mainScreen] frame], wf = [[self window] frame], bar, m;
	NSPoint c;
	int dockEdge = [dock edge];
	bar = NSMakeRect(wf.origin.x + barOrigin.x, wf.origin.y + barOrigin.y, barSize.width, barSize.height);
	c = NSEqualRects(slot, NSZeroRect) ? NSMakePoint(bar.origin.x + p.x, bar.origin.y + p.y) : NSMakePoint(NSMidX(slot) + bar.origin.x, NSMidY(slot) + bar.origin.y);
	if (dockEdge == NaplesEdgeBottom) m = NSMakeRect(c.x - panel->w / 2, NSMaxY(bar) + gap, panel->w, panel->h);
	else if (dockEdge == NaplesEdgeLeft) m = NSMakeRect(NSMaxX(bar) + gap, c.y - panel->h / 2, panel->w, panel->h);
	else m = NSMakeRect(bar.origin.x - gap - panel->w, c.y - panel->h / 2, panel->w, panel->h);
	if (NSMaxX(m) > NSMaxX(scr)) m.origin.x = NSMaxX(scr) - m.size.width;
	if (NSMinX(m) < NSMinX(scr)) m.origin.x = NSMinX(scr);
	if (NSMaxY(m) > NSMaxY(scr)) m.origin.y = NSMaxY(scr) - m.size.height;
	if (NSMinY(m) < NSMinY(scr)) m.origin.y = NSMinY(scr);
	panel->x = m.origin.x - scr.origin.x;
	panel->top = NSMaxY(scr) - NSMaxY(m);
}

/* ---- the name tip: a small label panel after the pointer rests on an item ---- */

- (void) hideTip
{
	if ([tipSet isShowing] && [[NSUserDefaults standardUserDefaults] boolForKey: @"NaplesDebug"]) NSLog(@"Naples dock: hideTip (was showing)");
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(showTip) object: nil];
	[tipSet hide];
}

- (void) showTip
{
	NaplesItem *it;
	NaplesPanel *p;
	if (tipIndex < 0 || tipIndex >= (NSInteger)[items count] || [self menuOpen] || dragging || movingDock) return;
	it = [items objectAtIndex: tipIndex];
	if ([[NSUserDefaults standardUserDefaults] boolForKey: @"NaplesDebug"]) NSLog(@"Naples dock: showTip %@", it->name);
	if (it->kind == NaplesItemDivider || ![it->name length]) return;
	p = [NaplesPanel tipWithTitle: it->name x: 0 top: 0];
	[self place: p besideSlot: [[slots objectAtIndex: tipIndex] rectValue] pointer: NSZeroPoint gap: 6];
	if (!tipSet) tipSet = [[NaplesPanelSet alloc] initWithDelegate: self];
	[tipSet showPanels: [NSArray arrayWithObject: p]];
	[self performSelector: @selector(hideTip) withObject: nil afterDelay: 4.0];	/* never left behind if the pointer left without a Leave event */
}

- (void) mouseMoved: (NSEvent *)e
{
	NSInteger i = [self hitIndex: [self convertPoint: [e locationInWindow] fromView: nil]];
	if ([[NSUserDefaults standardUserDefaults] boolForKey: @"NaplesDebug"]) NSLog(@"Naples dock: mouseMoved index %ld (tip %ld)", (long)i, (long)tipIndex);
	if (i == tipIndex) return;
	[self hideTip];
	tipIndex = i;
	if (i >= 0 && ![self menuOpen]) [self performSelector: @selector(showTip) withObject: nil afterDelay: 0.4];
}

- (void) openMenuWithEntries: (NSArray *)entries anchor: (NSRect)slot pointer: (NSPoint)p
{
	NSMutableArray *dicts = [NSMutableArray array];
	NaplesMenuEntry *e;
	NaplesPanel *panel;
	if (![entries count]) return;
	for (e in entries)
		[dicts addObject: [NSDictionary dictionaryWithObjectsAndKeys: e->title, @"title", [NSNumber numberWithBool: YES], @"enabled",
		                   [NSNumber numberWithInt: 0], @"state", nil]];
	[menuEntries release]; menuEntries = [entries retain];
	menuHover = -1;
	panel = [NaplesPanel panelWithItems: dicts x: 0 top: 0 style: NaplesPanelDark];
	[self place: panel besideSlot: slot pointer: p gap: 4];
	if (!panelSet) panelSet = [[NaplesPanelSet alloc] initWithDelegate: self];
	[panelSet showPanels: [NSArray arrayWithObject: panel]];
}

- (void) closeMenu
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil];
	if (![panelSet isShowing]) return;
	[panelSet hide];
	[menuEntries release]; menuEntries = nil;
	[self setNeedsDisplay: YES];
}

- (void) panelSet: (id)set level: (NSInteger)level hoverRow: (NSInteger)row
{
	NaplesPanel *p = set == tipSet ? nil : [[panelSet panels] firstObject];
	if (!p || p->hoverRow == row) return;
	p->hoverRow = row;
	[panelSet showPanels: [panelSet panels]];
}

- (void) panelSet: (id)set level: (NSInteger)level clickedRow: (NSInteger)row
{
	NaplesMenuEntry *entry;
	if (set == tipSet || row < 0 || row >= (NSInteger)[menuEntries count]) return;
	entry = [[menuEntries objectAtIndex: row] retain];
	[self closeMenu];
	if (entry->action) entry->action();
	[entry release];
}

- (void) panelSetPointerEntered: (id)set { if (set != tipSet) [self mouseEntered: nil]; }
- (void) panelSetPointerExited: (id)set { if (set != tipSet) [self mouseExited: nil]; }

- (void) showMenuForIndex: (NSInteger)i
{
	NaplesItem *it = i >= 0 ? [items objectAtIndex: i] : nil;
	NSRect bar = [self barRect];
	NSPoint p = [self convertPoint: [[self window] mouseLocationOutsideOfEventStream] fromView: nil];
	NSArray *entries;
	if (i == -2 || (it && it->kind == NaplesItemDivider)) return;
	entries = [dock menuEntriesForItem: it];
	[self openMenuWithEntries: entries
	                   anchor: i >= 0 ? [[slots objectAtIndex: i] rectValue] : NSZeroRect
	                  pointer: NSMakePoint(p.x - bar.origin.x, p.y - bar.origin.y)];
}

- (void) longClick
{
	longFired = YES;
	[self showMenuForIndex: downIndex];
}

/* the menu closes a moment after the pointer leaves the dock */
- (void) mouseEntered: (NSEvent *)e { [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil]; }
- (void) mouseExited: (NSEvent *)e { [self hideTip]; tipIndex = -2; if ([self menuOpen]) [self performSelector: @selector(closeMenu) withObject: nil afterDelay: 1.5]; }

- (void) retrack
{
	if (tracking) [self removeTrackingRect: trackTag];
	trackTag = [self addTrackingRect: [self bounds] owner: self userData: NULL assumeInside: NO];
	tracking = YES;
}

- (void) setFrameSize: (NSSize)s { [super setFrameSize: s]; if ([self window]) [self retrack]; }
- (void) viewDidMoveToWindow { if ([self window]) { [[self window] setAcceptsMouseMovedEvents: YES]; [self retrack]; } }

/* ---- mouse ---- */

static int
edgeForPoint(NSPoint p)
{
	NSSize s = [[NSScreen mainScreen] frame].size;
	CGFloat dl = p.x / s.width, dr = (s.width - p.x) / s.width, db = p.y / s.height;
	if (db <= dl && db <= dr) return NaplesEdgeBottom;
	return dl <= dr ? NaplesEdgeLeft : NaplesEdgeRight;
}

- (void) mouseDown: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	[self hideTip];
	if ([self menuOpen]) { [self closeMenu]; return; }
	[downEvent release]; downEvent = [e retain];
	downPoint = [NSEvent mouseLocation];
	downIndex = [self hitIndex: p];
	dragging = movingDock = longFired = NO;
	if (downIndex != -2)
		[self performSelector: @selector(longClick) withObject: nil afterDelay: LongClickMs / 1000.0];
	[self setNeedsDisplay: YES];
}

- (void) rightMouseDown: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(longClick) object: nil];
	[self closeMenu];
	downIndex = -2;
	[self showMenuForIndex: [self hitIndex: p]];
}

- (void) mouseDragged: (NSEvent *)e
{
	NSPoint cur = [NSEvent mouseLocation];
	if (longFired || dragging) return;
	if (!movingDock && hypot(cur.x - downPoint.x, cur.y - downPoint.y) > 5) {
		[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(longClick) object: nil];
		if (downIndex >= 0 && draggable([items objectAtIndex: downIndex])) {
			[self beginDragOfIndex: downIndex event: e];
			return;
		}
		if (downIndex == -1) movingDock = YES;
		else return;
	}
	if (movingDock) {
		int ne = edgeForPoint(cur);
		if (ne != [dock edge]) [dock setEdge: ne persist: NO];
	}
}

- (void) mouseUp: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	NSInteger hit = [self hitIndex: p], was = downIndex;
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(longClick) object: nil];
	downIndex = -2;
	[self setNeedsDisplay: YES];
	if (longFired) { longFired = NO; return; }
	if (movingDock) { movingDock = NO; [dock setEdge: [dock edge] persist: YES]; return; }
	if (dragging) return;
	if (was >= 0 && hit == was) [dock activateItem: [items objectAtIndex: was]];
}

/* ---- dragging out of / within the dock ---- */

- (void) beginDragOfIndex: (NSInteger)i event: (NSEvent *)e
{
	NaplesItem *it = [items objectAtIndex: i];
	NSPasteboard *pb = [NSPasteboard pasteboardWithName: NSDragPboard];
	NSImage *img = it->icon ? [[it->icon copy] autorelease] : [[[NSImage alloc] initWithSize: NSMakeSize(iconSize, iconSize)] autorelease];
	NSRect r = [self slotRect: i];
	if (!it->icon) {
		[img lockFocus]; drawGeneric(NSMakeRect(0, 0, iconSize, iconSize), it->name, 1); [img unlockFocus];
	}
	[img setSize: NSMakeSize(iconSize, iconSize)];
	[pb declareTypes: [NSArray arrayWithObject: NaplesPboardType] owner: nil];
	[pb setString: it->path forType: NaplesPboardType];
	dragging = YES; dragSource = i;
	[dock holdLayout: YES];	/* the window must not move or resize under the drag session */
	[self setNeedsDisplay: YES];
	[self dragImage: img at: r.origin offset: NSZeroSize event: e pasteboard: pb source: self slideBack: NO];
}

- (NSDragOperation) draggingSourceOperationMaskForLocal: (BOOL)isLocal { return NSDragOperationMove; }

- (void) finishDrag: (NSPoint)ignored operation: (NSDragOperation)op
{
	NaplesItem *it = (dragging && dragSource < (NSInteger)[items count]) ? [items objectAtIndex: dragSource] : nil;
	NSRect bar = [self barRect], wf = [[self window] frame];
	NSRect winBar = NSMakeRect(wf.origin.x + bar.origin.x, wf.origin.y + bar.origin.y, bar.size.width, bar.size.height);
	/* the pointer, not the point GNUstep passes (that is the drag image's corner, up to an icon away) */
	NSPoint pointer = [NSEvent mouseLocation];
	BOOL handled = dropHandled;
	dragging = NO; dropIndex = dropAppIndex = -1; dropOnTrash = NO; dropHandled = NO;
	downIndex = -2;
	/* let go outside the dock, and nothing in the dock took the drop: the app leaves the dock (a running program stays
	 * as a running item). The operation GNUstep reports is not used: it is None or stale depending on the last target. */
	if (it && it->pinned && !handled && !NSPointInRect(pointer, NSInsetRect(winBar, -6, -6)))
		[dock unpinPath: it->path];
	[dock holdLayout: NO];
	[self setNeedsDisplay: YES];
}

- (void) draggedImage: (NSImage *)img endedAt: (NSPoint)p operation: (NSDragOperation)op { [self finishDrag: p operation: op]; }
- (void) draggedImage: (NSImage *)img endedAt: (NSPoint)p deposited: (BOOL)ok { [self finishDrag: p operation: ok ? NSDragOperationMove : NSDragOperationNone]; }

/* ---- drops onto the dock ---- */

static BOOL
allApps(NSArray *files)
{
	NSString *f;
	BOOL isDir;
	if (![files count]) return NO;
	for (f in files)
		if (![[f pathExtension] isEqualToString: @"app"] || ![[NSFileManager defaultManager] fileExistsAtPath: f isDirectory: &isDir] || !isDir)
			return NO;
	return YES;
}

- (NSDragOperation) evaluateDrag: (id <NSDraggingInfo>)s
{
	NSPasteboard *pb = [s draggingPasteboard];
	BOOL internal = [[pb types] containsObject: NaplesPboardType];
	NSPoint p = [self convertPoint: [s draggingLocation] fromView: nil];
	NSInteger idx = [self hitIndex: p];
	NaplesItem *it = idx >= 0 ? [items objectAtIndex: idx] : nil;
	NSArray *files = internal ? nil : [pb propertyListForType: NSFilenamesPboardType];
	NSDragOperation op = NSDragOperationNone;
	dropIndex = dropAppIndex = -1; dropOnTrash = NO;
	if (idx == -2) goto done;
	if (it && it->kind == NaplesItemTrash) { dropOnTrash = YES; op = NSDragOperationMove; }
	else if (internal) { dropIndex = [self pinnedInsertionIndexForPoint: p]; op = NSDragOperationMove; }
	else if (allApps(files)) { dropIndex = [self pinnedInsertionIndexForPoint: p]; op = NSDragOperationCopy; }
	else if ([files count] && it && (it->kind == NaplesItemApp || it->kind == NaplesItemMilan)) { dropAppIndex = idx; op = NSDragOperationCopy; }
done:
	[self setNeedsDisplay: YES];
	return op;
}

- (NSDragOperation) draggingEntered: (id <NSDraggingInfo>)s { return [self evaluateDrag: s]; }
- (NSDragOperation) draggingUpdated: (id <NSDraggingInfo>)s { return [self evaluateDrag: s]; }
- (void) draggingExited: (id <NSDraggingInfo>)s { dropIndex = dropAppIndex = -1; dropOnTrash = NO; [self setNeedsDisplay: YES]; }

- (BOOL) performDragOperation: (id <NSDraggingInfo>)s
{
	NSPasteboard *pb = [s draggingPasteboard];
	BOOL internal = [[pb types] containsObject: NaplesPboardType];
	NSDragOperation op = [self evaluateDrag: s];
	NSInteger idx = dropIndex, appIdx = dropAppIndex;
	BOOL trash = dropOnTrash;
	NSArray *files = internal ? [NSArray arrayWithObject: [pb stringForType: NaplesPboardType]] : [pb propertyListForType: NSFilenamesPboardType];
	NSString *f;
	dropIndex = dropAppIndex = -1; dropOnTrash = NO;
	[self setNeedsDisplay: YES];
	if (op == NSDragOperationNone) return NO;
	dropHandled = YES;
	[dock holdLayout: YES];
	if (!dragging) NaplesRunOnMain(^{ [dock holdLayout: NO]; });	/* drags from elsewhere: after the drag machinery has returned; our own end in finishDrag */
	if (trash) {
		if (internal) [dock unpinPath: [files objectAtIndex: 0]];
		else [dock trashPaths: files];
	} else if (idx >= 0) {
		for (f in files) { [dock pinPath: f atIndex: idx]; idx = [dock pinnedIndexOfPath: f] + 1; }
	} else if (appIdx >= 0) {
		for (f in files) [dock openFile: f withItem: [items objectAtIndex: appIdx]];
	}
	return YES;
}

@end
