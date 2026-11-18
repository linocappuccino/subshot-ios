import SwiftUI
import WebKit
import UIKit
import Combine

// 2026-11-18 (hybrid app, step 3) — one reusable screen that shows a Subshot web page inside the app
// (Postproduction first; Ideas and Deliver work the same way). Built like IdeaBoardScreen:
//  • the web session lives in the default WKWebsiteDataStore (shared with the board), so a signed-in
//    page opens straight away; a redirect to /sign-in → one-time Clerk ticket (POST /me/web-ticket) →
//    /embed/auth?ticket&uid&next=<path> (the web side allows /projects/<id>, …/postproduction, …/deliver
//    and switches on «app mode»: no website header, no desktop-only buttons)
//  • native bridges: file input (Photos / Files / camera) is WebKit's own picker; downloads (video,
//    frame, zip) → WKDownload → share sheet («Video sichern» / «Bild sichern» / Files); element
//    fullscreen for the player; links that leave Subshot open in Safari; alert / confirm / prompt as
//    native dialogs (the page asks e.g. «als neue Version hochladen?» with window.confirm)
//  • back: the page's own history first (an open video is a history step), then the screen closes
//  • the web content process dies (memory) → reload once, then a reload / close message

enum AppWeb {
    static let base = URL(string: "https://app.subshot.ch")!
    static let host = "app.subshot.ch"

    /// 2026-11-18 — feature flag: Postproduction as the web page (default) or the old native screen.
    /// Switch back with `defaults write … subshot.nativePostpro -bool YES` or the launch argument
    /// `-subshot.nativePostpro YES`.
    static let nativePostproKey = "subshot.nativePostpro"
    static var useWebPostpro: Bool { !UserDefaults.standard.bool(forKey: nativePostproKey) }

    static func postproPath(projectId: String, videoId: String? = nil) -> String {
        var p = "/projects/\(projectId)/postproduction"
        if let videoId { p += "?video=\(videoId)" }
        return p
    }
    static func ideasPath(projectId: String) -> String { "/projects/\(projectId)" }
    static func deliverPath(projectId: String) -> String { "/projects/\(projectId)/deliver" }

    /// app mode on every direct load too (the cookie usually carries it already)
    static func url(for path: String) -> URL? {
        guard var c = URLComponents(string: base.absoluteString + path) else { return nil }
        var items = c.queryItems ?? []
        if !items.contains(where: { $0.name == "app" }) { items.append(URLQueryItem(name: "app", value: "1")) }
        c.queryItems = items
        return c.url
    }

    static func isSignIn(_ url: URL) -> Bool {
        guard let host = url.host, host.hasSuffix("subshot.ch") else { return false }
        return url.path.hasPrefix("/sign-in")
    }

    /// hosts the web view may load itself (Subshot, Clerk, the R2 file storage for downloads)
    static func isInternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "blob" || scheme == "data" || scheme == "about" { return true }
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("subshot.ch") || host.hasSuffix("r2.cloudflarestorage.com") || host.hasSuffix("clerk.accounts.dev")
    }
}

