import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 2026-09-20, Lino: "warum wird die ios app nicht sofort aktualisiert wenn
/// in der web app ein neues projekt angelegt wird?? das muss doch alles
/// IMMER sofort syncen!!! EGAL was angepasst oder geändert wird!!!" — iOS
/// had NO realtime client of any kind before this (web already had one,
/// lib/realtime.ts, for the public preview pages). This is a hand-rolled
/// Pusher Channels client via `URLSessionWebSocketTask` instead of pulling
/// in the official PusherSwift SPM package: there's no compiler in this
/// environment to verify a new Package.resolved/pbxproj SPM reference
/// resolves correctly (see [[feedback_ios_no_compiler]]), and the backend's
/// own Pusher usage (app/realtime.py) is deliberately as simple as it gets —
/// every channel is PUBLIC (no auth endpoint needed), sends exactly ONE
/// event ("changed") with an EMPTY payload. The whole client contract is
/// "reconnect, resubscribe to whatever's wanted, treat any 'changed' event
/// as a signal to refetch" — simple enough to implement correctly from the
/// bare protocol docs without a build to check it against.
///
/// Protocol (Pusher, version 7): connect to
/// `wss://ws-<cluster>.pusher.com/app/<key>?protocol=7&client=subshot-ios&version=1.0`.
/// Server sends `{"event":"pusher:connection_established",...}` once the
/// handshake completes — only after that does this client actually send its
/// `pusher:subscribe` frames (sending them earlier risks the write landing
/// before the WebSocket handshake itself has finished). A `pusher:ping`
/// from the server must be answered with `pusher:pong` or Pusher closes the
/// connection as dead after its activity_timeout.
@MainActor
final class RealtimeClient {
    static let shared = RealtimeClient()

    // Same public, client-exposed Pusher app key + cluster the web app uses
    // (NEXT_PUBLIC_PUSHER_KEY/_CLUSTER in subshot-web's .env.local) — safe
    // to embed here for the same reason it's safe in web's bundled JS: this
    // key can only ever SUBSCRIBE to Pusher's public, unauthenticated
    // channels, never trigger/publish anything (that needs the SECRET key,
    // which only ever lives server-side in app/realtime.py).
    private let pusherKey = "ea3e0df066aaea01f95c"
    private let cluster = "eu"

    private var task: URLSessionWebSocketTask?
    private var callbacks: [String: [UUID: () -> Void]] = [:]
    private var connected = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?

    private init() {
        #if canImport(UIKit)
        // The OS can silently drop a backgrounded socket without ever
        // firing this client's own failure handler — force a fresh
        // connection (and resubscribe to everything) every time the app
        // comes back to the foreground rather than trusting a possibly-
        // stale one. Subscribing again to a channel already subscribed is
        // harmless/idempotent on Pusher's side.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }
        #endif
    }

    /// Subscribes to `channel`'s "changed" event. Returns a token to pass
    /// to `unsubscribe(channel:token:)` (typically from a view's
    /// `.onDisappear`) — a token instead of web's closure-based unsubscribe
    /// since multiple SwiftUI views can independently subscribe to the same
    /// channel and must each be able to remove only their own callback.
    @discardableResult
    func subscribe(_ channel: String, onChanged: @escaping () -> Void) -> UUID {
        let token = UUID()
        let isNewChannel = callbacks[channel] == nil
        callbacks[channel, default: [:]][token] = onChanged
        connectIfNeeded()
        if connected && isNewChannel {
            send(event: "pusher:subscribe", data: ["channel": channel])
        }
        return token
    }

    func unsubscribe(_ channel: String, token: UUID) {
        callbacks[channel]?[token] = nil
        if callbacks[channel]?.isEmpty == true {
            callbacks[channel] = nil
            if connected {
                send(event: "pusher:unsubscribe", data: ["channel": channel])
            }
        }
    }

    private func reconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        connectIfNeeded()
    }

    private func connectIfNeeded() {
        guard task == nil else { return }
        guard let url = URL(
            string: "wss://ws-\(cluster).pusher.com/app/\(pusherKey)?protocol=7&client=subshot-ios&version=1.0"
        ) else { return }
        let newTask = URLSession.shared.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        listen(on: newTask)
    }

    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure:
                    self.handleDisconnect()
                case .success(let message):
                    self.handle(message)
                    self.listen(on: task)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String
        else { return }

        switch event {
        case "pusher:connection_established":
            connected = true
            reconnectAttempt = 0
            // Covers both the first-ever connect and any reconnect —
            // resubscribes to every channel a caller currently wants,
            // regardless of when subscribe() was originally called.
            for channel in callbacks.keys {
                send(event: "pusher:subscribe", data: ["channel": channel])
            }
        case "pusher:ping":
            send(event: "pusher:pong", data: [:])
        case "changed":
            guard let channel = json["channel"] as? String else { return }
            callbacks[channel]?.values.forEach { $0() }
        default:
            break
        }
    }

    private func send(event: String, data: [String: Any]) {
        guard let task else { return }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["event": event, "data": data]),
              let text = String(data: payload, encoding: .utf8)
        else { return }
        task.send(.string(text)) { _ in }
    }

    private func handleDisconnect() {
        connected = false
        task = nil
        reconnectAttempt += 1
        let delay = min(30, pow(2.0, Double(reconnectAttempt)))
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connectIfNeeded() }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
