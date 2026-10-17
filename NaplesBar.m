#import "NaplesBar.h"
#import "NaplesBarView.h"
#import "NaplesDock.h"
#import "NaplesPanel.h"
#import "NaplesSound.h"
#import "NaplesWifi.h"
#import "NaplesX.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <sys/sysctl.h>
#include <signal.h>

NSString *const NaplesMenuServerName = @"org.gnustep.Gershwin.MenuServer";
NSString *const NaplesMenuClientPrefix = @"org.gnustep.Gershwin.MenuClient.";

@interface NaplesBarWindow : NSWindow
@end
@implementation NaplesBarWindow
- (BOOL) canBecomeKeyWindow { return NO; }
- (BOOL) canBecomeMainWindow { return NO; }
@end

static BOOL
debugOn(void)
{
	static int on = -1;
	if (on < 0) on = [[NSUserDefaults standardUserDefaults] boolForKey: @"NaplesDebug"];
	return on;
}

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

- (NaplesSound *) sound { return sound; }
- (NaplesWifi *) wifi { return wifi; }

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
	/* the speaker left of the clock; redraw when the volume or the panel changes */
	sound = [[NaplesSound alloc] initWithChangeHandler: ^{ [view setNeedsDisplay: YES]; }];
	/* the Wi-Fi fan left of the speaker; redraw when the link, the signal or the panel changes */
	wifi = [[NaplesWifi alloc] initWithChangeHandler: ^{ [view setNeedsDisplay: YES]; }];

	/* the menu server: Eau in every app looks this name up and pushes menus to it */
	serverConnection = [[NSConnection alloc] init];
	[serverConnection setRootObject: self];
	if (![serverConnection registerName: NaplesMenuServerName])
		NSLog(@"Naples: could not register %@ (another menu server running?)", NaplesMenuServerName);

	[[NaplesX shared] setPidResolver: ^int(unsigned long xid) { return [self pidForWindowId: windowKey(xid)]; }];
	/* apps that were running when Naples (re)started hold a dead connection to the old server and only notice at their next
	 * push: ask every GNUstep process for its menu now, which makes Eau reconnect to us */
	[self performSelector: @selector(nudgeClients) withObject: nil afterDelay: 1.0];
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
	/* the bar window is a fixed strip; menus have their own windows */
	NSRect scr = [[NSScreen mainScreen] frame];
	NSRect frame = NSMakeRect(scr.origin.x, NSMaxY(scr) - [view barHeight], scr.size.width, [view barHeight]);
	if (!NSEqualRects(frame, [window frame])) {
		[window setFrame: frame display: NO];
		[view setFrame: NSMakeRect(0, 0, frame.size.width, frame.size.height)];
	}
	[view setNeedsDisplay: YES];
}

/* ---- which application is in front ---- */

- (void) activeWindowChanged
{
	NaplesWindowInfo *w = [[NaplesX shared] activeWindow];
	if (!w || w->pid == getpid()) return;	/* nothing focused: keep showing the last application */
	[frontClient release]; [frontWindowId release]; [frontName release];
	frontWindowId = [windowKey(w->xid) retain];
	frontClient = [[self resolveClientForPid: w->pid window: frontWindowId wmClass: w->wmClass] retain];
	[frontWMClass release]; frontWMClass = [w->wmClass copy];
	frontName = [([w->wmClass length] ? w->wmClass : w->title ? w->title : @"") retain];
	if (debugOn()) NSLog(@"Naples bar: front window 0x%lx pid %d class %@ -> %@, menu stored: %@", w->xid, w->pid, w->wmClass, frontClient,
	                     [self menuData] ? @"yes" : @"no");
	[view closeMenu];
	if (frontClient && ![self menuData]) [self requestMenuFromClient: frontClient];	/* apps that started before us have not pushed yet */
	[view reload];
}

/* client names end in the process id */
static int
pidOfClient(NSString *client)
{
	return [[client substringFromIndex: [NaplesMenuClientPrefix length]] intValue];
}

- (NSString *) clientForWindowId: (NSNumber *)wid
{
	NSString *c;
	for (c in windowMenus) if ([[windowMenus objectForKey: c] objectForKey: wid]) return c;
	return nil;
}

