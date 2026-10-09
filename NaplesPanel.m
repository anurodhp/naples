#import "NaplesPanel.h"
#import "NaplesX.h"
#import <GNUstepGUI/GSDisplayServer.h>

enum { RowH = 20, SepH = 9, PanelPad = 4, MinPanelW = 150, Radius = 5 };

BOOL
NaplesIsSeparator(NSDictionary *item)
{
	return [[item objectForKey: @"isSeparator"] boolValue];
}

NSString *
NaplesKeyString(NSDictionary *item)
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

NSDictionary *
NaplesMenuTextAttrs(NaplesPanelStyle style, BOOL enabled, BOOL selected, BOOL bold)
{
	CGFloat base = style == NaplesPanelLight ? 0.08 : 1.0;
	NSColor *c = selected ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: base alpha: enabled ? 1.0 : 0.38];
	return [NSDictionary dictionaryWithObjectsAndKeys: bold ? [NSFont boldSystemFontOfSize: 12] : [NSFont systemFontOfSize: 12], NSFontAttributeName,
	        c, NSForegroundColorAttributeName, nil];
}

void
NaplesDrawCheck(NSRect r, NSInteger state, BOOL selected, NaplesPanelStyle style)
{
	NSBezierPath *p = [NSBezierPath bezierPath];
	[(selected ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: style == NaplesPanelLight ? 0.08 : 1.0 alpha: 0.9]) set];
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

@implementation NaplesPanel

+ (NaplesPanel *) panelWithItems: (NSArray *)items x: (CGFloat)x top: (CGFloat)top style: (NaplesPanelStyle)style
{
	NaplesPanel *p = [[[NaplesPanel alloc] init] autorelease];
	CGFloat y = PanelPad, w = MinPanelW;
	NSDictionary *it;
	p->items = [items retain];
	p->rowTops = [[NSMutableArray alloc] init];
	p->style = style;
	p->hoverRow = p->openRow = -1;
	for (it in items) {
		[p->rowTops addObject: [NSNumber numberWithDouble: y]];
		if (NaplesIsSeparator(it)) { y += SepH; continue; }
		{
			NSDictionary *a = NaplesMenuTextAttrs(style, YES, NO, NO);
			CGFloat tw = [[it objectForKey: @"title"] sizeWithAttributes: a].width + 36;
			NSString *k = NaplesKeyString(it);
			if (k) tw += [k sizeWithAttributes: a].width + 24;
			if (tw > w) w = tw;
		}
		y += RowH;
	}
	p->x = x; p->top = top; p->w = w; p->h = y + PanelPad;
	return p;
}

+ (NaplesPanel *) tipWithTitle: (NSString *)title x: (CGFloat)x top: (CGFloat)top
{
	NaplesPanel *p = [[[NaplesPanel alloc] init] autorelease];
	NSDictionary *it = [NSDictionary dictionaryWithObjectsAndKeys: title ? title : @"", @"title", [NSNumber numberWithBool: YES], @"enabled",
	                    [NSNumber numberWithInt: 0], @"state", nil];
	p->items = [[NSArray alloc] initWithObjects: it, nil];
	p->rowTops = [[NSMutableArray alloc] initWithObjects: [NSNumber numberWithDouble: 1], nil];
	p->style = NaplesPanelDark;
	p->compact = YES;
	p->hoverRow = p->openRow = -1;
	p->w = [title sizeWithAttributes: NaplesMenuTextAttrs(NaplesPanelDark, YES, NO, NO)].width + 20;
	p->h = RowH + 2;
	p->x = x; p->top = top;
	return p;
}

- (CGFloat) rowHeightAt: (NSUInteger)i { return NaplesIsSeparator([items objectAtIndex: i]) ? SepH : RowH; }

- (void) dealloc { [items release]; [rowTops release]; [super dealloc]; }

@end

/* ---- one panel's window ---- */

@interface NaplesPanelWindow : NSWindow
@end
@implementation NaplesPanelWindow
- (BOOL) canBecomeKeyWindow { return NO; }
- (BOOL) canBecomeMainWindow { return NO; }
@end

@interface NaplesPanelView : NSView {
	NaplesPanel *panel;
	NaplesPanelSet *set;
	NSInteger level;
	NSImage *backdrop;
	NSRect backdropFor;
	NSTrackingRectTag trackTag;
	BOOL tracking;
}
- (void) setPanel: (NaplesPanel *)p level: (NSInteger)l set: (NaplesPanelSet *)s;
@end

