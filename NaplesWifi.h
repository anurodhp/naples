/* NaplesWifi: the menu bar's Wi-Fi control. A Wi-Fi fan left of the volume whose arcs follow the signal of the network
 * the Pi is on (faint arcs: on but not connected; faint with a slash: off). Clicking it opens a "Wi-Fi" panel with an
 * on/off switch, the network it is connected to, and the networks in range; clicking one joins it, asking for the
 * password in a small dialog when it is secured and not the remembered one. Option-clicking the icon also shows the
 * connection's details under the network in use, as macOS does: IP address, router, channel and band, security,
 * 802.11 protocol, RSSI and noise, transmit rate, and "Forget This Network…" for the remembered one.
 *
 * It talks to iokit's BCM43430Wifi driver directly, through its user client (the ABI in iokit's
 * iokit/BCM43430Wifi/BCM43430WifiShared.h, the same one /usr/sbin/wifi uses), with IOKitLib opened by dlopen from
 * /usr/lib/libiokituser.dylib: an image without the library or a kernel without wifi=1 shows no icon. Every call can
 * block (a scan takes seconds, a join up to 20 s), so they run on a serial queue, never on the main thread.
 *
 * The driver's methods other than status need root, which the session is on this image. Joining remembers the network
 * in /etc/wifi.conf (mode 600), which the boot job org.puredarwin.wifi joins at startup; turning Wi-Fi off leaves
 * /etc/wifi.off, which keeps the radio off at the next boot. The address comes from IPConfiguration
 * (`ipconfig set en1 DHCP`) after a join, as the boot job does it. */
#import <AppKit/AppKit.h>

/* the Wi-Fi fan in r (about 18 x 14): `bars` 0-3 arcs drawn solid, the rest faint; `off` adds a slash */
void NaplesDrawWifi(NSRect r, int bars, BOOL off, NSColor *color);
/* arcs for a signal: 3 at -60 dBm or better, 2 at -72 or better, else 1 */
int NaplesWifiBars(int rssi);

@interface NaplesWifi : NSObject {
	void (^changed)(void);
	dispatch_queue_t queue;
	unsigned int conn;	/* io_connect_t, used on `queue` only */
	BOOL known;	/* the driver answered (until then the bar draws no icon) */
	BOOL firmwareUp, radioOff, associated, scanning, showing;
	int powerPending;	/* on/off calls queued and not yet answered */
	uint32_t fwState;	/* kWifiState* from the last status */
	BOOL securedNow;	/* the connected network was joined with WPA2 */
	NSString *remembered;	/* the SSID in /etc/wifi.conf, read with each status */
	NSDictionary *autoJoin;	/* the remembered network, to join once a scan after turning on finds it */
	NSString *ssid;	/* the connected network */
	int rssi;
	NSArray *networks;	/* NSDictionary {ssid, rssi, secure}, strongest first, one per name, the connected one left out */
	NSString *joining;	/* the network a join is in progress for, nil if none */
	NSString *message;	/* a short error for the panel, nil if none */
	BOOL showDetails;	/* the panel was opened with Option */
	NSArray *details;	/* NSArray pairs {label, value} for the connected network, nil if not associated */
	NSString *ipAddress, *router;	/* en1's address and router, read when the details show */
	NSWindow *panelWindow;
	NSView *panelView;
	NSPanel *passwordPanel;
	NSSecureTextField *passwordField;
	NSTextField *passwordLabel;
	NSString *passwordFor;
	dispatch_source_t pollTimer;
	NSTimeInterval lastScan;
}
/* nil when /usr/lib/libiokituser.dylib is not there. `handler` runs on the main thread when anything shown changes. */
- (id) initWithChangeHandler: (void (^)(void))handler;
- (BOOL) known;
- (BOOL) enabled;	/* firmware running and the radio on */
- (BOOL) associated;
- (NSString *) ssid;
- (int) rssi;
- (NSArray *) networks;
- (BOOL) scanning;
- (NSString *) joining;
- (NSString *) message;
- (void) setEnabled: (BOOL)on;
- (void) joinNetwork: (NSDictionary *)net;	/* an entry of -networks */
- (BOOL) remembersCurrent;	/* the connected network is the one in /etc/wifi.conf */
- (void) forgetCurrent;	/* confirm, then disconnect and forget it */
/* the panel, hanging under icon (screen coordinates, top-left origin) */
- (void) togglePanelUnder: (NSRect)icon;
- (void) togglePanelUnder: (NSRect)icon details: (BOOL)withDetails;	/* Option-click */
- (BOOL) showsDetails;
- (BOOL) securedNow;	/* the connected network uses WPA2 */
- (NSArray *) details;
- (void) hidePanel;
- (BOOL) panelShowing;
@end
