import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            // URL bar + controls
            HStack(spacing: 8) {
                Button(action: { model.webView?.goBack() }) {
                    Image(systemName: "chevron.left")
                }.disabled(!(model.canGoBack))

                Button(action: { model.webView?.goForward() }) {
                    Image(systemName: "chevron.right")
                }.disabled(!(model.canGoForward))

                TextField("URL", text: $model.addressBar, onCommit: {
                    model.navigate(to: model.addressBar)
                })
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)

                if model.isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button(action: { model.webView?.reload() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .padding(8)

            // Web view
            BrowserWebView(model: model)
                .edgesIgnoringSafeArea(.bottom)

            // Transpile stats
            if model.transpiledCount > 0 {
                Text("已转译 \(model.transpiledCount) 个 JS 文件")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(4)
            }
        }
        .onAppear {
            if model.addressBar.isEmpty {
                model.navigate(to: "https://muse.ai")
            }
        }
    }
}

final class BrowserModel: ObservableObject {
    @Published var addressBar: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var transpiledCount = 0
    weak var webView: WKWebView?

    func navigate(to text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t) else { return }
        addressBar = t
        webView?.load(URLRequest(url: url))
    }
}

struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        // Spoof iOS 17 UA so server-side version checks pass.
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        model.webView = view
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.isLoading = true
            if let url = webView.url?.absoluteString, !url.isEmpty {
                model.addressBar = url
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.isLoading = false
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
            // Count transpiled files via the marker attribute.
            webView.evaluateJavaScript("document.documentElement.getAttribute('data-muse-browser-polyfill')") { result, _ in
                if let s = result as? String, !s.isEmpty {
                    // polyfill ran; count is tracked in protocol logs
                }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
        }
    }
}
