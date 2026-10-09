/* The Distributed Objects protocol between GNUstep apps (the Eau theme is the client) and the process that draws the
 * global menu bar (Gershwin's Menu.app, here Naples). Identical to Eau.h; the selectors are the wire format.
 *   server: registered as @"org.gnustep.Gershwin.MenuServer"
 *   client: registered by each app as @"org.gnustep.Gershwin.MenuClient.<pid>"
 * menuData: { title, items: [ { title, enabled, state, keyEquivalent, keyEquivalentModifierMask, submenu? }
 *                             | { isSeparator: YES } ] }; an item's index path is its position in `items`, per level. */
#import <Foundation/Foundation.h>

extern NSString *const NaplesMenuServerName;
extern NSString *const NaplesMenuClientPrefix;

@protocol GSGNUstepMenuClient <NSObject>
- (oneway void)activateMenuItemAtPath:(NSArray *)indexPath forWindow:(NSNumber *)windowId;
- (oneway void)requestMenuUpdateForWindow:(NSNumber *)windowId;
- (bycopy id)validateMenuStateForWindow:(NSNumber *)windowId;	/* flat array of @[title, enabled, state], DFS, no separators */
- (oneway void)requestApplicationMenuUpdate;
@end

@protocol GSGNUstepMenuServer <NSObject>
- (oneway void)updateMenuForWindow:(bycopy NSNumber *)windowId
                          menuData:(bycopy NSDictionary *)menuData
                        clientName:(bycopy NSString *)clientName;
- (oneway void)unregisterWindow:(bycopy NSNumber *)windowId
                       clientName:(bycopy NSString *)clientName;
- (oneway void)updateMenuEnabledStatesForWindow:(bycopy NSNumber *)windowId
                                       menuData:(bycopy NSDictionary *)menuData
                                     clientName:(bycopy NSString *)clientName;
- (oneway void)updateMenuForApplication:(bycopy NSDictionary *)menuData
                             clientName:(bycopy NSString *)clientName;
- (oneway void)unregisterApplication:(bycopy NSString *)clientName;
- (oneway void)updateApplicationMenuEnabledStates:(bycopy NSDictionary *)menuData
                                        clientName:(bycopy NSString *)clientName;
@end
