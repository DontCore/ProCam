import SwiftUI

@main
struct ProCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        }
    }
}
