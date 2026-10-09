/* Naples: a Dock for GNUstep + Window Maker on Darwin/XNU. See README.md.
 * Defaults (all optional): NaplesIconSize (44), NaplesEdge (0 bottom, 1 left, 2 right), NaplesReserveSpace (YES),
 * NaplesMilanPath, NaplesTakeOverMinimize (YES), NaplesBar (YES), NaplesPinned (the list of pinned app paths, managed by the dock). */
#import <AppKit/AppKit.h>
#import "NaplesDock.h"
#import "NaplesX.h"
#import "NaplesBar.h"

@interface NaplesApp : NSObject {
	NaplesDock *dock;
	NaplesBar *bar;
}
@end

@implementation NaplesApp

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	if (![d objectForKey: @"NaplesTakeOverMinimize"] || [d boolForKey: @"NaplesTakeOverMinimize"])
		if (NaplesEnsureWMTakeover())
			NSLog(@"Naples: set DisableMiniwindows in the Window Maker defaults; Window Maker applies it within a few seconds "
			      @"(windows minimized before that keep their icon)");
	dock = [[NaplesDock alloc] init];
	[dock start];
	/* the global menu bar: Hexley, the frontmost app's menu, the clock; also the menu server for Eau */
	if (![d objectForKey: @"NaplesBar"] || [d boolForKey: @"NaplesBar"]) {
		bar = [[NaplesBar alloc] initWithDock: dock];
		[bar start];
	}
}

@end

int
main(int argc, const char *argv[])
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NaplesApp *delegate;
	/* the dock is not an application with an app icon of its own */
	[[NSUserDefaults standardUserDefaults] registerDefaults:
	    [NSDictionary dictionaryWithObject: [NSNumber numberWithInt: 1] forKey: @"GSSuppressAppIcon"]];
	[NSApplication sharedApplication];
	delegate = [[NaplesApp alloc] init];
	[NSApp setDelegate: delegate];
	[NSApp run];
	[pool release];
	return 0;
}
