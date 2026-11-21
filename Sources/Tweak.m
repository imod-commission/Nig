// SPDX-License-Identifier: MIT
//
// Nig: dark mode for apps that do not support it.
//
// Ported from the Logos tweak (Tweak.xm) to Apelin's plain Objective-C hooks.
// Design notes (what changed from the original and why):
//  * Dark colours become a LIGHTER COUNTERPART OF THE SAME COLOUR (hue kept),
//    not flat white. Neutral greys stay grey, so hierarchy survives.
//  * Every colour transform is idempotent (a second pass changes nothing) and
//    the app's original colour is remembered per view, so repeated refreshes
//    no longer flip colours back and forth, and light mode can be restored.
//  * Text is only lightened when what is behind it is (or will be) dark. Text
//    over images, gradients or a backdrop that stays light keeps its colour.
//  * Dark backgrounds are never flipped to light, so white text stays visible.
//  * Apps that already follow the system appearance are left alone.
//  * No more timers or writes into every app's container: the system style is
//    read from the global preferences inside the app.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <math.h>
#import <notify.h>
#import <substrate.h>
// WebKit is reached at run time only (no link): apps without a web view
// never load it because of Nig.
#import <WebKit/WebKit.h>
#import <Vision/Vision.h>
#import "NigWebScript.h"

#pragma mark - Logging

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

#pragma mark - Barcode detection

typedef void (^NigBarcodeCompletion)(NSArray<NSValue *> *rects);
static dispatch_queue_t gBarcodeQueue;

// Vision runs off the host's main thread. Results are normalized image-space
// rectangles and delivered on main for UIKit/WebKit state updates.
static void NigDetectBarcodes(CGImageRef image, NigBarcodeCompletion completion) {
    if (!image || !completion) return;
    CGImageRetain(image);
    dispatch_async(gBarcodeQueue, ^{
        @autoreleasepool {
            VNDetectBarcodesRequest *request = [VNDetectBarcodesRequest new];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
            NSError *error = nil;
            BOOL ok = [handler performRequests:@[request] error:&error];
            NSMutableArray<NSValue *> *rects = [NSMutableArray array];
            if (ok) {
                for (VNBarcodeObservation *observation in request.results) {
                    CGRect box = observation.boundingBox;
                    if (!CGRectIsEmpty(box) && isfinite(box.origin.x) && isfinite(box.origin.y) &&
                        isfinite(box.size.width) && isfinite(box.size.height)) {
                        [rects addObject:[NSValue valueWithCGRect:box]];
                    }
                }
            } else if (error) {
                os_log(TweakLog(), "ApelinBarcode Vision error %{public}@", error.localizedDescription);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(rects);
                CGImageRelease(image);
            });
        }
    });
}

#pragma mark - State

// True while the system is dark AND the host app itself renders light.
static BOOL gDarkModeActive = NO;
static BOOL gEverActive = NO;
static BOOL gRefreshPending = NO;
static const void *kNigBarcodeSource = &kNigBarcodeSource;
static const void *kNigBarcodeAnchorCount = &kNigBarcodeAnchorCount;
static const void *kNigBarcodeAnchorForSource = &kNigBarcodeAnchorForSource;
static const void *kNigBarcodeSnapshotToken = &kNigBarcodeSnapshotToken;
static const void *kNigBarcodeLastSnapshotTime = &kNigBarcodeLastSnapshotTime;
static NSUInteger gBarcodeSnapshotBudget = 0;

@interface NigBarcodeWeakViewBox : NSObject
@property (nonatomic, weak) UIView *view;
@end
@implementation NigBarcodeWeakViewBox
@end

static BOOL NigHasBarcodeProtection(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([objc_getAssociatedObject(v, kNigBarcodeSource) boolValue] ||
            [objc_getAssociatedObject(v, kNigBarcodeAnchorCount) unsignedIntegerValue] > 0) return YES;
    }
    return NO;
}

static void NigClearBarcodeProtection(UIView *view) {
    if (![objc_getAssociatedObject(view, kNigBarcodeSource) boolValue]) return;
    NigBarcodeWeakViewBox *box = objc_getAssociatedObject(view, kNigBarcodeAnchorForSource);
    UIView *anchor = box.view;
    objc_setAssociatedObject(view, kNigBarcodeSource, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kNigBarcodeAnchorForSource, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!anchor) return;
    NSUInteger count = [objc_getAssociatedObject(anchor, kNigBarcodeAnchorCount) unsignedIntegerValue];
    if (count <= 1) objc_setAssociatedObject(anchor, kNigBarcodeAnchorCount, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    else objc_setAssociatedObject(anchor, kNigBarcodeAnchorCount, @(count - 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// Set while Nig itself changes a property, so the hooks let it through.
static __thread BOOL tInHook = NO;
// While a view draws itself: 1 = it sits on a surface Nig made dark, 2 = it does not,
// 0 = not inside a view's drawLayer:inContext: at all. Core Graphics colour
// hooks only act in state 1, so glyphs are never lightened over a light surface.
static __thread int tDrawState = 0;
// How the app itself resolves dynamic colours: dark when the app follows the
// system appearance (its dynamic colours are then already dark), light when it
// is locked to light. Fixed by the window's real trait in NigRefresh.
static UIUserInterfaceStyle gResolveStyle = UIUserInterfaceStyleLight;
static UITraitCollection *gResolveTraits = nil;
// The traits of the view whose colours are being read right now. An app can
// lock one view controller to light while its window follows the system, so
// a dynamic colour is resolved the way that view itself renders it.
static __thread __unsafe_unretained UITraitCollection *tTraits = nil;
// Reads colours with `view`'s traits until NIG_END_TRAITS() in the same scope.
// The strong local keeps the trait collection alive while tTraits points at it.
#define NIG_WITH_TRAITS(view)                                         \
    UITraitCollection *__nigSavedTraits = tTraits;                    \
    UITraitCollection *__nigTraits = (view).traitCollection;          \
    tTraits = __nigTraits
#define NIG_END_TRAITS() do { tTraits = __nigSavedTraits; (void)__nigTraits; } while (0)
// The background of the view drawing itself (tDrawState 1), so that the
// fill of its own background is not taken for a glyph and lightened.
static __thread BOOL tDrawBgValid = NO;
static __thread CGFloat tDrawBg[3];

typedef NS_ENUM(NSInteger, NigRole) {
    NigRoleText,        // text, tint, glyph fills: lighten, keep hue
    NigRoleBackground,  // surfaces: darken, never flip dark to light
    NigRoleBorder,      // hairlines: dim but keep visible
};

typedef NS_ENUM(NSInteger, NigBackdrop) {
    NigBackdropDark,   // a solid surface known to be dark
    NigBackdropLight,  // a solid surface known to be light
    NigBackdropMedia,  // image, gradient, custom drawing, or unknown: do not guess
};

#pragma mark - Colour maths

static void NigRGBToHSL(CGFloat r, CGFloat g, CGFloat b, CGFloat *h, CGFloat *s, CGFloat *l) {
    CGFloat mx = MAX(MAX(r, g), b), mn = MIN(MIN(r, g), b);
    CGFloat light = (mx + mn) / 2.0, hue = 0.0, sat = 0.0;
    if (mx != mn) {
        CGFloat d = mx - mn;
        sat = (light > 0.5) ? d / (2.0 - mx - mn) : d / (mx + mn);
        if (mx == r)      hue = (g - b) / d + (g < b ? 6.0 : 0.0);
        else if (mx == g) hue = (b - r) / d + 2.0;
        else              hue = (r - g) / d + 4.0;
        hue /= 6.0;
    }
    *h = hue; *s = sat; *l = light;
}

static CGFloat NigHueToRGB(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0) t += 1.0;
    if (t > 1) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

static void NigHSLToRGB(CGFloat h, CGFloat s, CGFloat l, CGFloat *r, CGFloat *g, CGFloat *b) {
    if (s <= 0.0) { *r = *g = *b = l; return; }
    CGFloat q = (l < 0.5) ? l * (1.0 + s) : l + s - l * s;
    CGFloat p = 2.0 * l - q;
    *r = NigHueToRGB(p, q, h + 1.0 / 3.0);
    *g = NigHueToRGB(p, q, h);
    *b = NigHueToRGB(p, q, h - 1.0 / 3.0);
}

// Maps one colour for a role. Returns NO when it should stay as it is.
// Every branch lands in a range its own gate leaves alone: idempotent.
static BOOL NigMapRGB(NigRole role, CGFloat r, CGFloat g, CGFloat b,
                      CGFloat *nr, CGFloat *ng, CGFloat *nb) {
    CGFloat mx = MAX(MAX(r, g), b), mn = MIN(MIN(r, g), b);
    CGFloat h, s, l;
    NigRGBToHSL(r, g, b, &h, &s, &l);
    CGFloat chroma = mx - mn;
    CGFloat hsvSat = (mx > 0.0001) ? chroma / mx : 0.0;

    switch (role) {
        case NigRoleText: {
            if (l >= 0.6) return NO;  // already readable on a dark surface
            CGFloat t = l / 0.6;
            if (chroma < 0.1 || hsvSat < 0.25) {
                // Neutral: black -> 0.95, mid grey stays a grey (0.65 at the gate).
                CGFloat v = 0.95 - 0.30 * t;
                *nr = *ng = *nb = v;
            } else {
                // Same hue, lighter. Lightness 0.64 ... 0.72.
                CGFloat nl = 0.72 - 0.08 * t;
                NigHSLToRGB(h, MIN(s, 0.92), nl, nr, ng, nb);
            }
            return YES;
        }
        case NigRoleBackground: {
            if (chroma < 0.1 || hsvSat < 0.3) {
                if (l > 0.3) { *nr = *ng = *nb = 0.1; return YES; }
                return NO;
            }
            if (l <= 0.62) return NO;  // brand colours and darker keep their colour
            CGFloat nl = MIN(MAX(1.0 - l, 0.14), 0.45);
            NigHSLToRGB(h, s * 0.75, nl, nr, ng, nb);
            return YES;
        }
        case NigRoleBorder: {
            if (chroma < 0.1 || hsvSat < 0.3) {
                if (l <= 0.45) return NO;
                CGFloat v = 0.15 + (1.0 - l) * 0.45;
                *nr = *ng = *nb = v;
                return YES;
            }
            return NigMapRGB(NigRoleBackground, r, g, b, nr, ng, nb);
        }
    }
    return NO;
}

static UITraitCollection *NigLightTraits(void) {
    static UITraitCollection *traits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    });
    return traits;
}

// Components of a colour as the light app sees it (dynamic colours resolved light).
static void NigSetResolveStyle(UIUserInterfaceStyle style) {
    gResolveStyle = style;
    gResolveTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:style];
}

static BOOL NigGetRGBA(UIColor *color, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (!color) return NO;
    // Resolved the way the app resolves it: an app that follows the system
    // style already has dark dynamic colours, which must not be "fixed" again.
    UITraitCollection *traits = tTraits ?: (gResolveTraits ?: NigLightTraits());
    UIColor *resolved = [color resolvedColorWithTraitCollection:traits] ?: color;
    return [resolved getRed:r green:g blue:b alpha:a];
}

// The transformed colour, or nil when it should stay.
static UIColor *NigTransformColor(UIColor *color, NigRole role) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (!NigGetRGBA(color, &r, &g, &b, &a) || a < 0.01) return nil;
    CGFloat nr, ng, nb;
    if (!NigMapRGB(role, r, g, b, &nr, &ng, &nb)) return nil;
    return [UIColor colorWithRed:nr green:ng blue:nb alpha:a];
}

// Same for a CGColor drawn straight into a context. Caller releases.
static CGColorRef NigCopyTransformedCGColor(CGColorRef color, NigRole role) {
    CGColorSpaceRef space = CGColorGetColorSpace(color);
    if (!space) return NULL;
    CGColorSpaceModel model = CGColorSpaceGetModel(space);
    size_t n = CGColorGetNumberOfComponents(color);
    const CGFloat *c = CGColorGetComponents(color);
    if (!c) return NULL;
    CGFloat r, g, b, a;
    if (model == kCGColorSpaceModelRGB && n >= 3) {
        r = c[0]; g = c[1]; b = c[2]; a = (n >= 4) ? c[3] : 1.0;
    } else if (model == kCGColorSpaceModelMonochrome && n >= 1) {
        r = g = b = c[0]; a = (n >= 2) ? c[1] : 1.0;  // [UIColor blackColor] is gray
    } else {
        return NULL;
    }
    if (a < 0.01) return NULL;
    CGFloat nr, ng, nb;
    if (!NigMapRGB(role, r, g, b, &nr, &ng, &nb)) return NULL;
    return CGColorCreateSRGB(nr, ng, nb, a);
}

#pragma mark - System UI and appearance

static BOOL NigClassIsSystemUI(Class cls) {
    static CFMutableDictionaryRef cache;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (!cache) cache = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    const void *cached = CFDictionaryGetValue(cache, (__bridge const void *)cls);
    os_unfair_lock_unlock(&lock);
    if (cached) return cached == (const void *)1;

    NSString *name = NSStringFromClass(cls);
    BOOL system = [name containsString:@"UIKB"] || [name containsString:@"Keyboard"] ||
                  [name containsString:@"InputView"] || [name containsString:@"UITextEffects"];
    os_unfair_lock_lock(&lock);
    CFDictionarySetValue(cache, (__bridge const void *)cls, system ? (const void *)1 : (const void *)2);
    os_unfair_lock_unlock(&lock);
    return system;
}

// The keyboard and its windows are not Nig's to recolour.
static BOOL NigIsSystemUI(UIView *view) {
    NSInteger depth = 0;
    for (UIView *v = view; v && depth < 80; v = v.superview, depth++) {
        if (NigClassIsSystemUI([v class])) return YES;
    }
    return NO;
}

// An app's own traits cannot tell the system style: an app locked to light
// mode sees light everywhere. SpringBoard (which Nig also loads into) always
// knows, and publishes it as the state of a Darwin notification that any
// sandboxed app can read. 0 = not published yet, 1 = light, 2 = dark.
static const char *const kStyleNotification = "com.imodcommission.nig.style";

static int NigPublishedStyle(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(kStyleNotification, &token) != NOTIFY_STATUS_OK) token = NOTIFY_TOKEN_INVALID;
    });
    if (token == NOTIFY_TOKEN_INVALID) return 0;
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return 0;
    return (int)state;
}

