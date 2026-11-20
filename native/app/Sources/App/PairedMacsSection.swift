// Settings > Paired Macs: one row per Mac paired through the bridge, with who paired it, a Messaging / Full scope switch
// and Revoke. A Mac an agent paired starts as Messaging; only the operator (this app's own connection to muyad) can widen
// it, muyad refuses `bridge.set_peer_capability` from anyone else. Rows are built with the ModalParts helpers like every
// other Settings group; the list is the daemon's `bridge.list_peers`, never a copy kept here.

import AppKit

final class PairedMacsSection: NSObject {
    unowned let store: Store
    private let host: () -> NSWindow
    private let holder = NSView()
    private var peers: [BridgePeer] = []
    private var failure: String?

    init(store: Store, host: @escaping () -> NSWindow) {
        self.store = store; self.host = host
        super.init()
        holder.translatesAutoresizingMaskIntoConstraints = false
        rebuild()
    }

    /// The group label, the rows box (rebuilt when the list changes) and the helper line under it.
    func blocks() -> [NSView] {
        let note = ThemedText.helper("Messaging lets a Mac exchange messages with your agents. Full also lets its agents use SSH, secrets, sessions and keys here. Only you can change this.")
        return [ThemedText.label("Paired Macs"), holder, note]
    }

    func reload() {
        store.call("bridge.list_peers") { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.peers = (v as? [[String: Any]] ?? []).compactMap(BridgePeer.init(json:)).sorted { $0.pairedAt < $1.pairedAt }
                self.failure = nil
            case let .failure(e): self.failure = describe(e)
            }
            self.rebuild()
        }
    }

    private func rebuild() {
        holder.subviews.forEach { $0.removeFromSuperview() }
        let rows: [NSView]
        if peers.isEmpty {
            let text = failure ?? "No Mac is paired yet. A Mac paired by an agent shows up here."
            rows = [ThemedText.helper(text)]
        } else {
            rows = peers.map(row)
        }
        let box = ModalLayout.rowsBox(rows)
        holder.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: holder.topAnchor), box.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: holder.leadingAnchor), box.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
    }

    private func row(_ peer: BridgePeer) -> NSView {
        let scope = ThemedSegmented(options: PeerScope.titles, selected: peer.isMessagingOnly ? PeerScope.messaging.index : PeerScope.full.index)
        scope.compact = true
        scope.setAccessibilityLabel("Scope of \(peer.label)")
        scope.onChange = { [weak self] i in MainActor.assumeIsolated { self?.setScope(PeerScope(index: i), of: peer) } }
        let revoke = ModalButton("Revoke", height: 28, label: "Revoke \(peer.label)")
        revoke.onClick = { [weak self] in MainActor.assumeIsolated { self?.confirmRevoke(peer) } }
        // Same widths on every row so the controls line up down the list.
        scope.translatesAutoresizingMaskIntoConstraints = false
        scope.widthAnchor.constraint(equalToConstant: 150).isActive = true
        revoke.widthAnchor.constraint(equalToConstant: 66).isActive = true
        // Own row (not settingRow): the text column is narrow here, so the helper stays on one line and the controls sit flush right.
        let title = ThemedText.title(peer.label), helper = ThemedText.helper(peer.pairedLine)
        for t in [title, helper] { t.lineBreakMode = .byTruncatingTail; t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        helper.maximumNumberOfLines = 1
        let texts = Kit.vstack([title, helper], spacing: 4)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = Kit.hstack([scope, revoke], spacing: 8)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.widthAnchor.constraint(equalToConstant: 160).isActive = true
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setContentHuggingPriority(.required, for: .horizontal)
        let r = Kit.hstack([texts, spacer, controls], spacing: 8, alignment: .centerY)
        r.distribution = .fill
        return r
    }

    private func setScope(_ scope: PeerScope, of peer: BridgePeer) {
        store.call("bridge.set_peer_capability", ["peerSpki": peer.spkiHash, "capability": scope.rawValue]) { [weak self] r in
            if case let .failure(e) = r { Toasts.center?.show(title: "Could not change \(peer.label)", message: describe(e), seconds: 8) }
            self?.reload()
        }
    }

    private func confirmRevoke(_ peer: BridgePeer) {
        Dialogs.shared.confirm(over: host(), title: "Revoke \(peer.label)?",
                               message: "This Mac and its agents can no longer reach yours. Pair again to bring it back.",
                               confirmTitle: "Revoke", danger: true) { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.store.call("bridge.revoke_peer", ["spkiHash": peer.spkiHash]) { r in
                    if case let .failure(e) = r { Toasts.center?.show(title: "Could not revoke \(peer.label)", message: describe(e), seconds: 8) }
                    self?.reload()
                }
            }
        }
    }
}
