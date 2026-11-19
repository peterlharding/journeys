//
//  MotionMonitor.swift
//  Journeys
//
//  What the phone's motion sensors say the user is doing, for the tracker.
//

import CoreMotion

/// What the motion sensors say, as far as the tracker cares.
enum MotionState: Equatable {
    /// No reliable reading: no permission, no motion hardware (the simulator), or low confidence.
    case unknown
    case stationary
    /// Walking or running: small moves are real even when indoor location fixes are poor.
    case onFoot
    /// Driving or cycling.
    case vehicle
}

/// A protocol so tests can say what the user is doing.
@MainActor
protocol MotionStateProviding: AnyObject {
    var state: MotionState { get }
    func start()
    func stop()
}

/// Reads iOS's motion activity (accelerometer based, so unaffected by poor GPS indoors) while tracking.
@MainActor
final class MotionMonitor: MotionStateProviding {
    private(set) var state: MotionState = .unknown
    private let manager = CMMotionActivityManager()
    private var running = false

    func start() {
        guard CMMotionActivityManager.isActivityAvailable(), !running else { return }
        running = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            MainActor.assumeIsolated {
                self?.state = activity.map(Self.state(for:)) ?? .unknown
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopActivityUpdates()
        state = .unknown
    }

    nonisolated static func state(for activity: CMMotionActivity) -> MotionState {
        guard activity.confidence != .low else { return .unknown }
        if activity.walking || activity.running { return .onFoot }
        if activity.automotive || activity.cycling { return .vehicle }
        if activity.stationary { return .stationary }
        return .unknown
    }
}