static void NigPublishStyleIfChanged(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    static uint64_t last = 0;
    if (token == NOTIFY_TOKEN_INVALID &&
        notify_register_check(kStyleNotification, &token) != NOTIFY_STATUS_OK) {
        token = NOTIFY_TOKEN_INVALID;
        return;
    }
    uint64_t now = ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? 2 : 1;
    if (now == last) return;
    last = now;
    notify_set_state(token, now);
    notify_post(kStyleNotification);
    os_log(TweakLog(), "ApelinPublished style=%llu", now);
}

static BOOL NigSystemIsDark(BOOL allowScreen) {
    int published = NigPublishedStyle();
    if (published != 0) return published == 2;
    // SpringBoard has not published yet (it loads Nig only after a respring):
    // fall back to what the app itself can see.
    BOOL dark = NO;
    id style = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleInterfaceStyle"];
    if ([style isKindOfClass:[NSString class]]) dark = [style isEqualToString:@"Dark"];
    if (!dark && allowScreen) {
        dark = ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    }
    return dark;
}

#pragma mark - Settings

// The Settings pane stores `enabled` and `web` in the package's preferences
// domain and posts kPrefsChanged. A sandboxed app cannot read another
// domain, so SpringBoard reads them and publishes them as the state of
// kPrefsNotification, as it does the style. 0 (also: not published yet) is
// the default, everything on; bit 0 = Nig off, bit 1 = web pages off.
static const char *const kPrefsChanged = APELIN_PACKAGE_ID "/changed";
static const char *const kPrefsNotification = "com.imodcommission.nig.prefs";
static BOOL gNigEnabled = YES;  // read in NigRefresh
static BOOL gWebEnabled = YES;  // web pages inside apps

static BOOL NigPrefBool(CFStringRef key, BOOL fallback) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CFSTR(APELIN_PACKAGE_ID));
    BOOL out = fallback;
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
        out = CFBooleanGetValue((CFBooleanRef)v);
    } else if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        int i = 0;
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i);
        out = i != 0;
    }
    if (v) CFRelease(v);
    return out;
}

// SpringBoard only.
static void NigPublishPrefs(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID &&
        notify_register_check(kPrefsNotification, &token) != NOTIFY_STATUS_OK) {
        token = NOTIFY_TOKEN_INVALID;
        return;
    }
    CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
    uint64_t state = (NigPrefBool(CFSTR("enabled"), YES) ? 0 : 1) | (NigPrefBool(CFSTR("web"), YES) ? 0 : 2);
    notify_set_state(token, state);
    notify_post(kPrefsNotification);
    os_log(TweakLog(), "ApelinPrefs state=%llu", state);
}

static void NigReadPrefs(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(kPrefsNotification, &token) != NOTIFY_STATUS_OK) token = NOTIFY_TOKEN_INVALID;
    });
    uint64_t state = 0;
    if (token != NOTIFY_TOKEN_INVALID) notify_get_state(token, &state);
    gNigEnabled = !(state & 1);
    gWebEnabled = gNigEnabled && !(state & 2);
}

#pragma mark - Per-view memory of the app's own colours

static const void *kNigStoreKey = &kNigStoreKey;
static NSString *const kBg = @"bg";
static NSString *const kText = @"text";
static NSString *const kHiText = @"hiText";
static NSString *const kAttr = @"attr";
static NSString *const kAttrOut = @"attrOut";
static NSString *const kTint = @"tint";
static NSString *const kBorder = @"border";
static NSString *const kOverride = @"override";
static NSString *const kKeyboard = @"keyboard";
static NSString *const kPlaceholder = @"placeholder";
static NSString *const kPlaceholderOut = @"placeholderOut";
static NSString *const kLayerBg = @"layerBg";
static NSString *const kShapeFill = @"shapeFill";

static id NigStoreGet(id obj, NSString *key) {
    NSMutableDictionary *d = objc_getAssociatedObject(obj, kNigStoreKey);
    return d[key];
}

static void NigStoreSet(id obj, NSString *key, id value) {
    NSMutableDictionary *d = objc_getAssociatedObject(obj, kNigStoreKey);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(obj, kNigStoreKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    d[key] = value;
}

static void NigStoreRemove(id obj, NSString *key) {
    NSMutableDictionary *d = objc_getAssociatedObject(obj, kNigStoreKey);
    [d removeObjectForKey:key];
}

#pragma mark - What is behind a view?

static CGFloat NigLuma(CGFloat r, CGFloat g, CGFloat b) {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

static BOOL NigIsPlainSublayer(CALayer *s, CALayer *parent) {
    if ([s.delegate isKindOfClass:[UIView class]]) return NO;  // a subview's own layer
    CGRect pb = parent.bounds;
    return CGRectGetWidth(s.frame) >= 0.5 * CGRectGetWidth(pb) &&
           CGRectGetHeight(s.frame) >= 0.5 * CGRectGetHeight(pb);
}

// Layer contents that are an image the app set (a photo, a banner). A view
// that draws itself has a backing store there instead, which says nothing
// about what the view looks like: its fills are handled while it draws.
static BOOL NigIsCGImage(id contents) {
    return contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID();
}

// What a layer's image looks like at `p` (in the layer's coordinates).
// Frameworks such as Taobao's MUS give every box a bitmap of its own,
// usually transparent but for a border or a corner: such a bitmap is no
// surface where the text is, and the search goes on (answers NO). Where it
// is opaque, its colour there decides. Images that cannot be mapped
// simply (gravity other than resize, huge ones) stay media.
// Answers are cached on the layer per image and spot, so a bitmap is read
// once, not on every query.
static NSString *const kImageLook = @"imageLook";  // @{ img, spots }
static BOOL NigImageLookAt(CALayer *layer, CGPoint p, NigBackdrop *out) {
    CGImageRef image = (__bridge CGImageRef)layer.contents;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    CGRect b = layer.bounds;
    if (w == 0 || h == 0 || w * h > 4000000 || CGRectIsEmpty(b) ||
        ![layer.contentsGravity isEqualToString:kCAGravityResize]) {
        *out = NigBackdropMedia;
        return YES;
    }
    CGFloat u = MIN(MAX((p.x - b.origin.x) / b.size.width, 0), 1);
    CGFloat v = MIN(MAX((p.y - b.origin.y) / b.size.height, 0), 1);
    CGRect cc = layer.contentsCenter;
    if (!CGRectEqualToRect(cc, CGRectMake(0, 0, 1, 1))) {
        // A stretchable image (a bubble, a card): its middle is what fills.
        u = CGRectGetMidX(cc);
        v = CGRectGetMidY(cc);
    }
    CGRect cr = layer.contentsRect;
    u = cr.origin.x + u * cr.size.width;
    v = cr.origin.y + v * cr.size.height;
    size_t x = MIN((size_t)(u * w), w - 1), y = MIN((size_t)(v * h), h - 1);

    BOOL main = [NSThread isMainThread];
    NSNumber *spot = @((x / 4) << 20 | (y / 4));
    NSMutableDictionary *spots = nil;
    if (main) {
        NSDictionary *cache = NigStoreGet(layer, kImageLook);
        if (cache && cache[@"img"] == (__bridge id)image) {
            spots = cache[@"spots"];
            NSNumber *hit = spots[spot];
            if (hit) {
                if (hit.integerValue < 0) return NO;
                *out = (NigBackdrop)hit.integerValue;
                return YES;
            }
        } else {
            spots = [NSMutableDictionary dictionary];
            NigStoreSet(layer, kImageLook, @{ @"img": (__bridge id)image, @"spots": spots });
        }
    }

    uint8_t px[4] = {0, 0, 0, 0};
    CGImageRef crop = CGImageCreateWithImageInRect(image, CGRectMake(x, y, 1, 1));
    if (crop) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        if (ctx) {
            CGContextSetBlendMode(ctx, kCGBlendModeCopy);
            CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), crop);
            CGContextRelease(ctx);
        }
        CGImageRelease(crop);
    }
    NSInteger result;
    if (px[3] < 153) {
        result = -1;  // see-through here
    } else {
        CGFloat a = px[3] / 255.0;
        CGFloat r = px[0] / 255.0 / a, g = px[1] / 255.0 / a, bl = px[2] / 255.0 / a;
        result = NigLuma(r, g, bl) > 0.55 ? NigBackdropLight : NigBackdropDark;
    }
    if (spots && spots.count < 64) spots[spot] = @(result);
    if (result < 0) return NO;
    *out = (NigBackdrop)result;
    return YES;
}

// What a view painted below another one (an earlier sibling) looks like.
// Answers NO when it has no look of its own there, so the search goes on.
static BOOL NigSiblingLook(UIView *s, CGPoint pp, NigBackdrop *out) {
    if (s.hidden || s.alpha < 0.05) return NO;
    if ([s isKindOfClass:[UIVisualEffectView class]]) { *out = NigBackdropDark; return YES; }
    if ([s isKindOfClass:[UIImageView class]] && ((UIImageView *)s).image) { *out = NigBackdropMedia; return YES; }
    CALayer *layer = s.layer;
    CGPoint sp = [s convertPoint:pp fromView:s.superview];
    if ([layer isKindOfClass:[CAGradientLayer class]]) { *out = NigBackdropMedia; return YES; }
    if (NigIsCGImage(layer.contents) && NigImageLookAt(layer, sp, out)) return YES;
    NSArray<CALayer *> *subs = layer.sublayers;
    NSUInteger n = MIN(subs.count, (NSUInteger)4);
    for (NSUInteger i = 0; i < n; i++) {
        CALayer *sub = subs[i];
        if (!NigIsPlainSublayer(sub, layer)) continue;
        if ([sub isKindOfClass:[CAGradientLayer class]]) { *out = NigBackdropMedia; return YES; }
        if (NigIsCGImage(sub.contents)) {
            CGPoint subp = [layer convertPoint:sp toLayer:sub];
            if (CGRectContainsPoint(sub.bounds, subp) && NigImageLookAt(sub, subp, out)) return YES;
        }
    }
    CGFloat r, g, b, a;
    UIColor *bg = s.backgroundColor;
    if (bg) {
        if (!NigGetRGBA(bg, &r, &g, &b, &a)) { *out = NigBackdropMedia; return YES; }
    } else if (layer.backgroundColor) {
        if (!NigGetRGBA([UIColor colorWithCGColor:layer.backgroundColor], &r, &g, &b, &a)) return NO;
    } else {
        return NO;
    }
    if (a * s.alpha < 0.6) return NO;
    *out = NigLuma(r, g, b) > 0.55 ? NigBackdropLight : NigBackdropDark;
    return YES;
}

// Classifies the first thing behind `view` that has a look of its own:
// the view itself, then what its parent paints below it (earlier siblings
// that cover it: SwiftUI and many apps put a card or a gradient beside the
// text rather than above it), then the parent, and so on up.
// `why`, when given, names the view or layer that decided (for the dump).
#define NIG_WHY(fmt, ...) do { if (why) *why = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; } while (0)
static NigBackdrop NigBackdropExplainInner(UIView *view, NSString **why) {
    NSInteger depth = 0;
    CGPoint p = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    for (UIView *v = view; v && depth < 60; v = v.superview, depth++) {
        UITraitCollection *vt = v.traitCollection;
        tTraits = vt;
        // Blur bars are forced dark by Nig (see NigApplySelf).
        if ([v isKindOfClass:[UIVisualEffectView class]]) {
            NIG_WHY(@"%@ %p effect", NSStringFromClass([v class]), v);
            return NigBackdropDark;
        }
        CALayer *layer = v.layer;

        if (v != view) {
            if ([v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image) {
                NIG_WHY(@"%@ %p image", NSStringFromClass([v class]), v);
                return NigBackdropMedia;
            }
            if ([layer isKindOfClass:[CAGradientLayer class]]) {
                NIG_WHY(@"%@ %p gradient", NSStringFromClass([v class]), v);
                return NigBackdropMedia;
            }
            if (NigIsCGImage(layer.contents)) {
                NigBackdrop look;
                if (NigImageLookAt(layer, p, &look)) {
                    NIG_WHY(@"%@ %p contents", NSStringFromClass([v class]), v);
                    return look;
                }
            }

            NSArray<CALayer *> *subs = layer.sublayers;
            NSUInteger n = MIN(subs.count, (NSUInteger)8);
            for (NSUInteger i = 0; i < n; i++) {
                CALayer *s = subs[i];
                if (!NigIsPlainSublayer(s, layer)) continue;
                if ([s isKindOfClass:[CAGradientLayer class]]) {
                    NIG_WHY(@"%@ %p sublayer %@ media", NSStringFromClass([v class]), v, NSStringFromClass([s class]));
                    return NigBackdropMedia;
                }
                if (NigIsCGImage(s.contents)) {
                    CGPoint sp = [layer convertPoint:p toLayer:s];
                    NigBackdrop look;
                    if (CGRectContainsPoint(s.bounds, sp) && NigImageLookAt(s, sp, &look)) {
                        NIG_WHY(@"%@ %p sublayer %@ image", NSStringFromClass([v class]), v, NSStringFromClass([s class]));
                        return look;
                    }
                    continue;
                }
                CGColorRef fill = [s isKindOfClass:[CAShapeLayer class]] ? ((CAShapeLayer *)s).fillColor : s.backgroundColor;
                if (fill && CGColorGetAlpha(fill) >= 0.6) {
                    UIColor *c = [UIColor colorWithCGColor:fill];
                    CGFloat r, g, b, a;
                    NIG_WHY(@"%@ %p sublayer %@ %p fill", NSStringFromClass([v class]), v, NSStringFromClass([s class]), s);
                    if (NigGetRGBA(c, &r, &g, &b, &a)) {
                        return NigLuma(r, g, b) > 0.55 ? NigBackdropLight : NigBackdropDark;
                    }
                    return NigBackdropMedia;
                }
            }
        }

        UIColor *bg = v.backgroundColor;
        if (bg) {
            CGFloat r, g, b, a;
            if (!NigGetRGBA(bg, &r, &g, &b, &a)) {
                NIG_WHY(@"%@ %p pattern", NSStringFromClass([v class]), v);
                return NigBackdropMedia;  // pattern colour
            }
            if (a >= 0.6) {
                NIG_WHY(@"%@ %p bg", NSStringFromClass([v class]), v);
                return NigLuma(r, g, b) > 0.55 ? NigBackdropLight : NigBackdropDark;
            }
        } else if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) >= 0.6) {
            CGFloat r, g, b, a;
            if (NigGetRGBA([UIColor colorWithCGColor:layer.backgroundColor], &r, &g, &b, &a)) {
                NIG_WHY(@"%@ %p layerBg", NSStringFromClass([v class]), v);
                return NigLuma(r, g, b) > 0.55 ? NigBackdropLight : NigBackdropDark;
            }
        }

        // Siblings painted below `v` that cover the view's centre, nearest first.
        UIView *parent = v.superview;
        if (!parent) break;
        CGPoint pp = [v convertPoint:p toView:parent];
        NSArray<UIView *> *siblings = parent.subviews;
        NSUInteger idx = [siblings indexOfObjectIdenticalTo:v];
        if (idx != NSNotFound) {
            NSUInteger checked = 0;
            for (NSInteger i = (NSInteger)idx - 1; i >= 0 && checked < 24; i--, checked++) {
                UIView *s = siblings[(NSUInteger)i];
                if (!CGRectContainsPoint(s.frame, pp)) continue;
                NigBackdrop look;
                if (NigSiblingLook(s, pp, &look)) {
                    NIG_WHY(@"%@ %p below", NSStringFromClass([s class]), s);
                    return look;
                }
            }
        }
        p = pp;
    }
    NIG_WHY(@"nothing solid up to the window");
    return NigBackdropMedia;
}

