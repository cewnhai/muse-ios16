import SwiftUI

@main
struct MuseBrowserApp: App {
    init() {
        // v7-minimal: URLProtocol disabled for testing. Pure WKWebView.
        // MuseURLProtocol.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
