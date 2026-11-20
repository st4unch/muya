// The one place the SSH page touches the app's Store: its rpc over muyad, and the Connect hand-off.

import AppKit

/// Adapter: the SSH page's rpc over the app's Store (replies already arrive on the main thread).
@MainActor
final class StoreSSHRpc: SSHRpc {
    unowned let store: Store
    init(store: Store) { self.store = store }
    func call(_ method: String, _ params: [String: Any], done: @escaping @MainActor (Result<Any, RpcFailure>) -> Void) {
        store.call(method, params) { r in
            switch r {
            case let .success(v): done(.success(v))
            case let .failure(e): done(.failure(RpcFailure(message: describe(e))))
            }
        }
    }
}

/// Keeps the daemon's idle clock honest (classic: 15 minutes without mouse / key / scroll anywhere in Muya locks the
/// Password Store) and refreshes the page when the daemon says it locked (`muya://vault-locked`).
@MainActor
final class VaultIdleBridge: NSObject {
    private weak var store: Store?
    private weak var hub: SSHHubPage?
    private var lastPing = Date.distantPast
    private var monitor: Any?
    /// One ping per 20 s is plenty for a 15-minute limit.
    static let pingEvery: TimeInterval = 20

    init(store: Store, hub: SSHHubPage) {
        self.store = store; self.hub = hub
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(daemonEvent(_:)), name: Store.eventNotification, object: store)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated { self?.interaction() }
            return e
        }
    }

    func interaction(now: Date = Date()) {
        guard now.timeIntervalSince(lastPing) >= Self.pingEvery else { return }
        lastPing = now
        store?.call("vault.activity") { _ in }
    }

    @objc private func daemonEvent(_ n: Notification) {
        guard (n.userInfo?["name"] as? String) == "muya://vault-locked" else { return }
        hub?.vaultWasLocked()
    }
}

enum SSHPageFactory {
    nonisolated(unsafe) private static var bridge: VaultIdleBridge?
    /// The page wired to the running app: rpc over the Store, Connect opens a terminal session that runs `ssh`.
    /// Called from MainController (main thread, not annotated), hence assumeIsolated.
    static func make(store: Store) -> SSHHubPage {
        return MainActor.assumeIsolated {
            let hub = SSHHubPage(rpc: StoreSSHRpc(store: store)) { name, command in
                store.openShell(cwd: store.home, name: name, typing: command)
            }
            bridge = VaultIdleBridge(store: store, hub: hub)
            return hub
        }
    }
}