static NigBackdrop NigBackdropExplain(UIView *view, NSString **why) {
    UITraitCollection *saved = tTraits;
    NigBackdrop result = NigBackdropExplainInner(view, why);
    tTraits = saved;
    return result;
}

static NigBackdrop NigBackdropOf(UIView *view) {
    return NigBackdropExplain(view, NULL);
}

// Use only stable, explicit surface information. Rendering the entire window
// separately for every small text view is costly and can race page transitions;
// images, gradients and unclassified custom drawing stay untouched.
static NigBackdrop NigTextBackdrop(UIView *view) {
    return NigBackdropOf(view);
}

#pragma mark - Decisions

static UIColor *NigDesiredBackground(UIColor *orig) {
    return NigTransformColor(orig, NigRoleBackground);
}

// Text only follows when the surface behind it is dark.
static UIColor *NigDesiredText(UIView *view, UIColor *orig) {
    if (!orig || NigTransformColor(orig, NigRoleText) == nil) return nil;  // cheap test first
    if (NigTextBackdrop(view) != NigBackdropDark) return nil;
    return NigTransformColor(orig, NigRoleText);
}

static NSAttributedString *NigTransformAttr(NSAttributedString *attr, UIView *view) {
    if (attr.length == 0) return attr;
    BOOL darkSurface = NigTextBackdrop(view) == NigBackdropDark;
    __block NSMutableAttributedString *m = nil;
    void (^mapAttribute)(NSString *, NigRole) = ^(NSString *key, NigRole role) {
        [attr enumerateAttribute:key
                         inRange:NSMakeRange(0, attr.length)
                         options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop __unused) {
            if (![value isKindOfClass:[UIColor class]]) return;
            UIColor *mapped = NigTransformColor(value, role);
            if (!mapped || [mapped isEqual:value]) return;
            if (!m) m = [attr mutableCopy];
            [m addAttribute:key value:mapped range:range];
        }];
    };

    if (darkSurface) {
        mapAttribute(NSForegroundColorAttributeName, NigRoleText);
        mapAttribute(NSUnderlineColorAttributeName, NigRoleText);
        mapAttribute(NSStrikethroughColorAttributeName, NigRoleText);
        mapAttribute(NSStrokeColorAttributeName, NigRoleText);
    }
    // Explicit run backgrounds (selection/highlight pills) are surfaces too;
    // map them even when the surrounding view has no solid background.
    if (gDarkModeActive) mapAttribute(NSBackgroundColorAttributeName, NigRoleBackground);
    return m ?: attr;
}

// YES when some run carries a colour other than the label's own textColor.
static BOOL NigAttrHasCustomColors(NSAttributedString *attr, UIColor *base) {
    __block BOOL custom = NO;
    NSArray<NSString *> *textKeys = @[NSForegroundColorAttributeName, NSUnderlineColorAttributeName,
                                      NSStrikethroughColorAttributeName, NSStrokeColorAttributeName];
    for (NSString *key in textKeys) {
        [attr enumerateAttribute:key
                         inRange:NSMakeRange(0, attr.length)
                         options:0
                      usingBlock:^(id value, NSRange range __unused, BOOL *stop) {
            if ([value isKindOfClass:[UIColor class]] && ![value isEqual:base]) {
                custom = YES;
                *stop = YES;
            }
        }];
        if (custom) return YES;
    }
    [attr enumerateAttribute:NSBackgroundColorAttributeName
                     inRange:NSMakeRange(0, attr.length)
                     options:0
                  usingBlock:^(id value, NSRange range __unused, BOOL *stop) {
        if ([value isKindOfClass:[UIColor class]]) {
            custom = YES;
            *stop = YES;
        }
    }];
    return custom;
}

#pragma mark - Applying to one view

// Brings one color property in line with `active`, remembering the app's own.
static void NigSyncColor(UIView *view, NSString *key, UIColor *current, BOOL active,
                         UIColor *(^desired)(UIColor *orig), void (^set)(UIColor *c)) {
    UIColor *stored = NigStoreGet(view, key);
    UIColor *orig = stored ?: current;
    if (!orig) return;
    UIColor *want = active ? (desired(orig) ?: orig) : orig;
    if (active && want != orig) NigStoreSet(view, key, orig);
    else NigStoreRemove(view, key);
    if (current != want && ![current isEqual:want]) set(want);
}

static void NigApplyLabel(UILabel *label, BOOL active) {
    UIColor *curText = label.textColor;
    NSAttributedString *attr0 = label.attributedText;
    NSAttributedString *storedAttr = NigStoreGet(label, kAttr);
    NSAttributedString *storedOut = NigStoreGet(label, kAttrOut);
    BOOL attrIsOurs = storedOut && attr0 && [attr0 isEqualToAttributedString:storedOut];
    NSAttributedString *origAttr = attrIsOurs ? storedAttr : attr0;

    UIColor *storedText = NigStoreGet(label, kText);
    UIColor *origText = storedText ?: curText;
    BOOL custom = origAttr.length > 0 && origText && NigAttrHasCustomColors(origAttr, origText);

    UIColor *wantText = active ? (NigDesiredText(label, origText) ?: origText) : origText;
    BOOL textChanged = wantText && ![curText isEqual:wantText];
    if (active && wantText != origText) NigStoreSet(label, kText, origText);
    else NigStoreRemove(label, kText);
    if (textChanged) label.textColor = wantText;  // flattens attributedText, redone below

    // Selected tabs and cells often show the label highlighted, in a colour
    // of its own (often near black).
    UIColor *hl = label.highlightedTextColor;
    if (hl || NigStoreGet(label, kHiText)) {
        NigSyncColor(label, kHiText, hl, active,
                     ^UIColor *(UIColor *o) { return NigDesiredText(label, o); },
                     ^(UIColor *c) { label.highlightedTextColor = c; });
    }

    if (custom) {
        NSAttributedString *wantAttr = active ? NigTransformAttr(origAttr, label) : origAttr;
        if (active && wantAttr != origAttr) {
            NigStoreSet(label, kAttr, origAttr);
            NigStoreSet(label, kAttrOut, wantAttr);
        } else {
            NigStoreRemove(label, kAttr);
            NigStoreRemove(label, kAttrOut);
        }
        if (textChanged || ![label.attributedText isEqualToAttributedString:wantAttr]) {
            label.attributedText = wantAttr;
        }
    } else if (!active && attrIsOurs) {
        label.attributedText = origAttr;
        NigStoreRemove(label, kAttr);
        NigStoreRemove(label, kAttrOut);
    }
}

static void NigApplyButton(UIButton *button, BOOL active) {
    UIControlState states[] = {UIControlStateNormal, UIControlStateHighlighted,
                               UIControlStateSelected, UIControlStateDisabled};
    for (size_t i = 0; i < sizeof(states) / sizeof(states[0]); i++) {
        UIControlState st = states[i];
        NSString *key = [NSString stringWithFormat:@"btn%lu", (unsigned long)st];
        NigSyncColor(button, key, [button titleColorForState:st], active,
                     ^UIColor *(UIColor *o) { return NigDesiredText(button, o); },
                     ^(UIColor *c) { [button setTitleColor:c forState:st]; });
    }
}

static void NigApplyTextInput(UIView *view, BOOL active) {
    UIKeyboardAppearance appearance = UIKeyboardAppearanceDefault;
    BOOL hasKeyboard = NO;
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *t = (UITextField *)view;
        NigSyncColor(view, kText, t.textColor, active,
                     ^UIColor *(UIColor *o) { return NigDesiredText(view, o); },
                     ^(UIColor *c) { t.textColor = c; });

        NSAttributedString *ph = t.attributedPlaceholder;
        NSAttributedString *phOut = NigStoreGet(view, kPlaceholderOut);
        BOOL ours = phOut && ph && [ph isEqualToAttributedString:phOut];
        NSAttributedString *phOrig = ours ? NigStoreGet(view, kPlaceholder) : ph;
        if (phOrig.length) {
            NSAttributedString *want = active ? NigTransformAttr(phOrig, view) : phOrig;
            if (active && want != phOrig) {
                NigStoreSet(view, kPlaceholder, phOrig);
                NigStoreSet(view, kPlaceholderOut, want);
            } else {
                NigStoreRemove(view, kPlaceholder);
                NigStoreRemove(view, kPlaceholderOut);
            }
            if (![ph isEqualToAttributedString:want]) t.attributedPlaceholder = want;
        }
        hasKeyboard = YES;
        appearance = t.keyboardAppearance;
    } else if ([view isKindOfClass:[UITextView class]]) {
        UITextView *t = (UITextView *)view;
        NigSyncColor(view, kText, t.textColor, active,
                     ^UIColor *(UIColor *o) { return NigDesiredText(view, o); },
                     ^(UIColor *c) { t.textColor = c; });

        NSAttributedString *current = t.attributedText;
        NSAttributedString *savedOut = NigStoreGet(view, @"textInputAttrOut");
        NSAttributedString *savedOrig = NigStoreGet(view, @"textInputAttr");
        BOOL ours = savedOut && current && [current isEqualToAttributedString:savedOut];
        NSAttributedString *orig = ours ? savedOrig : current;
        NSAttributedString *want = active ? NigTransformAttr(orig, view) : orig;
        BOOL changed = want && orig && ![want isEqualToAttributedString:orig];
        if (active && changed) {
            NigStoreSet(view, @"textInputAttr", orig);
            NigStoreSet(view, @"textInputAttrOut", want);
        } else {
            NigStoreRemove(view, @"textInputAttr");
            NigStoreRemove(view, @"textInputAttrOut");
        }
        if (want && (!current || ![current isEqualToAttributedString:want])) {
            NSRange selection = t.selectedRange;
            t.attributedText = want;
            if (selection.location != NSNotFound && selection.location <= want.length) {
                selection.length = MIN(selection.length, want.length - selection.location);
                t.selectedRange = selection;
            }
        }
        hasKeyboard = YES;
        appearance = t.keyboardAppearance;
    }

    if (hasKeyboard) {
        NSNumber *storedKb = NigStoreGet(view, kKeyboard);
        if (active && !storedKb && appearance != UIKeyboardAppearanceDark) {
            NigStoreSet(view, kKeyboard, @(appearance));
            [(id<UITextInputTraits>)view setKeyboardAppearance:UIKeyboardAppearanceDark];
        } else if (!active && storedKb) {
            [(id<UITextInputTraits>)view setKeyboardAppearance:(UIKeyboardAppearance)storedKb.integerValue];
            NigStoreRemove(view, kKeyboard);
        }
    }
}

#pragma mark - Icons (small one-colour bitmaps)

static NSString *const kIcon = @"icon";
static const void *kNigIconTintKey = &kNigIconTintKey;
static const void *kNigIconImageKey = &kNigIconImageKey;
static int gDiagIcons = 0;

