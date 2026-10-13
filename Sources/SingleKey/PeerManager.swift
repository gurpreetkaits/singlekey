import CryptoKit
import Foundation
import Network

/// One encrypted connection to another SingleKey instance.
final class Peer {
    let connection: NWConnection
    /// True when this Mac dialed the connection.
    let outgoing: Bool
    var id: String?
    var name = "Mac"
    var onMessage: ((Peer, Message) -> Void)?
    var onReady: ((Peer) -> Void)?
    var onClosed: ((Peer, NWError?) -> Void)?
    private var closed = false

    init(connection: NWConnection, outgoing: Bool, id: String? = nil) {
        self.connection = connection
        self.outgoing = outgoing
        self.id = id
    }


    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            log("connection \(self.connection.endpoint) \(state)")
            switch state {
            case .ready:
                self.onReady?(self)
                self.receiveNext()
            case .failed(let error), .waiting(let error):
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: Message) {
        guard !closed, let data = Wire.encode(message) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func close(_ error: NWError? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClosed?(self, error)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self else { return }
            guard let header, header.count == 4, error == nil else { return self.close(error) }
            let length = Wire.length(of: header)
            guard length > 0, length < 1 << 20 else { return self.close() }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, body.count == length, error == nil else { return self.close(error) }
                if let message = Wire.decode(body) { self.onMessage?(self, message) }
                self.receiveNext()
            }
        }
    }
}

/// Advertises this Mac over Bonjour, finds other Macs running SingleKey, and keeps one
/// TLS (pre-shared key) connection to each of them. Everything runs on the main queue.
final class PeerManager {
    static let serviceType = "_singlekey._tcp"
    static let port: NWEndpoint.Port = 24804

    let myID = Settings.instanceID
    let myName = Host.current().localizedName ?? "Mac"

    private(set) var peers: [Peer] = []
    var onMessage: ((Peer, Message) -> Void)?
    var onPeersChanged: (() -> Void)?
    private(set) var lastError: String?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pending: [Peer] = []
    private var discovered: Set<String> = []
    private var retryTimer: Timer?
    private var passcode = ""
    private let tailscale = TailscaleDiscovery()
    /// Tailscale address -> latest connection attempt to it.
    private var dialing: [String: Peer] = [:]
    /// Tailscale address -> SingleKey ID learned from that Mac's hello.
    private var tailscaleIDs: [String: String] = [:]

    func start(passcode: String) {
        stop()
        self.passcode = passcode
        guard !passcode.isEmpty else { return }

        do {
            let listener = try NWListener(using: Self.parameters(passcode: passcode), on: Self.port)
            listener.service = NWListener.Service(name: myID, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                self?.adopt(Peer(connection: connection, outgoing: false))
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.lastError = "Listener failed: \(error)"
                    self?.onPeersChanged?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.restart() }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = "Couldn't start listener: \(error)"
        }

        let browseParams = NWParameters()
        browseParams.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: browseParams)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = Set(results.compactMap {
                if case .service(let name, _, _, _) = $0.endpoint { return name }
                return nil
            })
            self.connectToDiscovered()
        }
        browser.start(queue: .main)
        self.browser = browser

        tailscale.onUpdate = { [weak self] in self?.connectToTailscale() }
        tailscale.start()

        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.connectToDiscovered()
            self?.connectToTailscale()
        }
    }

    func restart() { start(passcode: passcode) }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        tailscale.stop()
        dialing = [:]
        (peers + pending).forEach { $0.onClosed = nil; $0.close() }
        peers = []
        pending = []
        lastError = nil
        onPeersChanged?()
    }

    /// Only the instance with the smaller ID dials, so each pair ends up with one connection.
    private func connectToDiscovered() {
        for id in discovered where id != myID && myID < id {
            let known = (peers + pending).contains { $0.id == id }
            if known { continue }
            let endpoint = NWEndpoint.service(name: id, type: Self.serviceType, domain: "local.", interface: nil)
            let connection = NWConnection(to: endpoint, using: Self.parameters(passcode: passcode))
            adopt(Peer(connection: connection, outgoing: true, id: id))
        }
    }

    /// Dials other Macs on the same tailnet. Bonjour can't cross Tailscale, so we connect
    /// by IP; only the Mac with the lower Tailscale IP dials to avoid duplicate connections.
    private func connectToTailscale() {
        guard !passcode.isEmpty, let me = tailscale.selfIP else { return }
        for device in tailscale.macs where me < device.ip {
            if let attempt = dialing[device.ip] {
                if let id = attempt.id { tailscaleIDs[device.ip] = id }
                if (peers + pending).contains(where: { $0 === attempt }) { continue }
            }
            // Already connected to this Mac some other way (e.g. over the LAN).
            if let id = tailscaleIDs[device.ip], peers.contains(where: { $0.id == id }) { continue }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(device.ip), port: Self.port)
            let peer = Peer(connection: NWConnection(to: endpoint, using: Self.parameters(passcode: passcode)), outgoing: true)
            peer.name = device.name
            dialing[device.ip] = peer
            adopt(peer)
        }
    }

    private func adopt(_ peer: Peer) {
        pending.append(peer)
        peer.onReady = { [weak self] peer in
            guard let self else { return }
            peer.send(.hello(id: self.myID, name: self.myName))
        }
        peer.onMessage = { [weak self] peer, message in
            guard let self else { return }
            if case .hello(let id, let name) = message {
                peer.id = id
                peer.name = name
                if let existing = self.peers.first(where: { $0.id == id }) {
                    // Two connections to the same Mac (e.g. LAN + Tailscale). Both sides keep
                    // the one dialed by the Mac with the smaller ID, so they always agree.
                    let keepNew = peer.outgoing == (self.myID < id) && existing.outgoing != peer.outgoing
                    let loser = keepNew ? existing : peer
                    loser.onClosed = nil
                    loser.close()
                    self.pending.removeAll { $0 === loser }
                    self.peers.removeAll { $0 === loser }
                    if !keepNew { return }
                }
                self.pending.removeAll { $0 === peer }
                self.peers.append(peer)
                self.lastError = nil
                self.onPeersChanged?()
            } else if self.peers.contains(where: { $0 === peer }) {
                self.onMessage?(peer, message)
            }
        }
        peer.onClosed = { [weak self] peer, error in
            guard let self else { return }
            if case .tls = error {
                self.lastError = "Connection refused — make sure both Macs use the same pairing code."
            }
            self.pending.removeAll { $0 === peer }
            self.peers.removeAll { $0 === peer }
            self.onPeersChanged?()
        }
        peer.start()
    }

    /// TCP + TLS 1.2 with a pre-shared key derived from the pairing code. Peers with a
    /// different code fail the handshake, and all input is encrypted on the wire.
    static func parameters(passcode: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3

        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(passcode.utf8))
        let psk = HMAC<SHA256>.authenticationCode(for: Data("SingleKey".utf8), using: key)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("SingleKey".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}
