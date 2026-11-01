import Foundation

/// Intercepts https requests to muse.ai (and auth.meta.com), transpiles
/// class-static-block JS via Babel-in-JSC, and injects API polyfills into HTML.
/// The page keeps its real https://muse.ai origin, so auth checks pass.
final class MuseURLProtocol: URLProtocol {

    private static let handledKey = "MuseURLProtocolHandled"
    private var dataTask: URLSessionDataTask?

    // MARK: - Registration (private API to make it work with WKWebView)

    static func register() {
        URLProtocol.registerClass(MuseURLProtocol.self)
        // Private: WKBrowsingContextController.registerSchemeForCustomProtocol:
        // Makes WKWebView route https through our URLProtocol.
        if let cls = NSClassFromString("WKBrowsingContextController") as? NSObject.Type {
            let sel = NSSelectorFromString("registerSchemeForCustomProtocol:")
            if cls.responds(to: sel) {
                cls.perform(sel, with: "https")
                cls.perform(sel, with: "http")
                NSLog("[MuseBrowser] registered custom protocol for https/http")
            } else {
                NSLog("[MuseBrowser] WKBrowsingContextController does not respond to registerSchemeForCustomProtocol:")
            }
        } else {
            NSLog("[MuseBrowser] WKBrowsingContextController not found")
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else { return false }
        // Avoid loops.
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        // NEVER intercept API calls: let them go through WKWebView's native
        // network stack so TLS/HTTP fingerprints stay Safari-original.
        // (Intercepting APIs via URLSession gets flagged by Meta's bot detection.)
        if path.hasPrefix("/api/") { return false }
        // Only intercept page HTML and JS from muse.ai / meta / fbcdn.
        if host.hasSuffix("muse.ai") || host.hasSuffix("meta.com") || host.hasSuffix("fbcdn.net") {
            return true
        }
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        // Pass through the WebView's real User-Agent (do not spoof).
        // A spoofed UA mismatches the device fingerprint and gets blocked.

        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config)
        dataTask = session.dataTask(with: mutable as URLRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let httpResp = response as? HTTPURLResponse, let data = data else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            let contentType = (httpResp.allHeaderFields["Content-Type"] as? String ?? "").lowercased()
            let path = url.path.lowercased()
            var outData = data
            var outHeaders = httpResp.allHeaderFields as? [String: String] ?? [:]

            if contentType.contains("text/html") || path.hasSuffix(".html") || path == "/" || path.isEmpty {
                // HTML: no longer inject polyfill here (now via WKUserScript).
                // Just strip upgrade-insecure-requests from CSP.
                if var csp = outHeaders["Content-Security-Policy"] {
                    csp = csp.replacingOccurrences(of: "upgrade-insecure-requests; ", with: "")
                    csp = csp.replacingOccurrences(of: "upgrade-insecure-requests", with: "")
                    outHeaders["Content-Security-Policy"] = csp
                }
                NSLog("[MuseBrowser] HTML passthrough: \(url.absoluteString.prefix(80))")
            } else if contentType.contains("javascript") || path.hasSuffix(".js") {
                if JSTranspile.shouldTranspile(data) {
                    if let out = JSTranspile.transpile(data) {
                        outData = out
                        outHeaders.removeValue(forKey: "Content-Length")
                        NSLog("[MuseBrowser] JS transpiled: \(url.lastPathComponent)")
                    } else {
                        NSLog("[MuseBrowser] JS transpile FAILED, serving original: \(url.lastPathComponent)")
                    }
                }
            }

            let resp = HTTPURLResponse(url: url, statusCode: httpResp.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: outHeaders)!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: outData)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }
}

// MARK: - Helpers (transpile check + HTML patch), shared logic with the proxy app.

enum JSTranspile {
    private static let transpiler = Transpiler()

    /// Cheap pre-check for class static blocks.
    static func shouldTranspile(_ data: Data) -> Bool {
        guard data.count < 8_000_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return Transpiler.needsTranspile(text)
    }

    static func transpile(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let out = transpiler.transpile(text) else { return nil }
        return out.data(using: .utf8)
    }
}

enum HTMLPatcher {
    /// The same minimal polyfill set the proxy app injects.
    static let polyfillJS = """
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
    try{if(typeof window.OTPCredential==='undefined'){window.OTPCredential=function(){};patched.push('OTPCredential');}}catch(e){}
    try{
    if(typeof Array.prototype.toSorted!=='function'){
    Array.prototype.toSorted=function(c){return Array.prototype.slice.call(this).sort(c);};patched.push('Array.toSorted');}
    if(typeof Array.prototype.toReversed!=='function'){
    Array.prototype.toReversed=function(){return Array.prototype.slice.call(this).reverse();};patched.push('Array.toReversed');}
    if(typeof Array.prototype.toSpliced!=='function'){
    Array.prototype.toSpliced=function(s,dc){var a=Array.prototype.slice.call(this);var args=Array.prototype.slice.call(arguments,2);a.splice.apply(a,[s,dc].concat(args));return a;};patched.push('Array.toSpliced');}
    if(typeof Array.prototype.with!=='function'){
    Array.prototype.with=function(i,v){var a=Array.prototype.slice.call(this);a[i]=v;return a;};patched.push('Array.with');}
    if(typeof Array.prototype.findLast!=='function'){
    Array.prototype.findLast=function(fn){for(var i=this.length-1;i>=0;i--){if(fn(this[i],i,this))return this[i];}return undefined;};patched.push('Array.findLast');}
    if(typeof Array.prototype.findLastIndex!=='function'){
    Array.prototype.findLastIndex=function(fn){for(var i=this.length-1;i>=0;i--){if(fn(this[i],i,this))return i;}return -1;};patched.push('Array.findLastIndex');}
    }catch(e){}
    try{document.documentElement.setAttribute('data-muse-browser-polyfill',patched.join(','));}catch(e){}
    })();
    """

    static func injectPolyfill(_ html: String) -> String {
        guard let nRange = html.range(of: "nonce=\"") else { return html }
        let afterNonce = html[nRange.upperBound...]
        guard let endQuote = afterNonce.firstIndex(of: "\"") else { return html }
        let nonce = String(afterNonce[..<endQuote])
        guard !nonce.isEmpty, nonce.count < 128 else { return html }
        let tag = "<script nonce=\"\(nonce)\">\(polyfillJS)</script><script nonce=\"\(nonce)\">\(diagJS)</script>"
        if let headRange = html.range(of: "<head>") {
            var out = html
            out.insert(contentsOf: tag, at: headRange.upperBound)
            return out
        }
        return html
    }

    /// Diagnostic: log API availability and catch JS errors.
    static let diagJS = """
    (function(){
    function send(m){try{console.log('[MuseBrowser-DIAG] '+m);}catch(e){}}
    try{
    var info=[];
    info.push('crypto.subtle='+!!(window.crypto&&window.crypto.subtle));
    info.push('PublicKeyCredential='+('PublicKeyCredential' in window));
    info.push('AbortSignal.any='+(typeof AbortSignal.any));
    info.push('Promise.withResolvers='+(typeof Promise.withResolvers));
    info.push('OTPCredential='+('OTPCredential' in window));
    send('AUTH-DIAG: '+info.join(' | '));
    }catch(e){send('DIAG failed: '+e.message);}
    window.addEventListener('error',function(ev){send('ONERROR: '+(ev.message||'?')+' @ '+(ev.filename||'?')+':'+(ev.lineno||'?'));});
    window.addEventListener('unhandledrejection',function(ev){var r=ev.reason;send('UNHANDLED: '+((r&&(r.stack||r.message))||String(r)));});
    })();
    """
}