// A small, mostly transparent, one-colour, dark bitmap (a glyph the app
// ships as a PNG) cannot follow a tint, so it is recoloured as a whole.
// Returns its lighter counterpart, or nil for anything else (photos, icons
// with several colours, light icons, template images). Cached per image.
static UIColor *NigIconTint(UIImage *image) {
    id cached = objc_getAssociatedObject(image, kNigIconTintKey);
    if (cached) return [cached isKindOfClass:[UIColor class]] ? cached : nil;

    UIColor *result = nil;
    CGImageRef cg = image.CGImage;
    CGSize sz = image.size;
    BOOL eligible = cg && sz.width >= 8 && sz.height >= 8 && sz.width <= 64 && sz.height <= 64 &&
                    image.renderingMode != UIImageRenderingModeAlwaysTemplate &&
                    !image.isSymbolImage && image.images == nil;
    if (eligible) {
        enum { N = 16 };
        uint8_t px[N * N * 4];
        memset(px, 0, sizeof(px));
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bc = CGBitmapContextCreate(px, N, N, 8, N * 4, cs,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (bc) {
            CGContextDrawImage(bc, CGRectMake(0, 0, N, N), cg);
            CGContextRelease(bc);
            double sumA = 0, sr = 0, sg = 0, sb = 0;
            int opaque = 0, visible = 0;
            for (int i = 0; i < N * N; i++) {
                double a = px[i * 4 + 3] / 255.0;
                if (a > 0.9) opaque++;
                if (a > 0.3) visible++;
                sumA += a;
                sr += px[i * 4] / 255.0;
                sg += px[i * 4 + 1] / 255.0;
                sb += px[i * 4 + 2] / 255.0;
            }
            if (visible >= 6 && sumA > 0 && opaque < (int)(0.85 * N * N)) {
                double ar = sr / sumA, ag = sg / sumA, ab = sb / sumA;
                int mixed = 0;
                for (int i = 0; i < N * N; i++) {
                    double a = px[i * 4 + 3] / 255.0;
                    if (a <= 0.3) continue;
                    double dr = px[i * 4] / 255.0 / a - ar;
                    double dg = px[i * 4 + 1] / 255.0 / a - ag;
                    double db = px[i * 4 + 2] / 255.0 / a - ab;
                    if (MAX(MAX(fabs(dr), fabs(dg)), fabs(db)) > 0.22) mixed++;
                }
                if (mixed * 10 <= visible && NigLuma(ar, ag, ab) < 0.4) {
                    result = NigTransformColor([UIColor colorWithRed:ar green:ag blue:ab alpha:1], NigRoleText);
                }
            }
        }
    }
    objc_setAssociatedObject(image, kNigIconTintKey, result ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

static UIImage *NigRecolored(UIImage *image, UIColor *color) {
    UIImage *cached = objc_getAssociatedObject(image, kNigIconImageKey);
    if (cached) return cached;
    int previous = tDrawState;
    tDrawState = 0;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = image.scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    UIImage *out = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGRect rect = CGRectMake(0, 0, image.size.width, image.size.height);
        [image drawInRect:rect];
        CGContextSetBlendMode(rc.CGContext, kCGBlendModeSourceIn);
        CGContextSetFillColorWithColor(rc.CGContext, color.CGColor);
        CGContextFillRect(rc.CGContext, rect);
    }];
    tDrawState = previous;
    out = [out imageWithAlignmentRectInsets:image.alignmentRectInsets];
    objc_setAssociatedObject(image, kNigIconImageKey, out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

static void NigApplyImageView(UIImageView *iv, BOOL active) {
    NSDictionary *rec = NigStoreGet(iv, kIcon);
    UIImage *cur = iv.image;
    UIImage *orig = (rec && cur == rec[@"out"]) ? rec[@"orig"] : cur;
    UIImage *want = nil;
    if (active && orig && NigTextBackdrop(iv) == NigBackdropDark) {
        UIColor *tint = NigIconTint(orig);
        if (tint) want = NigRecolored(orig, tint);
    }
    if (want) {
        if (cur != want) { iv.image = want; gDiagIcons++; }
        NigStoreSet(iv, kIcon, @{@"orig": orig, @"out": want});
    } else {
        if (rec && cur == rec[@"out"]) iv.image = orig;
        NigStoreRemove(iv, kIcon);
    }
}

#pragma mark - Surfaces drawn by layers

// A colour on a layer, kept the same way as the view ones: what the app set
// and what Nig put there are both remembered, so a value the app sets later
// is recognised as its own and a restore puts the app's colour back.
static void NigSyncLayerColor(CALayer *layer, NSString *key, CGColorRef current, BOOL active,
                              NigRole role, void (^set)(CGColorRef c)) {
    NSDictionary *rec = NigStoreGet(layer, key);
    UIColor *cur = current ? [UIColor colorWithCGColor:current] : nil;
    UIColor *orig = (rec && cur && [cur isEqual:rec[@"out"]]) ? rec[@"orig"] : cur;
    if (!orig) return;
    UIColor *want = active ? NigTransformColor(orig, role) : nil;
    if (want) {
        if (!(cur && [cur isEqual:want])) set(want.CGColor);
        NigStoreSet(layer, key, @{@"orig": orig, @"out": want});
    } else {
        if (rec && ![orig isEqual:cur]) set(orig.CGColor);
        NigStoreRemove(layer, key);
    }
}

static void NigSyncGradient(CAGradientLayer *layer, BOOL active) {
    NSDictionary *rec = NigStoreGet(layer, @"grad");
    NSArray *cur = layer.colors;
    NSArray *orig = (rec && cur && [cur isEqualToArray:rec[@"out"]]) ? rec[@"orig"] : cur;
    if (orig.count == 0) return;
    NSMutableArray *out = nil;
    if (active) {
        out = [NSMutableArray arrayWithCapacity:orig.count];
        BOOL changed = NO;
        for (id item in orig) {
            if (CFGetTypeID((__bridge CFTypeRef)item) != CGColorGetTypeID()) { [out addObject:item]; continue; }
            CGColorRef mapped = NigCopyTransformedCGColor((__bridge CGColorRef)item, NigRoleBackground);
            if (mapped) { [out addObject:(__bridge id)mapped]; CGColorRelease(mapped); changed = YES; }
            else [out addObject:item];
        }
        if (!changed) out = nil;
    }
    if (out) {
        if (![cur isEqualToArray:out]) layer.colors = out;
        NigStoreSet(layer, @"grad", @{@"orig": orig, @"out": out});
    } else {
        if (rec && ![orig isEqualToArray:cur]) layer.colors = orig;
        NigStoreRemove(layer, @"grad");
    }
}

// Text a view draws with CATextLayer sublayers (some apps never use UILabel).
static void NigApplyTextLayers(UIView *view, BOOL active) {
    NSArray<CALayer *> *subs = view.layer.sublayers;
    if (subs.count == 0) return;
    BOOL dark = NO, known = NO;
    for (CALayer *s in [subs copy]) {
        if (![s isKindOfClass:[CATextLayer class]]) continue;
        if (!known) { dark = active && NigTextBackdrop(view) == NigBackdropDark; known = YES; }
        CATextLayer *t = (CATextLayer *)s;
        NigSyncLayerColor(t, @"textLayerFg", t.foregroundColor, dark, NigRoleText,
                          ^(CGColorRef c) { t.foregroundColor = c; });
    }
}

static BOOL NigLayerIsHandled(CALayer *layer) {
    // Plain colour layers only: not blur backdrops, video, Metal or emitters.
    Class c = [layer class];
    return c == [CALayer class] || c == [CAShapeLayer class] || c == [CAGradientLayer class];
}

// `own` is the view's own layer (only its backgroundColor is touched, and only
// when the view itself has none); the others are the big plain sublayers that
// act as a surface behind the content (cards, headers, gradients).
static void NigApplyLayerColors(CALayer *layer, BOOL active, BOOL own) {
    if (!NigLayerIsHandled(layer) || layer.contents) return;
    NigSyncLayerColor(layer, kLayerBg, layer.backgroundColor, active, NigRoleBackground,
                      ^(CGColorRef c) { layer.backgroundColor = c; });
    if (own) return;
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        NigSyncLayerColor(shape, kShapeFill, shape.fillColor, active, NigRoleBackground,
                          ^(CGColorRef c) { shape.fillColor = c; });
    } else if ([layer isKindOfClass:[CAGradientLayer class]]) {
        NigSyncGradient((CAGradientLayer *)layer, active);
    }
}

static void NigApplySurfaceSublayers(CALayer *parent, BOOL active, NSInteger depth) {
    if (depth > 4) return;
    id delegate = parent.delegate;
    if ([delegate isKindOfClass:[UIView class]] && NigHasBarcodeProtection((UIView *)delegate)) return;
    for (CALayer *s in [parent.sublayers copy]) {
        if (!NigIsPlainSublayer(s, parent)) continue;  // subview layers and small shapes stay
        NigApplyLayerColors(s, active, NO);
        NigApplySurfaceSublayers(s, active, depth + 1);
    }
}

// Bars and blur views follow the dark style natively, which also darkens
// whatever is drawn by the system in them. So does a web view: pages that
// have a dark design of their own (prefers-color-scheme) then use it.
static BOOL NigIsWebView(UIView *view) {
    static Class web;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ web = NSClassFromString(@"WKWebView"); });
    return web && [view isKindOfClass:web];
}

// Flutter and Compose Multiplatform draw a whole screen themselves, into one
// Metal layer, so there are no UIKit colours to change, and inverting that
// layer would also swap barcodes and photos. What Nig can do honestly is tell
// the engine the system is dark: it reads the brightness from the window's
// traits (an app that locks itself to Light in its Info.plist gets the same
// answer). An app with a dark theme then draws it; an app without one stays.
static BOOL gFlutterApp = NO;

static BOOL NigWantsDarkOverride(UIView *view) {
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        return [((UIVisualEffectView *)view).effect isKindOfClass:[UIBlurEffect class]];
    }
    if (gFlutterApp && [view isKindOfClass:[UIWindow class]]) return YES;
    return [view isKindOfClass:[UITabBar class]] || [view isKindOfClass:[UINavigationBar class]] ||
           [view isKindOfClass:[UIToolbar class]] || NigIsWebView(view);
}

#pragma mark - Web pages

// Pages are recoloured by Web/NigWeb.js, element by element, with the same
// rules as NigMapRGB. It runs in Nig's own content world, out of the page's
// reach, as a user script for every page the web view loads from now on and,
// once, in the page already shown.
static NSString *const kWeb = @"web";
static const void *kNigWebScriptKey = &kNigWebScriptKey;
static NSString *const kNigWebMarker = @"/* nig-web";

static WKContentWorld *NigWebWorld(void) {
    static WKContentWorld *world;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        world = [NSClassFromString(@"WKContentWorld") worldWithName:@"com.imodcommission.nig"];
    });
    return world;
}

static NSString *NigWebSource(BOOL on) {
    if (!on) return @"globalThis.__nigWeb && globalThis.__nigWeb.set(false);\n1;";
    return [kNigWebEngine stringByAppendingString:@"globalThis.__nigWeb.set(true);\n1;"];
}

// Adding the script is all it takes to turn it on. A user script cannot be
// removed alone: turning it off puts back every other script the app added.
static void NigSyncWebScript(WKUserContentController *ucc, BOOL on) {
    if (!ucc || !NigWebWorld()) return;
    NSNumber *has = objc_getAssociatedObject(ucc, kNigWebScriptKey);
    if (has.boolValue == on) return;
    if (on) {
        WKUserScript *mine = [[NSClassFromString(@"WKUserScript") alloc]
              initWithSource:NigWebSource(YES)
               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
            forMainFrameOnly:NO
              inContentWorld:NigWebWorld()];
        [ucc addUserScript:mine];
    } else {
        NSMutableArray<WKUserScript *> *keep = [NSMutableArray array];
        for (WKUserScript *s in ucc.userScripts) {
            if (![s.source hasPrefix:kNigWebMarker]) [keep addObject:s];
        }
        [ucc removeAllUserScripts];
        for (WKUserScript *s in keep) [ucc addUserScript:s];
    }
    objc_setAssociatedObject(ucc, kNigWebScriptKey, @(on), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void NigApplyWebView(UIView *view, BOOL active) {
    NSNumber *state = NigStoreGet(view, kWeb);
    if (state ? state.boolValue == active : !active) return;
    WKWebView *web = (WKWebView *)view;
    NigSyncWebScript(web.configuration.userContentController, active);
    NigStoreSet(view, kWeb, @(active));
    if (!web.URL || !NigWebWorld()) return;  // its first page gets the user script
    [web evaluateJavaScript:NigWebSource(active)
                    inFrame:nil
             inContentWorld:NigWebWorld()
          completionHandler:^(id result __unused, NSError *error) {
        if (error) {
            os_log(TweakLog(), "ApelinWeb error %{public}@ %{public}s",
                   error.localizedDescription, getprogname());
        }
    }];
}

#pragma mark - Views that draw text as pixels

// SwiftUI can rasterize a text run in a private CGDrawingView. Only that
// known renderer is eligible; custom app drawLayer implementations may contain
// photos, logos or whole screens and must never be inverted as a unit.
static NSString *const kInverted = @"inverted";
static void (*OrigDrawLayerInContext)(UIView *, SEL, CALayer *, CGContextRef);
static void HookedDrawLayerInContext(UIView *self, SEL _cmd, CALayer *layer, CGContextRef ctx);

static BOOL NigDrawsOwnBitmap(UIView *view) {
    return [NSStringFromClass([view class]) containsString:@"CGDrawingView"];
}

// Views that draw text glyphs into their own bitmap: UIKit's text views and
// their private TextKit 2 fragment views, and the many third-party text
// views (YYLabel, PDD's Lego text, ...) whose class names say so. Only their
// dark fills are lightened while they draw onto a dark surface; images they
// draw are untouched. Decided once per class.
static NSString *const kDrawn = @"drawn";
static BOOL NigIsTextRenderer(UIView *view) {
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UITextField class]] ||
        [view isKindOfClass:[UITextView class]]) {
        return YES;
    }
    static CFMutableDictionaryRef cache;
    Class cls = [view class];
    if (!cache) cache = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);  // main thread only
    const void *cached = CFDictionaryGetValue(cache, (__bridge const void *)cls);
    if (cached) return cached == (const void *)1;
    NSString *name = NSStringFromClass(cls);
    BOOL text = ([name containsString:@"Text"] && ![name containsString:@"Texture"]) ||
                [name containsString:@"Label"];
    CFDictionarySetValue(cache, (__bridge const void *)cls, text ? (const void *)1 : (const void *)2);
    return text;
}

// The style the app itself gives `view`: below a bar Nig forced dark, the
// style of that bar's parent, not Nig's override.
static UIUserInterfaceStyle NigAppStyle(UIView *view) {
    for (UIView *p = view; p; p = p.superview) {
        if (NigStoreGet(p, kOverride)) {
            return p.superview ? p.superview.traitCollection.userInterfaceStyle : gResolveStyle;
        }
    }
    return view.traitCollection.userInterfaceStyle;
}

static BOOL NigShouldFilterBitmap(UIView *view, BOOL active) {
    CGSize size = view.bounds.size;
    BOOL isolated = NigDrawsOwnBitmap(view) && size.height > 0 && size.height <= 120 &&
                    size.width * size.height <= 60000 && view.subviews.count == 0 &&
                    !view.backgroundColor && !view.layer.backgroundColor;
    return active && isolated && NigAppStyle(view) != UIUserInterfaceStyleDark &&
           NigTextBackdrop(view) == NigBackdropDark;
}

static NSArray *NigInvertFilters(void) {
    Class cafilter = NSClassFromString(@"CAFilter");
    if (!cafilter || ![cafilter respondsToSelector:@selector(filterWithType:)]) return nil;
    id invert = [cafilter performSelector:@selector(filterWithType:) withObject:@"colorInvert"];
    id hue = [cafilter performSelector:@selector(filterWithType:) withObject:@"colorHueRotate"];
    if (!invert || !hue) return nil;
    [hue setValue:@(M_PI) forKey:@"inputAngle"];
    return @[invert, hue];
}

static void NigSetInvertFilter(UIView *view, NSString *key, BOOL want) {
    NSDictionary *rec = NigStoreGet(view, key);
    CALayer *layer = view.layer;
    if (want && !rec) {
        NSArray *ours = NigInvertFilters();
        if (!ours) return;
        NSMutableArray *combined = [NSMutableArray arrayWithArray:layer.filters ?: @[]];
        [combined addObjectsFromArray:ours];
        NigStoreSet(view, key, @{ @"ours": ours });
        layer.filters = combined;
    } else if (!want && rec) {
        NSArray *ours = rec[@"ours"];
        NSMutableArray *remaining = [NSMutableArray array];
        for (id filter in layer.filters ?: @[]) {
            BOOL isOurs = NO;
            for (id oursFilter in ours) {
                if (filter == oursFilter) { isOurs = YES; break; }
            }
            if (!isOurs) [remaining addObject:filter];
        }
        layer.filters = remaining.count ? remaining : nil;
        NigStoreRemove(view, key);
    }
}

