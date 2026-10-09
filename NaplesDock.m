#import "NaplesDock.h"
#import "NaplesDockView.h"
#import "NaplesX.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <sys/sysctl.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>

NSString *const NaplesPboardType = @"NaplesDockItemPboardType";

static NSString *const KeyPinned = @"NaplesPinned";
static NSString *const KeyEdge = @"NaplesEdge";
enum { ScreenMargin = 3 };

@implementation NaplesItem
- (BOOL) running { return [pids count] > 0; }
- (void) dealloc
{
	[path release]; [name release]; [icon release]; [pids release]; [windows release];
	[super dealloc];
}
@end

@implementation NaplesMenuEntry
- (void) dealloc { [title release]; if (action) Block_release(action); [super dealloc]; }
@end

static NaplesMenuEntry *
entry(NSString *title, void (^action)(void))
{
	NaplesMenuEntry *e = [[[NaplesMenuEntry alloc] init] autorelease];
	e->title = [title retain];
	e->action = Block_copy(action);
	return e;
}

/* a borderless window never takes the keyboard focus from the application the user is working in */
@interface NaplesDockWindow : NSWindow
@end
@implementation NaplesDockWindow
- (BOOL) canBecomeKeyWindow { return NO; }
- (BOOL) canBecomeMainWindow { return NO; }
@end

static NSString *
trashDir(void)
{
	return [NSHomeDirectory() stringByAppendingPathComponent: @".Trash"];
}

/* "/Applications/Foo.app/Contents/MacOS/Foo" -> "/Applications/Foo.app" */
static NSString *
bundleOfExecutable(NSString *exe)
{
	NSArray *parts = [exe pathComponents];
	NSUInteger i;
	for (i = 0; i < [parts count]; i++)
		if ([[[parts objectAtIndex: i] pathExtension] isEqualToString: @"app"])
			return [NSString pathWithComponents: [parts subarrayWithRange: NSMakeRange(0, i + 1)]];
	return nil;
}

/* the executable path of a process: KERN_PROCARGS2 starts with argc, then the exec path (libproc is not in this port) */
static NSString *
executableOfPid(int pid)
{
	int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
	size_t len = 0;
	char *buf;
	NSString *s = nil;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) < 0 || len <= sizeof(int)) return nil;
	buf = malloc(len);
	if (sysctl(mib, 3, buf, &len, NULL, 0) == 0 && len > sizeof(int))
		s = [NSString stringWithUTF8String: buf + sizeof(int)];
	free(buf);
	return s;
}

@implementation NaplesDock

/* ---- setup ---- */

- (NSString *) findMilan
{
	NSString *p, *custom = [[NSUserDefaults standardUserDefaults] stringForKey: @"NaplesMilanPath"];
	NSArray *cands = [NSArray arrayWithObjects: @"/Applications/Milan.app", @"/usr/GNUstep/System/Applications/Milan.app",
	                  [NSHomeDirectory() stringByAppendingPathComponent: @"Applications/Milan.app"],
	                  @"/usr/local/GNUstep/Local/Applications/Milan.app", nil];
	if (custom) cands = [[NSArray arrayWithObject: custom] arrayByAddingObjectsFromArray: cands];
	for (p in cands) if ([[NSFileManager defaultManager] fileExistsAtPath: p]) return p;
	return @"/Applications/Milan.app";
}

