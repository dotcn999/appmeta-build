import SwiftUI

@main
struct AppMetaBuildApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 760, height: 500)
        .defaultPosition(.center)
    }
}