- (int) pidForWindowId: (NSNumber *)wid
{
	NSString *c = [self clientForWindowId: wid];
	return c ? pidOfClient(c) : 0;
}

/* the menu client of the front window: by pid when the window has one, else by the window id the client pushed its
 * menu for, else by a client whose executable has the window's WM_CLASS name */
- (NSString *) resolveClientForPid: (int)pid window: (NSNumber *)wid wmClass: (NSString *)cls
{
	NSString *c;
	if (pid > 0) return [NSString stringWithFormat: @"%@%d", NaplesMenuClientPrefix, pid];
	if ((c = [self clientForWindowId: wid])) return c;
	if ([cls length]) {
		NSMutableSet *all = [NSMutableSet setWithArray: [appMenus allKeys]];
		[all addObjectsFromArray: [windowMenus allKeys]];
		for (c in all)
			if ([[NaplesExecutableOfPid(pidOfClient(c)) lastPathComponent] caseInsensitiveCompare: cls] == NSOrderedSame) return c;
	}
	return nil;
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

- (void) nudgeClients
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	struct kinfo_proc *procs;
	size_t i, n;
	if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0 || !len) return;
	procs = malloc(len);
	if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
		n = len / sizeof *procs;
		for (i = 0; i < n; i++) {
			pid_t pid = procs[i].kp_proc.p_pid;
			if (pid <= 1 || pid == getpid()) continue;
			[self requestMenuFromClient: [NSString stringWithFormat: @"%@%d", NaplesMenuClientPrefix, pid]];
		}
	}
	free(procs);
}

- (void) requestMenuFromClient: (NSString *)name
{
	id proxy = [self proxyForClient: name];
	if (debugOn()) NSLog(@"Naples bar: asking %@ for its menu (proxy %@)", name, proxy ? @"found" : @"NOT registered");
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

/* the same panel Milan and Rome show: GNUstep's standard info panel, from the keys GSInfoPanel reads */
- (void) showAbout
{
	NSString *ver = [[[NSBundle mainBundle] infoDictionary] objectForKey: @"ApplicationRelease"];
	NSDictionary *opts = [NSDictionary dictionaryWithObjectsAndKeys:
	    @"Naples", @"ApplicationName",
	    @"A dock and global menu bar for GNUstep and Window Maker.", @"ApplicationDescription",
	    [ver length] ? ver : @"0.3", @"ApplicationRelease",
	    [NSArray arrayWithObject: @"Anurodh Pokharel"], @"Authors",
	    @"Copyright \u00a9 2026 Anurodh Pokharel. MIT license.", @"Copyright",
	    @"Hexley DarwinOS Mascot Copyright 2000 by Jon Hooper. All Rights Reserved.", @"CopyrightDescription",
	    nil];
	[NSApp orderFrontStandardAboutPanelWithOptions: opts];
}

/* ---- Log Out, Restart, Shut Down ---- */

/* Asks first. A log out ends the window manager (and with it the session); Restart and Shut Down also leave a request in the
 * home folder, which the session script (iokit's gsdm Xsession) turns into the exit status gsdm acts on (10 restart, 11
 * shut down). Open applications are asked to close their windows first. */
- (void) askPower: (int)kind
{
	NSString *titles[3] = { @"Log Out", @"Restart", @"Shut Down" };
	NSString *what[3] = { @"log out", @"restart", @"shut down" };
	NSString *msg = [NSString stringWithFormat: @"Are you sure you want to %@ now? Open applications will be asked to close.", what[kind]];
	[NaplesConfirm askTitle: [titles[kind] stringByAppendingString: @"?"] message: msg confirm: titles[kind] then: ^{ [self performPower: kind]; }];
}

- (void) performPower: (int)kind
{
	NaplesWindowInfo *w;
	if (kind != NaplesPowerLogOut) {
		/* the session script reads "$HOME/.session-request". Not NSHomeDirectory(): GNUstep takes that from the passwd entry
		 * (NSPathUtilities.m NSHomeDirectoryForUser), which for root is "/", while the script runs with HOME=/var/root. */
		const char *h = getenv("HOME");
		NSString *home = h && *h ? [NSString stringWithUTF8String: h] : NSHomeDirectory();
		NSString *file = [home stringByAppendingPathComponent: @".session-request"];
		if (![(kind == NaplesPowerRestart ? @"restart\n" : @"shutdown\n") writeToFile: file atomically: YES encoding: NSUTF8StringEncoding error: NULL]) {
			NSLog(@"Naples: could not write %@; not ending the session", file);	/* it would only log out */
			return;
		}
	}
	for (w in [[NaplesX shared] clientWindows]) [[NaplesX shared] closeWindow: w->xid];	/* let applications save and quit */
	[self performSelector: @selector(endSession) withObject: nil afterDelay: 2.5];
}

/* the window manager is the session: ending it ends the login (SIGTERM is its "exit", Window Maker saves its state) */
- (void) endSession
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0, i, n;
	struct kinfo_proc *procs;
	if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0 || !len) return;
	procs = malloc(len);
	if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
		n = len / sizeof *procs;
		for (i = 0; i < n; i++) {
			pid_t pid = procs[i].kp_proc.p_pid;
			if (procs[i].kp_eproc.e_ucred.cr_uid != getuid() || pid <= 1) continue;
			if ([[NaplesExecutableOfPid(pid) lastPathComponent] isEqualToString: @"wmaker"]) kill(pid, SIGTERM);
		}
	}
	free(procs);
}

