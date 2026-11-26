import Foundation

/// Where an account's Reply Later and Set Aside mail is kept, once that has been
/// settled: in a folder the app made, or in a mailbox the person picked. Kept on
/// this Mac and, so that every Mac uses the same mailboxes, in the account itself
/// (`SyncedState`).
public struct FolderAssignments: Codable, Equatable, Sendable {
    /// Mailbox paths, keyed by the folder's name.
    private var paths: [String: String] = [:]
    /// When each folder was last settled or set back to automatic, by the same key.
    /// Two Macs that settled a folder differently go by the later.
    private var changedAt: [String: Date] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paths = try container.decode([String: String].self, forKey: .paths)
        changedAt = try container.decodeIfPresent([String: Date].self, forKey: .changedAt) ?? [:]
    }

    public subscript(folder: MailboxDirectory.AppFolder) -> String? {
        paths[folder.rawValue]
    }

    /// Settles where a folder lives. Nil sets it back to automatic: the app finds
    /// or makes one under the folder's own name.
    public mutating func assign(_ path: String?, to folder: MailboxDirectory.AppFolder, at time: Date) {
        paths[folder.rawValue] = path
        // To the second, as it is written down.
        changedAt[folder.rawValue] = time.toTheSecond
    }
}

extension FolderAssignments: Mergeable {
    /// Each folder as whichever Mac settled it last left it.
    public func merged(with other: FolderAssignments) -> FolderAssignments {
        var merged = self
        for (folder, theirTime) in other.changedAt {
            let ourTime = changedAt[folder] ?? .distantPast
            // Settled in the same second: go by an order both Macs compute alike.
            guard theirTime > ourTime || (theirTime == ourTime && (other.paths[folder] ?? "") > (paths[folder] ?? "")) else { continue }
            merged.paths[folder] = other.paths[folder]
            merged.changedAt[folder] = theirTime
        }
        // A path settled before times were kept stands until either Mac settles it again.
        for (folder, path) in other.paths where merged.paths[folder] == nil && merged.changedAt[folder] == nil {
            merged.paths[folder] = path
        }
        return merged
    }
}

/// Setting up Reply Later and Set Aside on the server.
///
/// The first time mail is put in one of them the app makes a folder for it. Some
/// servers refuse (Proton will not make a folder that shares its name with a label),
/// and then the person says what to use instead: a mailbox that already exists, or a
/// new folder under another name. The mail that was waiting is delivered once the
/// folder is settled.
public struct AppFoldersFeature: Feature {
    public typealias Folder = MailboxDirectory.AppFolder

    public struct State: Equatable, Sendable {
        /// Nil until loaded. Nothing can be settled before then.
        public var assignments: FolderAssignments?
        /// What is under way for each folder. A folder with nothing under way is absent.
        public var setups: [Folder: Setup] = [:]
        /// Why the assignments could not be read or written, until it has been seen.
        public var storageProblem: String?

        public init() {}

        /// The folder whose refusal the person is being asked about, if any.
        public var choice: Choice? {
            for folder in Folder.allCases {
                if case .choosing(let path, let refusal, _) = setups[folder] {
                    return Choice(folder: folder, refusedPath: path, refusal: refusal)
                }
            }
            return nil
        }
    }

    /// A folder the server would not make, and why.
    public struct Choice: Identifiable, Equatable, Sendable {
        public let folder: Folder
        public let refusedPath: String
        public let refusal: MailError

        public var id: String { "\(folder.rawValue)\n\(refusedPath)" }
    }

    public enum Setup: Equatable, Sendable {
        /// Making a folder at `path`, for the mail waiting to go into it.
        case creating(path: String, waiting: [MessageSummary.ID])
        /// The server would not make the folder. The person is deciding what to use.
        case choosing(refusedPath: String, refusal: MailError, waiting: [MessageSummary.ID])
    }

    public enum Event: Sendable {
        case loadRequested
        case loaded(FolderAssignments?)
        /// What another Mac settled has been read from the account.
        case remoteArrived(FolderAssignments)
        /// Mail is to go into a folder that does not exist yet.
        case folderNeeded(Folder, path: String, for: [MessageSummary.ID])
        case creationFinished(Folder, Result<Void, MailError>, at: Date)
        /// The person picked a mailbox that already exists.
        case existingChosen(Folder, path: String, at: Date)
        /// The person asked for a new folder at another path.
        case newFolderChosen(Folder, path: String)
        case choiceCancelled(Folder)
        /// The person changed where a folder lives, in Settings. Nil goes back to
        /// having the app make one the next time it is needed.
        case reassigned(Folder, path: String?, at: Date)
        case storageFailed(String)
        case storageProblemDismissed
    }

