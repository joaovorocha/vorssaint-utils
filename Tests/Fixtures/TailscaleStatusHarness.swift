// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct TailscaleStatusHarness {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        // Synthetic `tailscale status --json`, trimmed to the fields that matter plus private ones that must be ignored.
        let json = #"""
        {"BackendState":"Running","TailscaleIPs":["100.100.1.1","fd7a:115c:a1e0::1"],"MagicDNSSuffix":"tail0000.ts.net",
         "CurrentTailnet":{"Name":"owner@example.com"},"User":{"1":{"LoginName":"owner@example.com"}},
         "Self":{"DNSName":"laptop.tail0000.ts.net.","TailscaleIPs":["100.100.1.1"],"Online":true,"PublicKey":"nodekey:secret"},
         "Peer":{
          "nodekey:a":{"ID":"a","HostName":"server","DNSName":"server.tail0000.ts.net.","OS":"linux","Online":true,
                       "CurAddr":"192.0.2.10:41641","Relay":"sfo","TailscaleIPs":["100.100.1.2"],"ExitNode":true},
          "nodekey:b":{"ID":"b","HostName":"phone","DNSName":"phone.tail0000.ts.net.","OS":"iOS","Online":true,
                       "CurAddr":"","Relay":"sfo","TailscaleIPs":["100.100.1.3"]},
          "nodekey:c":{"ID":"c","HostName":"Old-PC","DNSName":"","OS":"windows","Online":false,"Relay":"","TailscaleIPs":["100.100.1.4"]},
          "nodekey:d":{"ID":"d","HostName":"alpha","DNSName":"alpha.tail0000.ts.net.","OS":"linux","Online":true,
                       "CurAddr":"","Relay":"","TailscaleIPs":["fd7a:115c:a1e0::5"]}
         }}
        """#
        let status = TailscaleStatus.parse(Data(json.utf8))
        expect(status?.state == .running, "running state")
        expect(status?.name == "laptop.tail0000.ts.net" && status?.address == "100.100.1.1", "self name and IPv4")
        expect(status?.exitNode == "server", "exit node named")
        expect(status?.peers.map(\.name) == ["alpha", "phone", "server", "Old-PC"], "online first, then by name")
        let byName = Dictionary(uniqueKeysWithValues: (status?.peers ?? []).map { ($0.name, $0) })
        expect(byName["server"]?.relay == nil, "direct path has no relay")
        expect(byName["phone"]?.relay == "sfo", "relayed path names the DERP region")
        expect(byName["Old-PC"]?.online == false && byName["Old-PC"]?.address == "100.100.1.4", "offline peer kept, HostName fallback")
        expect(byName["alpha"]?.address == nil && byName["alpha"]?.relay == nil, "IPv6-only peer has no IPv4, empty relay ignored")
        let dump = String(describing: status)
        expect(!dump.contains("example.com") && !dump.contains("nodekey"), "no account or key leaks into the model")

        for (backend, state) in [("Stopped", TailscaleStatus.State.stopped), ("NeedsLogin", .needsLogin),
                                 ("NeedsMachineAuth", .needsLogin), ("Starting", .starting), ("NoState", .other)] {
            let parsed = TailscaleStatus.parse(Data(#"{"BackendState":"\#(backend)","Peer":null}"#.utf8))
            expect(parsed?.state == state && parsed?.peers.isEmpty == true, "\(backend) state, null Peer")
        }
        expect(TailscaleStatus.parse(Data("not json".utf8)) == nil, "bad JSON rejected")
        expect(TailscaleStatus.parse(Data("{}".utf8)) == nil, "missing BackendState rejected")

        expect(TailscaleStatus.pingMilliseconds("pong from server (100.100.1.2) via 192.0.2.10:41641 in 67ms\n") == 67, "direct ping")
        expect(TailscaleStatus.pingMilliseconds("pong from phone (100.100.1.3) via DERP(sfo) in 45.5ms") == 45.5, "relayed ping")
        expect(TailscaleStatus.pingMilliseconds("ping \"100.100.1.4\" timed out\nno reply") == nil, "timeout has no time")

        if failures.isEmpty { print("PASS: Tailscale status and ping parsing") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