- (NSDictionary *) systemMenu
{
	NSMutableArray *items = [NSMutableArray array];
	NSArray *names = [NSArray arrayWithObjects: @"Dock at Bottom", @"Dock on the Left", @"Dock on the Right", nil];
	int e;
	[items addObject: localItem(@"About Naples", YES, ^{ [self showAbout]; })];
	[items addObject: localSeparator()];
	[items addObject: localItem(@"Settings\u2026", YES, ^{ [dock openSettings]; })];
	[items addObject: localSeparator()];
	[items addObject: localItem(@"Open Milan", YES, ^{ [dock openMilan]; })];
	[items addObject: localSeparator()];
	for (e = 0; e < 3; e++)
		[items addObject: localItem([names objectAtIndex: e], e != [dock edge], ^{ [dock setEdge: e persist: YES]; })];
	[items addObject: localSeparator()];
	[items addObject: localItem(@"Quit Naples", YES, ^{ [NSApp terminate: nil]; })];
	[items addObject: localSeparator()];
	[items addObject: localItem(@"Log Out\u2026", YES, ^{ [self askPower: NaplesPowerLogOut]; })];
	[items addObject: localItem(@"Restart\u2026", YES, ^{ [self askPower: NaplesPowerRestart]; })];
	[items addObject: localItem(@"Shut Down\u2026", YES, ^{ [self askPower: NaplesPowerShutDown]; })];
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
	if (debugOn()) NSLog(@"Naples bar: window menu from %@ window %@ (%lu items)", client, wid, (unsigned long)[[menu objectForKey: @"items"] count]);
	if (![menu isKindOfClass: [NSDictionary class]] || !wid || !client) return;
	if (!(per = [windowMenus objectForKey: client])) { per = [NSMutableDictionary dictionary]; [windowMenus setObject: per forKey: client]; }
	BOOL newPair = ![per objectForKey: wid];
	[per setObject: menu forKey: wid];
	if (newPair) [[NaplesX shared] noteWindowsChanged];	/* the dock can now tell which process owns this window */
	if (!frontClient && frontWindowId && [wid isEqual: frontWindowId]) frontClient = [client retain];
	if ([client isEqualToString: frontClient]) [self refreshIfNotTracking];
}

- (void) storeAppMenu: (NSDictionary *)menu client: (NSString *)client
{
	if (debugOn()) NSLog(@"Naples bar: app menu from %@ (%lu items)", client, (unsigned long)[[menu objectForKey: @"items"] count]);
	if (![menu isKindOfClass: [NSDictionary class]] || !client) return;
	[appMenus setObject: menu forKey: client];
	if (!frontClient && frontWindowId) {
		NSString *c = [self resolveClientForPid: 0 window: frontWindowId wmClass: frontWMClass];
		if (c) frontClient = [c retain];
	}
	if ([client isEqualToString: frontClient]) [self refreshIfNotTracking];
}

/* a menu changing under the pointer while it is open would shift the rows; the next open picks it up */
- (void) refreshIfNotTracking
{
	if (![view menuOpen]) [view reload];
}

@end