static void NigApplyBitmapFilter(UIView *view, BOOL active) {
    NigSetInvertFilter(view, kInverted, NigShouldFilterBitmap(view, active));
}

#pragma mark - Text drawn off the main thread

// Third-party text views (DinamicX's DXRichTextView, YYLabel, ...) render
// their text into a CGImage on a background queue and hand it to the layer
// as contents, so no drawing hook sees their colours. When such a bitmap
// lands on a dark surface, its dark pixels get the same lighter, same-hue
// colour Nig gives text; light and bright pixels stay. Only mostly
// transparent bitmaps qualify: a photo or an opaque card is never touched.
// It runs once per bitmap the app sets, never on a timer.
static NSString *const kRecolor = @"recolor";  // @{ orig, out }: the app's bitmap and Nig's
static void (*OrigLayerSetContents)(CALayer *, SEL, id);
static BOOL NigShouldHandle(UIView *view);

static BOOL NigIsAsyncTextView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UITextField class]] ||
        [view isKindOfClass:[UITextView class]] || [view isKindOfClass:[UIImageView class]]) {
        return NO;
    }
    return NigIsTextRenderer(view);
}

static BOOL NigIsClearColor(CGColorRef c) {
    return !c || CGColorGetAlpha(c) < 0.05;
}

static BOOL NigWantsRecolor(UIView *view, BOOL active) {
    return active && view.window && !view.hidden && view.subviews.count == 0 &&
           NigIsClearColor(view.backgroundColor.CGColor) && NigIsClearColor(view.layer.backgroundColor) &&
           NigAppStyle(view) != UIUserInterfaceStyleDark && NigTextBackdrop(view) == NigBackdropDark;
}

// The recoloured bitmap (+1), or NULL when it is not text-like or nothing changed.
static CGImageRef NigCopyRecoloredText(CGImageRef image) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w == 0 || h == 0 || w * h > 3000000) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    uint8_t *px = CGBitmapContextGetData(ctx);
    size_t count = w * h;
    if (!px) { CGContextRelease(ctx); return NULL; }

    // Text is mostly empty space; a photo or a filled card is not.
    size_t sampled = 0, clear = 0;
    for (size_t i = 0; i < count; i += 7, sampled++) {
        if (px[i * 4 + 3] < 26) clear++;
    }
    if (clear * 2 < sampled) { CGContextRelease(ctx); return NULL; }

    // NigMapRGB for each 15-bit colour, filled as colours are met.
    // Entry: 0 unknown, 1 keep, else 0x80000000 | 0xRRGGBB.
    static uint32_t *table;
    if (!table) table = calloc(32768, sizeof(uint32_t));
    if (!table) { CGContextRelease(ctx); return NULL; }

    size_t changed = 0;
    for (size_t i = 0; i < count; i++) {
        uint8_t *p = px + i * 4;
        unsigned a = p[3];
        if (a < 8) continue;
        unsigned r = MIN(255u, p[0] * 255u / a), g = MIN(255u, p[1] * 255u / a), b = MIN(255u, p[2] * 255u / a);
        unsigned key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
        uint32_t entry = table[key];
        if (!entry) {
            CGFloat nr, ng, nb;
            CGFloat cr = ((r >> 3) * 8 + 4) / 255.0, cg = ((g >> 3) * 8 + 4) / 255.0, cb = ((b >> 3) * 8 + 4) / 255.0;
            if (NigMapRGB(NigRoleText, cr, cg, cb, &nr, &ng, &nb)) {
                entry = 0x80000000u | ((uint32_t)lround(nr * 255) << 16) | ((uint32_t)lround(ng * 255) << 8) |
                        (uint32_t)lround(nb * 255);
            } else {
                entry = 1;
            }
            table[key] = entry;
        }
        if (entry == 1) continue;
        p[0] = (uint8_t)(((entry >> 16) & 0xFF) * a / 255);
        p[1] = (uint8_t)(((entry >> 8) & 0xFF) * a / 255);
        p[2] = (uint8_t)((entry & 0xFF) * a / 255);
        changed++;
    }
    CGImageRef out = changed ? CGBitmapContextCreateImage(ctx) : NULL;
    CGContextRelease(ctx);
    return out;
}

// Edge fades: a small light bitmap of one colour whose alpha ramps along one
// axis, laid over the end of a scrolling row to blend it into a light
// surface. On a surface Nig darkened it shows as a white smear, so it takes
// the colour Nig gives that light surface instead. Icons are not fades: their
// alpha is all or nothing but for the edges, and varies across both axes.
static CGImageRef NigCopyRecoloredFade(CGImageRef image) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w < 2 || h < 2 || w * h > 250000) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    uint8_t *px = CGBitmapContextGetData(ctx);
    if (!px) { CGContextRelease(ctx); return NULL; }

    size_t count = w * h, partial = 0, colored = 0;
    unsigned lo[3] = {255, 255, 255}, hi[3] = {0, 0, 0};
    double sum[3] = {0, 0, 0};
    for (size_t i = 0; i < count; i++) {
        uint8_t *p = px + i * 4;
        unsigned a = p[3];
        if (a >= 16 && a <= 239) partial++;
        if (a < 64) continue;
        colored++;
        for (int c = 0; c < 3; c++) {
            unsigned v = MIN(255u, p[c] * 255u / a);
            lo[c] = MIN(lo[c], v);
            hi[c] = MAX(hi[c], v);
            sum[c] += v;
        }
    }
    BOOL fade = colored * 5 >= count && partial * 10 >= count * 3;
    for (int c = 0; fade && c < 3; c++) fade = hi[c] - lo[c] <= 24;
    CGFloat r = 0, g = 0, b = 0;
    if (fade) {
        r = sum[0] / colored / 255.0; g = sum[1] / colored / 255.0; b = sum[2] / colored / 255.0;
        fade = NigLuma(r, g, b) > 0.8;
    }
    // Alpha constant down every column (a sideways fade) or along every row.
    BOOL cols = fade, rows = fade;
    for (size_t x = 0; cols && x < w; x++) {
        unsigned amin = 255, amax = 0;
        for (size_t y = 0; y < h; y++) {
            unsigned a = px[(y * w + x) * 4 + 3];
            amin = MIN(amin, a); amax = MAX(amax, a);
        }
        cols = amax - amin <= 20;
    }
    for (size_t y = 0; !cols && rows && y < h; y++) {
        unsigned amin = 255, amax = 0;
        for (size_t x = 0; x < w; x++) {
            unsigned a = px[(y * w + x) * 4 + 3];
            amin = MIN(amin, a); amax = MAX(amax, a);
        }
        rows = amax - amin <= 20;
    }
    CGFloat nr, ng, nb;
    if (!fade || !(cols || rows) || !NigMapRGB(NigRoleBackground, r, g, b, &nr, &ng, &nb)) {
        CGContextRelease(ctx);
        return NULL;
    }
    for (size_t i = 0; i < count; i++) {
        uint8_t *p = px + i * 4;
        unsigned a = p[3];
        p[0] = (uint8_t)lround(nr * a);
        p[1] = (uint8_t)lround(ng * a);
        p[2] = (uint8_t)lround(nb * a);
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

// Small self-contained views that show a bitmap the app set on their layer:
// where edge fades live. Image views are left alone (their pictures are
// never changed), and so are views with content of their own.
static BOOL NigIsFadeCandidate(UIView *view) {
    if ([view isKindOfClass:[UIImageView class]] || [view isKindOfClass:[UILabel class]] ||
        [view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UITextView class]]) {
        return NO;
    }
    CGSize s = view.bounds.size;
    return s.width > 0 && s.height > 0 && s.width * s.height <= 40000 && view.subviews.count == 0;
}

static BOOL NigIsRecolorCandidate(UIView *view) {
    return NigIsAsyncTextView(view) || NigIsFadeCandidate(view);
}

// Sets the bitmap `view` should show for the app's `orig`, recording it.
// A bitmap that is not text-like is recorded as skipped, so it is not
// scanned again until the app sets another one.
static void NigSetRecolored(UIView *view, id orig, BOOL want) {
    CALayer *layer = view.layer;
    CGImageRef out = !want ? NULL
                     : NigIsAsyncTextView(view) ? NigCopyRecoloredText((__bridge CGImageRef)orig)
                                                : NigCopyRecoloredFade((__bridge CGImageRef)orig);
    id target = orig;
    if (out) {
        id outObj = (__bridge_transfer id)out;
        NigStoreSet(view, kRecolor, @{ @"orig": orig, @"out": outObj });
        target = outObj;
    } else if (want) {
        NigStoreSet(view, kRecolor, @{ @"orig": orig, @"skip": @YES });
    } else {
        NigStoreRemove(view, kRecolor);
    }
    if (layer.contents != target) OrigLayerSetContents(layer, @selector(setContents:), target);
}

// Called from NigApplySelf: the surface or the style may have changed.
static void NigApplyRecolor(UIView *view, BOOL active) {
    id cur = view.layer.contents;
    NSDictionary *rec = NigStoreGet(view, kRecolor);
    BOOL ours = rec[@"out"] && cur == rec[@"out"];
    BOOL skipped = rec[@"skip"] && cur == rec[@"orig"];
    if (rec && !ours && !skipped) { NigStoreRemove(view, kRecolor); rec = nil; }
    id orig = ours ? rec[@"orig"] : cur;
    if (!NigIsCGImage(orig)) return;
    BOOL want = NigWantsRecolor(view, active);
    if (want == ours || (want && skipped)) return;  // already as it should be: no work
    NigSetRecolored(view, orig, want);
}

static void NigProtectBarcodeView(UIView *view);
static void NigScheduleSettle(UIView *view);

static void HookedLayerSetContents(CALayer *self, SEL _cmd, id contents) {
    if (!tInHook && [NSThread isMainThread]) {
        id delegate = self.delegate;
        if ([delegate isKindOfClass:[UIView class]]) {
            UIView *view = delegate;
            BOOL hadProtection = [objc_getAssociatedObject(view, kNigBarcodeSource) boolValue];
            NigClearBarcodeProtection(view);
            if (hadProtection) NigScheduleSettle(view);
        }
        if (NigIsCGImage(contents) && [delegate isKindOfClass:[UIView class]] &&
            ![delegate isKindOfClass:[UIImageView class]]) {
            __weak UIView *weakView = delegate;
            __weak CALayer *weakLayer = self;
            id sourceObject = contents;
            NigDetectBarcodes((__bridge CGImageRef)contents, ^(NSArray<NSValue *> *rects) {
                UIView *view = weakView;
                CALayer *layer = weakLayer;
                if (!view || !layer || rects.count == 0 || layer.contents != sourceObject) return;
                NigProtectBarcodeView(view);
                os_log(TweakLog(), "ApelinBarcode layer detected count=%lu %{public}s",
                       (unsigned long)rects.count, getprogname());
            });
        }
    }
    if (tInHook || !NigIsCGImage(contents) || ![NSThread isMainThread]) {
        OrigLayerSetContents(self, _cmd, contents);
        return;
    }
    id delegate = self.delegate;
    if (![delegate isKindOfClass:[UIView class]] || !NigIsRecolorCandidate((UIView *)delegate)) {
        OrigLayerSetContents(self, _cmd, contents);
        return;
    }
    UIView *view = (UIView *)delegate;
    if (NigShouldHandle(view) && NigWantsRecolor(view, gDarkModeActive)) {
        BOOL previous = tInHook;
        tInHook = YES;
        NIG_WITH_TRAITS(view);
        NigSetRecolored(view, contents, YES);
        NIG_END_TRAITS();
        tInHook = previous;
        return;
    }
    if (NigStoreGet(view, kRecolor)) NigStoreRemove(view, kRecolor);
    OrigLayerSetContents(self, _cmd, contents);
}

static void NigApplySelf(UIView *view) {
    if (!view || NigIsSystemUI(view)) return;
    BOOL active = gDarkModeActive && !NigHasBarcodeProtection(view);
    BOOL previous = tInHook;
    tInHook = YES;
    NIG_WITH_TRAITS(view);

    NigSyncColor(view, kBg, view.backgroundColor, active,
                 ^UIColor *(UIColor *o) { return NigDesiredBackground(o); },
                 ^(UIColor *c) { view.backgroundColor = c; });

    if (NigWantsDarkOverride(view)) {
        // A bar whose parent already renders dark needs no override. The
        // parent's traits are read, since this view's carry Nig's own override.
        UIView *parent = view.superview;
        BOOL parentDark = parent && parent.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        BOOL wantOverride = active && !parentDark;
        if (wantOverride && view.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) {
            NigStoreSet(view, kOverride, @(view.overrideUserInterfaceStyle));
            view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        } else if (!wantOverride && NigStoreGet(view, kOverride)) {
            view.overrideUserInterfaceStyle = (UIUserInterfaceStyle)[NigStoreGet(view, kOverride) integerValue];
            NigStoreRemove(view, kOverride);
        }
    }

    // Surfaces that are layers rather than the view's backgroundColor, so
    // that the backdrop check below sees them dark before any text follows.
    if (!view.backgroundColor && ![view isKindOfClass:[UIVisualEffectView class]] &&
        ![view isKindOfClass:[UIImageView class]]) {
        NigApplyLayerColors(view.layer, active, YES);
    }
    if (![view isKindOfClass:[UIVisualEffectView class]] && ![view isKindOfClass:[UIImageView class]]) {
        NigApplySurfaceSublayers(view.layer, active, 0);
    }

    if ([view isKindOfClass:[UILabel class]]) {
        NigApplyLabel((UILabel *)view, active);
    } else if ([view isKindOfClass:[UIButton class]]) {
        NigApplyButton((UIButton *)view, active);
    } else if ([view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UITextView class]]) {
        NigApplyTextInput(view, active);
    } else if ([view isKindOfClass:[UIImageView class]]) {
        NigApplyImageView((UIImageView *)view, active);
    }
    NigApplyTextLayers(view, active);
    if (NigIsWebView(view)) NigApplyWebView(view, active && gWebEnabled);
    if (NigDrawsOwnBitmap(view)) NigApplyBitmapFilter(view, active);
    if (NigIsRecolorCandidate(view)) NigApplyRecolor(view, active);

    // The window's tint is inherited by every view below it; touching each
    // subview's tint would break that inheritance.
    if ([view isKindOfClass:[UIWindow class]]) {
        NigSyncColor(view, kTint, view.tintColor, active,
                     ^UIColor *(UIColor *o) { return NigTransformColor(o, NigRoleText); },
                     ^(UIColor *c) { view.tintColor = c; });
    }

    CGColorRef border = view.layer.borderColor;
    if (view.layer.borderWidth > 0 && (border || NigStoreGet(view, kBorder))) {
        UIColor *cur = border ? [UIColor colorWithCGColor:border] : nil;
        NigSyncColor(view, kBorder, cur, active,
                     ^UIColor *(UIColor *o) { return NigTransformColor(o, NigRoleBorder); },
                     ^(UIColor *c) { view.layer.borderColor = c.CGColor; });
    }

    // A text view drawn before it reached its final place (or before the
    // style changed) is drawn again, once, with the answer it has now.
    NSNumber *drawn = NigStoreGet(view, kDrawn);
    if (drawn) {
        BOOL lighten = active && NigTextBackdrop(view) == NigBackdropDark;
        if (lighten != drawn.boolValue) {
            NigStoreSet(view, kDrawn, @(lighten));
            [view.layer setNeedsDisplay];
        }
    }

    NIG_END_TRAITS();
    tInHook = previous;
}

