# NodePin

macOS menu bar app that shows which access point (node) of a multi-AP Wi-Fi network the Mac is connected to and switches to another
node's 5 GHz radio with one click (CoreWLAN `associate(to:password:)` pins the BSSID).

## Build and run
Open `NodePin.xcodeproj` in Xcode and run, or:

    DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
      xcodebuild -project NodePin.xcodeproj -scheme NodePin -configuration Debug -derivedDataPath build build
    open build/Build/Products/Debug/NodePin.app

Requirements: App Sandbox off, Hardened Runtime on with the Location entitlement, signed with a
stable team identity (so the Location permission survives rebuilds). Allow Location access on first
launch; without it macOS hides BSSIDs. Copy the built app to /Applications and turn on
**Launch at Login** in the menu.

## Using it
- The menu bar shows the current node's name (or the last two BSSID octets if unnamed).
- Open the menu to see every node, strongest first. Click one to switch. NodePin uses the Wi-Fi password macOS already saved
  for the network (System keychain, service `AirPort`) and never stores one itself. The first switch
  shows macOS's keychain prompt: enter your Mac login password and choose **Always Allow**.
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
