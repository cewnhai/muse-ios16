import SwiftUI

final class AppState: ObservableObject {
    @Published var isRunning = false
    @Published var logs: [String] = []
    private let proxy = ReverseProxy()
    private var counter = 0

    init() {
        proxy.logHandler = { [weak self] msg in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.counter += 1
                self.logs.append("[\(self.counter)] \(msg)")
                if self.logs.count > 300 {
                    self.logs.removeFirst(100)
                }
            }
        }
    }

    func toggle() {
        if isRunning {
            proxy.stop()
            isRunning = false
        } else {
            do {
                try proxy.start()
                isRunning = true
            } catch {
                logs.append("启动失败: \(error.localizedDescription)")
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var state = AppState()
    private let localURL = "http://127.0.0.1:8080"

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                Text("本机转译代理")
                    .font(.title2).bold()

                Text("把 muse.ai 的新语法 JS 转成 iOS 16.3 能解析的版本")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: { state.toggle() }) {
                    Text(state.isRunning ? "停止代理" : "启动代理")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                if state.isRunning {
                    VStack(spacing: 8) {
                        Text("在 Safari 中打开：")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Text(localURL)
                            .font(.headline)
                            .textSelection(.enabled)
                        Button("打开 Muse") {
                            if let url = URL(string: localURL) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                List(state.logs.indices.reversed(), id: \.self) { i in
                    Text(state.logs[i])
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .listStyle(.plain)
            }
            .navigationTitle("Muse 代理")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}
