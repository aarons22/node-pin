# AGENTS.md

Orientation for AI agents working on NodePin. Read this before scanning the repo. Everything you
need for most tasks is here. User-facing docs are in [README.md](README.md).

## What it is
NodePin is a macOS 14+ menu bar app (SwiftUI, `MenuBarExtra` in `.window` style) for networks with
several access points on one SSID, such as eero mesh. It shows which access point (node) the Mac is
on and switches to another node's radio with one click by pinning the BSSID through CoreWLAN.
There are no tests, no other targets, and the only dependency is Sparkle (SPM) for updates.

## Layout
All source is in `NodePin/` (an Xcode file-system-synchronized group, so new `.swift` files are
picked up without editing `project.pbxproj`).

| File | Role |
|---|---|
| `NodePinApp.swift` | `@main`. Builds `LocationGate`, `NodeStore` and `WiFiService`, and declares the menu bar extra and the Settings `Window` (id `"settings"`). |
| `WiFiService.swift` | Core logic: current connection, throttled scans, menu bar name flash on node change, `switchTo(_:)`, BSSID-pinned association, landing confirmation, failure notices and notifications. |
| `NodeModel.swift` | Pure value types and logic: `ScannedRadio`, `PhysicalNode`, `RadioRow`, `BandFilter`, `BSSID` (normalize/pairing/labels) and `NodeGrouping` (radios → nodes → rows). |
| `NodeStore.swift` | UserDefaults: node names keyed by 5 GHz BSSID, band filter, menu bar name visibility, one-time migration from the old EeroPin defaults. |
| `SystemWiFiPassword.swift` | `SystemWiFiPassword` reads macOS's saved password (System keychain, service `AirPort`). `FallbackWiFiPassword` stores a user-entered copy in the login keychain (service `NodePin`) when the System keychain can't be read, for example without admin rights. |
| `MenuContent.swift` | Menu bar label and panel UI, `MenuRow`, `PanelVisibility` (open/close tracking via key-window notifications), `LoginItem`. |
| `SettingsView.swift` | General tab (band filter, menu bar name toggle, launch at login, diagnostics log, saved Wi-Fi passwords). |
| `NodeNamingView.swift` | Nodes tab: name each node. |
| `LocationGate.swift` | Location authorization. Without it macOS hides BSSIDs. |
| `DebugLog.swift` | Opt-in file log (Settings → Diagnostics). Never log passwords. |
| `Updater.swift` | Sparkle wrapper, disabled in Debug builds. |

Other files: `Info.plist` (Sparkle feed URL and public EdDSA key), `NodePin.entitlements` (Location
only), `NodePin/AppIcon.icon` (Icon Composer icon), `scripts/release.sh`.

## Build
```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer xcodebuild -project NodePin.xcodeproj -scheme NodePin -configuration Debug -derivedDataPath build build
```
Run it with `open build/Build/Products/Debug/NodePin.app`. Check for success with
`| grep -E "error|BUILD"`. There is no test suite, so building is the main automated check. Switching
behavior can only be verified on real hardware with several access points.

## Conventions
- **Swift 5 mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.** Everything is main-actor by default.
  Mark pure or background types `nonisolated` (see `NodeModel.swift`, `SystemWiFiPassword`). Blocking
  CoreWLAN and keychain calls run in `Task.detached`.
- State uses `@Observable` classes. Use `@ObservationIgnored` for internal caches.
- Code is compact: short doc comments that explain *why*, no boilerplate, and few files. Match
  this style.
- User-facing failures go through `WiFiService.fail(_:)`, which shows a menu notice, sends a notification
  and writes to the debug log.

## Things that must not change casually
- **Matching is by BSSID, never by channel.** A node's two radios are paired when the first five
  octets match and the last differs by one (`BSSID.arePaired`). The band decides which is the 5 GHz
  radio, and node names are keyed by the 5 GHz BSSID.
- **Association** uses the private `associateToNetwork:password:forceBSSID:remember:error:` through the
  ObjC runtime, because the public `associate(to:password:)` ignores the chosen BSSID. It falls back to
  the public call if the selector is missing. `defaults write com.tinyvlogllc.NodePin usePublicAssociate -bool YES`
  forces the public path for A/B testing.
- A password is always required: passwordless joins fail with tmpErr -3900. The lookup order is the
  `FallbackWiFiPassword` copy, then the System keychain, then an NSAlert that asks the user and saves
  the answer as a fallback copy.
- Scans are throttled to once per 10 s (scans interrupt traffic) and run only while the menu is open
  or during a switch. There is no background polling and no automatic switching.
- **Signing:** App Sandbox off, Hardened Runtime on, signed as "Apple Development: Aaron Sapp
  (S8JX59Y844)" (team `CAZ63TUDYL`). Changing the identity resets users' Location and keychain grants.
- **Bundle ID** `com.tinyvlogllc.NodePin`. Renamed from EeroPin. The migration code in
  `NodeStore` and `SystemWiFiPassword.deleteLegacyCopy()` handles old installs.
- **Sparkle:** never change `SUPublicEDKey` or rewrite `main` history. Build numbers are
  `git rev-list --count HEAD` and must only increase.

## Releasing
`scripts/release.sh <version>` must run on a clean `main` that is pushed to origin. It tags, builds a
universal Release app, signs the zip with the Sparkle key (login keychain, account `node-pin`) and
publishes the zip and `appcast.xml` to GitHub Releases (`aarons22/node-pin`). `--dry-run` builds
into `build/release` only. Only release when the user asks.

## Keep this file current
When you add a file, change a convention or change one of the invariants above, update this file in
the same change.
