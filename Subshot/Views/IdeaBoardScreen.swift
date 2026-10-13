import SwiftUI
import WebKit

// 2026-10-12 — the idea board in the app (Lino chose "Web-Board eingebettet"): the real web idea
// window (board, moodboard, GIFs, scenes with Drehorte, Fassungen, feedback, live collaboration) in a
// WKWebView, full screen. Sign-in: a one-time Clerk ticket from POST /me/web-ticket, consumed by
// app.subshot.ch/embed/auth, which then opens /embed/idea/{project}/{idea}. The web view keeps its
// own session (default data store), so later opens go straight through. Replaces the old text
// editor (IdeaEditSheet), whose plain text no longer matched the board on the web.

extension APIClient {
    struct WebTicket: Decodable { let ticket: String; let clerk_user_id: String }

    func webTicket() async throws -> WebTicket {
        let req = try await authorizedRequest("me/web-ticket", method: "POST")
        return try await send(req)
    }
}

struct IdeaBoardScreen: View {
    let idea: Idea
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var url: URL?
    @State private var failed = false
    @State private var loading = true
    /// 2026-10-13, Lino: "herumgezoomed und jetzt wurde der bildschirm schwarz und ich kann nichts
    /// mehr machen" — iOS killed the web content process (memory). Reload automatically; if it keeps
    /// dying, show a native reload/close choice (the web header with ✕ is gone in that state).
    @State private var crashes: [Date] = []
    @State private var reloadToken = 0
    @State private var crashed = false

    static let webBase = URL(string: "https://app.subshot.ch")!

    var body: some View {
        ZStack {
            Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255).ignoresSafeArea()
            if let url {
                BoardWebView(url: url, loading: $loading, reloadToken: reloadToken, onCrash: handleCrash) { message in
                    switch message["type"] as? String {
                    case "close": dismiss()
                    case "deleted": dismiss()
                    case "ready": loading = false
                    default: break
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
            if crashed {
                VStack(spacing: 14) {
                    Text(language.t("ideaBoard.crashed")).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(language.t("ideaBoard.reload")) {
                        crashed = false
                        loading = true
                        reloadToken += 1
                    }
                    .buttonStyle(.borderedProminent)
                    Button(language.t("planning.close")) { dismiss() }
                }
                .padding(32)
            } else if failed {
                VStack(spacing: 12) {
                    Text(language.t("ideaBoard.loadFailed")).foregroundStyle(.secondary)
                    Button(language.t("planning.close")) { dismiss() }
                }
            } else if loading {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // always reachable, even if the page itself hangs or went blank
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 14)
            .padding(.bottom, 6)
            .opacity(loading || crashed || failed ? 1 : 0.55)
        }
        .preferredColorScheme(.dark)
        .task { await prepare() }
        // safety net: never leave the spinner over a working board
        .task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            loading = false
        }
        .onDisappear {
            // approval / scenes / title may have changed on the board
            Task { await viewModel.load(resetGeneration: false, includeSecondary: true) }
        }
    }

    private func handleCrash() {
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashes.count >= 3 {
            crashed = true
        } else {
            loading = true
            reloadToken += 1
        }
    }

    private func prepare() async {
        do {
            let t = try await APIClient.shared.webTicket()
            var c = URLComponents(url: Self.webBase.appendingPathComponent("embed/auth"), resolvingAgainstBaseURL: false)
            c?.queryItems = [
                URLQueryItem(name: "ticket", value: t.ticket),
                URLQueryItem(name: "uid", value: t.clerk_user_id),
                URLQueryItem(name: "next", value: "/embed/idea/\(viewModel.projectId)/\(idea.id)"),
            ]
            url = c?.url
        } catch {
            failed = true
        }
    }
}

/// WKWebView with a "subshot" message handler (the embed page posts {type: "close" | "updated" | …})
struct BoardWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    var reloadToken: Int = 0
    var onCrash: () -> Void = {}
    let onMessage: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "subshot")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        // the board pans/zooms itself — no rubber-banding of the page around it
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // the page itself must never move (iOS scrolled it up when a text field got focus, so the
        // idea header disappeared) — the board pans/zooms on its own
        web.scrollView.isScrollEnabled = false
        web.scrollView.delegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.load(URLRequest(url: url))
        context.coordinator.observe(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            // the session cookie survives, so the auth page goes straight on to the board
            web.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "subshot")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: BoardWebView
        var reloadToken: Int
        private var urlObservation: NSKeyValueObservation?
        init(_ parent: BoardWebView) {
            self.parent = parent
            self.reloadToken = parent.reloadToken
        }

        /// iOS killed the page (memory) — the web view is blank now
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DispatchQueue.main.async { self.parent.onCrash() }
        }

        /// the auth page redirects client-side (history.replaceState) — no didFinish for the idea URL,
        /// but webView.url changes, so watch that too
        func observe(_ web: WKWebView) {
            urlObservation = web.observe(\.url, options: [.new]) { [weak self] view, _ in
                guard view.url?.path.hasPrefix("/embed/idea") == true else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.parent.loading = false }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            DispatchQueue.main.async { self.parent.onMessage(body) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // the auth page redirects client-side; stop the spinner once the idea page is reached
            if webView.url?.path.hasPrefix("/embed/idea") == true {
                DispatchQueue.main.async { self.parent.loading = false }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset != .zero { scrollView.contentOffset = .zero }
        }

        /// no pinch-zoom of the whole page (the board has its own zoom)
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

        /// links that leave the app (Google Maps, inspiration sites, downloads …) open in Safari
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let target = action.request.url, action.navigationType == .linkActivated || action.targetFrame == nil,
               target.host != BoardWebView.host {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    static let host = "app.subshot.ch"
}
