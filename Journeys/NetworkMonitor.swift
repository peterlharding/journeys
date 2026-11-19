//
//  NetworkMonitor.swift
//  Journeys
//
//  Whether automatic sync may run on the current network.
//

import Foundation
import Network

/// Automatic sync runs only on networks iOS does not flag as expensive (mobile data, a personal hotspot)
/// or constrained (Low Data Mode): in practice Wi-Fi. A protocol so tests can switch networks.
@MainActor
protocol NetworkStatusProviding: AnyObject {
    var allowsAutomaticSync: Bool { get }
    /// Called on the main actor whenever `allowsAutomaticSync` may have changed.
    var onChange: (() -> Void)? { get set }
}

@MainActor
final class NetworkMonitor: NetworkStatusProviding {
    private(set) var allowsAutomaticSync = false
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in
                guard let self, allowed != self.allowsAutomaticSync else { return }
                self.allowsAutomaticSync = allowed
                self.onChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.performiq.Journeys.NetworkMonitor"))
    }

    deinit {
        monitor.cancel()
    }
}
