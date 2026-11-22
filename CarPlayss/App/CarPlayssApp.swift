import SwiftUI
import UIKit

final class CarPlayssAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Gli hook vanno installati prima che qualsiasi app CarPlay venga caricata.
        CPSHooks.install()
        return true
    }

    // Lo schermo dell'auto è sempre orizzontale, anche se l'app ospite dichiara altro nel suo Info.plist.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
}

@main
struct CarPlayssApp: App {
    @UIApplicationDelegateAdaptor(CarPlayssAppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    @StateObject private var state = AppState()
    @StateObject private var media = MediaController()
    @StateObject private var nav = NavigationModel()
    @StateObject private var assistant = VoiceAssistant()
    @StateObject private var location = LocationManager()
    @StateObject private var library = AppLibrary()
    @StateObject private var runtime = GuestRuntime()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(state)
                .environmentObject(media)
                .environmentObject(nav)
                .environmentObject(assistant)
                .environmentObject(location)
                .environmentObject(library)
                .environmentObject(runtime)
                .preferredColorScheme(settings.appearance.colorScheme)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onOpenURL { url in
                    // "Apri con CarPlayss" da File/Safari su un file .ipa
                    if url.pathExtension.lowercased() == "ipa" {
                        library.importIPA(from: url)
                        state.open(.settings)
                    }
                }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    location.requestAuthorization()
                    runtime.runAppDelegate = settings.runGuestAppDelegate
                }
        }
    }
}
