// Nig's Settings pane. Root.plist describes the rows; Preferences stores them
// in the com.imodcommission.nig domain and posts com.imodcommission.nig/changed,
// which SpringBoard (where Nig is loaded too) relays to every app.
#import <Preferences/PSListController.h>
#import <notify.h>
#import "NigSites.h"

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

// The sites Nig leaves alone: one row each, "+" adds, swipe deletes. The list
// is stored as the array `blockedSites` in the same domain; SpringBoard hands
// it on to the apps (see NigPublishBlocklist in the tweak).
@interface NigBlocklistController : PSListController
@end

@implementation NigBlocklistController {
    NSMutableArray<NSString *> *_sites;
}

- (void)loadSites {
    CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    id raw = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("blockedSites"), CFSTR(APELIN_PACKAGE_ID)));
    _sites = [NigNormalizedSites(raw) mutableCopy];
}

- (void)saveSites {
    CFPreferencesSetAppValue(CFSTR("blockedSites"), (__bridge CFArrayRef)[_sites copy], CFSTR(APELIN_PACKAGE_ID));
    CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    notify_post(APELIN_PACKAGE_ID "/changed");
}

- (id)nigSiteValue:(PSSpecifier *)specifier {
    return nil;
}

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        [self loadSites];
        NSMutableArray *rows = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:(_sites.count
                            ? @"Swipe a site to remove it. Pages on these sites are left as they are, in Safari and inside apps. A site covers its subdomains; add a path (example.com/shop) to leave only those pages."
                            : @"No site is excluded. Tap + to add one: a domain such as example.com (its subdomains too) or a page address such as example.com/shop.")
                    forKey:@"footerText"];
        [rows addObject:group];
        for (NSString *site in _sites) {
            [rows addObject:[PSSpecifier preferenceSpecifierNamed:site
                                                           target:self
                                                              set:nil
                                                              get:@selector(nigSiteValue:)
                                                           detail:Nil
                                                             cell:PSTitleValueCell
                                                             edit:Nil]];
        }
        _specifiers = rows;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Excluded sites";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(nigAddSite)];
}

- (void)nigAddSite {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exclude a site"
                                                                   message:@"Enter a domain or a page address."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"example.com";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *__unused action) {
        NSString *text = weakAlert.textFields.firstObject.text;
        [weakSelf nigAddedSite:text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)nigAddedSite:(NSString *)text {
    if (text.length == 0) return;
    NSString *site = NigNormalizeSite(text);
    if (!site) {
        UIAlertController *bad = [UIAlertController alertControllerWithTitle:@"Not an address"
                                                                     message:@"Enter a domain such as example.com."
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [bad addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:bad animated:YES completion:nil];
        return;
    }
    if (![_sites containsObject:site]) {
        [_sites addObject:site];
        [self saveSites];
    }
    [self reloadSpecifiers];
}

#pragma mark - Swipe to delete

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && (NSUInteger)indexPath.row < _sites.count;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self tableView:tableView canEditRowAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete
                                                                      : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)style
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete || ![self tableView:tableView canEditRowAtIndexPath:indexPath]) return;
    [_sites removeObjectAtIndex:(NSUInteger)indexPath.row];
    [self saveSites];
    [self reloadSpecifiers];
}

@end