@interface NaplesPanelSet (Private)
- (id <NaplesPanelDelegate>) delegate;
@end

@implementation NaplesPanelView

- (BOOL) isFlipped { return NO; }
- (BOOL) isOpaque { return NO; }
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }

- (void) dealloc { [panel release]; [backdrop release]; [super dealloc]; }

- (void) setPanel: (NaplesPanel *)p level: (NSInteger)l set: (NaplesPanelSet *)s
{
	NSRect r = NSMakeRect(p->x, p->top, p->w, p->h);
	[panel release]; panel = [p retain];
	level = l; set = s;
	if (!backdrop || !NSEqualRects(r, backdropFor)) {	/* the wallpaper under the panel fills the corners the rounding leaves */
		[backdrop release];
		backdrop = [[[NaplesX shared] backgroundForRect: r] retain];
		backdropFor = r;
	}
	[self setNeedsDisplay: YES];
}

- (NSRect) rowRect: (NSUInteger)i
{
	CGFloat rt = [[panel->rowTops objectAtIndex: i] doubleValue], hgt = [panel rowHeightAt: i];
	return NSMakeRect(4, [self bounds].size.height - rt - hgt, [self bounds].size.width - 8, hgt);
}

- (void) drawRect: (NSRect)dirty
{
	NSRect b = [self bounds];
	NaplesPanelStyle st = panel ? panel->style : NaplesPanelLight;
	NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect: b xRadius: Radius yRadius: Radius];
	NSUInteger i;
	NSRectFillUsingOperation(dirty, NSCompositeClear);
	if (backdrop) {
		NSRect src = NSZeroRect;
		src.size = [backdrop size];
		[backdrop drawInRect: b fromRect: src operation: NSCompositeSourceOver fraction: 1.0];
	}
	if (st == NaplesPanelLight) [[NSColor colorWithCalibratedWhite: 0.97 alpha: 0.98] set];
	else [[NSColor colorWithCalibratedWhite: 0.12 alpha: 0.94] set];
	[outline fill];
	if (st == NaplesPanelLight) [[NSColor colorWithCalibratedWhite: 0 alpha: 0.35] set];
	else [[NSColor colorWithCalibratedWhite: 1 alpha: 0.3] set];
	[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(b, 0.5, 0.5) xRadius: Radius yRadius: Radius] stroke];
	for (i = 0; panel && i < [panel->items count]; i++) {
		NSDictionary *it = [panel->items objectAtIndex: i];
		NSRect rr = [self rowRect: i];
		BOOL enabled = [[it objectForKey: @"enabled"] boolValue], sel;
		NSString *ks;
		NSDictionary *a;
		if (NaplesIsSeparator(it)) {
			[[NSColor colorWithCalibratedWhite: st == NaplesPanelLight ? 0 : 1 alpha: 0.22] set];
			NSRectFill(NSMakeRect(rr.origin.x + 4, NSMidY(rr), rr.size.width - 8, 1));
			continue;
		}
		sel = enabled && ((NSInteger)i == panel->hoverRow || (NSInteger)i == panel->openRow);
		if (sel) {
			[[NSColor colorWithCalibratedRed: 0.2 green: 0.45 blue: 0.85 alpha: 1] set];
			[[NSBezierPath bezierPathWithRoundedRect: rr xRadius: 3 yRadius: 3] fill];
		}
		a = NaplesMenuTextAttrs(st, enabled, sel, NO);
		if ([[it objectForKey: @"state"] integerValue] != 0)
			NaplesDrawCheck(NSMakeRect(rr.origin.x + 5, rr.origin.y, 12, rr.size.height), [[it objectForKey: @"state"] integerValue], sel, st);
		[[it objectForKey: @"title"] drawAtPoint: NSMakePoint(rr.origin.x + (panel->compact ? 6 : 20), rr.origin.y + 3) withAttributes: a];
		if ((ks = NaplesKeyString(it)))
			[ks drawAtPoint: NSMakePoint(NSMaxX(rr) - [ks sizeWithAttributes: a].width - 10, rr.origin.y + 3) withAttributes: a];
		if ([it objectForKey: @"submenu"]) {	/* cascade arrow */
			NSBezierPath *ar = [NSBezierPath bezierPath];
			[(sel ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: st == NaplesPanelLight ? 0.08 : 1.0 alpha: enabled ? 0.8 : 0.35]) set];
			[ar moveToPoint: NSMakePoint(NSMaxX(rr) - 12, NSMidY(rr) + 4)];
			[ar lineToPoint: NSMakePoint(NSMaxX(rr) - 7, NSMidY(rr))];
			[ar lineToPoint: NSMakePoint(NSMaxX(rr) - 12, NSMidY(rr) - 4)];
			[ar fill];
		}
	}
}