- (void) start
{
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	NSArray *saved = [d arrayForKey: KeyPinned];
	unsigned long xid;
	pinned = [[NSMutableArray alloc] init];
	launched = [[NSMutableDictionary alloc] init];
	procSources = [[NSMutableDictionary alloc] init];
	icons = [[NSMutableDictionary alloc] init];
	runOrder = [[NSMutableArray alloc] init];
	milanPath = [[self findMilan] retain];
	edge = [d objectForKey: KeyEdge] ? (int)[d integerForKey: KeyEdge] : NaplesEdgeBottom;
	if (edge < 0 || edge > 2) edge = NaplesEdgeBottom;

	if (saved) {
		[pinned addObjectsFromArray: saved];
	} else {	/* first run: whatever is installed, so the dock is not empty */
		NSString *f;
		for (f in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath: @"/Applications" error: NULL] sortedArrayUsingSelector: @selector(compare:)])
			if ([[f pathExtension] isEqualToString: @"app"] && ![f isEqualToString: @"Milan.app"] && [pinned count] < 8)
				[pinned addObject: [@"/Applications" stringByAppendingPathComponent: f]];
		[self savePinned];
	}

	[[NaplesX shared] connect];
	[[NaplesX shared] setChangeHandler: ^{ [self rebuild]; }];
	[self watchTrash];

	view = [[NaplesDockView alloc] initWithDock: self];
	window = [[NaplesDockWindow alloc] initWithContentRect: NSMakeRect(0, 0, 100, 60) styleMask: NSBorderlessWindowMask
	                                               backing: NSBackingStoreBuffered defer: NO];
	[window setLevel: NSDockWindowLevel];
	[window setOpaque: NO];
	[window setBackgroundColor: [NSColor clearColor]];
	[window setHasShadow: NO];
	[window setReleasedWhenClosed: NO];
	[window setCanHide: NO];
	[window setContentView: view];
	[self rebuild];
	xid = (unsigned long)[GSCurrentServer() windowDevice: [window windowNumber]];
	[self applyHints: xid];	/* before the window is mapped, so the WM reads them */
	[window orderFrontRegardless];
	[self relayout];
	[window display];
	/* windows created at launch have painted late on this stack: paint once more after the first run-loop turn */
	[view performSelector: @selector(display) withObject: nil afterDelay: 0.5];
}

- (unsigned long) xid { return (unsigned long)[GSCurrentServer() windowDevice: [window windowNumber]]; }

- (void) applyHints: (unsigned long)xid
{
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	BOOL reserve = ![d objectForKey: @"NaplesReserveSpace"] || [d boolForKey: @"NaplesReserveSpace"];
	NSRect scr = [[NSScreen mainScreen] frame], bar = [window frame];
	if (xid) {
		if ([view menuOpen]) bar = NSOffsetRect([view barRect], bar.origin.x, bar.origin.y);
		bar.origin.y = scr.size.height - NSMaxY(bar);	/* X: top-left origin */
		[[NaplesX shared] setDockHints: xid edge: edge barRect: bar reserve: reserve opacity: 1.0];
	}
}

- (void) savePinned
{
	[[NSUserDefaults standardUserDefaults] setObject: [[pinned copy] autorelease] forKey: KeyPinned];
	[[NSUserDefaults standardUserDefaults] synchronize];
}

/* ---- the item list ---- */

- (NSArray *) items { return items; }
- (int) edge { return edge; }
- (NSUInteger) pinnedCount { return [pinned count]; }
- (NSInteger) pinnedIndexOfPath: (NSString *)path { return [pinned indexOfObject: path] == NSNotFound ? -1 : (NSInteger)[pinned indexOfObject: path]; }

- (NSImage *) iconForBundle: (NSString *)path
{
	id cached = [icons objectForKey: path];
	NSBundle *b;
	NSDictionary *info;
	NSString *f, *p = nil;
	NSImage *img = nil;
	if (cached) return cached == [NSNull null] ? nil : cached;
	b = [NSBundle bundleWithPath: path];
	info = [b infoDictionary];
	f = [info objectForKey: @"NSIcon"];
	if (!f) f = [info objectForKey: @"CFBundleIconFile"];
	if ([f length]) p = [b pathForResource: [f stringByDeletingPathExtension] ofType: [[f pathExtension] length] ? [f pathExtension] : nil];
	if (p) img = [[[NSImage alloc] initWithContentsOfFile: p] autorelease];
	[icons setObject: img ? (id)img : (id)[NSNull null] forKey: path];
	return img;
}

- (NSString *) nameForBundle: (NSString *)path { return [[path lastPathComponent] stringByDeletingPathExtension]; }

- (NaplesItem *) makeItem: (NaplesItemKind)kind path: (NSString *)path name: (NSString *)name
{
	NaplesItem *it = [[[NaplesItem alloc] init] autorelease];
	it->kind = kind;
	it->path = [path retain];
	it->name = [(name ? name : [self nameForBundle: path]) retain];
	it->pids = [[NSMutableArray alloc] init];
	it->windows = [[NSMutableArray alloc] init];
	if (path && kind != NaplesItemTrash) it->icon = [[self iconForBundle: path] retain];
	return it;
}

/* which program a window belongs to: its bundle if the process path says so, else a launched child, else a pinned
 * app of the same name (GNUstep sets WM_CLASS to the app name) */
