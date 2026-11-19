//
//  NewJourneyModal.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//
import SwiftUI

/// Sheet to create a journey; it becomes the current journey only once the API has stored it.
struct NewJourneyModal: View {
    @Environment(\.dismiss) private var dismiss

    @State private var journeyName: String = ""
    @State private var journeyNotes: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

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

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("saveError")
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("New Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await locationManager.createJourney(name: trimmedName, notes: journeyNotes)
                dismiss()
            } catch {
                errorMessage = "Journey not saved. \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}
