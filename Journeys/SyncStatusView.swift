//
//  SyncStatusView.swift
//  Journeys
//
//  One line saying what is waiting to upload and why, with a Sync now button.
//

import SwiftUI

struct SyncStatusView: View {
    @ObservedObject var syncEngine: SyncEngine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.subheadline)
                    .accessibilityIdentifier("syncStatus")
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("syncDetail")
                }
            }
            Spacer(minLength: 0)
            if syncEngine.status == .syncing {
                ProgressView()
            } else if syncEngine.pendingCount > 0 {
                Button("Sync now") {
                    Task { await syncEngine.syncNow() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
    }

    private var summary: String {
        let journeys = syncEngine.pendingJourneys
        let waypoints = syncEngine.pendingWaypoints
        switch (journeys, waypoints) {
        case (0, 0):
            return "All synced"
        case (0, _):
            return String(AttributedString(localized: "^[\(waypoints) waypoint](inflect: true) waiting").characters)
        case (_, 0):
            return String(AttributedString(localized: "^[\(journeys) journey](inflect: true) waiting").characters)
        default:
            return String(AttributedString(
                localized: "^[\(journeys) journey](inflect: true) and ^[\(waypoints) waypoint](inflect: true) waiting"
            ).characters)
        }
    }

    private var detail: String? {
        var parts: [String] = []
        switch syncEngine.status {
        case .syncing:
            parts.append("Syncing")
        case .waitingForWiFi:
            parts.append("Waiting for Wi-Fi")
        case .failed(let message):
            parts.append("Upload failed, will retry: \(message)")
        case .idle:
            if let lastSyncedAt = syncEngine.lastSyncedAt {
                parts.append("Last synced \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        if syncEngine.rejected > 0 {
            parts.append("\(syncEngine.rejected) rejected by the server")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch syncEngine.status {
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .failed: "exclamationmark.icloud"
        case .waitingForWiFi: "wifi.exclamationmark"
        case .idle: syncEngine.pendingCount == 0 ? "checkmark.icloud" : "icloud.and.arrow.up"
        }
    }

    private var tint: Color {
        switch syncEngine.status {
        case .failed: .red
        case .waitingForWiFi: .orange
        default: syncEngine.pendingCount == 0 ? .green : .accentColor
        }
    }
}
