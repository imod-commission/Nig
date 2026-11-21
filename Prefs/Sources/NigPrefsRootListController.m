// Nig's Settings pane. Root.plist describes the rows; Preferences stores them
// in the com.imodcommission.nig domain and posts com.imodcommission.nig/changed,
// which SpringBoard (where Nig is loaded too) relays to every app.
#import <Preferences/PSListController.h>

@interface NigPrefsRootListController : PSListController
@end

@implementation NigPrefsRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
