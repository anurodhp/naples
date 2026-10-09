#import "NaplesBar.h"
#import "NaplesBarView.h"
#import "NaplesDock.h"
#import "NaplesX.h"
#import <GNUstepGUI/GSDisplayServer.h>

NSString *const NaplesMenuServerName = @"org.gnustep.Gershwin.MenuServer";
NSString *const NaplesMenuClientPrefix = @"org.gnustep.Gershwin.MenuClient.";

@interface NaplesBarWindow : NSWindow
@end
@implementation NaplesBarWindow
- (BOOL) canBecomeKeyWindow { return NO; }
- (BOOL) canBecomeMainWindow { return NO; }
@end

static NSNumber *
windowKey(unsigned long xid)
{
	return [NSNumber numberWithUnsignedInt: (uint32_t)xid];	/* Eau sends the X window id as an unsigned int */
}

/* Eau's validateMenuStateForWindow: answers with @[title, enabled, state] for every titled, non-separator item in
 * depth-first order; fold that back into a menu tree */
static NSDictionary *
applyStates(NSDictionary *menu, NSArray *flat, NSUInteger *pos)
{
	NSMutableArray *items = [NSMutableArray array];
	NSDictionary *it;
	for (it in [menu objectForKey: @"items"]) {
		NSMutableDictionary *m;
		NSString *title = [it objectForKey: @"title"];
		if ([[it objectForKey: @"isSeparator"] boolValue] || ![title length]) { [items addObject: it]; continue; }
		m = [[it mutableCopy] autorelease];
		if (*pos < [flat count]) {
			NSArray *t = [flat objectAtIndex: (*pos)++];
			if ([t count] == 3 && [[t objectAtIndex: 0] isEqual: title]) {
				[m setObject: [t objectAtIndex: 1] forKey: @"enabled"];
				[m setObject: [t objectAtIndex: 2] forKey: @"state"];
			}
		}
		if ([it objectForKey: @"submenu"]) [m setObject: applyStates([it objectForKey: @"submenu"], flat, pos) forKey: @"submenu"];
		[items addObject: m];
	}
	return [NSDictionary dictionaryWithObjectsAndKeys: [menu objectForKey: @"title"] ? [menu objectForKey: @"title"] : @"", @"title",
	        items, @"items", nil];
}

static NSDictionary *
localItem(NSString *title, BOOL enabled, void (^blk)(void))
{
	NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObjectsAndKeys: title, @"title", [NSNumber numberWithBool: enabled], @"enabled",
	                          [NSNumber numberWithInt: 0], @"state", nil];
	if (blk) [d setObject: [[blk copy] autorelease] forKey: @"block"];
	return d;
}

static NSDictionary *
localSeparator(void)
{
	return [NSDictionary dictionaryWithObject: [NSNumber numberWithBool: YES] forKey: @"isSeparator"];
}

@implementation NaplesBar

- (id) initWithDock: (NaplesDock *)d
{
	if ((self = [super init])) {
		dock = d;
		windowMenus = [[NSMutableDictionary alloc] init];
		appMenus = [[NSMutableDictionary alloc] init];
		proxies = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (NSImage *) hexley
{
	if (!loadedHexley) {
		NSString *p = [[NSBundle mainBundle] pathForResource: @"hexley_head" ofType: @"png"];
		loadedHexley = YES;
		if (p) hexleyImage = [[NSImage alloc] initWithContentsOfFile: p];
	}
	return hexleyImage;
}

/* ---- start ---- */

- (void) start
{
	NSRect scr = [[NSScreen mainScreen] frame];
	unsigned long xid;
	time_t now = time(NULL);
	dispatch_source_t t;

	view = [[NaplesBarView alloc] initWithBar: self];
	window = [[NaplesBarWindow alloc] initWithContentRect: NSMakeRect(0, scr.size.height - [view barHeight], scr.size.width, [view barHeight])
	                                            styleMask: NSBorderlessWindowMask backing: NSBackingStoreBuffered defer: NO];
	[window setLevel: NSDockWindowLevel];
	[window setOpaque: NO];
	[window setBackgroundColor: [NSColor clearColor]];
	[window setHasShadow: NO];
	[window setReleasedWhenClosed: NO];
	[window setCanHide: NO];
	[window setContentView: view];

	/* the menu server: Eau in every app looks this name up and pushes menus to it */
	serverConnection = [[NSConnection alloc] init];
	[serverConnection setRootObject: self];
	if (![serverConnection registerName: NaplesMenuServerName])
		NSLog(@"Naples: could not register %@ (another menu server running?)", NaplesMenuServerName);

	[[NaplesX shared] setActiveHandler: ^{ [self activeWindowChanged]; }];
	[[NaplesX shared] addBackgroundHandler: ^{ [self refreshBackdrop]; }];
	[self activeWindowChanged];

	xid = (unsigned long)[GSCurrentServer() windowDevice: [window windowNumber]];
	[[NaplesX shared] setDockHints: xid edge: 3 barRect: NSMakeRect(0, 0, scr.size.width, [view barHeight]) reserve: YES opacity: 1.0];
	[view reload];
	[self refreshBackdrop];
	[window orderFrontRegardless];
	[self viewResized];
	[window display];
	[view performSelector: @selector(display) withObject: nil afterDelay: 0.5];

	/* the clock redraws on the minute: a GCD timer aligned to the wall clock */
	t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
	dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 - now % 60) * NSEC_PER_SEC), 60 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
	dispatch_source_set_event_handler(t, ^{ NaplesRunOnMain(^{ [view setNeedsDisplay: YES]; }); });
	dispatch_resume(t);
	clockSource = t;
}