@MainActor
final class AppWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    enum Phase: Equatable { case loading, ready, failed, crashed }

    @Published var phase: Phase = .loading
    @Published var canGoBack = false
    /// a finished download, shown in the share sheet
    @Published var sharedFile: URL?

    let path: String
    private var usedTicket = false
    private var crashes: [Date] = []
    private var downloadTargets: [ObjectIdentifier: URL] = [:]
    private var backObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?

    init(path: String) {
        self.path = path
        super.init()
    }

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.add(WeakScriptHandler(self), name: "subshot")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        let bg = UIColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255, alpha: 1)
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        web.accessibilityIdentifier = "appWeb.webView"
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        backObservation = web.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            let value = view.canGoBack
            Task { @MainActor in self?.canGoBack = value }
        }
        loadingObservation = web.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            let loading = view.isLoading
            Task { @MainActor in if !loading, self?.phase == .loading { self?.phase = .ready } }
        }
        return web
    }()

    func start() {
        guard webView.url == nil else { return }
        load()
    }

    func load() {
        phase = .loading
        guard let url = AppWeb.url(for: path) else { phase = .failed; return }
        webView.load(URLRequest(url: url))
    }

    func reloadAfterCrash() {
        crashes = []
        load()
    }

    /// page history first; false = nothing to go back to (the caller closes the screen)
    func goBack() -> Bool {
        guard webView.canGoBack else { return false }
        webView.goBack()
        return true
    }

    private func signInWithTicket() async {
        guard !usedTicket else { phase = .failed; return }
        usedTicket = true
        do {
            let t = try await APIClient.shared.webTicket()
            var c = URLComponents(url: AppWeb.base.appendingPathComponent("embed/auth"), resolvingAgainstBaseURL: false)
            c?.queryItems = [
                URLQueryItem(name: "ticket", value: t.ticket),
                URLQueryItem(name: "uid", value: t.clerk_user_id),
                URLQueryItem(name: "next", value: path),
            ]
            if let url = c?.url { webView.load(URLRequest(url: url)) } else { phase = .failed }
        } catch {
            phase = .failed
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "ready" { phase = .ready }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.allow) }
        // the web session is missing → ticket sign-in instead of a login form
        if AppWeb.isSignIn(target) {
            decisionHandler(.cancel)
            Task { await signInWithTicket() }
            return
        }
        // <a download>, blob: frames, zips
        if action.shouldPerformDownload {
            return decisionHandler(.download)
        }
        // links that leave Subshot (maps, inspiration sites, mail …) → Safari / the right app
        if !AppWeb.isInternal(target) {
            if let scheme = target.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
                UIApplication.shared.open(target)
            }
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // the video download is an R2 link with «Content-Disposition: attachment»
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"), disposition.lowercased().contains("attachment") {
            return decisionHandler(.download)
        }
        if !response.canShowMIMEType { return decisionHandler(.download) }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if phase == .loading { phase = .ready }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        // cancelled (our own sign-in interception) / «frame load interrupted» (a download) are fine
        if code == NSURLErrorCancelled || code == 102 { return }
        if webView.url == nil { phase = .failed }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashes.count >= 2 { phase = .crashed } else { load() }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("web-download-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "subshot-download" : suggestedFilename
        let url = dir.appendingPathComponent(name)
        downloadTargets[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        sharedFile = url
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        presentAlert(title: nil, message: error.localizedDescription, actions: [("OK", .default, {})])
    }

    // MARK: WKUIDelegate — window.open, alert / confirm / prompt

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if AppWeb.isInternal(url) { webView.load(action.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        presentAlert(title: nil, message: message, actions: [("OK", .default, { completionHandler() })], fallback: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let lang = AppLanguage.shared
        presentAlert(title: nil, message: message, actions: [
            (lang.t("pp.cancel"), .cancel, { completionHandler(false) }),
            ("OK", .default, { completionHandler(true) }),
        ], fallback: { completionHandler(false) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let top = Self.topController() else { return completionHandler(nil) }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: AppLanguage.shared.t("pp.cancel"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        top.present(alert, animated: true)
    }

    private func presentAlert(title: String?, message: String, actions: [(String, UIAlertAction.Style, () -> Void)], fallback: (() -> Void)? = nil) {
        guard let top = Self.topController() else { fallback?(); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for (label, style, run) in actions { alert.addAction(UIAlertAction(title: label, style: style) { _ in run() }) }
        top.present(alert, animated: true)
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

/// WKUserContentController keeps its handlers strongly — this breaks the cycle
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private struct AppWebViewHost: UIViewRepresentable {
    let controller: AppWebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The web page with loading / error / crash states and a native back / close control.
/// `embedded`: inside the project's own navigation (no close button, back only while the page has history).
struct AppWebScreen: View {
    @StateObject private var controller: AppWebController
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    let embedded: Bool
    var onClose: (() -> Void)? = nil

    init(path: String, embedded: Bool = false, onClose: (() -> Void)? = nil) {
        _controller = StateObject(wrappedValue: AppWebController(path: path))
        self.embedded = embedded
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255).ignoresSafeArea()
            AppWebViewHost(controller: controller)
                .ignoresSafeArea(edges: .bottom)
                .opacity(controller.phase == .failed || controller.phase == .crashed ? 0 : 1)
            switch controller.phase {
            case .loading:
                ProgressView().tint(.white)
            case .failed:
                VStack(spacing: 12) {
                    Text(language.t("appWeb.loadFailed")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(language.t("ideaBoard.reload")) { controller.reloadAfterCrash() }
                        .buttonStyle(.borderedProminent)
                    if !embedded { Button(language.t("planning.close")) { close() } }
                }
                .padding(32)
            case .crashed:
                VStack(spacing: 14) {
                    Text(language.t("ideaBoard.crashed")).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(language.t("ideaBoard.reload")) { controller.reloadAfterCrash() }
                        .buttonStyle(.borderedProminent)
                    if !embedded { Button(language.t("planning.close")) { close() } }
                }
                .padding(32)
            case .ready:
                EmptyView()
            }
        }
        .overlay(alignment: .bottomLeading) {
            // always reachable: page history back, else close (not when embedded without history)
            if controller.canGoBack || !embedded {
                Button {
                    if !controller.goBack() { close() }
                } label: {
                    Image(systemName: controller.canGoBack ? "chevron.left" : "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityIdentifier("appWeb.back")
                .accessibilityLabel(controller.canGoBack ? language.t("appWeb.back") : language.t("planning.close"))
                .padding(.leading, 14)
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: Binding(get: { controller.sharedFile != nil }, set: { if !$0 { cleanUpShared() } })) {
            if let file = controller.sharedFile {
                ActivityView(activityItems: [file])
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { controller.start() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func cleanUpShared() {
        if let file = controller.sharedFile { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        controller.sharedFile = nil
    }
}
