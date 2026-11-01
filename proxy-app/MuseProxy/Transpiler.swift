import Foundation
import JavaScriptCore

/// Transpiles class static blocks (Safari 16.4+ syntax) down to ES2021
/// using Babel running inside JavaScriptCore. Thread-safe via serial queue.
final class Transpiler {
    private let queue = DispatchQueue(label: "com.cewnhai.museproxy.transpile")
    private var ctx: JSContext?
    private var babelReady = false

    private static let staticBlockPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\bstatic\s*\{"#)
    }()

    /// Fast pre-check: skip Babel entirely when there is no static block.
    static func needsTranspile(_ code: String) -> Bool {
        let range = NSRange(code.startIndex..., in: code)
        return staticBlockPattern.firstMatch(in: code, range: range) != nil
    }

    private func ensureContext() -> JSContext? {
        if let ctx = ctx, babelReady { return ctx }
        guard let babelURL = Bundle.main.url(forResource: "babel.min", withExtension: "js"),
              let babelSrc = try? String(contentsOf: babelURL, encoding: .utf8)
        else { return nil }
        let c = JSContext()!
        c.exceptionHandler = { _, exc in
            print("[transpile] babel load error: \(exc?.toString() ?? "unknown")")
        }
        c.evaluateScript(babelSrc)
        // Verify Babel actually loaded.
        let check = c.evaluateScript("typeof Babel !== 'undefined' && typeof Babel.transform === 'function'")
        guard check?.toBool() == true else { return nil }
        ctx = c
        babelReady = true
        return c
    }

    /// Returns transpiled code, or nil on any failure (caller serves original).
    func transpile(_ code: String) -> String? {
        queue.sync {
            guard let c = ensureContext() else { return nil }
            c.setObject(code, forKeyedSubscript: "___museSrc" as NSString)
            let result = c.evaluateScript(
                "(function(){try{return Babel.transform(___museSrc,"
                    + "{plugins:['transform-class-static-block'],configFile:false,babelrc:false}).code;"
                    + "}catch(e){return null;}})()"
            )
            guard let result = result, !result.isNull, !result.isUndefined else { return nil }
            return result.toString()
        }
    }
}
