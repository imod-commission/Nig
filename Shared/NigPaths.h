// SPDX-License-Identifier: MIT
//
// Package identity and bootstrap paths, shared by the tweak and the Settings
// pane. A path under the jailbreak root is spelled the way compiled code must
// open it on rootful, rootless and roothide from one source:
//   rootful   the real root, "" in front of the path
//   rootless  /var/jb
//   roothide  the .jbroot-XXXX folder found from this image's own path, never
//             written down because roothide renames it
#pragma once

#import <Foundation/Foundation.h>
#import <dlfcn.h>

#define NIG_PACKAGE_ID "com.imodcommission.nig"

static inline NSString *_Nullable NigBootstrapRoot(void) {
// The build system defines one of these for the target it packages for.
#if defined(NIG_ROOTHIDE) || defined(APELIN_BOOTSTRAP_ROOTHIDE)
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char anchor = 0;
        Dl_info info;
        if (dladdr(&anchor, &info) == 0 || info.dli_fname == NULL) {
            return;
        }
        NSArray<NSString *> *parts =
            [@(info.dli_fname) componentsSeparatedByString:@"/"];
        for (NSUInteger i = 0; i < parts.count; i++) {
            if ([parts[i] hasPrefix:@".jbroot-"]) {
                root = [[parts subarrayWithRange:NSMakeRange(0, i + 1)]
                    componentsJoinedByString:@"/"];
                break;
            }
        }
    });
    return root;
#elif defined(NIG_ROOTLESS) || defined(APELIN_BOOTSTRAP_ROOTLESS)
    return @"/var/jb";
#else
    return @"";
#endif
}

static inline NSString *_Nullable NigRootPath(NSString *_Nonnull path) {
    NSString *root = NigBootstrapRoot();
    return root == nil ? nil : [root stringByAppendingString:path];
}
