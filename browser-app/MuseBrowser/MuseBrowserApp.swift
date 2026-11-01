import SwiftUI

@main
struct MuseBrowserApp: App {
    init() {
        // v8: URLProtocol re-enabled, but /api/* NO LONGER bypasses.
        // All requests go through URLSession so cookies stay in one jar.
        MuseURLProtocol.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
