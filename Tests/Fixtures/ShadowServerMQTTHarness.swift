// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct ShadowServerMQTTHarness {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        let connect = ShadowServerMQTT.connect(clientID: "c", username: "u", password: "p", keepAlive: 60)
        expect(connect == Data([0x10, 19, 0, 4, 77, 81, 84, 84, 4, 0xC2, 0, 60, 0, 1, 99, 0, 1, 117, 0, 1, 112]),
               "CONNECT bytes")
        let subscribe = ShadowServerMQTT.subscribe(["a/b"], packetID: 1)
        expect(subscribe == Data([0x82, 8, 0, 1, 0, 3, 97, 47, 98, 0]), "SUBSCRIBE bytes")

        // Two packets, the second a PUBLISH split across reads, plus a two-byte length.
        let payload = Data(repeating: 0x41, count: 200)
        var publish = Data([0x30, 0xCF, 0x01, 0, 5]) + Data("x/y/z".utf8) + payload
        var buffer = Data([0x20, 0x02, 0x00, 0x00]) + publish.prefix(10)
        publish = publish.dropFirst(10)
        let first = (try? ShadowServerMQTT.decode(&buffer)) ?? []
        expect(first == [.connAck(returnCode: 0)], "CONNACK decoded, partial PUBLISH kept")
        buffer.append(publish)
        let second = (try? ShadowServerMQTT.decode(&buffer)) ?? []
        expect(second == [.publish(topic: "x/y/z", payload: payload)], "PUBLISH reassembled")
        expect(buffer.isEmpty, "buffer drained")

        var qos1 = Data([0x32, 7, 0, 1, 0x74, 0, 9, 0x7B, 0x7D])
        expect((try? ShadowServerMQTT.decode(&qos1)) == [.publish(topic: "t", payload: Data("{}".utf8))], "QoS 1 packet id skipped")
        var bad = Data([0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        expect((try? ShadowServerMQTT.decode(&bad)) == nil, "5-byte length rejected")
        var huge = Data([0x30, 0xFF, 0xFF, 0xFF, 0x7F])
        expect((try? ShadowServerMQTT.decode(&huge)) == nil, "oversized packet rejected")

        var subAck = Data([0x90, 4, 0, 1, 0x00, 0x80])
        expect((try? ShadowServerMQTT.decode(&subAck)) == [.subAck(granted: [0x00, 0x80])], "SUBACK return codes kept")

        expect(ShadowServerMQTT.isTailnetAddress([100, 64, 0, 1]) && ShadowServerMQTT.isTailnetAddress([100, 127, 255, 254]),
               "tailnet IPv4 peer accepted")
        expect(!ShadowServerMQTT.isTailnetAddress([100, 128, 0, 1]) && !ShadowServerMQTT.isTailnetAddress([93, 184, 216, 34]),
               "non-tailnet IPv4 peer rejected")
        expect(ShadowServerMQTT.isTailnetAddress([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + Array(repeating: 1, count: 10)),
               "tailnet IPv6 peer accepted")
        expect(!ShadowServerMQTT.isTailnetAddress([0x20, 0x01] + Array(repeating: 0, count: 14)), "public IPv6 peer rejected")

        expect(ShadowServerMQTT.isTailnetHost("100.101.102.103"), "CGNAT accepted")
        expect(ShadowServerMQTT.isTailnetHost("shadow.tail1234.ts.net"), "MagicDNS accepted")
        for host in ["8.8.8.8", "100.128.0.1", "192.168.1.10", "example.com", "ts.net", "100.64.1", "evil.ts.net.example.com"] {
            expect(!ShadowServerMQTT.isTailnetHost(host), "\(host) rejected")
        }

        let towers = ShadowServerTower.list(Data(#"[{"cell":"5g:1","radio":"5g","band":"n41","lat":37.6,"lon":-122.4,"source":"ocid","samples":8,"best_rsrp":-82},{"cell":"x","lat":95,"lon":0}]"#.utf8))
        expect(towers?.count == 1 && towers?.first?.rsrp == -82, "tower list parsed, invalid row dropped")
        expect(ShadowServerTower.one(Data(#"{"cell":"5g:2","radio":"5g","band":"n25","lat":37.7,"lon":-122.4,"rsrp":-101}"#.utf8))?.rsrp == -101,
               "serving tower parsed")
        expect(ShadowServerTower.list(Data("not json".utf8)) == nil, "bad JSON ignored")

        if failures.isEmpty { print("PASS: Shadow server MQTT codec, host gate and tower parsing") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
