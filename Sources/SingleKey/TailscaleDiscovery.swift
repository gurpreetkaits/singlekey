import Foundation

/// Polls `tailscale status --json` for other online Macs on the same tailnet.
final class TailscaleDiscovery {
    struct Device { let ip: String; let name: String }

    private(set) var selfIP: String?
    private(set) var macs: [Device] = []
    var onUpdate: (() -> Void)?
    private var timer: Timer?

    private static let cliPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let cli = Self.cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
                log("tailscale status unreadable (exit \(process.terminationStatus), \(data.count) bytes)")
                return
            }

            let selfIP = status.Self?.ipv4
            let macs = (status.Peer ?? [:]).values.compactMap { node -> Device? in
                guard node.Online == true, node.OS == "macOS", let ip = node.ipv4 else { return nil }
                return Device(ip: ip, name: node.HostName ?? ip)
            }
            DispatchQueue.main.async {
                self.selfIP = selfIP
                self.macs = macs
                self.onUpdate?()
            }
        }
    }

    private struct Status: Decodable {
        let `Self`: Node?
        let Peer: [String: Node]?
    }

    private struct Node: Decodable {
        let HostName: String?
        let OS: String?
        let Online: Bool?
        let TailscaleIPs: [String]?
        var ipv4: String? { TailscaleIPs?.first { $0.contains(".") } }
    }
}
