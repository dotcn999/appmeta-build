import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = BuildEngine.running?.busy ?? false
        BuildEngine.running?.cancel()
        guard busy else { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct AppMetaBuildApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
