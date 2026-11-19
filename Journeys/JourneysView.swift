//
//  JourneysView.swift
//  Journeys
//
//  Past journeys and their waypoints, from the store, with what has reached the server
//  (docs/OFFLINE_SYNC.md, phase 4).
//

import CoreData
import SwiftUI

/// All journeys, newest first, each with its waypoint count and sync state.
struct JourneysView: View {
    @Environment(\.dismiss) private var dismiss

    let currentJourneyID: UUID?

    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: false)], animation: .default)
    private var journeys: FetchedResults<Journey>

    var body: some View {
        NavigationStack {
            Group {
                if journeys.isEmpty {
                    ContentUnavailableView("No Journeys", systemImage: "map",
                                           description: Text("Journeys you create appear here."))
                } else {
                    List(journeys) { journey in
                        NavigationLink {
                            JourneyDetailView(journey: journey)
                        } label: {
                            JourneyRow(journey: journey, isCurrent: journey.id == currentJourneyID)
                        }
                    }
                }
            }
            .navigationTitle("Journeys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct JourneyRow: View {
    @ObservedObject var journey: Journey
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            SyncStateIcon(state: journey.syncState)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(journey.name.isEmpty ? "Untitled" : journey.name)
                        .font(.headline)
                    if isCurrent {
                        Text("Current")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(journey.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(waypointCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("journeyRow")
    }

    private var waypointCount: String {
        String(AttributedString(localized: "^[\(journey.waypoints.count) waypoint](inflect: true)").characters)
    }
}

/// One journey: its details and sync state, then its waypoints, oldest first.
struct JourneyDetailView: View {
    @ObservedObject var journey: Journey
    @FetchRequest private var waypoints: FetchedResults<Waypoint>

    init(journey: Journey) {
        self.journey = journey
        _waypoints = FetchRequest(fetchRequest: Waypoint.fetchRequest(for: journey), animation: .default)
    }

    var body: some View {
        List {
            Section {
                if !journey.notes.isEmpty {
                    LabeledContent("Notes", value: journey.notes)
                }
                LabeledContent("Created", value: journey.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Upload") {
                    SyncStateLabel(state: journey.syncState, error: journey.syncError)
                }
            }
            Section(String(AttributedString(localized: "^[\(waypoints.count) Waypoint](inflect: true)").characters)) {
                if waypoints.isEmpty {
                    Text("No waypoints yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(waypoints) { waypoint in
                    WaypointRow(waypoint: waypoint)
                }
            }
        }
        .navigationTitle(journey.name.isEmpty ? "Untitled" : journey.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WaypointRow: View {
    @ObservedObject var waypoint: Waypoint

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SyncStateIcon(state: waypoint.syncState)
            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.recordedAt.formatted(date: .omitted, time: .standard))
                    .font(.subheadline.monospacedDigit())
                Text(String(format: "%.5f, %.5f", waypoint.latitude, waypoint.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if waypoint.source == .checkLocation {
                    Text("Check Location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if waypoint.syncState == .rejected, let error = waypoint.syncError {
                    Text("Rejected: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("waypointRow")
    }
}

/// Whether a record has reached the server, as an icon.
struct SyncStateIcon: View {
    let state: SyncState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .synced: "checkmark.icloud"
        case .pending: "icloud.and.arrow.up"
        case .rejected: "exclamationmark.icloud"
        }
    }

    private var tint: Color {
        switch state {
        case .synced: .green
        case .pending: .accentColor
        case .rejected: .red
        }
    }

    private var label: String {
        switch state {
        case .synced: "Uploaded"
        case .pending: "Waiting to upload"
        case .rejected: "Rejected by the server"
        }
    }
}

/// Sync state as words, with the server's reason for a rejection.
private struct SyncStateLabel: View {
    let state: SyncState
    let error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                SyncStateIcon(state: state)
                Text(text)
            }
            if state == .rejected, let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var text: String {
        switch state {
        case .synced: "Uploaded"
        case .pending: "Waiting"
        case .rejected: "Rejected"
        }
    }
}