- (void) refreshBackdrop
{
	[view setBackdrop: [[NaplesX shared] backgroundForRect: NSMakeRect(0, 0, [[NSScreen mainScreen] frame].size.width, [view barHeight])]];
}

- (void) viewResized
{
	NSRect scr = [[NSScreen mainScreen] frame];
	CGFloat h = [view desiredHeight];
	NSRect frame = NSMakeRect(scr.origin.x, NSMaxY(scr) - h, scr.size.width, h);
	if (!NSEqualRects(frame, [window frame])) {
		[window setFrame: frame display: NO];
		[view setFrame: NSMakeRect(0, 0, frame.size.width, h)];
	}
	[[NaplesX shared] setShape: (unsigned long)[GSCurrentServer() windowDevice: [window windowNumber]]
	                     rects: [view shapeRects] radius: 5 square: 1];
	[view setNeedsDisplay: YES];
}

/* ---- which application is in front ---- */

- (void) activeWindowChanged
{
	NaplesWindowInfo *w = [[NaplesX shared] activeWindow];
	if (!w || w->pid == getpid()) return;	/* nothing focused: keep showing the last application */
	[frontClient release]; [frontWindowId release]; [frontName release];
	frontClient = [[NSString stringWithFormat: @"%@%d", NaplesMenuClientPrefix, w->pid] retain];
	frontWindowId = [windowKey(w->xid) retain];
	frontName = [([w->wmClass length] ? w->wmClass : w->title ? w->title : @"") retain];
	[view closeMenu];
	if (![self menuData]) [self requestMenuFromClient: frontClient];	/* apps that started before us have not pushed yet */
	[view reload];
}

- (NSString *) frontName { return frontName ? frontName : @""; }

- (NSDictionary *) menuData
{
	NSDictionary *m = frontClient ? [[windowMenus objectForKey: frontClient] objectForKey: frontWindowId] : nil;
	if (!m && frontClient) m = [appMenus objectForKey: frontClient];
	return [[m objectForKey: @"items"] count] ? m : nil;
}

/* ---- talking to the client ---- */

- (id) proxyForClient: (NSString *)name
{
	id proxy = [proxies objectForKey: name];
	if (proxy && ![[proxy connectionForProxy] isValid]) { [proxies removeObjectForKey: name]; proxy = nil; }
	if (!proxy) {
		@try {
			proxy = [NSConnection rootProxyForConnectionWithRegisteredName: name host: nil];
			if (proxy) {
				[proxy setProtocolForProxy: @protocol(GSGNUstepMenuClient)];
				[[proxy connectionForProxy] setRequestTimeout: 0.4];
				[[proxy connectionForProxy] setReplyTimeout: 0.4];
				[proxies setObject: proxy forKey: name];
			}
		} @catch (NSException *e) { proxy = nil; }
	}
	return proxy;
}

- (void) requestMenuFromClient: (NSString *)name
{
	id proxy = [self proxyForClient: name];
	@try { [proxy requestApplicationMenuUpdate]; } @catch (NSException *e) { }
}

