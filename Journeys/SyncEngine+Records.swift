//
//  SyncEngine+Records.swift
//  Journeys
//
//  How the sync engine reads pending records and records the server's answers, on background contexts.
//

import CoreData
import Foundation

extension SyncEngine {
    /// The oldest pending records: journeys first, then waypoints whose journey the server has or
    /// is about to receive in this batch, so none is rejected just for arriving before its journey.
    func makeBatch() async -> SyncBatch {
        let context = store.container.newBackgroundContext()
        return await context.perform {
            let pending = NSPredicate(format: "syncStateValue == %d", SyncState.pending.rawValue)

            let journeyRequest = Journey.fetchRequest(matching: pending)
            journeyRequest.fetchLimit = SyncBatch.maxRecords
            let journeys = (try? context.fetch(journeyRequest)) ?? []

            let waypointRequest = NSFetchRequest<Waypoint>(entityName: "Waypoint")
            waypointRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                pending,
                NSPredicate(format: "journey.syncStateValue == %d OR journey IN %@",
                            SyncState.synced.rawValue, journeys)
            ])
            waypointRequest.sortDescriptors = [NSSortDescriptor(key: "recordedAt", ascending: true)]
            waypointRequest.fetchLimit = SyncBatch.maxRecords
            let waypoints = (try? context.fetch(waypointRequest)) ?? []

            return SyncBatch(
                journeys: journeys.map {
                    SyncBatch.Journey(id: $0.id, name: $0.name, notes: $0.notes, createdAt: $0.createdAt)
                },
                waypoints: waypoints.compactMap { waypoint in
                    guard let journey = waypoint.journey else { return nil }
                    return SyncBatch.Waypoint(id: waypoint.id, journeyId: journey.id,
                                              recordedAt: waypoint.recordedAt, latitude: waypoint.latitude,
                                              longitude: waypoint.longitude,
                                              horizontalAccuracy: waypoint.horizontalAccuracy,
                                              speed: waypoint.speed, course: waypoint.course,
                                              source: waypoint.sourceValue)
                }
            )
        }
    }

    /// Records the server's answers. Returns whether any record got an answer.
    func apply(_ response: SyncResponse) async -> Bool {
        let journeyOutcomes = SyncResponse.byID(response.journeys)
        let waypointOutcomes = SyncResponse.byID(response.waypoints)
        let context = store.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return await context.perform {
            let now = Date.now
            // Journeys first: a rejected journey marks its waypoints with its own reason.
            let answered = Self.applyJourneys(journeyOutcomes, in: context, at: now)
                + Self.applyWaypoints(waypointOutcomes, in: context, at: now)
            do {
                try context.save()
            } catch {
                print("Could not save sync results: \(error)")
                return false
            }
            return answered > 0
        }
    }

    /// Returns how many journeys got an answer.
    private nonisolated static func applyJourneys(_ outcomes: [UUID: SyncResponse.Outcome],
                                                  in context: NSManagedObjectContext, at now: Date) -> Int {
        let request = Journey.fetchRequest(matching: NSPredicate(format: "id IN %@", Array(outcomes.keys)))
        var answered = 0
        for journey in (try? context.fetch(request)) ?? [] {
            guard let outcome = outcomes[journey.id] else { continue }
            answered += 1
            switch outcome {
            case .accepted:
                journey.syncState = .synced
                journey.syncedAt = now
                journey.syncError = nil
            case .rejected(let reason):
                journey.syncState = .rejected
                journey.syncError = reason
                // Its waypoints can never be accepted without it.
                for waypoint in journey.waypoints where waypoint.syncState == .pending {
                    waypoint.syncState = .rejected
                    waypoint.syncError = "Its journey was rejected: \(reason)"
                }
            }
        }
        return answered
    }

    /// Returns how many waypoints got an answer.
    private nonisolated static func applyWaypoints(_ outcomes: [UUID: SyncResponse.Outcome],
                                                   in context: NSManagedObjectContext, at now: Date) -> Int {
        let request = NSFetchRequest<Waypoint>(entityName: "Waypoint")
        request.predicate = NSPredicate(format: "id IN %@", Array(outcomes.keys))
        var answered = 0
        for waypoint in (try? context.fetch(request)) ?? [] {
            guard let outcome = outcomes[waypoint.id] else { continue }
            answered += 1
            // Already marked with its journey's reason, which says more than the server's
            // "no journey with id" for a waypoint whose journey it refused.
            if waypoint.journey?.syncState == .rejected { continue }
            switch outcome {
            case .accepted:
                waypoint.syncState = .synced
                waypoint.syncedAt = now
                waypoint.syncError = nil
            case .rejected(let reason):
                waypoint.syncState = .rejected
                waypoint.syncError = reason
            }
        }
        return answered
    }
}
