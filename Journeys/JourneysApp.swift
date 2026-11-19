//
//  JourneysApp.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//

import SwiftUI

@main
struct JourneysApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, Store.shared.viewContext)
        }
    }
}
