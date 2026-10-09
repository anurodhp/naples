#import "NaplesDockView.h"
#import "NaplesX.h"

enum { Pad = 6, Gap = 4, DividerLen = 10, OuterMargin = 13, InnerMargin = 5, Radius = 5, EntryH = 22, LongClickMs = 500 };

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
		downIndex = -2; dropIndex = -1; dropAppIndex = -1; menuHover = -1;
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
	[backdrop release]; [items release]; [slots release]; [menuEntries release]; [downEvent release];
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
	[self setNeedsDisplay: YES];
}

- (NSSize) barSize { return barSize; }
- (BOOL) menuOpen { return menuEntries != nil; }
- (NSSize) menuSize { return menuSize; }
- (NSRect) menuAnchor { return menuAnchor; }
- (NSPoint) menuPointer { return menuPointer; }
- (NSRect) barRect { return NSMakeRect(barOrigin.x, barOrigin.y, barSize.width, barSize.height); }
- (NSRect) menuRect { return NSMakeRect(menuOrigin.x, menuOrigin.y, menuSize.width, menuSize.height); }

- (NSRect) slotRect: (NSInteger)i
{
	NSRect r = [[slots objectAtIndex: i] rectValue];
	r.origin.x += barOrigin.x; r.origin.y += barOrigin.y;
	return r;
}

- (void) setBarOrigin: (NSPoint)bar menuOrigin: (NSPoint)menu
{
	NSInteger i;
	barOrigin = bar; menuOrigin = menu;
	[self removeAllToolTips];
	for (i = 0; i < (NSInteger)[items count]; i++) {
		NaplesItem *it = [items objectAtIndex: i];
		if (it->kind != NaplesItemDivider)
			[self addToolTipRect: [self slotRect: i] owner: self userData: (void *)(NSUInteger)i];
	}
	[self setNeedsDisplay: YES];
}

- (NSString *) view: (NSView *)v stringForToolTip: (NSToolTipTag)tag point: (NSPoint)p userData: (void *)ud
{
	NSUInteger i = (NSUInteger)ud;
	return i < [items count] ? [dock toolTipForItem: [items objectAtIndex: i]] : nil;
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
	if (it->kind == NaplesItemTrash) { drawTrash(r, it->trashFull, alpha); return; }
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
		[NSGraphicsContext saveGraphicsState];
		[rounded(bar) addClip];
		[backdrop drawInRect: bar fromRect: src operation: NSCompositeSourceOver fraction: 1.0];
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

	if ([self menuOpen]) {
		NSRect m = [self menuRect];
		NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 12], NSFontAttributeName,
		                       [NSColor whiteColor], NSForegroundColorAttributeName, nil];
		[[NSColor colorWithCalibratedWhite: 0.12 alpha: 0.92] set];
		[rounded(m) fill];
		[[NSColor colorWithCalibratedWhite: 1 alpha: 0.3] set];
		[rounded(NSInsetRect(m, 0.5, 0.5)) stroke];
		for (i = 0; i < (NSInteger)[menuEntries count]; i++) {
			NaplesMenuEntry *e = [menuEntries objectAtIndex: i];
			NSRect er = NSMakeRect(m.origin.x + 4, NSMaxY(m) - 4 - EntryH * (i + 1), m.size.width - 8, EntryH);
			if (i == menuHover) {
				[[NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1] set];
				[[NSBezierPath bezierPathWithRoundedRect: er xRadius: 3 yRadius: 3] fill];
			}
			[e->title drawAtPoint: NSMakePoint(er.origin.x + 8, er.origin.y + 4) withAttributes: attrs];
		}
	}
}

/* ---- the long-click menu ---- */

- (void) openMenuWithEntries: (NSArray *)entries anchor: (NSRect)slot pointer: (NSPoint)p
{
	NSDictionary *attrs = [NSDictionary dictionaryWithObject: [NSFont systemFontOfSize: 12] forKey: NSFontAttributeName];
	CGFloat w = 120;
	NaplesMenuEntry *e;
	if (![entries count]) return;
	for (e in entries) {
		CGFloat tw = [e->title sizeWithAttributes: attrs].width + 28;
		if (tw > w) w = tw;
	}
	[menuEntries release]; menuEntries = [entries retain];
	menuSize = NSMakeSize(w, 8 + EntryH * [entries count]);
	menuAnchor = slot; menuPointer = p; menuHover = -1;
	[dock menuChanged];
}

- (void) closeMenu
{
	if (!menuEntries) return;
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil];
	[menuEntries release]; menuEntries = nil;
	[dock menuChanged];
	[self setNeedsDisplay: YES];
}

- (NSInteger) menuIndexAt: (NSPoint)p
{
	NSRect m = [self menuRect];
	NSInteger i;
	if (![self menuOpen] || !NSPointInRect(p, m)) return -1;
	i = (NSInteger)((NSMaxY(m) - 4 - p.y) / EntryH);
	return i >= 0 && i < (NSInteger)[menuEntries count] ? i : -1;
}

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

- (void) mouseMoved: (NSEvent *)e
{
	NSInteger h = [self menuIndexAt: [self convertPoint: [e locationInWindow] fromView: nil]];
	if (h != menuHover) { menuHover = h; [self setNeedsDisplay: YES]; }
}

/* the menu closes a moment after the pointer leaves the dock */
- (void) mouseEntered: (NSEvent *)e { [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(closeMenu) object: nil]; }
- (void) mouseExited: (NSEvent *)e { if ([self menuOpen]) [self performSelector: @selector(closeMenu) withObject: nil afterDelay: 1.5]; }

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
	if ([self menuOpen]) {
		NSInteger m = [self menuIndexAt: p];
		if (m >= 0) {
			NaplesMenuEntry *entry = [[menuEntries objectAtIndex: m] retain];
			[self closeMenu];
			if (entry->action) entry->action();
			[entry release];
			return;
		}
		[self closeMenu];
		return;
	}
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
	[self setNeedsDisplay: YES];
	[self dragImage: img at: r.origin offset: NSZeroSize event: e pasteboard: pb source: self slideBack: NO];
}

- (NSDragOperation) draggingSourceOperationMaskForLocal: (BOOL)isLocal { return NSDragOperationMove; }

- (void) finishDrag: (NSPoint)screenPoint operation: (NSDragOperation)op
{
	NaplesItem *it = (dragging && dragSource < (NSInteger)[items count]) ? [items objectAtIndex: dragSource] : nil;
	NSRect bar = [self barRect];
	NSRect winBar = NSMakeRect([[self window] frame].origin.x + bar.origin.x, [[self window] frame].origin.y + bar.origin.y,
	                           bar.size.width, bar.size.height);
	dragging = NO; dropIndex = dropAppIndex = -1; dropOnTrash = NO;
	downIndex = -2;
	/* let go outside the dock: the app leaves the dock (a running program stays as a running item) */
	if (it && it->pinned && op == NSDragOperationNone && !NSPointInRect(screenPoint, winBar))
		[dock unpinPath: it->path];
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
