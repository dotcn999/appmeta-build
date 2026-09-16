import SwiftUI

@main
struct AppMetaBuildApp: App {
    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appearance)
                .preferredColorScheme(appearance.preferredScheme)
                .tint(Color(red: 0.09, green: 0.41, blue: 0.88))
                .frame(minWidth: 720, minHeight: 440)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 880, height: 540)
        .defaultPosition(.center)
    }
}
