# MuseProxy — iOS 16 本地转译代理 App

在 iOS 16.3 上无法直接打开 muse.ai（它的 JS 用了 Safari 16.4+ 才支持的
`class static {}` 语法，旧版 WebKit 解析直接报错）。

这个 App 在手机本地（127.0.0.1:8080）跑一个反向代理：
把 muse.ai 的页面抓回来，用 Babel（跑在 App 内置的 JavaScriptCore 里）
把 `static {}` 转成旧语法，再喂给 Safari。Safari 看到的已经是能解析的 JS。

## 原理

- App 内置 HTTP 服务器（127.0.0.1:8080）+ 反向代理到 `https://muse.ai`
- HTML/JS/CSS 中的绝对 URL 重写回本地
- JS 中的 `class static block` 用 Babel 转译（带磁盘缓存）
- `https://auth.meta.com` 的登录流程通过 `/__r__/auth.meta.com/...` 同样代理
- 不需要装证书、不需要 Mac、不需要改系统设置

## 使用

1. 用 TrollStore 安装 `MuseProxy.ipa`（GitHub Actions 自动构建）
2. 打开 App，点「启动代理」
3. 点「打开 Muse」（或在 Safari 访问 http://127.0.0.1:8080）
4. 像正常网页一样登录使用

## 构建

推送到 `proxy-app/` 即触发 GitHub Actions（`.github/workflows/build-muse-proxy.yml`），
产物 `MuseProxy.ipa` 在 Actions 的 Artifacts 里下载（未签名，TrollStore 直装）。

## 文件

- `MuseProxy/MuseProxyApp.swift` — App 入口
- `MuseProxy/ContentView.swift` — UI（启动/停止、日志）
- `MuseProxy/LocalHTTPServer.swift` — 基于 Network.framework 的极简 HTTP/1.1 服务器
- `MuseProxy/ReverseProxy.swift` — 反向代理 + URL 重写 + 转译调度
- `MuseProxy/Transpiler.swift` — JSC 内运行 Babel
- `MuseProxy/babel.min.js` — Babel standalone（转译引擎）
