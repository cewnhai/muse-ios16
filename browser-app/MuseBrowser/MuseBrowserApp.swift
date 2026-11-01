import SwiftUI

@main
struct MuseBrowserApp: App {
    init() {
        // Register our URLProtocol for https (via private API, TrollStore OK).
        MuseURLProtocol.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
