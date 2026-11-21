<p align="center"><img src="assets/icon.png" width="96" alt="Nig"></p>

# Nig

**Night mode for unsupported apps and websites!**

Nig turns on a dark look for apps and web pages that have no dark theme of their own. It follows the system appearance: when iOS is in Dark mode, Nig recolours what the app draws; in Light mode it does nothing.

## Where Nig applies

- **UIKit apps.** Backgrounds, labels, tints, text fields, keyboards and custom-drawn views of apps that ignore Dark mode. Apps that already support Dark mode are left alone.
- **Web pages.** Safari, in-app browsers (`SFSafariViewController`), web views inside apps (`WKWebView`) and Home Screen web apps.
- **Settings pane.** *Settings ▸ Nig* has a switch for Nig, a switch for web pages and an **Excluded sites** list. The pane is available in English, Japanese, Simplified Chinese and Traditional Chinese.

### How colours are changed

- A dark colour becomes a lighter shade of the **same hue**, not flat white, so hierarchy survives.
- Photos, videos and other media are never inverted, and QR codes and barcodes are never recoloured.
- Every change is reversible: switching back to Light mode restores the app's own colours.

### Excluding things

- **An app:** use [Choicy](https://havoc.app/package/choicy) and disable Nig for it.
- **A website:** *Settings ▸ Nig ▸ Excluded sites ▸ +*. Enter a domain (`example.com`, subdomains included) or a page address (`example.com/shop`, only those pages). The list applies in Safari and inside apps.

## Disclaimer

Nig **will not work in every app**. It recolours the standard UIKit and web content that apps draw through the system, so:

- Apps that draw their whole interface themselves (Flutter, Compose Multiplatform, games, Metal or Unity based apps, some Weex/Unicorn apps) cannot be recoloured and stay as they are.
- Some apps and pages may look wrong: low contrast, a missed element or an unexpected colour. Turn Nig off for that app or site if that happens.
- Nig injects into apps. Use it at your own risk; the author is not responsible for crashes, glitches or lost data.

## Requirements

- iOS 16.0 or later, arm64e
- A jailbreak with a tweak injection environment (MobileSubstrate or compatible) and PreferenceLoader
- A rootless or roothide jailbreak (the Nig code also handles rootful paths, but no rootful package is built yet)

## Installation

Download the package for your jailbreak from the [latest release](https://github.com/imod-commission/Nig/releases/latest), install it with your package manager and respring.

| Jailbreak | Package architecture |
| --- | --- |
| Rootless | `iphoneos-arm64` |
| Roothide | `iphoneos-arm64e` |

## Repository layout

| Path | What it is |
| --- | --- |
| `Sources/Tweak.m` | The tweak: hooks and colour logic |
| `Web/NigWeb.js` | The web page engine, embedded in `Sources/NigWebScript.h` by `Web/embed.py` |
| `Shared/` | Code shared by the tweak and the settings pane |
| `Prefs/` | The Settings pane, its strings and its icon |
| `Prefs/Packaging/entry.plist` | The PreferenceLoader entry (becomes `NigPrefs.plist` in the package) |
| `apelin-project.json` | The build description: products, package control fields, file layout and the injection filter. The `control` file and `Nig.plist` filter are generated from it at build time |
| `assets/` | The package icon |

## License

MIT, as stated in the SPDX headers of the sources.