- (void) prepareMenu
{
	id proxy;
	NSArray *flat;
	NSDictionary *m = [self menuData];
	NSUInteger pos = 0;
	if (!m || !(proxy = [self proxyForClient: frontClient])) return;
	@try { flat = [proxy validateMenuStateForWindow: frontWindowId]; } @catch (NSException *e) { flat = nil; }
	if (![flat isKindOfClass: [NSArray class]] || ![flat count]) return;
	m = applyStates(m, flat, &pos);
	if ([[windowMenus objectForKey: frontClient] objectForKey: frontWindowId])
		[[windowMenus objectForKey: frontClient] setObject: m forKey: frontWindowId];
	else
		[appMenus setObject: m forKey: frontClient];
}

- (void) activatePath: (NSArray *)path
{
	id proxy = [self proxyForClient: frontClient];
	@try { [proxy activateMenuItemAtPath: path forWindow: frontWindowId]; }
	@catch (NSException *e) { NSLog(@"Naples: menu action failed: %@", e); }
}

/* ---- the Hexley menu ---- */

- (NSDictionary *) systemMenu
{
	NSMutableArray *items = [NSMutableArray array];
	NSArray *names = [NSArray arrayWithObjects: @"Dock at Bottom", @"Dock on the Left", @"Dock on the Right", nil];
	int e;
	[items addObject: localItem(@"Open Milan", YES, ^{ [dock openMilan]; })];
	[items addObject: localSeparator()];
	for (e = 0; e < 3; e++)
		[items addObject: localItem([names objectAtIndex: e], e != [dock edge], ^{ [dock setEdge: e persist: YES]; })];
	[items addObject: localSeparator()];
	[items addObject: localItem(@"Quit Naples", YES, ^{ [NSApp terminate: nil]; })];
	return [NSDictionary dictionaryWithObjectsAndKeys: @"Naples", @"title", items, @"items", nil];
}

/* ---- GSGNUstepMenuServer: called by the apps (hop to the main thread, copy the arguments) ---- */

- (oneway void) updateMenuForWindow: (bycopy NSNumber *)windowId menuData: (bycopy NSDictionary *)menuData clientName: (bycopy NSString *)clientName
{
	NaplesRunOnMain(^{ [self storeWindowMenu: menuData window: windowId client: clientName]; });
}

- (oneway void) updateMenuEnabledStatesForWindow: (bycopy NSNumber *)windowId menuData: (bycopy NSDictionary *)menuData clientName: (bycopy NSString *)clientName
{
	NaplesRunOnMain(^{ [self storeWindowMenu: menuData window: windowId client: clientName]; });
}

- (oneway void) unregisterWindow: (bycopy NSNumber *)windowId clientName: (bycopy NSString *)clientName
{
	NaplesRunOnMain(^{
		[[windowMenus objectForKey: clientName] removeObjectForKey: windowId];
		if ([clientName isEqualToString: frontClient]) [view reload];
	});
}

- (oneway void) updateMenuForApplication: (bycopy NSDictionary *)menuData clientName: (bycopy NSString *)clientName
{
	NaplesRunOnMain(^{ [self storeAppMenu: menuData client: clientName]; });
}

- (oneway void) updateApplicationMenuEnabledStates: (bycopy NSDictionary *)menuData clientName: (bycopy NSString *)clientName
{
	NaplesRunOnMain(^{ [self storeAppMenu: menuData client: clientName]; });
}

- (oneway void) unregisterApplication: (bycopy NSString *)clientName
{
	NaplesRunOnMain(^{
		[windowMenus removeObjectForKey: clientName];
		[appMenus removeObjectForKey: clientName];
		[proxies removeObjectForKey: clientName];
		if ([clientName isEqualToString: frontClient]) [view reload];
	});
}

- (void) storeWindowMenu: (NSDictionary *)menu window: (NSNumber *)wid client: (NSString *)client
{
	NSMutableDictionary *per;
	if (![menu isKindOfClass: [NSDictionary class]] || !wid || !client) return;
	if (!(per = [windowMenus objectForKey: client])) { per = [NSMutableDictionary dictionary]; [windowMenus setObject: per forKey: client]; }
	[per setObject: menu forKey: wid];
	if ([client isEqualToString: frontClient]) [self refreshIfNotTracking];
}

- (void) storeAppMenu: (NSDictionary *)menu client: (NSString *)client
{
	if (![menu isKindOfClass: [NSDictionary class]] || !client) return;
	[appMenus setObject: menu forKey: client];
	if ([client isEqualToString: frontClient]) [self refreshIfNotTracking];
}

/* a menu changing under the pointer while it is open would shift the rows; the next open picks it up */
- (void) refreshIfNotTracking
{
	if (![view menuOpen]) [view reload];
}

@end
