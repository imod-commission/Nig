// SPDX-License-Identifier: MIT
//
// The one spelling of an excluded site, shared by the Settings pane (which
// stores it) and the tweak (which reads it back): lower case, no scheme, no
// user, port, query or fragment, no trailing slash: "example.com" or
// "example.com/shop". A site covers its sub-domains; one with a path covers
// the pages below that path.
#pragma once

#import <Foundation/Foundation.h>

static inline NSString *_Nullable NigNormalizeSite(NSString *_Nullable input) {
    if (![input isKindOfClass:[NSString class]]) return nil;
    NSString *s = [[input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                      lowercaseString];
    NSRange scheme = [s rangeOfString:@"://"];
    if (scheme.location != NSNotFound) s = [s substringFromIndex:NSMaxRange(scheme)];
    NSRange cut = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    if (cut.location != NSNotFound) s = [s substringToIndex:cut.location];
    while ([s hasPrefix:@"*."] || [s hasPrefix:@"."]) s = [s substringFromIndex:[s hasPrefix:@"*."] ? 2 : 1];
    NSRange slash = [s rangeOfString:@"/"];
    NSString *host = slash.location == NSNotFound ? s : [s substringToIndex:slash.location];
    NSString *path = slash.location == NSNotFound ? @"" : [s substringFromIndex:slash.location];
    NSRange at = [host rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound) host = [host substringFromIndex:NSMaxRange(at)];
    NSRange colon = [host rangeOfString:@":"];
    if (colon.location != NSNotFound && ![host hasPrefix:@"["]) host = [host substringToIndex:colon.location];
    while ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if (host.length == 0) return nil;
    if ([host rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return nil;
    return [host stringByAppendingString:path];
}

// A stored list, cleaned: normalised, without empties and duplicates, in order.
static inline NSArray<NSString *> *_Nonnull NigNormalizedSites(id _Nullable raw) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![raw isKindOfClass:[NSArray class]]) return out;
    for (id item in (NSArray *)raw) {
        NSString *site = NigNormalizeSite(item);
        if (site && ![out containsObject:site]) [out addObject:site];
    }
    return out;
}
