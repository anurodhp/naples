/* NaplesBluetooth: the menu bar's Bluetooth control. The Bluetooth rune left of Wi-Fi (faint with a slash when
 * Bluetooth is off). Clicking it opens a "Bluetooth" panel, as on macOS: an on/off switch, My Devices (the paired
 * keyboards and mice, each Connected or Not Connected; clicking one offers Forget This Device…), Nearby Devices while
 * the panel is open (clicking one pairs it), and Bluetooth Settings… (Settings' Bluetooth pane).
 *
 * Pairing shows a small dialog with the code to type on a keyboard (a PIN, or the Secure Simple Pairing passkey);
 * a mouse pairs without one. Everything goes through iokit's /usr/sbin/btsetup (status, power, scan, pair,
 * forget), which drives NetBSD's Bluetooth tools; without it, or without the controller (boot-arg bt=1), no icon
 * is shown. Calls take seconds (a scan 10 s, pairing up to 90 s), so they run on serial queues. They need root,
 * which the session is on this image. */
#import <AppKit/AppKit.h>

/* the Bluetooth rune in r (about 10 x 15); `off`: faint, with a slash */
void NaplesDrawBluetooth(NSRect r, BOOL off, NSColor *color);

@interface NaplesBluetooth : NSObject {
	void (^changed)(void);
	void (^openSettings)(void);
	dispatch_queue_t queue;	/* status, power, forget */
	dispatch_queue_t scanQueue;	/* scans, which take 10 s */
	BOOL known, on, scanning, showing;
	int powerPending;
	NSArray *devices;	/* paired: NSDictionary {addr, state, name} */
	NSArray *nearby;	/* found by the last scan, paired ones left out: {addr, kind, name} */
	NSString *pairing;	/* the address being paired, nil if none */
	pid_t pairPid;
	NSString *message;	/* a short error for the panel, nil if none */
	NSString *expanded;	/* the paired device whose Forget row shows */
	NSWindow *panelWindow;
	NSView *panelView;
	NSPanel *codePanel;
	NSTextField *codeLabel, *codeField;
	dispatch_source_t pollTimer;
	NSTimeInterval lastScan;
}
/* nil when /usr/sbin/btsetup is not there. `handler` runs on the main thread when anything shown changes;
 * `settings` opens Settings' Bluetooth pane. */
- (id) initWithChangeHandler: (void (^)(void))handler openSettings: (void (^)(void))settings;
- (BOOL) known;	/* the controller answered (until then the bar draws no icon) */
- (BOOL) enabled;
- (BOOL) anyConnected;
- (NSArray *) devices;
- (NSArray *) nearby;
- (BOOL) scanning;
- (NSString *) pairing;
- (NSString *) message;
- (NSString *) expanded;
- (void) setEnabled: (BOOL)v;
- (void) pair: (NSDictionary *)device;	/* an entry of -nearby */
- (void) toggleExpanded: (NSString *)addr;
- (void) forget: (NSDictionary *)device;	/* confirm, then forget */
- (void) showSettings;
/* the panel, hanging under icon (screen coordinates, top-left origin) */
- (void) togglePanelUnder: (NSRect)icon;
- (void) hidePanel;
- (BOOL) panelShowing;
@end
