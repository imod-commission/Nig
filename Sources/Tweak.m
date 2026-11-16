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
#import <notify.h>
#import <substrate.h>

#pragma mark - Logging

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

#pragma mark - State

// True while the system is dark AND the host app itself renders light.
static BOOL gDarkModeActive = NO;
static BOOL gEverActive = NO;
static BOOL gRefreshPending = NO;
// Set while Nig itself changes a property, so the hooks let it through.
static __thread BOOL tInHook = NO;
// While a view draws itself: 1 = it sits on a surface Nig made dark, 2 = it does not,
// 0 = not inside a view's drawLayer:inContext: at all. Core Graphics colour
// hooks only act in state 1, so glyphs are never lightened over a light surface.
static __thread int tDrawState = 0;
// Set while Nig renders the window to look at the pixels behind a view: the
// drawing it triggers must still be recoloured like any other drawing.
static __thread BOOL tSampling = NO;
// Bumped whenever a surface colour changes, which invalidates sampled backdrops.
static NSUInteger gSampleEpoch = 0;
// How the app itself resolves dynamic colours: dark when the app follows the
// system appearance (its dynamic colours are then already dark), light when it
// is locked to light. Fixed by the window's real trait in NigRefresh.
static UIUserInterfaceStyle gResolveStyle = UIUserInterfaceStyleLight;
static UITraitCollection *gResolveTraits = nil;

typedef NS_ENUM(NSInteger, NigRole) {
    NigRoleText,        // text, tint, glyph fills: lighten, keep hue
    NigRoleBackground,  // surfaces: darken, never flip dark to light
    NigRoleBorder,      // hairlines: dim but keep visible
};