static void NigScanCompositeBarcodeView(UIView *view);

static void NigApplyTree(UIView *view, NSInteger depth) {
    if (!view || depth > 200) return;
    NigScanCompositeBarcodeView(view);
    NigApplySelf(view);
    for (UIView *sub in [view.subviews copy]) {
        NigApplyTree(sub, depth + 1);
    }
}

#pragma mark - Refresh

static UIWindow *NigProbeWindow(NSMutableArray<UIWindow *> *all) {
    UIWindow *probe = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            [all addObject:w];
            if (!probe && !w.hidden && !NigClassIsSystemUI([w class])) probe = w;
        }
    }
    return probe;
}

// Nig only follows the system's style. Whether an app supports dark mode is
// not its business: a user who does not want an app touched turns the
// injection off for it (Choicy). An app that already renders dark is left
// alone by the transforms themselves (dark colours stay, only light ones move).
static void NigRefresh(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindow *probe = NigProbeWindow(windows);
    if (!probe) return;  // no window yet: a later notification retries

    if (!gFlutterApp) gFlutterApp = NSClassFromString(@"FlutterView") != Nil;
    BOOL system = NigSystemIsDark(YES);
    NigReadPrefs();
    // Dynamic colours are read the way the app itself resolves them.
    BOOL traitDark = (probe.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NigSetResolveStyle(traitDark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight);
    // Switched off in Settings: everything Nig changed is put back, as when
    // the system turns light.
    BOOL active = system && gNigEnabled;

    static int lastSig = -1;
    int sig = (system ? 1 : 0) | (traitDark ? 2 : 0) | (gNigEnabled ? 4 : 0) | (gWebEnabled ? 8 : 0);
    if (sig != lastSig) {
        lastSig = sig;
        os_log(TweakLog(), "ApelinState active=%d system=%d published=%d traitDark=%d enabled=%d web=%d %{public}s",
               active, system, NigPublishedStyle(), traitDark, gNigEnabled, gWebEnabled, getprogname());
    }
    gDarkModeActive = active;
    if (active) gEverActive = YES;
    if (!gEverActive) return;  // nothing was ever changed, nothing to restore

    for (UIWindow *w in windows) {
        gBarcodeSnapshotBudget = 0;
        NigApplyTree(w, 0);
    }
}

static void NigRequestRefresh(void) {
    if (gRefreshPending) return;
    gRefreshPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gRefreshPending = NO;
        NigRefresh();
    });
}

#pragma mark - Diagnostics dump

// `com.imodcommission.nig.dump` makes the app in front write its whole
// view and layer tree, with the colours Nig saw, changed and decided, to
// <app tmp>/nig-dump-<time>.txt. It runs only on that signal or when the
// user takes a screenshot: nothing is polled.
static const char *const kDumpNotification = "com.imodcommission.nig.dump";

static NSString *NigHex(UIColor *c) {
    if (!c) return @"-";
    UIColor *resolved = [c resolvedColorWithTraitCollection:(tTraits ?: (gResolveTraits ?: NigLightTraits()))] ?: c;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) return @"pattern";
    int R = (int)lround(MAX(0.0, MIN(1.0, r)) * 255), G = (int)lround(MAX(0.0, MIN(1.0, g)) * 255),
        B = (int)lround(MAX(0.0, MIN(1.0, b)) * 255);
    NSMutableString *s = [NSMutableString stringWithFormat:@"#%02X%02X%02X", R, G, B];
    if (a < 0.995) [s appendFormat:@"/%.2f", a];
    if (resolved != c) [s appendString:@"(dyn)"];
    return s;
}

static NSString *NigHexCG(CGColorRef c) {
    return c ? NigHex([UIColor colorWithCGColor:c]) : @"-";
}

static NSString *NigContentsDesc(id contents) {
    if (!contents) return nil;
    CFTypeID t = CFGetTypeID((__bridge CFTypeRef)contents);
    if (t == CGImageGetTypeID()) {
        CGImageRef i = (__bridge CGImageRef)contents;
        return [NSString stringWithFormat:@"CGImage %zux%zu", CGImageGetWidth(i), CGImageGetHeight(i)];
    }
    // Layer contents can be a plain Objective-C object (IOSurface, a backing
    // store), whose type ID CoreFoundation never registered: describing it
    // with CFCopyTypeIDDescription crashes (dpoint, on screenshot). The class
    // name is always safe to read.
    Class cls = object_getClass(contents);
    return cls ? [NSString stringWithUTF8String:class_getName(cls)] : @"?";
}

static NSString *NigShort(NSString *text) {
    if (!text) return @"";
    NSString *s = text.length > 28 ? [[text substringToIndex:28] stringByAppendingString:@"…"] : text;
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"];
    return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
}

static NSString *NigAttrColors(NSAttributedString *a, NSString *key) {
    if (a.length == 0) return @"";
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    [a enumerateAttribute:key inRange:NSMakeRange(0, a.length) options:0
               usingBlock:^(id value, NSRange range __unused, BOOL *stop) {
        [set addObject:[value isKindOfClass:[UIColor class]] ? NigHex(value) : (value ? @"?" : @"-")];
        if (set.count >= 5) *stop = YES;
    }];
    return [set.array componentsJoinedByString:@","];
}

static NSString *NigBackdropName(NigBackdrop b) {
    return b == NigBackdropDark ? @"Dark" : (b == NigBackdropLight ? @"Light" : @"Media");
}

static BOOL NigOverrides(Class cls, SEL sel) {
    Method base = class_getInstanceMethod([UIView class], sel);
    Method mine = class_getInstanceMethod(cls, sel);
    return base && mine && method_getImplementation(base) != method_getImplementation(mine);
}

static NSString *NigStoredDesc(id obj, NSString *key) {
    id v = NigStoreGet(obj, key);
    if (!v) return nil;
    if ([v isKindOfClass:[UIColor class]]) return NigHex(v);
    if ([v isKindOfClass:[NSDictionary class]] && [v[@"orig"] isKindOfClass:[UIColor class]]) return NigHex(v[@"orig"]);
    return @"yes";
}

static void NigDumpLayer(NSMutableString *out, CALayer *l, NSString *indent, int depth, NSUInteger *lines) {
    if (*lines > 12000) return;
    (*lines)++;
    [out appendFormat:@"%@~%@ %p f=%@ bg=%@", indent, NSStringFromClass([l class]), l,
                      NSStringFromCGRect(l.frame), NigHexCG(l.backgroundColor)];
    NSString *was = NigStoredDesc(l, kLayerBg);
    if (was) [out appendFormat:@" was=%@", was];
    if ([l isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *sh = (CAShapeLayer *)l;
        [out appendFormat:@" fill=%@ stroke=%@", NigHexCG(sh.fillColor), NigHexCG(sh.strokeColor)];
        NSString *fw = NigStoredDesc(l, kShapeFill);
        if (fw) [out appendFormat:@" fillWas=%@", fw];
    } else if ([l isKindOfClass:[CATextLayer class]]) {
        CATextLayer *t = (CATextLayer *)l;
        id str = t.string;
        NSString *text = [str isKindOfClass:[NSAttributedString class]] ? [str string] : ([str isKindOfClass:[NSString class]] ? str : @"");
        [out appendFormat:@" fg=%@ text=\"%@\"", NigHexCG(t.foregroundColor), NigShort(text)];
    } else if ([l isKindOfClass:[CAGradientLayer class]]) {
        NSMutableArray *cs = [NSMutableArray array];
        for (id c in ((CAGradientLayer *)l).colors) {
            if (CFGetTypeID((__bridge CFTypeRef)c) == CGColorGetTypeID()) [cs addObject:NigHexCG((__bridge CGColorRef)c)];
        }
        [out appendFormat:@" grad=[%@]", [cs componentsJoinedByString:@","]];
    }
    NSString *contents = NigContentsDesc(l.contents);
    if (contents) [out appendFormat:@" contents=%@", contents];
    if (l.filters.count) [out appendFormat:@" filters=%lu", (unsigned long)l.filters.count];
    if (l.compositingFilter) [out appendFormat:@" comp=%@", l.compositingFilter];
    if (l.mask) [out appendString:@" mask"];
    if (l.hidden) [out appendString:@" HIDDEN"];
    if (l.opacity < 0.999) [out appendFormat:@" op=%.2f", l.opacity];
    if (l.borderWidth > 0) [out appendFormat:@" border=%@", NigHexCG(l.borderColor)];
    [out appendString:@"\n"];
    if (depth >= 3) return;
    NSUInteger n = 0;
    NSString *inner = [indent stringByAppendingString:@"  "];
    for (CALayer *s in l.sublayers) {
        if ([s.delegate isKindOfClass:[UIView class]]) continue;
        if (++n > 16) { [out appendFormat:@"%@~… %lu more\n", inner, (unsigned long)(l.sublayers.count - 16)]; break; }
        NigDumpLayer(out, s, inner, depth + 1, lines);
    }
}

static void NigDumpView(NSMutableString *out, UIView *v, int depth, NSUInteger *lines) {
    if (*lines > 12000) return;
    (*lines)++;
    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)MIN(depth, 80) withString:@" " startingAtIndex:0];
    Class cls = [v class];
    CALayer *layer = v.layer;
    CGRect wf = [v convertRect:v.bounds toView:nil];
    [out appendFormat:@"%@%@ %p w=%@", indent, NSStringFromClass(cls), v, NSStringFromCGRect(wf)];
    if (v.hidden) [out appendString:@" HIDDEN"];
    if (v.alpha < 0.999) [out appendFormat:@" a=%.2f", v.alpha];
    [out appendFormat:@" bg=%@", NigHex(v.backgroundColor)];
    NSString *bgWas = NigStoredDesc(v, kBg);
    if (bgWas) [out appendFormat:@" was=%@", bgWas];
    if ([layer class] != [CALayer class]) [out appendFormat:@" L=%@", NSStringFromClass([layer class])];
    if (!v.backgroundColor && layer.backgroundColor) {
        [out appendFormat:@" lbg=%@", NigHexCG(layer.backgroundColor)];
        NSString *lw = NigStoredDesc(layer, kLayerBg);
        if (lw) [out appendFormat:@" lwas=%@", lw];
    }
    NSString *contents = NigContentsDesc(layer.contents);
    if (contents) [out appendFormat:@" contents=%@", contents];
    if (layer.filters.count) [out appendFormat:@" filters=%lu%@", (unsigned long)layer.filters.count,
                                                NigStoreGet(v, kInverted) ? @"(nig)" : @""];
    if (layer.mask) [out appendString:@" mask"];
    NSDictionary *recolor = NigStoreGet(v, kRecolor);
    if (recolor) [out appendString:recolor[@"out"] ? @" recolor(nig)" : @" recolor-skipped"];
    if (layer.borderWidth > 0) [out appendFormat:@" border=%@", NigHexCG(layer.borderColor)];
    if (v.overrideUserInterfaceStyle != UIUserInterfaceStyleUnspecified)
        [out appendFormat:@" override=%ld", (long)v.overrideUserInterfaceStyle];
    NSNumber *web = NigStoreGet(v, kWeb);
    if (web) [out appendFormat:@" web=%@", web.boolValue ? @"on" : @"off"];
    if (v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) [out appendString:@" traitDark"];
    if (NigOverrides(cls, @selector(drawRect:))) [out appendString:@" drawRect"];
    if (NigOverrides(cls, @selector(drawLayer:inContext:))) [out appendString:@" drawLayer"];
    if (NigClassIsSystemUI(cls)) [out appendString:@" SYSTEM"];
    NSString *why = nil;
    NigBackdrop bd = NigBackdropExplain(v, &why);
    [out appendFormat:@" bd=%@<%@>\n", NigBackdropName(bd), why ?: @""];
    NIG_WITH_TRAITS(v);

    NSString *detail = [indent stringByAppendingString:@"  | "];
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        NSAttributedString *a = l.attributedText;
        [out appendFormat:@"%@label \"%@\" tc=%@", detail, NigShort(l.text), NigHex(l.textColor)];
        NSString *tw = NigStoredDesc(l, kText);
        if (tw) [out appendFormat:@" was=%@", tw];
        if (l.highlighted || l.highlightedTextColor) {
            [out appendFormat:@" hl%@=%@", l.highlighted ? @"(on)" : @"", NigHex(l.highlightedTextColor)];
            NSString *hw = NigStoredDesc(l, kHiText);
            if (hw) [out appendFormat:@" hlwas=%@", hw];
        }
        [out appendFormat:@" fg=[%@] runBg=[%@]%@\n", NigAttrColors(a, NSForegroundColorAttributeName),
                          NigAttrColors(a, NSBackgroundColorAttributeName),
                          NigStoreGet(l, kAttrOut) ? @" attr(nig)" : @""];
    } else if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        [out appendFormat:@"%@button \"%@\" title=%@", detail, NigShort([b titleForState:UIControlStateNormal]),
                          NigHex([b titleColorForState:UIControlStateNormal])];
        NSString *bw = NigStoredDesc(b, @"btn0");
        if (bw) [out appendFormat:@" was=%@", bw];
        if (@available(iOS 15.0, *)) {
            UIButtonConfiguration *conf = b.configuration;
            if (conf) [out appendFormat:@" config fg=%@ bg=%@", NigHex(conf.baseForegroundColor), NigHex(conf.baseBackgroundColor)];
        }
        [out appendString:@"\n"];
    } else if ([v isKindOfClass:[UITextField class]]) {
        UITextField *t = (UITextField *)v;
        [out appendFormat:@"%@field tc=%@ ph=[%@]\n", detail, NigHex(t.textColor),
                          NigAttrColors(t.attributedPlaceholder, NSForegroundColorAttributeName)];
    } else if ([v isKindOfClass:[UITextView class]]) {
        UITextView *t = (UITextView *)v;
        [out appendFormat:@"%@textview \"%@\" tc=%@ fg=[%@]\n", detail, NigShort(t.text), NigHex(t.textColor),
                          NigAttrColors(t.attributedText, NSForegroundColorAttributeName)];
    } else if ([v isKindOfClass:[UIImageView class]]) {
        UIImage *img = ((UIImageView *)v).image;
        if (img) {
            [out appendFormat:@"%@image %.0fx%.0f@%.0f mode=%ld sym=%d tint=%@%@\n", detail, img.size.width,
                              img.size.height, img.scale, (long)img.renderingMode, img.isSymbolImage,
                              NigHex(v.tintColor), NigStoreGet(v, kIcon) ? @" icon(nig)" : @""];
        }
    }
    NIG_END_TRAITS();

    NSUInteger n = 0;
    NSString *inner = [indent stringByAppendingString:@"  "];
    for (CALayer *s in layer.sublayers) {
        if ([s.delegate isKindOfClass:[UIView class]]) continue;
        if (++n > 16) { [out appendFormat:@"%@~… more layers\n", inner]; break; }
        NigDumpLayer(out, s, inner, 1, lines);
    }
    if (v.hidden || v.alpha < 0.01) return;
    for (UIView *sub in v.subviews) NigDumpView(out, sub, depth + 1, lines);
}

