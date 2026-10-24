import Foundation
import Sparkle

@MainActor
final class CampUpdater {
    static let shared = CampUpdater()

    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else {
            controller = nil
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.automaticallyChecksForUpdates = true
        DispatchQueue.main.async {
            updaterController.updater.checkForUpdatesInBackground()
        }
        controller = updaterController
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
