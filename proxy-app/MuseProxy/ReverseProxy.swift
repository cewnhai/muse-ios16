import Foundation

/// Reverse proxy: localhost -> https://muse.ai (default) or
/// /__r__/<host>/... -> https://<host>/...  (for auth.meta.com etc.)
/// Rewrites absolute URLs back to localhost and transpiles class static
/// blocks in JavaScript so iOS 16.3 WebKit can parse it.
final class ReverseProxy {
    static let localPort: UInt16 = 8080
    static var localBase: String { "http://127.0.0.1:\(localPort)" }

    private let server: LocalHTTPServer
    private let transpiler = Transpiler()
    private let session: URLSession
    private let diskCache: URL

    var logHandler: (String) -> Void = { print($0) }
    private func log(_ msg: String) { logHandler(msg) }

    init() {
        server = LocalHTTPServer(port: Self.localPort)
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCache = caches.appendingPathComponent("muse-js-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCache, withIntermediateDirectories: true)
    }

    func start() throws {
        server.handler = { [weak self] req in
            guard let self = self else {
                return HTTPResponse(status: 500, headers: [:], body: Data())
            }
            return await self.handle(req)
        }
        try server.start()
        log("代理已启动 \(Self.localBase)")
    }

    func stop() {
        server.stop()
        log("代理已停止")
    }

    // MARK: - Routing

    private func route(_ path: String) -> (host: String, path: String) {
        if path.hasPrefix("/__r__/") {
            let rest = String(path.dropFirst("/__r__/".count))
            if let slash = rest.firstIndex(of: "/") {
                return (String(rest[..<slash]), String(rest[slash...]))
            } else {
                // "/__r__/example.com" -> host only
                let host = rest.split(separator: "?").first.map(String.init) ?? rest
                var query = ""
                if rest.contains("?"), let q = rest.split(separator: "?", maxSplits: 1).last {
                    query = "?" + String(q)
                }
                return (host, "/" + query)
            }
        }
        return ("muse.ai", path)
    }

    // MARK: - Request handling

    private func handle(_ req: HTTPRequest) async -> HTTPResponse {
        if req.path == "/" || req.path.hasPrefix("/?") {
            // Top-level entry always serves the muse.ai homepage.
            return await fetchUpstream(host: "muse.ai", path: "/", req: req)
        }
        let (host, upPath) = route(req.path)
        return await fetchUpstream(host: host, path: upPath, req: req)
    }

    private func buildUpstreamRequest(host: String, path: String, req: HTTPRequest) -> URLRequest? {
        guard let url = URL(string: "https://\(host)\(path)") else { return nil }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = req.method
        let skip: Set<String> = [
            "host", "cookie", "content-length", "connection", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "te", "trailer",
            "transfer-encoding", "upgrade",
            // Let URLSession manage compression itself; forwarding Safari's
            // Accept-Encoding would leave us with compressed bytes but no
            // content-encoding header to tell Safari.
            "accept-encoding",
        ]
        for (k, v) in req.headers where !skip.contains(k) {
            urlReq.setValue(v, forHTTPHeaderField: k)
        }
        if !req.body.isEmpty { urlReq.httpBody = req.body }
        return urlReq
    }

    private func isTransient(_ error: Error) -> Bool {
        let nsErr = error as NSError
        guard nsErr.domain == NSURLErrorDomain else { return false }
        // -1005 connection lost, -1001 timeout, -1003 DNS, -1004 connect failed,
        // -1009 no internet, -1200 SSL error (retry may pick a fresh connection)
        return [-1005, -1001, -1003, -1004, -1009, -1200].contains(nsErr.code)
    }

    private func fetchUpstream(host: String, path: String, req: HTTPRequest) async -> HTTPResponse {
        var lastError: Error?
        for attempt in 0..<3 {
            guard let urlReq = buildUpstreamRequest(host: host, path: path, req: req) else {
                return HTTPResponse(status: 400, headers: [:], body: Data())
            }
            do {
                let (data, resp) = try await session.data(for: urlReq)
                guard let httpResp = resp as? HTTPURLResponse else {
                    return HTTPResponse(status: 502, headers: [:], body: Data())
                }
                if attempt > 0 {
                    log("上游重试成功 \(host)\(shortPath(path))")
                }
                return processResponse(data: data, response: httpResp, localPath: req.path, host: host)
            } catch {
                lastError = error
                if isTransient(error), attempt < 2 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                break
            }
        }
        let nsErr = lastError as NSError?
        log("上游错误 \(req.method) \(host)\(shortPath(path)): [\(nsErr?.domain ?? "?"):\(nsErr?.code ?? 0)] \(lastError?.localizedDescription ?? "?")")
        return HTTPResponse(
            status: 502,
            headers: ["content-type": "text/plain; charset=utf-8"],
            body: Data("proxy error".utf8)
        )
    }

    // MARK: - Response processing

    private func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, ks.lowercased() == name, let vs = v as? String {
                return vs
            }
        }
        return nil
    }

    private func processResponse(data: Data, response: HTTPURLResponse, localPath: String, host: String) -> HTTPResponse {
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            guard let ks = k as? String, let vs = v as? String else { continue }
            let kl = ks.lowercased()
            // We re-encode the body ourselves; cookies stay in the app's jar.
            if ["content-length", "transfer-encoding", "connection", "content-encoding", "set-cookie"].contains(kl) {
                continue
            }
            headers[ks] = vs
        }
        if let locKey = headers.keys.first(where: { $0.lowercased() == "location" }),
           let loc = headers[locKey]
        {
            headers[locKey] = rewriteURL(loc)
        }
        if let cspKey = headers.keys.first(where: { $0.lowercased() == "content-security-policy" }),
           var csp = headers[cspKey]
        {
            // localhost must stay http; strip forced https upgrade.
            csp = csp.replacingOccurrences(of: "upgrade-insecure-requests", with: "")
            headers[cspKey] = csp
        }

        let ct = header(response, "content-type")?.lowercased() ?? ""
        var body = data
        if ct.contains("text/html") {
            if let html = String(data: data, encoding: .utf8) {
                body = Data(rewriteHTML(html).utf8)
            }
        } else if ct.contains("javascript") || ct.contains("ecmascript")
            || localPath.hasSuffix(".js") || localPath.contains(".js?")
        {
            if var js = String(data: data, encoding: .utf8) {
                js = rewriteJS(js)
                if Transpiler.needsTranspile(js) {
                    if let cached = cachedTranspile(localPath) {
                        js = cached
                        log("转译缓存命中 \(shortPath(localPath))")
                    } else if let out = transpiler.transpile(js) {
                        js = out
                        storeTranspile(localPath, out)
                        log("转译完成 \(shortPath(localPath))")
                    } else {
                        log("转译失败，走原文 \(shortPath(localPath))")
                    }
                }
                body = Data(js.utf8)
            }
        } else if ct.contains("text/css") {
            if let css = String(data: data, encoding: .utf8) {
                body = Data(rewriteCSS(css).utf8)
            }
        }

        if let origCT = header(response, "content-type") {
            headers["content-type"] = origCT
        }
        return HTTPResponse(status: response.statusCode, headers: headers, body: body)
    }

    private func shortPath(_ p: String) -> String {
        if p.count > 60 { return "..." + p.suffix(57) }
        return p
    }

    // MARK: - URL rewriting

    /// Absolute upstream URLs -> localhost equivalents.
    func rewriteURL(_ url: String) -> String {
        var u = url
        u = u.replacingOccurrences(of: "https://muse.ai", with: Self.localBase)
        u = u.replacingOccurrences(of: "https://auth.meta.com", with: Self.localBase + "/__r__/auth.meta.com")
        return u
    }

    private func rewriteHTML(_ html: String) -> String { rewriteURL(html) }
    private func rewriteJS(_ js: String) -> String { rewriteURL(js) }
    private func rewriteCSS(_ css: String) -> String { rewriteURL(css) }

    // MARK: - Transpile disk cache

    private func cacheKey(_ path: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(format: "%016llx", h)
    }

    private func cachedTranspile(_ path: String) -> String? {
        let f = diskCache.appendingPathComponent(cacheKey(path) + ".js")
        return try? String(contentsOf: f, encoding: .utf8)
    }

    private func storeTranspile(_ path: String, _ code: String) {
        let f = diskCache.appendingPathComponent(cacheKey(path) + ".js")
        try? code.write(to: f, atomically: true, encoding: .utf8)
    }
}
