import UIKit
import BackgroundTasks

// Best effort only. iOS chooses if/when the app may run, and sideloading
// containers can decline background scheduling altogether. Foreground sync
// remains the reliable path.
final class SitoBackgroundDelegate: NSObject, UIApplicationDelegate {
    private let taskID = "com.seraphi.sito.vaultrefresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.perform(refresh)
        }
        scheduleNext()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleNext()
    }

    private func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func perform(_ task: BGAppRefreshTask) {
        scheduleNext()
        let job = Task { @MainActor in
            // Give the reachability monitor time to obtain the initial path.
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { task.setTaskCompleted(success: false); return }
            let vault = CloudVault()
            let feed = NewsFeed()
            // iOS may expire BGAppRefresh quickly; only attempt two articles
            // on a permitted Wi-Fi/power path before the ordinary cloud sync.
            await feed.autoCompleteMissingText(wifiAvailable: vault.wifiAvailable, limit: 2)
            await vault.automaticBackupIfDue(feed: feed)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { job.cancel() }
    }
}
