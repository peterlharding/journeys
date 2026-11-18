//
//  NewJourneyModal.swift
//  LocationDemo
//
//  Created by Peter Harding on 14/10/2024.
//
import SwiftUI

// Modal view to create a new Journey with a GUID and additional info
struct NewJourneyModal: View {

    @Binding var isPresented: Bool
    @Binding var currentJourney: JourneyData?

    @State private var journeyName: String = ""
    @State private var journeyNotes: String = ""

    var locationManager: LocationManager

    var body: some View {
        NavigationView {
            Form {
                TextField("Journey Name", text: $journeyName)
                TextField("Notes", text: $journeyNotes)
            }
            .navigationBarTitle("New Journey", displayMode: .inline)
            .navigationBarItems(leading: Button("Cancel") {
                isPresented = false
            }, trailing: Button("Save") {

                let newJourney = JourneyData(id: UUID(), name: journeyName, notes: journeyNotes)

                currentJourney = newJourney

                locationManager.saveJourneyToUserDefaults(journey: newJourney) // Save to UserDefaults

                postJourneyData(journey: newJourney)

                isPresented = false
            })
        }
    }

    // Function to POST the Journey data to the API
    func postJourneyData(journey: JourneyData) {
        let journeyData = JourneyData(id: journey.id, name: journey.name, notes: journey.notes)

        guard let url = URL(string: "https://mongo-api.performiq.com/journeys") else {
            print("Invalid URL")
            return
        }

        // Create the URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            // Convert journey data to JSON
            let jsonData = try JSONEncoder().encode(journeyData)
            request.httpBody = jsonData

            // Perform the network request
            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error {
                    print("Error posting journey data: \(error)")
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    print("Journey data successfully posted")
                } else {
                    print("Failed to post journey data, response: \(String(describing: response))")
                }
            }.resume()

        } catch {
            print("Failed to encode journey data: \(error)")
        }
    }
}
