import AppKit
import Sparkle

/// Sparkle updates from the GitHub Releases appcast (SUFeedURL in Info.plist). Off in Debug builds
/// so it never tries to replace an app run from the build folder.
final class Updater {
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private let controller = SPUStandardUpdaterController(
        startingUpdater: isEnabled, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