- (NSString *) keyForWindow: (NaplesWindowInfo *)w path: (NSString **)bundle
{
	NSString *p = nil, *k, *exe;
	*bundle = nil;
	if (w->pid > 0 && (exe = executableOfPid(w->pid))) p = bundleOfExecutable(exe);
	if (!p && w->pid > 0)
		for (k in launched) if ([[launched objectForKey: k] intValue] == w->pid) { p = k; break; }
	if (!p && [w->wmClass length]) {
		NSMutableArray *known = [NSMutableArray arrayWithArray: pinned];
		[known addObject: milanPath];
		for (k in known) if ([[self nameForBundle: k] caseInsensitiveCompare: w->wmClass] == NSOrderedSame) { p = k; break; }
	}
	*bundle = p;
	if (p) return p;
	return w->pid > 0 ? [NSString stringWithFormat: @"pid:%d", w->pid] : [NSString stringWithFormat: @"xid:%lu", w->xid];
}

- (void) rebuild
{
	NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
	NSMutableArray *list = [NSMutableArray array], *minimized = [NSMutableArray array], *seen = [NSMutableArray array];
	NaplesItem *milan = [self makeItem: NaplesItemMilan path: milanPath name: @"Milan"], *it;
	NaplesWindowInfo *w;
	NSString *p, *k;

	[byKey setObject: milan forKey: milanPath];
	milan->pinned = YES;
	[list addObject: milan];
	for (p in pinned) {
		if ([byKey objectForKey: p]) continue;
		it = [self makeItem: NaplesItemApp path: p name: nil];
		it->pinned = YES;
		[byKey setObject: it forKey: p];
		[list addObject: it];
	}
	[list addObject: [self makeItem: NaplesItemDivider path: nil name: @""]];

	for (w in [[NaplesX shared] clientWindows]) {
		NSString *bundle;
		k = [self keyForWindow: w path: &bundle];
		it = [byKey objectForKey: k];
		if (!it) {
			it = [self makeItem: NaplesItemApp path: bundle name: bundle ? nil : ([w->wmClass length] ? w->wmClass : w->title)];
			[byKey setObject: it forKey: k];
		}
		[seen addObject: k];
		if (w->pid > 0 && ![it->pids containsObject: [NSNumber numberWithInt: w->pid]]) [it->pids addObject: [NSNumber numberWithInt: w->pid]];
		[it->windows addObject: w];
		if (w->minimized && !w->transient) {
			NaplesItem *mi = [self makeItem: NaplesItemWindow path: it->path name: [w->title length] ? w->title : it->name];
			if (!mi->icon) mi->icon = [it->icon retain];
			mi->xid = w->xid;
			[minimized addObject: mi];
		}
	}
	/* processes we started that have no window yet still count as running */
	for (k in launched) {
		it = [byKey objectForKey: k];
		if (it) {
			NSNumber *n = [launched objectForKey: k];
			if (![it->pids containsObject: n]) [it->pids addObject: n];
		}
	}

	/* running programs that are not pinned, in the order they appeared */
	for (k in seen) if (![runOrder containsObject: k]) [runOrder addObject: k];
	for (k in [[runOrder copy] autorelease]) if (![seen containsObject: k]) [runOrder removeObject: k];
	for (k in runOrder) {
		it = [byKey objectForKey: k];
		if (it && !it->pinned && it != milan) [list addObject: it];
	}
	[list addObjectsFromArray: minimized];
	it = [self makeItem: NaplesItemTrash path: nil name: @"Trash"];
	it->trashFull = trashFull;
	[list addObject: it];

	[items release];
	items = [list retain];
	[self relayout];
}

/* ---- window placement ---- */

- (void) setEdge: (int)e persist: (BOOL)persist
{
	if (e != edge) { edge = e; [self relayout]; }
	if (persist) {
		[[NSUserDefaults standardUserDefaults] setObject: [NSNumber numberWithInt: edge] forKey: KeyEdge];
		[[NSUserDefaults standardUserDefaults] synchronize];
	}
}

- (void) menuChanged { [self relayout]; }

