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
        // We manage cookies manually for transparency (see below); do not let
        // URLSession maintain a separate jar that Safari's JS cannot see.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
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
        if req.path == "/__log_error" {
            let msg = String(data: req.body, encoding: .utf8) ?? "(empty)"
            log("页面JS错误: \(msg)")
            return HTTPResponse(status: 200, headers: [:], body: Data())
        }
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
            "host", "content-length", "connection", "keep-alive",
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
        // The browser thinks it's on http://127.0.0.1:8080, but upstream
        // must see the real origin, otherwise Meta's API rejects the request
        // as CSRF ("we cannot send the verification code").
        let upstreamOrigin = "https://\(host)"
        if let origin = req.headers["origin"], origin.hasPrefix(Self.localBase) {
            urlReq.setValue(upstreamOrigin, forHTTPHeaderField: "Origin")
        }
        if let referer = req.headers["referer"], referer.hasPrefix(Self.localBase) {
            urlReq.setValue(rewriteToUpstream(referer), forHTTPHeaderField: "Referer")
        }
        if !req.body.isEmpty { urlReq.httpBody = req.body }
        return urlReq
    }

    /// http://127.0.0.1:8080/__r__/<host>/... -> https://<host>/...
    /// http://127.0.0.1:8080/... -> https://muse.ai/...
    private func rewriteToUpstream(_ url: String) -> String {
        let prefix = Self.localBase + "/__r__/"
        if url.hasPrefix(prefix) {
            let rest = String(url.dropFirst(prefix.count))
            if let slash = rest.firstIndex(of: "/") {
                let h = String(rest[..<slash])
                let p = String(rest[slash...])
                return "https://" + h + p
            }
            if let q = rest.firstIndex(of: "?") {
                let h = String(rest[..<q])
                let query = String(rest[q...])
                return "https://" + h + "/" + query
            }
            return "https://" + rest + "/"
        }
        if url.hasPrefix(Self.localBase) {
            return "https://muse.ai" + String(url.dropFirst(Self.localBase.count))
        }
        return url
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
                // Log auth API response bodies for diagnosis (first 500 chars).
                if path.contains("/api/auth/") || path.contains("/api/") {
                    let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
                    log("API响应 \(host)\(shortPath(path)) [\(httpResp.statusCode)]: \(bodyPreview)")
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
        var setCookies: [String] = []
        for (k, v) in response.allHeaderFields {
            guard let ks = k as? String, let vs = v as? String else { continue }
            let kl = ks.lowercased()
            if kl == "set-cookie" {
                setCookies.append(vs)
                continue
            }
            // We re-encode the body ourselves.
            if ["content-length", "transfer-encoding", "connection", "content-encoding"].contains(kl) {
                continue
            }
            headers[ks] = vs
        }
        // Rewrite Set-Cookie for localhost so Safari's JS can read cookies
        // (CSRF tokens etc.). Domain=<upstream> -> 127.0.0.1, strip Secure.
        for sc in setCookies {
            headers["Set-Cookie"] = rewriteSetCookie(sc)
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
                body = Data(injectPolyfill(rewriteHTML(html)).utf8)
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

    /// Rewrite a Set-Cookie header so Safari accepts it on http://127.0.0.1:8080:
    /// drop Domain (host-only for 127.0.0.1) and strip the Secure flag.
    private func rewriteSetCookie(_ sc: String) -> String {
        var parts = sc.components(separatedBy: ";")
        var out: [String] = []
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            let tl = t.lowercased()
            if tl.hasPrefix("domain=") { continue }
            if tl == "secure" { continue }
            out.append(t)
        }
        return out.joined(separator: "; ")
    }

    // MARK: - Polyfill injection

    /// API polyfills for iOS 16.3 (AbortSignal.any, Promise.withResolvers).
    /// Injected as an inline <script> with the page's own CSP nonce so it
    /// passes script-src. Runs before the app's scripts (placed in <head>).
    private let polyfillJS = #"""
    (function(){'use strict';var patched=[];
    if(typeof AbortSignal!=='undefined'&&typeof AbortSignal.any!=='function'){
    Object.defineProperty(AbortSignal,'any',{configurable:true,writable:true,value:function(signals){
    var list=Array.from(signals);var controller=new AbortController();var i;
    for(i=0;i<list.length;i++){if(list[i].aborted){controller.abort(list[i].reason);return controller.signal;}}
    var onAbort=function(event){if(!controller.signal.aborted){controller.abort(event.target.reason);cleanup();}};
    var cleanup=function(){for(var j=0;j<list.length;j++){list[j].removeEventListener('abort',onAbort);}};
    for(i=0;i<list.length;i++){list[i].addEventListener('abort',onAbort,{once:true});}
    return controller.signal;}});patched.push('AbortSignal.any');}
    if(typeof AbortSignal!=='undefined'&&typeof AbortSignal.timeout!=='function'){
    Object.defineProperty(AbortSignal,'timeout',{configurable:true,writable:true,value:function(ms){
    var controller=new AbortController();
    setTimeout(function(){controller.abort(new DOMException('The operation timed out','TimeoutError'));},Math.max(0,Number(ms)||0));
    return controller.signal;}});patched.push('AbortSignal.timeout');}
    if(typeof Promise.withResolvers!=='function'){
    Object.defineProperty(Promise,'withResolvers',{configurable:true,writable:true,value:function(){
    var resolve,reject;var promise=new Promise(function(res,rej){resolve=res;reject=rej;});
    return{promise:promise,resolve:resolve,reject:reject};}});patched.push('Promise.withResolvers');}
    try{document.documentElement.setAttribute('data-muse-proxy-polyfill',patched.join(','));}catch(e){}
    // HTMLMediaElement.play() may return undefined on old WebKit; ensure Promise.
    try{
    if(typeof HTMLMediaElement!=='undefined'&&HTMLMediaElement.prototype.play){
    var _origPlay=HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play=function(){
    try{var r=_origPlay.apply(this,arguments);return (r instanceof Promise)?r:Promise.resolve(r);}
    catch(e){return Promise.reject(e);}
    };patched.push('HTMLMediaElement.play');}
    }catch(e){}
    })();
    """#

    private func injectPolyfill(_ html: String) -> String {
        // Extract a CSP nonce from an existing script tag.
        guard let nRange = html.range(of: "nonce=\"") else { return html }
        let afterNonce = html[nRange.upperBound...]
        guard let endQuote = afterNonce.firstIndex(of: "\"") else { return html }
        let nonce = String(afterNonce[..<endQuote])
        guard !nonce.isEmpty, nonce.count < 128 else { return html }

        let tag = "<script nonce=\"\(nonce)\">\(polyfillJS)</script><script nonce=\"\(nonce)\">\(errorCollectorJS)</script>"
        // Insert right after <head...> so it runs before app scripts.
        if let headStart = html.range(of: "<head"),
           let headEnd = html[headStart.upperBound...].firstIndex(of: ">")
        {
            var out = html
            out.insert(contentsOf: tag, at: html.index(after: headEnd))
            log("已注入 API polyfill")
            return out
        }
        return html
    }

    /// Captures JS runtime errors and sends them to the proxy log.
    private let errorCollectorJS = #"""
    (function(){
    function send(msg){try{fetch('/__log_error',{method:'POST',headers:{'Content-Type':'text/plain'},body:String(msg).slice(0,2000),keepalive:true});}catch(e){}}
    // Diagnostic: log auth-relevant API availability.
    try{
    var info=[];
    info.push('isSecureContext='+window.isSecureContext);
    info.push('protocol='+location.protocol);
    info.push('hostname='+location.hostname);
    info.push('crypto.subtle='+!!(window.crypto&&window.crypto.subtle));
    info.push('PublicKeyCredential='+('PublicKeyCredential' in window));
    info.push('navigator.credentials='+!!(navigator.credentials));
    info.push('OTPCredential='+('OTPCredential' in window));
    info.push('AbortSignal.any='+(typeof AbortSignal.any));
    info.push('Promise.withResolvers='+(typeof Promise.withResolvers));
    send('AUTH-DIAG: '+info.join(' | '));
    }catch(e){send('AUTH-DIAG failed: '+e.message);}
    window.addEventListener('error',function(ev){
    var msg=ev.message||'';
    // Suppress the known non-fatal play().catch TypeError (media/animation shim gap).
    if(msg.indexOf("evaluating 'e.play().catch'")!==-1||msg.indexOf('e.play')!==-1&&msg.indexOf('.catch')!==-1){
    send('SUPPRESSED play().catch error');
    ev.preventDefault();return false;
    }
    send('ONERROR: '+(ev.message||'?')+' @ '+(ev.filename||'?')+':'+(ev.lineno||'?')+':'+(ev.colno||'?'));});
    window.addEventListener('unhandledrejection',function(ev){var r=ev.reason;var m=(r&&(r.stack||r.message))||String(r);send('UNHANDLED: '+m);});
    })();
    """#

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
