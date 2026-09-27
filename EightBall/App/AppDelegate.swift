import UIKit

/// UIKit entry point: one window whose root is the `GameViewController` (SceneKit view + SwiftUI overlay).
@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true

        let settings: GameSettings = GameSettings()
        let root: GameViewController = GameViewController(settings: settings)

        let win: UIWindow = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = UIColor(red: 10.0 / 255.0, green: 22.0 / 255.0, blue: 34.0 / 255.0, alpha: 1.0)
        win.rootViewController = root
        win.makeKeyAndVisible()
        self.window = win
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.landscape
    }
}