- (void) relayout
{
	NSRect scr = [[NSScreen mainScreen] frame], bar, menu = NSZeroRect, frame;
	NSSize bs;
	NSMutableArray *shape = [NSMutableArray array];
	NSPoint barLocal, menuLocal = NSZeroPoint;
	NSRect r;
	if (!window || !items) return;
	[view reloadItems: items edge: edge maxLength: (edge == NaplesEdgeBottom ? scr.size.width : scr.size.height) - 40];
	bs = [view barSize];
	if (edge == NaplesEdgeBottom) bar = NSMakeRect(NSMinX(scr) + (scr.size.width - bs.width) / 2, NSMinY(scr) + ScreenMargin, bs.width, bs.height);
	else if (edge == NaplesEdgeLeft) bar = NSMakeRect(NSMinX(scr) + ScreenMargin, NSMinY(scr) + (scr.size.height - bs.height) / 2, bs.width, bs.height);
	else bar = NSMakeRect(NSMaxX(scr) - bs.width - ScreenMargin, NSMinY(scr) + (scr.size.height - bs.height) / 2, bs.width, bs.height);
	frame = bar;

	if ([view menuOpen]) {	/* the window grows to hold the menu overlay next to the item it belongs to */
		NSSize ms = [view menuSize];
		NSRect anchor = [view menuAnchor];
		NSPoint c = NSEqualRects(anchor, NSZeroRect) ? NSMakePoint(bar.origin.x + [view menuPointer].x, bar.origin.y + [view menuPointer].y)
		                                           : NSMakePoint(bar.origin.x + NSMidX(anchor), bar.origin.y + NSMidY(anchor));
		if (edge == NaplesEdgeBottom) menu = NSMakeRect(c.x - ms.width / 2, NSMaxY(bar) + 4, ms.width, ms.height);
		else if (edge == NaplesEdgeLeft) menu = NSMakeRect(NSMaxX(bar) + 4, c.y - ms.height / 2, ms.width, ms.height);
		else menu = NSMakeRect(bar.origin.x - 4 - ms.width, c.y - ms.height / 2, ms.width, ms.height);
		if (NSMaxX(menu) > NSMaxX(scr)) menu.origin.x = NSMaxX(scr) - menu.size.width;
		if (NSMinX(menu) < NSMinX(scr)) menu.origin.x = NSMinX(scr);
		if (NSMaxY(menu) > NSMaxY(scr)) menu.origin.y = NSMaxY(scr) - menu.size.height;
		if (NSMinY(menu) < NSMinY(scr)) menu.origin.y = NSMinY(scr);
		frame = NSUnionRect(bar, menu);
	}
	barLocal = NSMakePoint(bar.origin.x - frame.origin.x, bar.origin.y - frame.origin.y);
	if ([view menuOpen]) menuLocal = NSMakePoint(menu.origin.x - frame.origin.x, menu.origin.y - frame.origin.y);

	[window setFrame: frame display: NO];
	[view setFrame: NSMakeRect(0, 0, frame.size.width, frame.size.height)];
	[view setBarOrigin: barLocal menuOrigin: menuLocal];

	r = [view barRect];	/* shape rects are in X coordinates: origin at the window's top left */
	[shape addObject: [NSValue valueWithRect: NSMakeRect(r.origin.x, frame.size.height - NSMaxY(r), r.size.width, r.size.height)]];
	if ([view menuOpen]) {
		r = [view menuRect];
		[shape addObject: [NSValue valueWithRect: NSMakeRect(r.origin.x, frame.size.height - NSMaxY(r), r.size.width, r.size.height)]];
	}
	[[NaplesX shared] setShape: [self xid] rects: shape radius: 5];
	[self applyHints: [self xid]];
	[view setNeedsDisplay: YES];
}

/* ---- launching, activating, killing ---- */

