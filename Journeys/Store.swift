//
//  Store.swift
//  Journeys
//
//  The on-device database: journeys and their waypoints, in Core Data on SQLite.
//  Everything recorded is saved here first; uploading is tracked per record with `SyncState`.
//

import CoreData
import CoreLocation

/// Whether a record has reached the API.
enum SyncState: Int16 {
    /// Saved on the phone, not yet confirmed by the API.
    case pending = 0
    /// Confirmed by the API.
    case synced = 1
    /// Refused by the API; not retried automatically.
    case rejected = 2
}

@objc(Journey)
final class Journey: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var notes: String
    @NSManaged var createdAt: Date
    @NSManaged var syncStateValue: Int16
    @NSManaged var syncedAt: Date?
    @NSManaged var syncError: String?
    @NSManaged var waypoints: Set<Waypoint>

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateValue) ?? .pending }
        set { syncStateValue = newValue.rawValue }
    }
}

@objc(Waypoint)
final class Waypoint: NSManagedObject, Identifiable {
    /// Where a waypoint came from.
    enum Source: String {
        case tracker
        case checkLocation = "check"
    }

    @NSManaged var id: UUID
    @NSManaged var recordedAt: Date
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var horizontalAccuracy: Double
    @NSManaged var speed: Double
    @NSManaged var course: Double
    @NSManaged var sourceValue: String
    @NSManaged var syncStateValue: Int16
    @NSManaged var syncedAt: Date?
    @NSManaged var syncError: String?
    /// Nil for a Check Location fix taken with no current journey; such waypoints are never uploaded.
    @NSManaged var journey: Journey?

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateValue) ?? .pending }
        set { syncStateValue = newValue.rawValue }
    }

    var source: Source {
        get { Source(rawValue: sourceValue) ?? .tracker }
        set { sourceValue = newValue.rawValue }
    }

    var location: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: 0, horizontalAccuracy: horizontalAccuracy, verticalAccuracy: -1,
                   course: course, speed: speed, timestamp: recordedAt)
    }
}

/// Owns the Core Data stack. The screens and `LocationManager` use `viewContext` on the main actor.
@MainActor
final class Store {
    static let shared = Store()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    /// The compiled model, loaded once: Core Data warns when several containers load their own copies.
    private static let model: NSManagedObjectModel = {
        guard let url = Bundle(for: Journey.self).url(forResource: "Journeys", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("Journeys.momd is missing from the app bundle")
        }
        return model
    }()

    /// - Parameter url: the SQLite file; `nil` uses the default location in Application Support.
    ///   Pass `URL(fileURLWithPath: "/dev/null")` for an in-memory store (unit tests).
    init(url: URL? = nil) {
        container = NSPersistentContainer(name: "Journeys", managedObjectModel: Self.model)
        if let url {
            container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        }
        container.loadPersistentStores { _, error in
            if let error {
                // The store is the app's only copy of unsynced data; never start without it silently.
                fatalError("Could not open the journeys database: \(error)")
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// An empty in-memory store, for tests.
    static func inMemory() -> Store {
        Store(url: URL(fileURLWithPath: "/dev/null"))
    }

    // MARK: - Writing

    @discardableResult
    func addJourney(id: UUID = UUID(), name: String, notes: String, createdAt: Date = .now,
                    syncState: SyncState) -> Journey {
        let journey = Journey(context: viewContext)
        journey.id = id
        journey.name = name
        journey.notes = notes
        journey.createdAt = createdAt
        journey.syncState = syncState
        if syncState == .synced { journey.syncedAt = .now }
        save()
        return journey
    }

    @discardableResult
    func addWaypoint(_ location: CLLocation, source: Waypoint.Source, journey: Journey?) -> Waypoint {
        let waypoint = Waypoint(context: viewContext)
        waypoint.id = UUID()
        waypoint.recordedAt = location.timestamp
        waypoint.latitude = location.coordinate.latitude
        waypoint.longitude = location.coordinate.longitude
        waypoint.horizontalAccuracy = location.horizontalAccuracy
        waypoint.speed = location.speed
        waypoint.course = location.course
        waypoint.source = source
        waypoint.syncState = .pending
        waypoint.journey = journey
        save()
        return waypoint
    }

    func save() {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
        } catch {
            // Losing a recorded fix silently is worse than a visible failure during development.
            assertionFailure("Could not save to the journeys database: \(error)")
            print("Could not save to the journeys database: \(error)")
        }
    }

    // MARK: - Reading

    func journey(id: UUID) -> Journey? {
        let request = Journey.fetchRequest(matching: NSPredicate(format: "id == %@", id as CVarArg))
        request.fetchLimit = 1
        return (try? viewContext.fetch(request))?.first
    }

    /// The waypoints of `journey`, or the waypoints with no journey when it is nil, oldest first.
    func waypoints(of journey: Journey?) -> [Waypoint] {
        let request = Waypoint.fetchRequest(for: journey)
        return (try? viewContext.fetch(request)) ?? []
    }
}

extension Journey {
    static func fetchRequest(matching predicate: NSPredicate? = nil) -> NSFetchRequest<Journey> {
        let request = NSFetchRequest<Journey>(entityName: "Journey")
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return request
    }
}

extension Waypoint {
    /// The waypoints of `journey`, or the waypoints with no journey when it is nil, oldest first.
    static func fetchRequest(for journey: Journey?) -> NSFetchRequest<Waypoint> {
        let request = NSFetchRequest<Waypoint>(entityName: "Waypoint")
        request.predicate = journey.map { NSPredicate(format: "journey == %@", $0) }
            ?? NSPredicate(format: "journey == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "recordedAt", ascending: true)]
        return request
    }
}
