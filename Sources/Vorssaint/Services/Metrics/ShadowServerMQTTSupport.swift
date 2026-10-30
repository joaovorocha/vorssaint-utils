// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Minimal MQTT 3.1.1 codec for a subscribe-only client: CONNECT, SUBSCRIBE,
/// PINGREQ out; CONNACK, SUBACK, PUBLISH (QoS 0), PINGRESP in.
enum ShadowServerMQTT {
    enum Packet: Equatable {
        case connAck(returnCode: UInt8)
        case subAck(granted: [UInt8]) // 0x80 = topic refused
        case publish(topic: String, payload: Data)
        case pingResp
        case other(type: UInt8)
    }

    enum DecodeError: Error { case malformed, tooLarge }

    // Retained coverage topics reach a few hundred KB; anything far beyond is not ours.
    static let maximumPacketBytes = 8 * 1_024 * 1_024

    static let topics = ["van/router/towers/estimated", "van/router/towers/serving"]

    static func connect(clientID: String, username: String, password: String, keepAlive: UInt16) -> Data {
        var body = string("MQTT")
        body.append(4) // protocol level 3.1.1
        body.append(0xC2) // username + password + clean session
        body.append(contentsOf: [UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)])
        body.append(string(clientID)); body.append(string(username)); body.append(string(password))
        return packet(0x10, body)
    }

    static func subscribe(_ topics: [String], packetID: UInt16) -> Data {
        var body = Data([UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
        for topic in topics { body.append(string(topic)); body.append(0) }
        return packet(0x82, body)
    }

    static let ping = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    /// Removes every complete packet from the front of `buffer`; a partial packet stays.
    static func decode(_ buffer: inout Data) throws -> [Packet] {
        var packets: [Packet] = []
        while true {
            let bytes = [UInt8](buffer.prefix(5))
            guard bytes.count >= 2 else { return packets }
            var length = 0, multiplier = 1, index = 1
            while true {
                guard index < bytes.count else {
                    if index >= 5 { throw DecodeError.malformed }
                    return packets
                }
                let byte = bytes[index]
                length += Int(byte & 0x7F) * multiplier
                index += 1
                if byte & 0x80 == 0 { break }
                multiplier *= 128
                if index >= 5 { throw DecodeError.malformed }
            }
            guard length <= maximumPacketBytes else { throw DecodeError.tooLarge }
            guard buffer.count >= index + length else { return packets }
            let start = buffer.startIndex
            let body = Data(buffer[(start + index)..<(start + index + length)])
            buffer = Data(buffer.dropFirst(index + length))
            packets.append(try parse(type: bytes[0], body: body))
        }
    }

    private static func parse(type header: UInt8, body: Data) throws -> Packet {
        let bytes = [UInt8](body)
        switch header >> 4 {
        case 2:
            guard bytes.count == 2 else { throw DecodeError.malformed }
            return .connAck(returnCode: bytes[1])
        case 3:
            guard bytes.count >= 2 else { throw DecodeError.malformed }
            let topicLength = Int(bytes[0]) << 8 | Int(bytes[1])
            var offset = 2 + topicLength
            guard bytes.count >= offset,
                  let topic = String(bytes: bytes[2..<offset], encoding: .utf8) else { throw DecodeError.malformed }
            if (header >> 1) & 0x03 > 0 { offset += 2 } // packet identifier for QoS 1/2
            guard bytes.count >= offset else { throw DecodeError.malformed }
            return .publish(topic: topic, payload: Data(bytes[offset...]))
        case 9:
            guard bytes.count >= 3 else { throw DecodeError.malformed }
            return .subAck(granted: Array(bytes[2...]))
        case 13: return .pingResp
        default: return .other(type: header >> 4)
        }
    }

    private static func string(_ value: String) -> Data {
        let utf8 = Array(value.utf8.prefix(65_535))
        return Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8)
    }

    private static func packet(_ header: UInt8, _ body: Data) -> Data {
        var data = Data([header])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            data.append(byte)
        } while length > 0
        data.append(body)
        return data
    }

    /// Credentials travel in plaintext MQTT, so only tailnet addresses are allowed:
    /// Tailscale CGNAT IPv4 (100.64.0.0/10) or a MagicDNS `*.ts.net` name.
    static func isTailnetHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasSuffix(".ts.net"), host.count > 7,
           host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// The resolved peer must also be on the tailnet: a `*.ts.net` name could resolve elsewhere.
    static func isTailnetAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return bytes[0] == 100 && (64...127).contains(bytes[1]) }
        return bytes.count == 16 && bytes.prefix(6) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    }
}

/// A tower or cell estimate published by the Shadow server's tower map service.
struct ShadowServerTower: Equatable {
    let cell: String
    let radio: String
    let band: String?
    let latitude: Double
    let longitude: Double
    let source: String?
    let samples: Int?
    let rsrp: Int?

    private struct Wire: Decodable {
        let cell: String
        let radio: String?
        let band: String?
        let lat: Double
        let lon: Double
        let source: String?
        let samples: Int?
        let best_rsrp: Int?
        let rsrp: Int?
    }

    static func list(_ payload: Data) -> [ShadowServerTower]? {
        (try? JSONDecoder().decode([Wire].self, from: payload))?.compactMap(make)
    }

    static func one(_ payload: Data) -> ShadowServerTower? {
        (try? JSONDecoder().decode(Wire.self, from: payload)).flatMap(make)
    }

    private static func make(_ wire: Wire) -> ShadowServerTower? {
        guard (-90...90).contains(wire.lat), (-180...180).contains(wire.lon), !wire.cell.isEmpty else { return nil }
        return .init(cell: String(wire.cell.prefix(32)), radio: wire.radio ?? "", band: wire.band,
                     latitude: wire.lat, longitude: wire.lon, source: wire.source,
                     samples: wire.samples, rsrp: wire.rsrp ?? wire.best_rsrp)
    }
}