- (BOOL) launch: (NSString *)path file: (NSString *)file arguments: (NSArray *)args
{
	NSBundle *b = [NSBundle bundleWithPath: path];
	NSString *exe = [b executablePath];
	NSTask *t;
	pid_t pid;
	if (![exe length] || ![[NSFileManager defaultManager] isExecutableFileAtPath: exe])
		exe = [path stringByAppendingPathComponent: [[path lastPathComponent] stringByDeletingPathExtension]];
	if (![[NSFileManager defaultManager] isExecutableFileAtPath: exe]) { NSLog(@"Naples: %@ has no executable", path); return NO; }
	t = [[[NSTask alloc] init] autorelease];
	[t setLaunchPath: exe];
	if (file) args = [NSArray arrayWithObjects: @"-NSOpen", file, nil];
	if (args) [t setArguments: args];
	[t setCurrentDirectoryPath: NSHomeDirectory()];
	[t setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
	[t setStandardError: [NSFileHandle fileHandleWithNullDevice]];
	NS_DURING
		[t launch];
	NS_HANDLER
		NSLog(@"Naples: %@ could not be started", path);
		return NO;
	NS_ENDHANDLER
	pid = [t processIdentifier];
	[launched setObject: [NSNumber numberWithInt: pid] forKey: path];
	[self watchChild: pid];
	[self rebuild];
	return YES;
}

/* GCD process source: kqueue EVFILT_PROC / NOTE_EXIT, so the dot goes out the moment the process dies */
- (void) watchChild: (pid_t)pid
{
	dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT,
	                                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
	dispatch_source_set_event_handler(src, ^{
		dispatch_source_cancel(src);
		NaplesRunOnMain(^{ [self childExited: pid]; });
	});
	dispatch_resume(src);
	[procSources setObject: [NSValue valueWithPointer: src] forKey: [NSNumber numberWithInt: pid]];
}

- (void) childExited: (pid_t)pid
{
	NSNumber *n = [NSNumber numberWithInt: pid];
	NSValue *v = [procSources objectForKey: n];
	NSString *k;
	if (v) { dispatch_release((dispatch_source_t)[v pointerValue]); [procSources removeObjectForKey: n]; }
	for (k in [launched allKeysForObject: n]) [launched removeObjectForKey: k];
	[self rebuild];
}

- (void) activateItem: (NaplesItem *)item
{
	NaplesWindowInfo *w, *pick = nil;
	switch (item->kind) {
	case NaplesItemWindow:
		[[NaplesX shared] activateWindow: item->xid];
		break;
	case NaplesItemTrash:
		[self launch: milanPath file: nil arguments: [NSArray arrayWithObject: trashDir()]];
		break;
	case NaplesItemMilan:
	case NaplesItemApp:
		if ([item->windows count]) {	/* already running: bring a window forward, un-minimizing it if need be */
			for (w in item->windows) if (!w->minimized && !w->transient) pick = w;
			if (!pick) for (w in item->windows) if (!w->transient) { pick = w; break; }
			if (!pick) pick = [item->windows lastObject];
			[[NaplesX shared] activateWindow: pick->xid];
		} else if (![item running] && item->path) {
			[self launch: item->path file: nil arguments: nil];
		}
		break;
	default:
		break;
	}
}

- (void) openFile: (NSString *)file withItem: (NaplesItem *)item
{
	if (item->path) [self launch: item->path file: file arguments: nil];
}

- (void) signalItem: (NaplesItem *)item signal: (int)sig
{
	NSNumber *n;
	for (n in [[item->pids copy] autorelease]) {
		pid_t pid = [n intValue];
		if (pid > 1 && pid != getpid()) kill(pid, sig);
	}
}

- (NSString *) toolTipForItem: (NaplesItem *)item
{
	return item->kind == NaplesItemDivider ? nil : item->name;
}

/* ---- menus ---- */

- (NSArray *) menuEntriesForItem: (NaplesItem *)item
{
	NSMutableArray *m = [NSMutableArray array];
	NaplesItem *it = item;
	if (!item) {
		int e;
		NSArray *names = [NSArray arrayWithObjects: @"Dock at Bottom", @"Dock on the Left", @"Dock on the Right", nil];
		for (e = 0; e < 3; e++)
			if (e != edge) [m addObject: entry([names objectAtIndex: e], ^{ [self setEdge: e persist: YES]; })];
		[m addObject: entry(@"Quit Naples", ^{ [NSApp terminate: nil]; })];
		return m;
	}
	switch (item->kind) {
	case NaplesItemWindow:
		[m addObject: entry(@"Restore", ^{ [[NaplesX shared] activateWindow: it->xid]; })];
		[m addObject: entry(@"Close Window", ^{ [[NaplesX shared] closeWindow: it->xid]; })];
		break;
	case NaplesItemTrash:
		[m addObject: entry(@"Open Trash", ^{ [self activateItem: it]; })];
		if (item->trashFull) [m addObject: entry(@"Empty Trash", ^{ [self emptyTrash]; })];
		break;
	case NaplesItemMilan:
	case NaplesItemApp:
		if ([item running]) {
			[m addObject: entry(@"Show", ^{ [self activateItem: it]; })];
			[m addObject: entry(@"Quit", ^{ [self signalItem: it signal: SIGTERM]; })];
			[m addObject: entry(@"Force Quit", ^{ [self signalItem: it signal: SIGKILL]; })];
		} else {
			[m addObject: entry(@"Open", ^{ [self activateItem: it]; })];
		}
		if (item->kind == NaplesItemApp && item->path) {
			if (item->pinned) [m addObject: entry(@"Remove from Dock", ^{ [self unpinPath: it->path]; })];
			else [m addObject: entry(@"Keep in Dock", ^{ [self pinPath: it->path atIndex: [pinned count]]; })];
		}
		break;
	default:
		break;
	}
	return m;
}

/* ---- the pinned list ---- */

- (void) pinPath: (NSString *)path atIndex: (NSInteger)index
{
	NSUInteger old = [pinned indexOfObject: path];
	if ([path isEqualToString: milanPath]) return;
	if (old != NSNotFound) { [pinned removeObjectAtIndex: old]; if ((NSInteger)old < index) index--; }
	if (index < 0 || index > (NSInteger)[pinned count]) index = [pinned count];
	[pinned insertObject: path atIndex: index];
	[self savePinned];
	[self rebuild];
}

- (void) unpinPath: (NSString *)path
{
	[pinned removeObject: path];
	[self savePinned];
	[self rebuild];
}

/* ---- the Trash: Milan's layout (~/.Trash plus a .milan-origins plist for Put Back) ---- */

- (void) trashPaths: (NSArray *)paths
{
	paths = [paths copy];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
		NSString *dir = trashDir(), *p;
		NSString *originsFile = [dir stringByAppendingPathComponent: @".milan-origins"];
		NSMutableDictionary *origins;
		[fm createDirectoryAtPath: dir withIntermediateDirectories: YES
		               attributes: [NSDictionary dictionaryWithObject: [NSNumber numberWithInt: 0700] forKey: NSFilePosixPermissions] error: NULL];
		origins = [NSMutableDictionary dictionaryWithContentsOfFile: originsFile];
		if (!origins) origins = [NSMutableDictionary dictionary];
		for (p in paths) {
			NSString *name = [p lastPathComponent], *dest = [dir stringByAppendingPathComponent: name];
			int n = 2;
			if ([p hasPrefix: dir]) continue;
			while ([fm attributesOfItemAtPath: dest error: NULL]) {
				name = [NSString stringWithFormat: @"%@ %d%@", [[p lastPathComponent] stringByDeletingPathExtension], n++,
				        [[p pathExtension] length] ? [@"." stringByAppendingString: [p pathExtension]] : @""];
				dest = [dir stringByAppendingPathComponent: name];
			}
			if ([fm moveItemAtPath: p toPath: dest error: NULL]) [origins setObject: p forKey: name];
		}
		[origins writeToFile: originsFile atomically: YES];
		[paths release];
	});
}

