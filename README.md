# NodePin

macOS menu bar app that shows which access point (node) of a multi-AP Wi-Fi network the Mac is connected to and switches to another
node's 5 GHz radio with one click (CoreWLAN `associate(to:password:)` pins the BSSID).

## Install
Requires macOS 14 or later.
1. Download `NodePin-<version>.zip` from the [latest release](https://github.com/aarons22/node-pin/releases/latest),
   unzip it and move `NodePin.app` to **/Applications** (updates can't install anywhere else).
2. Open it. NodePin isn't notarized by Apple, so macOS blocks the first launch: open
   **System Settings → Privacy & Security**, scroll to the NodePin message and click **Open Anyway**.
   This is needed only once.
3. Allow Location access when asked. Without it macOS hides access point addresses.
4. Optionally turn on **Launch at Login** in the menu.

NodePin checks for updates once a day and offers to install them; **Check for Updates…** in the
menu checks now. Updates keep your node names and permissions.

## Build and run
Open `NodePin.xcodeproj` in Xcode and run, or:

    DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
      xcodebuild -project NodePin.xcodeproj -scheme NodePin -configuration Debug -derivedDataPath build build
    open build/Build/Products/Debug/NodePin.app

Requirements: App Sandbox off, Hardened Runtime on with the Location entitlement, signed with a
stable team identity (so the Location permission survives rebuilds). Allow Location access on first
launch; without it macOS hides BSSIDs. Debug builds don't check for updates.

## Release
    scripts/release.sh 1.2.0             # tag, build, sign, publish to GitHub Releases
    scripts/release.sh 1.2.0 --dry-run   # build the zip and appcast into build/release only

The script builds a universal Release app signed with the Apple Development certificate, zips it,
signs the zip with the Sparkle EdDSA key (login keychain, account `node-pin`) and uploads the zip and
`appcast.xml` to a new GitHub release. The app reads the appcast from the latest release. Build
numbers are the commit count on main, so release from main and never rewrite its history.

Keep these stable or existing installs break:
- **Sparkle private key.** Without it, updates can't be signed for existing installs. Back it up:
  `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account node-pin -x node-pin-sparkle.key`
  and store the file somewhere safe (not in the repo).
- **Signing certificate name.** Apps are trusted by the name "Apple Development: Aaron Sapp
  (S8JX59Y844)". A renewed certificate with the same name keeps Location and keychain grants;
  signing with anything else makes users grant them again.

## Using it
- The menu bar shows the current node's name (or the last two BSSID octets if unnamed).
- Open the menu to see every node, strongest first. Click one to switch. NodePin uses the Wi-Fi password macOS already saved
  for the network (System keychain, service `AirPort`). The first switch
  shows macOS's keychain prompt: enter your Mac login password and choose **Always Allow**.
- That prompt needs an admin account. If the System keychain can't be read (no admin rights, prompt
  cancelled, or no saved password), NodePin asks for the Wi-Fi password and keeps its own copy
  in your login keychain (service `NodePin`), which needs no admin. Later switches use that copy
  without prompting. **Settings… → General** lists saved copies and lets you forget them; forget one
  after changing the Wi-Fi password.
- Failures appear as a notification and as a line in the menu.
- **Settings…** has the band filter (5 GHz, 2.4 GHz or both), Launch at Login and node names
  (stored in UserDefaults, keyed by 5 GHz BSSID).

## Confirm the node mapping
Nodes start unnamed; name them as you identify them.
1. Open the menu and note the nodes.
2. Unplug one access point, wait about 60 s, click **Rescan**. The node that greys out is that access point.
3. Name it in **Settings… → Nodes**, plug it back in, repeat. The node that never disappears is the one wired to your router.

Repeat after replacing nodes: BSSIDs change with hardware.

## Notes
- Matching is by BSSID, never channel. The two radios of a node are paired by BSSID (same first five
  octets, last octet differs by one); the band decides which is the 5 GHz one.
- Scans are throttled to once per 10 s and run when the menu opens. No background polling and no
  automatic switching.
- macOS may still roam away after a switch; the label follows it.
- Works with any network that has several access points on one SSID (mesh or wired APs). Radio
  pairing assumes a node's 2.4 and 5 GHz BSSIDs differ by one in the last octet, as on eero; on
  other hardware the radios may show as separate nodes, but switching still works.
- Renamed from EeroPin. On first launch NodePin copies node names and settings from the old
  `com.tinyvlogllc.EeroPin` defaults. Location access, the keychain "Always Allow" and Launch at
  Login must be granted again; delete the old EeroPin.app.