typedef NS_ENUM(NSInteger, NigBackdrop) {
    NigBackdropDark,   // a solid colour Nig has made dark (or nothing known)
    NigBackdropLight,  // a solid colour that is still light
    NigBackdropMedia,  // image, gradient, custom drawing: leave text alone
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
    UIColor *resolved = [color resolvedColorWithTraitCollection:(gResolveTraits ?: NigLightTraits())] ?: color;
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

#pragma mark - Per-view memory of the app's own colours

static const void *kNigStoreKey = &kNigStoreKey;
static NSString *const kBg = @"bg";
static NSString *const kText = @"text";
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

// Classifies the first thing behind `view` that has a look of its own.
static NigBackdrop NigBackdropOf(UIView *view) {
    NSInteger depth = 0;
    for (UIView *v = view; v && depth < 60; v = v.superview, depth++) {
        // Blur bars are forced dark by Nig (see NigApplySelf).
        if ([v isKindOfClass:[UIVisualEffectView class]]) return NigBackdropDark;
        CALayer *layer = v.layer;

        if (v != view) {
            if ([v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image) return NigBackdropMedia;
            if (NigIsCGImage(layer.contents) || [layer isKindOfClass:[CAGradientLayer class]]) return NigBackdropMedia;

            NSArray<CALayer *> *subs = layer.sublayers;
            NSUInteger n = MIN(subs.count, (NSUInteger)8);
            for (NSUInteger i = 0; i < n; i++) {
                CALayer *s = subs[i];
                if (!NigIsPlainSublayer(s, layer)) continue;
                if (NigIsCGImage(s.contents) || [s isKindOfClass:[CAGradientLayer class]]) return NigBackdropMedia;
                CGColorRef fill = [s isKindOfClass:[CAShapeLayer class]] ? ((CAShapeLayer *)s).fillColor : s.backgroundColor;
                if (fill && CGColorGetAlpha(fill) >= 0.6) {
                    UIColor *c = [UIColor colorWithCGColor:fill];
                    CGFloat r, g, b, a;
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
            if (!NigGetRGBA(bg, &r, &g, &b, &a)) return NigBackdropMedia;  // pattern colour
            if (a >= 0.6) return NigLuma(r, g, b) > 0.55 ? NigBackdropLight : NigBackdropDark;
        } else if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) >= 0.6) {
            CGFloat r, g, b, a;
            if (NigGetRGBA([UIColor colorWithCGColor:layer.backgroundColor], &r, &g, &b, &a)) {
                return NigLuma(r, g, b) > 0.55 ? NigBackdropLight : NigBackdropDark;
            }
        }
    }
    return NigBackdropDark;
}

// What is really behind a view, by looking: the window is rendered with the
// view hidden, into a few pixels covering the view's frame. The app's own
// colours and Nig's both show up there, so text follows what is directly under
// it: dark underneath becomes light text, light underneath keeps dark text.
// Returns NO when nothing reliable can be read (nothing drawn there, GPU content).
static BOOL NigSampleBehind(UIView *view, CGFloat *mean, CGFloat *spread) {
    UIWindow *window = view.window;
    if (!window || view.bounds.size.width < 1 || view.bounds.size.height < 1) return NO;
    CGRect r = CGRectIntersection([view convertRect:view.bounds toView:window], window.bounds);
    if (CGRectIsNull(r) || r.size.width < 1 || r.size.height < 1) return NO;

    NSDictionary *cached = NigStoreGet(view, @"behind");
    if (cached && [cached[@"epoch"] unsignedIntegerValue] == gSampleEpoch &&
        CGRectEqualToRect(CGRectIntegral(r), CGRectIntegral(CGRectFromString(cached[@"rect"])))) {
        if (![cached[@"ok"] boolValue]) return NO;
        *mean = [cached[@"mean"] doubleValue];
        *spread = [cached[@"spread"] doubleValue];
        return YES;
    }

    enum { N = 4 };
    uint8_t px[N * N * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px, N, N, 8, N * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;
    CGContextTranslateCTM(ctx, 0, N);
    CGContextScaleCTM(ctx, 1, -1);  // UIKit's orientation
    CGContextScaleCTM(ctx, N / r.size.width, N / r.size.height);
    CGContextTranslateCTM(ctx, -r.origin.x, -r.origin.y);

    BOOL previousInHook = tInHook, previousSampling = tSampling;
    tInHook = YES;
    tSampling = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    BOOL wasHidden = view.layer.hidden;
    view.layer.hidden = YES;
    [window.layer renderInContext:ctx];
    view.layer.hidden = wasHidden;
    [CATransaction commit];
    tSampling = previousSampling;
    tInHook = previousInHook;
    CGContextRelease(ctx);

    double sum = 0, lo = 1, hi = 0;
    int covered = 0;
    for (int i = 0; i < N * N; i++) {
        double a = px[i * 4 + 3] / 255.0;
        if (a < 0.9) continue;
        covered++;
        double l = NigLuma(px[i * 4] / 255.0 / a, px[i * 4 + 1] / 255.0 / a, px[i * 4 + 2] / 255.0 / a);
        sum += l; lo = MIN(lo, l); hi = MAX(hi, l);
    }
    BOOL ok = covered >= (N * N * 3) / 4;
    CGFloat m = ok ? sum / covered : 0, sp = ok ? hi - lo : 0;
    NigStoreSet(view, @"behind", @{@"epoch": @(gSampleEpoch), @"rect": NSStringFromCGRect(CGRectIntegral(r)),
                                   @"time": @(CACurrentMediaTime()), @"ok": @(ok), @"mean": @(m), @"spread": @(sp)});
    if (!ok) return NO;
    *mean = m; *spread = sp;
    return YES;
}

// For text and glyphs: the backdrop as it looks, falling back to the model
// (NigBackdropOf) when it cannot be read.
static NigBackdrop NigTextBackdrop(UIView *view) {
    // The model is cheap and gives the same answer every time. Pixels are only
    // read when it cannot tell (a photo, a gradient or a banner behind).
    NigBackdrop model = NigBackdropOf(view);
    if (model != NigBackdropMedia) return model;
    CGSize size = view.bounds.size;
    BOOL small = size.height <= 120 && size.width * size.height <= 60000;  // a big view has no single backdrop
    if (small && view.window && [NSThread isMainThread]) {
        CGFloat mean, spread;
        if (NigSampleBehind(view, &mean, &spread)) {
            if (spread > 0.45) return NigBackdropMedia;
            if (mean < 0.45) return NigBackdropDark;
            if (mean > 0.55) return NigBackdropLight;
        }
    }
    return NigBackdropMedia;
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
    if (attr.length == 0 || NigTextBackdrop(view) != NigBackdropDark) return attr;
    __block NSMutableAttributedString *m = nil;
    [attr enumerateAttribute:NSForegroundColorAttributeName
                     inRange:NSMakeRange(0, attr.length)
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop __unused) {
        if (![value isKindOfClass:[UIColor class]]) return;
        UIColor *n = NigTransformColor(value, NigRoleText);
        if (!n) return;
        if (!m) m = [attr mutableCopy];
        [m addAttribute:NSForegroundColorAttributeName value:n range:range];
    }];
    return m ?: attr;
}

// YES when some run carries a colour other than the label's own textColor.
static BOOL NigAttrHasCustomColors(NSAttributedString *attr, UIColor *base) {
    __block BOOL custom = NO;
    [attr enumerateAttribute:NSForegroundColorAttributeName
                     inRange:NSMakeRange(0, attr.length)
                     options:0
                  usingBlock:^(id value, NSRange range __unused, BOOL *stop) {
        if ([value isKindOfClass:[UIColor class]] && ![value isEqual:base]) {
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
    if (current != want && ![current isEqual:want]) { gSampleEpoch++; set(want); }
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

        // Placeholder runs keep their own colour unless they are dark.
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
        if (t.textStorage.length == 0) {
            NigSyncColor(view, kText, t.textColor, active,
                         ^UIColor *(UIColor *o) { return NigDesiredText(view, o); },
                         ^(UIColor *c) { t.textColor = c; });
        } else if (active) {
            // Per run, in place: setting textColor would flatten the styling.
            NSTextStorage *storage = t.textStorage;
            [storage beginEditing];
            [storage enumerateAttribute:NSForegroundColorAttributeName
                                inRange:NSMakeRange(0, storage.length)
                                options:0
                             usingBlock:^(id value, NSRange range, BOOL *stop __unused) {
                if (![value isKindOfClass:[UIColor class]]) return;
                UIColor *n = NigDesiredText(view, value);
                if (n) [storage addAttribute:NSForegroundColorAttributeName value:n range:range];
            }];
            [storage endEditing];
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
        if (!(cur && [cur isEqual:want])) { gSampleEpoch++; set(want.CGColor); }
        NigStoreSet(layer, key, @{@"orig": orig, @"out": want});
    } else {
        if (rec && ![orig isEqual:cur]) { gSampleEpoch++; set(orig.CGColor); }
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
    for (CALayer *s in [parent.sublayers copy]) {
        if (!NigIsPlainSublayer(s, parent)) continue;  // subview layers and small shapes stay
        NigApplyLayerColors(s, active, NO);
        NigApplySurfaceSublayers(s, active, depth + 1);
    }
}

// Bars and blur views follow the dark style natively, which also darkens
// whatever is drawn by the system in them.
static BOOL NigWantsDarkOverride(UIView *view) {
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        return [((UIVisualEffectView *)view).effect isKindOfClass:[UIBlurEffect class]];
    }
    return [view isKindOfClass:[UITabBar class]] || [view isKindOfClass:[UINavigationBar class]] ||
           [view isKindOfClass:[UIToolbar class]];
}

#pragma mark - Views that draw text as pixels

// Some views put their text (and glyph-like shapes) into a bitmap with their
// own drawing code: SwiftUI's CGDrawingView, or any app view that overrides
// drawLayer:inContext:. No colour reaches Nig there, so the layer itself is
// flipped by the compositor: invert plus a 180 degree hue turn, which swaps
// light and dark while keeping the hue (dark navy becomes pale blue).
static NSString *const kInverted = @"inverted";
static void (*OrigDrawLayerInContext)(UIView *, SEL, CALayer *, CGContextRef);
static void HookedDrawLayerInContext(UIView *self, SEL _cmd, CALayer *layer, CGContextRef ctx);

static BOOL NigDrawsOwnBitmap(UIView *view) {
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    Class cls = [view class];
    NSString *name = NSStringFromClass(cls);
    NSNumber *known = cache[name];
    if (known) return known.boolValue;
    BOOL result = NO;
    if ([name containsString:@"CGDrawingView"]) {
        result = YES;
    } else {
        IMP imp = class_getMethodImplementation(cls, @selector(drawLayer:inContext:));
        if (imp != (IMP)OrigDrawLayerInContext && imp != (IMP)HookedDrawLayerInContext) {
            const char *image = class_getImageName(cls);
            result = image && strncmp(image, "/System/", 8) != 0 && strncmp(image, "/usr/lib/", 9) != 0;
        }
    }
    cache[name] = @(result);
    return result;
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

static void NigApplyBitmapFilter(UIView *view, BOOL active) {
    BOOL want = active && gResolveStyle != UIUserInterfaceStyleDark &&  // an app already rendering dark stays
                NigTextBackdrop(view) == NigBackdropDark;
    NSDictionary *rec = NigStoreGet(view, kInverted);
    CALayer *layer = view.layer;
    if (want && !rec) {
        NSArray *ours = NigInvertFilters();
        if (!ours) return;
        NSArray *before = layer.filters ?: @[];
        NigStoreSet(view, kInverted, @{@"before": before});
        layer.filters = [before arrayByAddingObjectsFromArray:ours];
    } else if (!want && rec) {
        NSArray *before = rec[@"before"];
        layer.filters = before.count ? before : nil;
        NigStoreRemove(view, kInverted);
    }
}

static void NigApplySelf(UIView *view) {
    if (!view || NigIsSystemUI(view)) return;
    BOOL active = gDarkModeActive;
    BOOL previous = tInHook;
    tInHook = YES;

    NigSyncColor(view, kBg, view.backgroundColor, active,
                 ^UIColor *(UIColor *o) { return NigDesiredBackground(o); },
                 ^(UIColor *c) { view.backgroundColor = c; });

    if (NigWantsDarkOverride(view)) {
        // An app that already follows the system style has dark bars.
        BOOL wantOverride = active && gResolveStyle != UIUserInterfaceStyleDark;
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
    if (NigDrawsOwnBitmap(view)) NigApplyBitmapFilter(view, active);

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

    tInHook = previous;
}

static void NigApplyTree(UIView *view, NSInteger depth) {
    if (!view || depth > 200) return;
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

    gSampleEpoch++;
    BOOL system = NigSystemIsDark(YES);
    // Dynamic colours are read the way the app itself resolves them.
    BOOL traitDark = (probe.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NigSetResolveStyle(traitDark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight);
    BOOL active = system;

    static int lastSig = -1;
    int sig = (system ? 1 : 0) | (traitDark ? 2 : 0);
    if (sig != lastSig) {
        lastSig = sig;
        os_log(TweakLog(), "ApelinState active=%d system=%d published=%d traitDark=%d %{public}s",
               active, system, NigPublishedStyle(), traitDark, getprogname());
    }
    gDarkModeActive = active;
    if (active) gEverActive = YES;
    if (!gEverActive) return;  // nothing was ever changed, nothing to restore

    for (UIWindow *w in windows) {
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

#pragma mark - Hooks: UIView

static void (*OrigSetBackgroundColor)(UIView *, SEL, UIColor *);
static void (*OrigSetTintColor)(UIView *, SEL, UIColor *);
static void (*OrigDidMoveToWindow)(UIView *, SEL);
static void (*OrigLabelSetTextColor)(UILabel *, SEL, UIColor *);
static void (*OrigLabelSetAttributedText)(UILabel *, SEL, NSAttributedString *);
static void (*OrigLayerSetBackgroundColor)(CALayer *, SEL, CGColorRef);
static void (*OrigDrawLayerInContext)(UIView *, SEL, CALayer *, CGContextRef);
static void (*OrigSetFillColor)(CGContextRef, CGColorRef);
static void (*OrigSetStrokeColor)(CGContextRef, CGColorRef);

// A hook only does Nig's work on the main thread, for views Nig may touch.
static BOOL NigShouldHandle(UIView *view) {
    if (tInHook || !gDarkModeActive || ![NSThread isMainThread]) return NO;
    return !NigIsSystemUI(view);
}

static void HookedSetBackgroundColor(UIView *self, SEL _cmd, UIColor *color) {
    if (!NigShouldHandle(self)) {
        if (!tInHook && gEverActive && [NSThread isMainThread]) NigStoreRemove(self, kBg);
        OrigSetBackgroundColor(self, _cmd, color);
        return;
    }
    if (!color) {
        NigStoreRemove(self, kBg);
        OrigSetBackgroundColor(self, _cmd, color);
        return;
    }
    gSampleEpoch++;
    UIColor *want = NigDesiredBackground(color);
    if (want) NigStoreSet(self, kBg, color); else NigStoreRemove(self, kBg);
    tInHook = YES;
    OrigSetBackgroundColor(self, _cmd, want ?: color);
    tInHook = NO;
}

static void HookedSetTintColor(UIView *self, SEL _cmd, UIColor *color) {
    if (!NigShouldHandle(self) || !color) {
        if (!tInHook && gEverActive && [NSThread isMainThread]) NigStoreRemove(self, kTint);
        OrigSetTintColor(self, _cmd, color);
        return;
    }
    UIColor *want = NigDesiredText(self, color);
    if (want) NigStoreSet(self, kTint, color); else NigStoreRemove(self, kTint);
    tInHook = YES;
    OrigSetTintColor(self, _cmd, want ?: color);
    tInHook = NO;
}

// A page change builds its views before their backgrounds and images are in
// place, so a decision taken the moment a view arrives can be premature. The
// arrived views are remembered and judged once more when things have been
// quiet for a moment: one pass, no timer, nothing while the app is idle.
static NSHashTable<UIView *> *gArrived;
static NSUInteger gSettleGeneration = 0;

static void NigSettleArrived(void) {
    NSArray<UIView *> *views = gArrived.allObjects;
    [gArrived removeAllObjects];
    if (!gDarkModeActive || views.count == 0) return;
    NSHashTable *set = [NSHashTable weakObjectsHashTable];
    for (UIView *v in views) [set addObject:v];
    gSampleEpoch++;
    for (UIView *v in views) {
        if (!v.window) continue;
        BOOL covered = NO;  // an ancestor is also arrived: its pass reaches this view
        for (UIView *a = v.superview; a; a = a.superview) {
            if ([set containsObject:a]) { covered = YES; break; }
        }
        if (!covered) NigApplyTree(v, 0);
    }
}

static void NigScheduleSettle(UIView *view) {
    if (!gArrived) gArrived = [NSHashTable weakObjectsHashTable];
    [gArrived addObject:view];
    NSUInteger generation = ++gSettleGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == gSettleGeneration) NigSettleArrived();
    });
}

// Only this view: its subviews get their own didMoveToWindow. Walking the
// whole subtree here was quadratic.
static void HookedDidMoveToWindow(UIView *self, SEL _cmd) {
    OrigDidMoveToWindow(self, _cmd);
    if (self.window && gDarkModeActive && [NSThread isMainThread] && !tInHook) {
        NigApplySelf(self);
        NigScheduleSettle(self);
    }
}

#pragma mark - Hooks: UIImageView

static void (*OrigImageSetImage)(UIImageView *, SEL, UIImage *);

static void HookedImageSetImage(UIImageView *self, SEL _cmd, UIImage *image) {
    OrigImageSetImage(self, _cmd, image);
    if (NigShouldHandle(self) && self.window) {
        tInHook = YES;
        NigApplyImageView(self, YES);
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
    UIColor *want = NigDesiredText(self, color);
    if (want) NigStoreSet(self, kText, color); else NigStoreRemove(self, kText);
    tInHook = YES;
    OrigLabelSetTextColor(self, _cmd, want ?: color);
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
    NSAttributedString *want = NigTransformAttr(text, self);
    if (want != text) {
        NigStoreSet(self, kAttr, text);
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
    if (tInHook || !gDarkModeActive || !color || ![NSThread isMainThread] ||
        !NigLayerIsHandled(self) || self.contents) {
        OrigLayerSetBackgroundColor(self, _cmd, color);
        return;
    }
    id delegate = self.delegate;
    if ([delegate isKindOfClass:[UIView class]] && NigIsSystemUI((UIView *)delegate)) {
        OrigLayerSetBackgroundColor(self, _cmd, color);
        return;
    }
    UIColor *orig = [UIColor colorWithCGColor:color];
    UIColor *want = NigTransformColor(orig, NigRoleBackground);
    if (!want) {
        NigStoreRemove(self, kLayerBg);
        OrigLayerSetBackgroundColor(self, _cmd, color);
        return;
    }
    gSampleEpoch++;
    NigStoreSet(self, kLayerBg, @{@"orig": orig, @"out": want});
    tInHook = YES;
    OrigLayerSetBackgroundColor(self, _cmd, want.CGColor);
    tInHook = NO;
}

// Sets tDrawState for the duration of a view's own drawing: Core Graphics
// colours are only lightened while the view draws onto a surface Nig made dark.
static void HookedDrawLayerInContext(UIView *self, SEL _cmd, CALayer *layer, CGContextRef ctx) {
    int previous = tDrawState;
    if (gDarkModeActive && !tSampling && NigDrawsOwnBitmap(self)) {
        tDrawState = 2;  // flipped as a whole by NigApplyBitmapFilter
    } else if (gDarkModeActive && (!tInHook || tSampling) && [NSThread isMainThread]) {
        tDrawState = (!NigIsSystemUI(self) &&
                      (tSampling ? NigBackdropOf(self) : NigTextBackdrop(self)) == NigBackdropDark) ? 1 : 2;
    } else {
        tDrawState = 2;
    }
    OrigDrawLayerInContext(self, _cmd, layer, ctx);
    tDrawState = previous;
}

// Dark fills and strokes (text glyphs, icons, shapes) get their lighter
// counterpart, but only while a view draws onto a dark surface (tDrawState 1).
// Light colours are untouched.
static void HookedSetFillColor(CGContextRef ctx, CGColorRef color) {
    if (gDarkModeActive && color && (!tInHook || tSampling) && tDrawState == 1) {
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
    if (gDarkModeActive && color && (!tInHook || tSampling) && tDrawState == 1) {
        CGColorRef mapped = NigCopyTransformedCGColor(color, NigRoleText);
        if (mapped) {
            OrigSetStrokeColor(ctx, mapped);
            CGColorRelease(mapped);
            return;
        }
    }
    OrigSetStrokeColor(ctx, color);
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
        // SpringBoard only reports the system style; it recolours nothing.
        dispatch_async(dispatch_get_main_queue(), ^{
            NigPublishStyleIfChanged();
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                      NSEC_PER_SEC, NSEC_PER_SEC / 4);
            dispatch_source_set_event_handler(timer, ^{ NigPublishStyleIfChanged(); });
            dispatch_resume(timer);
            static dispatch_source_t keep;
            keep = timer;
        });
        return;
    }
    if (!NigShouldRunInThisProcess()) return;

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
    MSHookMessageEx([UILabel class], @selector(setAttributedText:),
                    (IMP)HookedLabelSetAttributedText, (IMP *)&OrigLabelSetAttributedText);
    MSHookMessageEx([CALayer class], @selector(setBackgroundColor:),
                    (IMP)HookedLayerSetBackgroundColor, (IMP *)&OrigLayerSetBackgroundColor);
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
    NigObserve(UIApplicationDidFinishLaunchingNotification, 0.6);
    NigObserve(UIApplicationWillEnterForegroundNotification, 0.0);
    NigObserve(UIApplicationDidBecomeActiveNotification, 0.6);
    NigObserve(UIWindowDidBecomeVisibleNotification, 0.0);
    NigObserve(UIWindowDidBecomeKeyNotification, 0.0);
}