static void NigDumpControllers(NSMutableString *out, UIViewController *vc, int depth) {
    if (!vc || depth > 12) return;
    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@VC %@ %p view=%p%@%@\n", indent, NSStringFromClass([vc class]), vc,
                      vc.isViewLoaded ? vc.view : nil, vc.isViewLoaded && vc.view.window ? @" visible" : @"",
                      vc.overrideUserInterfaceStyle != UIUserInterfaceStyleUnspecified
                          ? [NSString stringWithFormat:@" override=%ld", (long)vc.overrideUserInterfaceStyle] : @""];
    for (UIViewController *child in vc.childViewControllers) NigDumpControllers(out, child, depth + 1);
    if (vc.presentedViewController && vc.presentedViewController.presentingViewController == vc) {
        [out appendFormat:@"%@presents:\n", indent];
        NigDumpControllers(out, vc.presentedViewController, depth + 1);
    }
}

static void NigDump(NSString *reason) {
    NSMutableString *out = [NSMutableString string];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NigProbeWindow(windows);
    [out appendFormat:@"Nig dump (%@) %s build %s pid %d bundle %@\n", reason, getprogname(), APELIN_BUILD_ID, getpid(),
                      [NSBundle mainBundle].bundleIdentifier];
    [out appendFormat:@"active=%d everActive=%d resolve=%ld published=%d windows=%lu\n", gDarkModeActive,
                      gEverActive, (long)gResolveStyle, NigPublishedStyle(), (unsigned long)windows.count];
    [out appendString:@"legend: w=frame in window, bg/was=now/app's own, L=layer class, ~=plain sublayer,"
                      " bd=backdrop Nig decided <who decided>\n"];
    NSUInteger lines = 0;
    for (UIWindow *w in windows) {
        [out appendFormat:@"\n== %@ %p level=%.0f key=%d hidden=%d\n", NSStringFromClass([w class]), w,
                          w.windowLevel, w.isKeyWindow, w.hidden];
        if (w.hidden) continue;
        NigDumpControllers(out, w.rootViewController, 0);
        NigDumpView(out, w, 0, &lines);
    }
    if (lines > 12000) [out appendString:@"\n(truncated at 12000 lines)\n"];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"nig-dump-%@.txt", [fmt stringFromDate:[NSDate date]]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSError *error = nil;
    BOOL ok = [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    os_log(TweakLog(), "ApelinDump ok=%d lines=%lu bytes=%lu %{public}s %{public}@", ok, (unsigned long)lines,
           (unsigned long)out.length, getprogname(), ok ? path : error.localizedDescription);
}

#pragma mark - Hooks: UIView

static void (*OrigSetBackgroundColor)(UIView *, SEL, UIColor *);
static void (*OrigSetTintColor)(UIView *, SEL, UIColor *);
static void (*OrigDidMoveToWindow)(UIView *, SEL);
static void (*OrigLabelSetTextColor)(UILabel *, SEL, UIColor *);
static void (*OrigLabelSetHighlightedTextColor)(UILabel *, SEL, UIColor *);
static void (*OrigLabelSetAttributedText)(UILabel *, SEL, NSAttributedString *);
static void (*OrigLayerSetBackgroundColor)(CALayer *, SEL, CGColorRef);
static void (*OrigDrawLayerInContext)(UIView *, SEL, CALayer *, CGContextRef);
static void (*OrigSetFillColor)(CGContextRef, CGColorRef);
static void (*OrigSetStrokeColor)(CGContextRef, CGColorRef);
static void (*OrigTraitCollectionDidChange)(UIView *, SEL, UITraitCollection *);
static void NigScheduleSettle(UIView *view);

// A hook only does Nig's work on the main thread, for views Nig may touch.
static BOOL NigShouldHandle(UIView *view) {
    if (tInHook || !gDarkModeActive || ![NSThread isMainThread] || NigHasBarcodeProtection(view)) return NO;
    return !NigIsSystemUI(view);
}

static void HookedSetBackgroundColor(UIView *self, SEL _cmd, UIColor *color) {
    if (!NigShouldHandle(self)) {
        if (!tInHook && gEverActive && [NSThread isMainThread]) NigStoreRemove(self, kBg);
        OrigSetBackgroundColor(self, _cmd, color);
        return;
    }
    UIColor *stored = NigStoreGet(self, kBg);
    BOOL changed = stored ? ![stored isEqual:color] : ![self.backgroundColor isEqual:color];
    if (!color) {
        NigStoreRemove(self, kBg);
        OrigSetBackgroundColor(self, _cmd, color);
        if (changed) NigScheduleSettle(self);
        return;
    }
    NIG_WITH_TRAITS(self);
    UIColor *want = NigDesiredBackground(color);
    NIG_END_TRAITS();
    if (want) NigStoreSet(self, kBg, color); else NigStoreRemove(self, kBg);
    tInHook = YES;
    OrigSetBackgroundColor(self, _cmd, want ?: color);
    tInHook = NO;
    if (changed) NigScheduleSettle(self);
}

static void HookedSetTintColor(UIView *self, SEL _cmd, UIColor *color) {
    if (!NigShouldHandle(self) || !color) {
        if (!tInHook && gEverActive && [NSThread isMainThread]) NigStoreRemove(self, kTint);
        OrigSetTintColor(self, _cmd, color);
        return;
    }
    UIColor *stored = NigStoreGet(self, kTint);
    UIColor *orig = (stored && [color isEqual:self.tintColor]) ? stored : color;
    NIG_WITH_TRAITS(self);
    UIColor *want = NigDesiredText(self, orig);
    NIG_END_TRAITS();
    if (want) NigStoreSet(self, kTint, orig); else NigStoreRemove(self, kTint);
    tInHook = YES;
    OrigSetTintColor(self, _cmd, want ?: orig);
    tInHook = NO;
}

// A single one-shot debounce coalesces view arrival and surface changes. It is
// disarmed while idle; it never polls or queues a delayed block per subview.
static NSHashTable<UIView *> *gArrived;
static dispatch_source_t gSettleTimer;

static void NigSettleArrived(void) {
    NSArray<UIView *> *views = gArrived.allObjects;
    [gArrived removeAllObjects];
    if (!gDarkModeActive || views.count == 0) return;
    NSHashTable *set = [NSHashTable weakObjectsHashTable];
    for (UIView *v in views) [set addObject:v];
    for (UIView *v in views) {
        if (!v.window) continue;
        BOOL covered = NO;
        for (UIView *a = v.superview; a; a = a.superview) {
            if ([set containsObject:a]) { covered = YES; break; }
        }
        if (!covered) NigApplyTree(v, 0);
    }
}

static void NigScheduleSettle(UIView *view) {
    if (!view || !gDarkModeActive || ![NSThread isMainThread]) return;
    if (!gArrived) gArrived = [NSHashTable weakObjectsHashTable];
    [gArrived addObject:view];
    if (!gSettleTimer) {
        gSettleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               dispatch_get_main_queue());
        dispatch_source_set_event_handler(gSettleTimer, ^{
            dispatch_source_set_timer(gSettleTimer, DISPATCH_TIME_FOREVER,
                                      DISPATCH_TIME_FOREVER, 0);
            NigSettleArrived();
        });
        dispatch_resume(gSettleTimer);
    }
    dispatch_source_set_timer(gSettleTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 20 * NSEC_PER_MSEC);
}

// Restore detached/reused views even after the system has returned to light.
static void HookedDidMoveToWindow(UIView *self, SEL _cmd) {
    OrigDidMoveToWindow(self, _cmd);
    if (self.window && (gDarkModeActive || gEverActive) &&
        [NSThread isMainThread] && !tInHook) {
        // Compose Multiplatform draws a whole screen itself, as Flutter does:
        // the first of its views to show tells Nig, and its window takes the
        // dark trait the engine reads.
        if (!gFlutterApp && strstr(class_getName([self class]), "androidx.compose.ui.")) {
            gFlutterApp = YES;
            NigApplySelf(self.window);
        }
        NigApplySelf(self);
        if (gDarkModeActive) NigScheduleSettle(self);
    }
}

#pragma mark - Hooks: UIImageView

static void (*OrigImageSetImage)(UIImageView *, SEL, UIImage *);

