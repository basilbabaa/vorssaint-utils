// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Darwin
import Foundation

/// One line of the external address block: what a single connection looks like
/// from the internet.
struct ExternalAddress: Equatable, Identifiable {
    var id: String { interface }
    let interface: String      // BSD name, e.g. en1
    let connection: String     // system name, e.g. Wi-Fi
    let ip: String?            // nil when the connection has no route out
    let provider: String?      // e.g. Spectrum, T-Mobile
}

/// View-owned. Asks ipinfo.io once per active connection, binding each request
/// to that connection so two ISPs show two answers. A request leaves the
/// machine only while the block is on screen, and answers are cached for a few
/// minutes.
final class ExternalAddressService: ObservableObject {
    @Published private(set) var addresses: [ExternalAddress] = []
    @Published private(set) var isLoading = false

    private var lastFetch: Date?
    private var serial = 0
    private static let cacheSeconds: TimeInterval = 300

    func refresh(force: Bool = false) {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < Self.cacheSeconds { return }
        guard !isLoading else { return }
        isLoading = true
        lastFetch = Date()
        serial += 1
        let mySerial = serial
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let results = Self.lookupAll()
            DispatchQueue.main.async {
                guard let self, self.serial == mySerial else { return }
                self.addresses = results
                self.isLoading = false
            }
        }
    }

    func cancel() {
        serial += 1
        isLoading = false
    }

    // MARK: - Lookup

    private static func lookupAll() -> [ExternalAddress] {
        let interfaces = activeInterfaces()
        var results = [ExternalAddress?](repeating: nil, count: interfaces.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: interfaces.count) { index in
            let (bsd, display) = interfaces[index]
            let answer = lookup(interface: bsd)
            let entry = ExternalAddress(interface: bsd, connection: display,
                                        ip: answer?.ip, provider: answer?.provider)
            lock.lock()
            results[index] = entry
            lock.unlock()
        }
        return results.compactMap { $0 }
    }

    /// BSD name and system name of every up, running IPv4 connection.
    private static func activeInterfaces() -> [(String, String)] {
        let names = NetworkAddressService.connectionNames()
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var seen = Set<String>()
        var out: [(String, String)] = []
        var current = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let address = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            guard NetworkAddressService.includesLocalAddress(
                name: name, flags: entry.ifa_flags, family: Int32(address.pointee.sa_family)),
                  seen.insert(name).inserted else { continue }
            out.append((name, names[name] ?? name))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func lookup(interface: String) -> (ip: String, provider: String?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-s", "-m", "6", "--interface", interface, "https://ipinfo.io/json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = json["ip"] as? String else { return nil }
        return (ip, providerName(org: json["org"] as? String))
    }

    /// "AS11426 Charter Communications Inc" -> "Spectrum".
    static func providerName(org: String?) -> String? {
        guard var org, !org.isEmpty else { return nil }
        if let space = org.firstIndex(of: " "), org.hasPrefix("AS") {
            org = String(org[org.index(after: space)...])
        }
        let lower = org.lowercased()
        if lower.contains("charter") || lower.contains("spectrum") { return "Spectrum" }
        if lower.contains("t-mobile") || lower.contains("tmobile") { return "T-Mobile" }
        return org
    }
}