- (NSInteger) rowAt: (NSPoint)p
{
	NSUInteger i;
	for (i = 0; panel && i < [panel->items count]; i++)
		if (NSPointInRect(p, [self rowRect: i])) return (NSInteger)i;
	return -1;
}

- (void) mouseMoved: (NSEvent *)e
{
	[[set delegate] panelSet: set level: level hoverRow: [self rowAt: [self convertPoint: [e locationInWindow] fromView: nil]]];
}

- (void) mouseDown: (NSEvent *)e
{
	[[set delegate] panelSet: set level: level clickedRow: [self rowAt: [self convertPoint: [e locationInWindow] fromView: nil]]];
}

- (void) mouseEntered: (NSEvent *)e { [[set delegate] panelSetPointerEntered: set]; }
- (void) mouseExited: (NSEvent *)e { [[set delegate] panelSetPointerExited: set]; }

- (void) retrack
{
	if (tracking) [self removeTrackingRect: trackTag];
	trackTag = [self addTrackingRect: [self bounds] owner: self userData: NULL assumeInside: NO];
	tracking = YES;
}

- (void) setFrameSize: (NSSize)s { [super setFrameSize: s]; if ([self window]) [self retrack]; }
- (void) viewDidMoveToWindow { if ([self window]) { [[self window] setAcceptsMouseMovedEvents: YES]; [self retrack]; } }

@end

/* ---- the set ---- */

@implementation NaplesPanelSet

- (id) initWithDelegate: (id <NaplesPanelDelegate>)d
{
	if ((self = [super init])) {
		delegate = d;
		windows = [[NSMutableArray alloc] init];
		shown = [[NSMutableArray alloc] init];
	}
	return self;
}

- (id <NaplesPanelDelegate>) delegate { return delegate; }
- (BOOL) isShowing { return [shown count] > 0; }
- (NSArray *) panels { return shown; }

- (void) showPanels: (NSArray *)panels
{
	NSRect scr = [[NSScreen mainScreen] frame];
	NSUInteger i;
	for (i = 0; i < [panels count]; i++) {
		NaplesPanel *p = [panels objectAtIndex: i];
		NSWindow *w;
		NaplesPanelView *v;
		NSRect frame = NSMakeRect(NSMinX(scr) + p->x, NSMaxY(scr) - p->top - p->h, p->w, p->h);
		if (i < [windows count]) {
			w = [windows objectAtIndex: i];
			v = (NaplesPanelView *)[w contentView];
		} else {
			w = [[[NaplesPanelWindow alloc] initWithContentRect: frame styleMask: NSBorderlessWindowMask backing: NSBackingStoreBuffered defer: NO] autorelease];
			v = [[[NaplesPanelView alloc] initWithFrame: NSMakeRect(0, 0, p->w, p->h)] autorelease];
			/* a dock-type window like the dock and bar: the window manager does not focus it or put it in the client list
			 * (NSPopUpMenuWindowLevel makes GNUstep tag it as a dialog, which Window Maker manages and focuses) */
			[w setLevel: NSStatusWindowLevel];
			[w setOpaque: NO];
			[w setBackgroundColor: [NSColor clearColor]];
			[w setHasShadow: NO];
			[w setReleasedWhenClosed: NO];
			[w setCanHide: NO];
			[w setContentView: v];
			[windows addObject: w];
			[[NaplesX shared] registerOwnWindow: (unsigned long)[GSCurrentServer() windowDevice: [w windowNumber]]];
		}
		if (!NSEqualRects(frame, [w frame])) {
			[w setFrame: frame display: NO];
			[v setFrame: NSMakeRect(0, 0, p->w, p->h)];
		}
		[v setPanel: p level: (NSInteger)i set: self];
		/* always, not only when not visible: after orderOut: the window can still count as visible and stay unmapped */
		[w orderFrontRegardless];
		[w display];
	}
	for (i = [panels count]; i < [windows count]; i++) [[windows objectAtIndex: i] orderOut: nil];
	[shown setArray: panels];
}

- (void) hide
{
	NSWindow *w;
	for (w in windows) [w orderOut: nil];
	[shown removeAllObjects];
}

@end
