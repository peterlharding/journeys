//
//  NewJourneyModal.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//
import SwiftUI

/// Sheet to create a journey. It is saved on the phone and becomes current at once, online or not;
/// the sync engine uploads it.
struct NewJourneyModal: View {
    @Environment(\.dismiss) private var dismiss

    @State private var journeyName: String = ""
    @State private var journeyNotes: String = ""

    var locationManager: LocationManager

    private var trimmedName: String {
        journeyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Journey Name", text: $journeyName)
                    .accessibilityIdentifier("journeyName")
                TextField("Notes", text: $journeyNotes)
            }
            .navigationTitle("New Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        locationManager.createJourney(name: trimmedName, notes: journeyNotes)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}
