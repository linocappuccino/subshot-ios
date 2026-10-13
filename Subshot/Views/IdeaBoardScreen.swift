import SwiftUI
import WebKit

// 2026-10-12 — the idea board in the app (Lino chose "Web-Board eingebettet"): the real web idea
// window (board, moodboard, GIFs, scenes with Drehorte, Fassungen, feedback, live collaboration) in a
// WKWebView, full screen. Replaces the old text editor (IdeaEditSheet), whose plain text no longer
// matched the board on the web.
//
// 2026-10-13, Lino: "ist es möglich, dass die app das board schneller lädt?" — one web view for the
// whole app (BoardWebPool), warmed up in the background (app.subshot.ch/embed/warm: Clerk + the idea
// window's code) while the ideas grid is visible; opening a board then only loads its data. Signed in
// already → straight to /embed/idea/{project}/{idea}; only when the web session is missing does the
// app fetch a one-time Clerk ticket (POST /me/web-ticket) and go through /embed/auth. After closing,
// the view goes back to the tiny warm page so the board's memory is freed.
//
// 2026-10-13, Lino: "herumgezoomed und jetzt wurde der bildschirm schwarz" — iOS killed the web
// content process (memory): reload automatically, after repeated crashes offer reload/close; a
// native ✕ is always reachable.

extension APIClient {
    struct WebTicket: Decodable { let ticket: String; let clerk_user_id: String }

    func webTicket() async throws -> WebTicket {
        let req = try await authorizedRequest("me/web-ticket", method: "POST")
        return try await send(req)
    }
}

/// the app's single board web view (warm, reused)
@MainActor
final class BoardWebPool: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate {
    static let shared = BoardWebPool()
    static let base = URL(string: "https://app.subshot.ch")!
    static let host = "app.subshot.ch"
    private static let warmURL = base.appendingPathComponent("embed/warm")

    /// nil = not known yet
    private(set) var signedIn: Bool?
    private var inUse = false

    // the board screen currently using the view
    var onMessage: (([String: Any]) -> Void)?
    var onCrash: (() -> Void)?
    var onIdeaReached: (() -> Void)?
    var onNeedsSignIn: (() -> Void)?

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "subshot")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        // the page itself must never move (iOS scrolled it up when a text field got focus, so the
        // idea header disappeared) — the board pans/zooms on its own
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        web.scrollView.delegate = self
        web.allowsBackForwardNavigationGestures = false
        urlObservation = web.observe(\.url, options: [.new]) { [weak self] view, _ in
            let path = view.url?.path ?? ""
            Task { @MainActor in self?.urlChanged(path) }
        }
        return web
    }()
    private var urlObservation: NSKeyValueObservation?

    /// load the warm page in the background (no-op while a board is open or already warm)
    func prewarm() {
        guard !inUse else { return }
        if webView.url?.path.hasPrefix("/embed/warm") == true { return }
        webView.load(URLRequest(url: Self.warmURL))
    }

    func open(_ url: URL) {
        inUse = true
        webView.load(URLRequest(url: url))
    }

    /// the board was closed — free its memory, stay warm
    func release() {
        inUse = false
        onMessage = nil; onCrash = nil; onIdeaReached = nil; onNeedsSignIn = nil
        webView.load(URLRequest(url: Self.warmURL))
    }

    private func urlChanged(_ path: String) {
        if path.hasPrefix("/embed/idea") {
            signedIn = true
            // the auth page redirects client-side, so no didFinish for this URL — give it a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.onIdeaReached?() }
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "warm" { signedIn = body["signedIn"] as? Bool }
        onMessage?(body)
    }

    // MARK: WKNavigationDelegate

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if inUse { onCrash?() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.path.hasPrefix("/embed/idea") == true { onIdeaReached?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.allow) }
        // the board needs a web session → let the screen fetch a ticket instead of showing a login form
        if target.host == Self.host, target.path.hasPrefix("/sign-in") {
            signedIn = false
            if inUse { onNeedsSignIn?() }
            return decisionHandler(.cancel)
        }
        // links that leave the app (Google Maps, inspiration sites, downloads …) open in Safari
        if action.navigationType == .linkActivated || action.targetFrame == nil, target.host != Self.host {
            UIApplication.shared.open(target)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentOffset != .zero { scrollView.contentOffset = .zero }
    }

    /// no pinch-zoom of the whole page (the board has its own zoom)
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }
}

/// hosts the pooled web view
private struct PooledBoardWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .clear
        let web = BoardWebPool.shared.webView
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct IdeaBoardScreen: View {
    let idea: Idea
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var failed = false
    @State private var loading = true
    @State private var crashes: [Date] = []
    @State private var crashed = false
    @State private var usedTicket = false

    private var ideaPath: String { "/embed/idea/\(viewModel.projectId)/\(idea.id)" }

    var body: some View {
        ZStack {
            Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255).ignoresSafeArea()
            PooledBoardWebView()
                .ignoresSafeArea(edges: .bottom)
                .opacity(crashed || failed ? 0 : 1)
            if crashed {
                VStack(spacing: 14) {
                    Text(language.t("ideaBoard.crashed")).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(language.t("ideaBoard.reload")) {
                        crashed = false
                        loading = true
                        openBoard()
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
        .onAppear { start() }
        // safety net: never leave the spinner over a working board
        .task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            loading = false
        }
        .onDisappear {
            BoardWebPool.shared.release()
            // approval / scenes / title may have changed on the board
            Task { await viewModel.load(resetGeneration: false, includeSecondary: true) }
        }
    }

    private func start() {
        let pool = BoardWebPool.shared
        pool.onMessage = { message in
            switch message["type"] as? String {
            case "close", "deleted": dismiss()
            case "ready": loading = false
            default: break
            }
        }
        pool.onIdeaReached = { loading = false }
        pool.onCrash = { handleCrash() }
        pool.onNeedsSignIn = { Task { await signInWithTicket() } }
        if pool.signedIn == false {
            Task { await signInWithTicket() }
        } else {
            openBoard()
        }
    }

    /// straight to the board (the web session is there, or we find out via a /sign-in redirect)
    private func openBoard() {
        BoardWebPool.shared.open(BoardWebPool.base.appendingPathComponent(String(ideaPath.dropFirst())))
    }

    private func signInWithTicket() async {
        guard !usedTicket else { failed = true; return }
        usedTicket = true
        do {
            let t = try await APIClient.shared.webTicket()
            var c = URLComponents(url: BoardWebPool.base.appendingPathComponent("embed/auth"), resolvingAgainstBaseURL: false)
            c?.queryItems = [
                URLQueryItem(name: "ticket", value: t.ticket),
                URLQueryItem(name: "uid", value: t.clerk_user_id),
                URLQueryItem(name: "next", value: ideaPath),
            ]
            if let url = c?.url { BoardWebPool.shared.open(url) } else { failed = true }
        } catch {
            failed = true
        }
    }

    private func handleCrash() {
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashes.count >= 3 {
            crashed = true
        } else {
            loading = true
            openBoard()
        }
    }
}