- (void) emptyTrash
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
		NSString *dir = trashDir(), *f;
		for (f in [fm contentsOfDirectoryAtPath: dir error: NULL])
			[fm removeItemAtPath: [dir stringByAppendingPathComponent: f] error: NULL];
	});
}

static BOOL
trashHasItems(void)
{
	NSString *f;
	for (f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath: trashDir() error: NULL])
		if (![f isEqualToString: @".milan-origins"] && ![f isEqualToString: @".DS_Store"] && ![f isEqualToString: @".gwdir"]) return YES;
	return NO;
}

/* kqueue vnode source on ~/.Trash: the can fills and empties as files come and go, whoever does it */
- (void) watchTrash
{
	int fd;
	[[NSFileManager defaultManager] createDirectoryAtPath: trashDir() withIntermediateDirectories: YES attributes: nil error: NULL];
	trashFull = trashHasItems();
	if ((fd = open([trashDir() fileSystemRepresentation], O_EVTONLY)) < 0) return;
	trashSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
	                                     DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
	                                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
	dispatch_source_set_event_handler(trashSource, ^{
		BOOL full = trashHasItems();
		NaplesRunOnMain(^{
			if (full != trashFull) { trashFull = full; [self rebuild]; }
		});
	});
	dispatch_source_set_cancel_handler(trashSource, ^{ close(fd); });
	dispatch_resume(trashSource);
}

@end
