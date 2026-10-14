import UIKit

// The editor opens in landscape on iPhone, where a waveform needs the width; everything else follows the device.

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var allowed: UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? Self.allowed : .all
    }
}

@MainActor
enum Orientation {
    /// Landscape only (iPhone), or back to every orientation.
    static func landscape(_ on: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.allowed = on ? .landscape : .allButUpsideDown
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait)) { _ in }
        }
    }
}