    public enum Effect: Equatable, Sendable {
        case load
        case save(FolderAssignments)
        case create(Folder, path: String)
        /// Move the mail that was waiting into the folder that is now settled.
        case deliver(ids: [MessageSummary.ID], to: String)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .loadRequested:
            return state.assignments == nil ? [.load] : []

        case .loaded(let saved):
            state.assignments = saved ?? FolderAssignments()
            return []

        case .remoteArrived(let remote):
            guard let assignments = state.assignments else { return [] }
            let merged = assignments.merged(with: remote)
            guard merged != assignments else { return [] }
            state.assignments = merged
            return [.save(merged)]

        case .folderNeeded(let folder, let path, let ids):
            guard state.assignments != nil else { return [] }
            switch state.setups[folder] {
            case nil:
                state.setups[folder] = .creating(path: path, waiting: ids)
                return [.create(folder, path: path)]
            case .creating(let path, let waiting):
                state.setups[folder] = .creating(path: path, waiting: waiting + ids)
                return []
            case .choosing(let path, let refusal, let waiting):
                state.setups[folder] = .choosing(refusedPath: path, refusal: refusal, waiting: waiting + ids)
                return []
            }

        case .creationFinished(let folder, .success, let time):
            guard case .creating(let path, let waiting) = state.setups[folder] else { return [] }
            return settle(folder, at: path, time, delivering: waiting, in: &state)

        case .creationFinished(let folder, .failure(let error), _):
            guard case .creating(let path, let waiting) = state.setups[folder] else { return [] }
            state.setups[folder] = .choosing(refusedPath: path, refusal: error, waiting: waiting)
            return []

        case .existingChosen(let folder, let path, let time):
            guard case .choosing(_, _, let waiting) = state.setups[folder] else { return [] }
            return settle(folder, at: path, time, delivering: waiting, in: &state)

        case .newFolderChosen(let folder, let path):
            guard case .choosing(_, _, let waiting) = state.setups[folder] else { return [] }
            state.setups[folder] = .creating(path: path, waiting: waiting)
            return [.create(folder, path: path)]

        case .choiceCancelled(let folder):
            // The waiting mail stays where it is.
            if case .choosing = state.setups[folder] { state.setups[folder] = nil }
            return []

        case .reassigned(let folder, let path, let time):
            guard var assignments = state.assignments, assignments[folder] != path else { return [] }
            assignments.assign(path, to: folder, at: time)
            state.assignments = assignments
            return [.save(assignments)]

        case .storageFailed(let message):
            state.storageProblem = message
            return []

        case .storageProblemDismissed:
            state.storageProblem = nil
            return []
        }
    }

    /// Records where the folder is and sends on the mail that was waiting for it.
    private func settle(
        _ folder: Folder,
        at path: String,
        _ time: Date,
        delivering waiting: [MessageSummary.ID],
        in state: inout State
    ) -> [Effect] {
        guard var assignments = state.assignments else { return [] }
        assignments.assign(path, to: folder, at: time)
        state.assignments = assignments
        state.setups[folder] = nil
        return [.save(assignments)] + (waiting.isEmpty ? [] : [.deliver(ids: waiting, to: path)])
    }

    /// - Parameter deliver: moves messages into a mailbox that exists.
    public static func effects(
        store: JSONFileStore<FolderAssignments>,
        service: any MailService,
        now: @escaping @Sendable () -> Date = { Date() },
        deliver: @escaping @Sendable ([MessageSummary.ID], String) async -> Void
    ) -> EffectRunner<AppFoldersFeature> {
        { effect, send in
            switch effect {
            case .load:
                do throws(StorageError) {
                    await send(.loaded(try store.load()))
                } catch {
                    // Unreadable assignments are reported and then treated as none:
                    // the folders are found by name, or settled again when next used.
                    await send(.storageFailed(error.message))
                    await send(.loaded(nil))
                }
            case .save(let assignments):
                do throws(StorageError) {
                    try store.save(assignments)
                } catch {
                    await send(.storageFailed(error.message))
                }
            case .create(let folder, let path):
                let created = await outcome { () throws(MailError) in try await service.createMailbox(path) }
                await send(.creationFinished(folder, created, at: now()))
            case .deliver(let ids, let path):
                await deliver(ids, path)
            }
        }
    }
}