static void NigProtectBarcodeView(UIView *view) {
    if (!view || [objc_getAssociatedObject(view, kNigBarcodeSource) boolValue]) return;
    UIView *anchor = view;
    for (UIView *p = view.superview; p; p = p.superview) {
        anchor = p;
        CGFloat a = p.backgroundColor ? CGColorGetAlpha(p.backgroundColor.CGColor) : 0;
        if (a >= 0.5) break;
        a = p.layer.backgroundColor ? CGColorGetAlpha(p.layer.backgroundColor) : 0;
        if (a >= 0.5) break;
    }
    NSUInteger count = [objc_getAssociatedObject(anchor, kNigBarcodeAnchorCount) unsignedIntegerValue];
    NigBarcodeWeakViewBox *box = [NigBarcodeWeakViewBox new];
    box.view = anchor;
    objc_setAssociatedObject(view, kNigBarcodeSource, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kNigBarcodeAnchorForSource, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(anchor, kNigBarcodeAnchorCount, @(count + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NigApplyTree(anchor, 0);
}

// Some apps draw codes from many vector/layer pieces rather than assigning an
// image. Snapshot only compact, structurally complex candidate views, locally,
// then ask Vision to inspect the rendered result off the main thread. No image
// leaves the app, and no fallback surface is inserted.
static void NigScanCompositeBarcodeView(UIView *view) {
    if (!gDarkModeActive || !view.window || ![NSThread isMainThread] ||
        [view isKindOfClass:[UIImageView class]] || NigIsWebView(view) ||
        NigHasBarcodeProtection(view) || gBarcodeSnapshotBudget >= 6) return;

    CGSize size = view.bounds.size;
    CGFloat area = size.width * size.height;
    CGFloat windowArea = view.window.bounds.size.width * view.window.bounds.size.height;
    if (size.width < 120 || size.height < 48 || area < 12000 ||
        area > windowArea * 0.72 || area > 900000) return;

    NSUInteger layerCount = view.layer.sublayers.count;
    NSUInteger childCount = view.subviews.count;
    NSString *name = NSStringFromClass([view class]).lowercaseString;
    BOOL named = [name containsString:@"barcode"] || [name containsString:@"qrcode"] ||
                 [name containsString:@"qrview"] || [name containsString:@"codeview"];
    if (!named && layerCount < 16 && childCount < 8) return;

    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(view, kNigBarcodeLastSnapshotTime);
    if (last && now - last.doubleValue < 2.0) return;
    objc_setAssociatedObject(view, kNigBarcodeLastSnapshotTime, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id token = [NSObject new];
    objc_setAssociatedObject(view, kNigBarcodeSnapshotToken, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gBarcodeSnapshotBudget++;

    UIGraphicsBeginImageContextWithOptions(size, NO, 1.0);
    BOOL rendered = [view drawViewHierarchyInRect:(CGRect){CGPointZero, size} afterScreenUpdates:NO];
    UIImage *snapshot = rendered ? UIGraphicsGetImageFromCurrentImageContext() : nil;
    UIGraphicsEndImageContext();
    CGImageRef image = snapshot.CGImage;
    if (!image) return;

    __weak UIView *weakView = view;
    NigDetectBarcodes(image, ^(NSArray<NSValue *> *rects) {
        UIView *current = weakView;
        if (!current || !current.window || rects.count == 0 ||
            objc_getAssociatedObject(current, kNigBarcodeSnapshotToken) != token) return;
        NigProtectBarcodeView(current);
        os_log(TweakLog(), "ApelinBarcode composite detected count=%lu %{public}s",
               (unsigned long)rects.count, getprogname());
    });
}

static void HookedImageSetImage(UIImageView *self, SEL _cmd, UIImage *image) {
    BOOL hadProtection = [objc_getAssociatedObject(self, kNigBarcodeSource) boolValue];
    NigClearBarcodeProtection(self);
    OrigImageSetImage(self, _cmd, image);
    if (hadProtection && self.window) NigScheduleSettle(self);
    if (image.CGImage) {
        __weak UIImageView *weakView = self;
        CGImageRef source = image.CGImage;
        NigDetectBarcodes(source, ^(NSArray<NSValue *> *rects) {
            UIImageView *view = weakView;
            if (!view || rects.count == 0 || view.image.CGImage != source) return;
            NigProtectBarcodeView(view);
            os_log(TweakLog(), "ApelinBarcode native detected count=%lu %{public}s",
                   (unsigned long)rects.count, getprogname());
        });
    }
    if (NigShouldHandle(self) && self.window) {
        tInHook = YES;
        NIG_WITH_TRAITS(self);
        NigApplyImageView(self, YES);
        NIG_END_TRAITS();
        tInHook = NO;
    }
}

#pragma mark - Hooks: UILabel

static void HookedLabelSetTextColor(UILabel *self, SEL _cmd, UIColor *color) {
    if (!NigShouldHandle(self) || !color) {
        if (!tInHook && gEverActive && [NSThread isMainThread]) NigStoreRemove(self, kText);
        OrigLabelSetTextColor(self, _cmd, color);
        return;
    }
    UIColor *stored = NigStoreGet(self, kText);
    UIColor *orig = (stored && [color isEqual:self.textColor]) ? stored : color;
    NIG_WITH_TRAITS(self);
    UIColor *want = NigDesiredText(self, orig);
    NIG_END_TRAITS();
    if (want) NigStoreSet(self, kText, orig); else NigStoreRemove(self, kText);
    tInHook = YES;
    OrigLabelSetTextColor(self, _cmd, want ?: orig);
    tInHook = NO;
}

static void HookedLabelSetHighlightedTextColor(UILabel *self, SEL _cmd, UIColor *color) {
    if (!NigShouldHandle(self) || !color) {
        if (!tInHook && gEverActive && [NSThread isMainThread]) NigStoreRemove(self, kHiText);
        OrigLabelSetHighlightedTextColor(self, _cmd, color);
        return;
    }
    UIColor *stored = NigStoreGet(self, kHiText);
    UIColor *orig = (stored && [color isEqual:self.highlightedTextColor]) ? stored : color;
    NIG_WITH_TRAITS(self);
    UIColor *want = NigDesiredText(self, orig);
    NIG_END_TRAITS();
    if (want) NigStoreSet(self, kHiText, orig); else NigStoreRemove(self, kHiText);
    tInHook = YES;
    OrigLabelSetHighlightedTextColor(self, _cmd, want ?: orig);
    tInHook = NO;
}

static void HookedLabelSetAttributedText(UILabel *self, SEL _cmd, NSAttributedString *text) {
    if (!NigShouldHandle(self) || text.length == 0) {
        if (!tInHook && gEverActive && [NSThread isMainThread]) {
            NigStoreRemove(self, kAttr);
            NigStoreRemove(self, kAttrOut);
        }
        OrigLabelSetAttributedText(self, _cmd, text);
        return;
    }
    NSAttributedString *storedOut = NigStoreGet(self, kAttrOut);
    NSAttributedString *storedOrig = NigStoreGet(self, kAttr);
    NSAttributedString *orig = (storedOut && [text isEqualToAttributedString:storedOut]) ? storedOrig : text;
    NIG_WITH_TRAITS(self);
    NSAttributedString *want = NigTransformAttr(orig, self);
    NIG_END_TRAITS();
    if (want != orig) {
        NigStoreSet(self, kAttr, orig);
        NigStoreSet(self, kAttrOut, want);
    } else {
        NigStoreRemove(self, kAttr);
        NigStoreRemove(self, kAttrOut);
    }
    tInHook = YES;
    OrigLabelSetAttributedText(self, _cmd, want);
    tInHook = NO;
}

#pragma mark - Hooks: CALayer and CoreGraphics

// A background a layer gets from the app (or UIKit) while dark mode is on.
// The app's colour is remembered like NigSyncLayerColor does, so it can be restored.
static void HookedLayerSetBackgroundColor(CALayer *self, SEL _cmd, CGColorRef color) {
    if (tInHook || !gDarkModeActive || ![NSThread isMainThread] ||
        !NigLayerIsHandled(self) || self.contents) {
        OrigLayerSetBackgroundColor(self, _cmd, color);
        return;
    }
    id delegate = self.delegate;
    if ([delegate isKindOfClass:[UIView class]] && NigIsSystemUI((UIView *)delegate)) {
        OrigLayerSetBackgroundColor(self, _cmd, color);
        return;
    }
    if (!color) {
        BOOL changed = self.backgroundColor != NULL || NigStoreGet(self, kLayerBg) != nil;
        NigStoreRemove(self, kLayerBg);
        OrigLayerSetBackgroundColor(self, _cmd, color);
        if (changed && [delegate isKindOfClass:[UIView class]]) NigScheduleSettle((UIView *)delegate);
        return;
    }
    UIColor *orig = [UIColor colorWithCGColor:color];
    NSDictionary *record = NigStoreGet(self, kLayerBg);
    UIColor *current = self.backgroundColor ? [UIColor colorWithCGColor:self.backgroundColor] : nil;
    BOOL changed = record ? ![record[@"orig"] isEqual:orig] : ![current isEqual:orig];
    UIView *owner = [delegate isKindOfClass:[UIView class]] ? (UIView *)delegate : nil;
    NIG_WITH_TRAITS(owner);
    UIColor *want = NigTransformColor(orig, NigRoleBackground);
    NIG_END_TRAITS();
    if (!want) {
        NigStoreRemove(self, kLayerBg);
        OrigLayerSetBackgroundColor(self, _cmd, color);
        if (changed && [delegate isKindOfClass:[UIView class]]) NigScheduleSettle((UIView *)delegate);
        return;
    }
    NigStoreSet(self, kLayerBg, @{@"orig": orig, @"out": want});
    tInHook = YES;
    OrigLayerSetBackgroundColor(self, _cmd, want.CGColor);
    tInHook = NO;
    if (changed && [delegate isKindOfClass:[UIView class]]) NigScheduleSettle((UIView *)delegate);
}

// Core Graphics colour rewriting is limited to UIKit's text controls. Arbitrary
// app drawing may mix text with backgrounds, logos and data graphics; rasterized
// SwiftUI glyph views use the separate narrow layer-filter path above.
static void HookedDrawLayerInContext(UIView *self, SEL _cmd, CALayer *layer, CGContextRef ctx) {
    int previous = tDrawState;
    BOOL prevBgValid = tDrawBgValid;
    CGFloat prevBg[3] = { tDrawBg[0], tDrawBg[1], tDrawBg[2] };
    BOOL main = [NSThread isMainThread];
    BOOL textRenderer = main && NigIsTextRenderer(self);
    BOOL lighten = gDarkModeActive && !tInHook && textRenderer && !NigIsSystemUI(self) &&
                   NigTextBackdrop(self) == NigBackdropDark;
    // Remembered so that NigApplySelf redraws it only when the answer changes.
    if (textRenderer && !tInHook) NigStoreSet(self, kDrawn, @(lighten));
    tDrawBgValid = NO;
    if (gDarkModeActive && !tInHook && NigShouldFilterBitmap(self, YES)) {
        tDrawState = 2;  // this small rasterized glyph is recoloured by its layer filter
    } else if (lighten) {
        tDrawState = 1;
        // UIKit fills a self-drawing view's background into its own bitmap:
        // that fill is the (already dark) surface, not a glyph to lighten.
        CGColorRef bg = self.layer.backgroundColor;
        CGFloat a = 0;
        NIG_WITH_TRAITS(self);
        if (self.backgroundColor) {
            tDrawBgValid = NigGetRGBA(self.backgroundColor, &tDrawBg[0], &tDrawBg[1], &tDrawBg[2], &a);
        } else if (bg) {
            tDrawBgValid = NigGetRGBA([UIColor colorWithCGColor:bg], &tDrawBg[0], &tDrawBg[1], &tDrawBg[2], &a);
        }
        NIG_END_TRAITS();
    } else {
        tDrawState = 2;
    }
    OrigDrawLayerInContext(self, _cmd, layer, ctx);
    tDrawState = previous;
    tDrawBgValid = prevBgValid;
    tDrawBg[0] = prevBg[0]; tDrawBg[1] = prevBg[1]; tDrawBg[2] = prevBg[2];
}

// YES when `color` is the background of the view drawing itself.
static BOOL NigIsDrawingBackground(CGColorRef color) {
    if (!tDrawBgValid) return NO;
    CGColorSpaceRef space = CGColorGetColorSpace(color);
    if (!space) return NO;
    CGColorSpaceModel model = CGColorSpaceGetModel(space);
    size_t n = CGColorGetNumberOfComponents(color);
    const CGFloat *c = CGColorGetComponents(color);
    if (!c) return NO;
    CGFloat r, g, b;
    if (model == kCGColorSpaceModelRGB && n >= 3) { r = c[0]; g = c[1]; b = c[2]; }
    else if (model == kCGColorSpaceModelMonochrome && n >= 1) { r = g = b = c[0]; }
    else return NO;
    return fabs(r - tDrawBg[0]) < 0.02 && fabs(g - tDrawBg[1]) < 0.02 && fabs(b - tDrawBg[2]) < 0.02;
}

// Dark fills and strokes (text glyphs, icons, shapes) get their lighter
// counterpart, but only while a view draws onto a dark surface (tDrawState 1).
// Light colours are untouched.
static void HookedSetFillColor(CGContextRef ctx, CGColorRef color) {
    if (gDarkModeActive && color && !tInHook && tDrawState == 1 && !NigIsDrawingBackground(color)) {
        CGColorRef mapped = NigCopyTransformedCGColor(color, NigRoleText);
        if (mapped) {
            OrigSetFillColor(ctx, mapped);
            CGColorRelease(mapped);
            return;
        }
    }
    OrigSetFillColor(ctx, color);
}

static void HookedSetStrokeColor(CGContextRef ctx, CGColorRef color) {
    if (gDarkModeActive && color && !tInHook && tDrawState == 1) {
        CGColorRef mapped = NigCopyTransformedCGColor(color, NigRoleText);
        if (mapped) {
            OrigSetStrokeColor(ctx, mapped);
            CGColorRelease(mapped);
            return;
        }
    }
    OrigSetStrokeColor(ctx, color);
}

static void HookedTraitCollectionDidChange(UIView *self, SEL _cmd, UITraitCollection *previous) {
    OrigTraitCollectionDidChange(self, _cmd, previous);
    if (!previous || previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        NigPublishStyleIfChanged();
    }
}

#pragma mark - Entry point

static BOOL NigShouldRunInThisProcess(void) {
    NSBundle *main = [NSBundle mainBundle];
    NSString *bid = main.bundleIdentifier ?: @"";
    // Only real apps: no daemons, extensions or keyboards. Apple's own apps
    // already support dark mode, and SpringBoard is not an app to recolour.
    if (![main.bundlePath hasSuffix:@".app"]) return NO;
    if ([bid hasPrefix:@"com.apple."]) return NO;
    return NSClassFromString(@"UIApplication") != Nil;
}

static void NigObserve(NSNotificationName name, NSTimeInterval followUp) {
    [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note __unused) {
        NigRequestRefresh();
        if (followUp > 0) {
            // Apps build their UI a moment after the notification.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(followUp * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ NigRefresh(); });
        }
    }];
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        // SpringBoard publishes only when UIKit reports a real trait change;
        // no periodic poll is left running while the device is idle.
        MSHookMessageEx([UIView class], @selector(traitCollectionDidChange:),
                        (IMP)HookedTraitCollectionDidChange,
                        (IMP *)&OrigTraitCollectionDidChange);
        dispatch_async(dispatch_get_main_queue(), ^{
            NigPublishStyleIfChanged();
            NigPublishPrefs();
        });
        // The Settings pane posts this after each change.
        int changedToken = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kPrefsChanged, &changedToken, dispatch_get_main_queue(), ^(int t __unused) {
            NigPublishPrefs();
        });
        return;
    }
    if (!NigShouldRunInThisProcess()) return;
    gBarcodeQueue = dispatch_queue_create("com.imodcommission.nig.barcode", DISPATCH_QUEUE_CONCURRENT);
    gFlutterApp = NSClassFromString(@"FlutterView") != Nil;

    MSHookMessageEx([UIView class], @selector(setBackgroundColor:),
                    (IMP)HookedSetBackgroundColor, (IMP *)&OrigSetBackgroundColor);
    MSHookMessageEx([UIView class], @selector(setTintColor:),
                    (IMP)HookedSetTintColor, (IMP *)&OrigSetTintColor);
    MSHookMessageEx([UIView class], @selector(didMoveToWindow),
                    (IMP)HookedDidMoveToWindow, (IMP *)&OrigDidMoveToWindow);
    MSHookMessageEx([UIImageView class], @selector(setImage:),
                    (IMP)HookedImageSetImage, (IMP *)&OrigImageSetImage);
    MSHookMessageEx([UILabel class], @selector(setTextColor:),
                    (IMP)HookedLabelSetTextColor, (IMP *)&OrigLabelSetTextColor);
    MSHookMessageEx([UILabel class], @selector(setHighlightedTextColor:),
                    (IMP)HookedLabelSetHighlightedTextColor, (IMP *)&OrigLabelSetHighlightedTextColor);
    MSHookMessageEx([UILabel class], @selector(setAttributedText:),
                    (IMP)HookedLabelSetAttributedText, (IMP *)&OrigLabelSetAttributedText);
    MSHookMessageEx([CALayer class], @selector(setBackgroundColor:),
                    (IMP)HookedLayerSetBackgroundColor, (IMP *)&OrigLayerSetBackgroundColor);
    MSHookMessageEx([CALayer class], @selector(setContents:),
                    (IMP)HookedLayerSetContents, (IMP *)&OrigLayerSetContents);
    MSHookMessageEx([UIView class], @selector(drawLayer:inContext:),
                    (IMP)HookedDrawLayerInContext, (IMP *)&OrigDrawLayerInContext);
    MSHookFunction((void *)CGContextSetFillColorWithColor,
                   (void *)HookedSetFillColor, (void **)&OrigSetFillColor);
    MSHookFunction((void *)CGContextSetStrokeColorWithColor,
                   (void *)HookedSetStrokeColor, (void **)&OrigSetStrokeColor);

    // UIApplication never had -application:didFinishLaunchingWithOptions: (it
    // is the delegate's), so the old hook on it never ran. Notifications are
    // the reliable trigger; the system style is read once the app is up.
    int styleToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kStyleNotification, &styleToken, dispatch_get_main_queue(), ^(int t __unused) {
        NigRequestRefresh();
    });
    int prefsToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kPrefsNotification, &prefsToken, dispatch_get_main_queue(), ^(int t __unused) {
        NigRequestRefresh();
    });
    int dumpToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kDumpNotification, &dumpToken, dispatch_get_main_queue(), ^(int t __unused) {
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) NigDump(@"notify");
    });
    // A screenshot of a page that looks wrong also records that page's tree.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationUserDidTakeScreenshotNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note __unused) {
        NigDump(@"screenshot");
    }];
    NigObserve(UIApplicationDidFinishLaunchingNotification, 0.6);
    NigObserve(UIApplicationWillEnterForegroundNotification, 0.0);
    NigObserve(UIApplicationDidBecomeActiveNotification, 0.6);
    NigObserve(UIWindowDidBecomeVisibleNotification, 0.0);
    NigObserve(UIWindowDidBecomeKeyNotification, 0.0);
}
