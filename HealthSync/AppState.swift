import Foundation
import BackgroundTasks
import SwiftUI

@MainActor
struct BackgroundSyncScheduler {
    static let taskIdentifier = "com.megabyte0x.HealthSync.background-sync"

    func scheduleIfNeeded(for frequency: SyncFrequency, now: Date = Date()) async throws {
        guard let earliestBeginDate = BackgroundSyncSchedule.earliestBeginDate(for: frequency, now: now) else {
            return
        }

        let pending = await BGTaskScheduler.shared.pendingTaskRequests()
        try Task.checkCancellation()
        if let request = pending.first(where: { $0.identifier == Self.taskIdentifier }),
           (request.earliestBeginDate ?? .distantPast) <= earliestBeginDate {
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }
}

enum HealthSyncUserMessages {
    static let noNewSamplesFound = "No new Apple Health samples found."
    static let noSamplesFoundForDateRange = "No Apple Health samples found for this date range."

    static func displayLogMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: "No new HealthKit samples found.", with: noNewSamplesFound)
            .replacingOccurrences(of: "No HealthKit samples found for this date range.", with: noSamplesFoundForDateRange)
    }
}

struct HealthActionFeedback: Equatable {
    enum Kind: Equatable {
        case success
        case info
        case error
    }

    let kind: Kind
    let message: String

    static let permissionRequested = HealthActionFeedback(
        kind: .success,
        message: "Health access request completed. You can change access at any time in iPhone Settings."
    )
    static let noSamples = HealthActionFeedback(
        kind: .info,
        message: "No health samples were found for the last 24 hours."
    )
    static let syncCompleted = HealthActionFeedback(
        kind: .success,
        message: "The last 24 hours were synced successfully."
    )
    static let syncStopped = HealthActionFeedback(
        kind: .info,
        message: "Sync stopped. Unsent records stay in the pending queue. To pause automatic sync, set Background Sync to Manual only in Settings."
    )

    static func failure(_ message: String) -> HealthActionFeedback {
        HealthActionFeedback(kind: .error, message: message)
    }
}

enum DevelopmentKeychainBypass {
    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func hasStoredToken(readProductionTokenState: () throws -> Bool) throws -> Bool {
        guard !isEnabled else { return true }
        return try readProductionTokenState()
    }

    static func hostedAgentToken(readProductionToken: () throws -> String?) throws -> String {
        guard !isEnabled else { return "" }
        return try readProductionToken() ?? ""
    }
}

enum BusyOperation {
    static func canStart(isBusy: Bool) -> Bool {
        !isBusy
    }

    static func shouldRerunPendingSync(hasWaiters: Bool, stopRequested: Bool) -> Bool {
        hasWaiters && !stopRequested
    }
}

enum BackfillSyncError: LocalizedError, Equatable {
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .uploadFailed(message):
            message
        }
    }
}

enum BackfillSync {
    private static let chunkLength: TimeInterval = 30 * 24 * 60 * 60
    private static let maxRecordsPerUpload = 100

    static func chunks(start: Date, end: Date) -> [SyncDateRange] {
        guard end > start else { return [] }

        var ranges: [SyncDateRange] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor.addingTimeInterval(chunkLength), end)
            ranges.append(SyncDateRange(start: cursor, end: next))
            cursor = next
        }
        return ranges
    }

    static func validateUpload(_ result: SyncRunResult) throws {
        guard result.failedCount == 0 else {
            throw BackfillSyncError.uploadFailed(result.lastFailure ?? result.messages.last ?? "Upload failed.")
        }
        guard result.uploadedCount > 0 else {
            throw BackfillSyncError.uploadFailed("Upload is still queued. Retry after the current sync finishes.")
        }
    }

    static func shouldUpload(_ payload: SyncPayload) -> Bool {
        !payload.isEmpty
    }

    static func uploadPayloads(for payload: SyncPayload) -> [SyncPayload] {
        payload.chunked(maxRecords: maxRecordsPerUpload)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var shouldShowOnboarding = true
    @Published var settings = AppSettings.default
    @Published var status = SyncStatus.empty
    @Published var logs: [SyncLogEntry] = []
    @Published var permissionSummary = "Not requested"
    @Published var hostedAgentToken = ""
    @Published var hasStoredToken = false
    @Published var isBusy = false
    @Published var backfillProgress = 0.0
    @Published var backfillError: String?
    @Published var lastError: String?
    @Published var actionFeedback: HealthActionFeedback?
    @Published private(set) var backendFeedback: HealthActionFeedback?
    @Published private(set) var isSavingSettings = false
    @Published private(set) var isTestingConnection = false
    /// True while a sync or backfill runs, so the UI offers Stop sync.
    @Published private(set) var canStopSync = false
    @Published private(set) var isStoppingSync = false

    private let storeURL: URL?
    private var store: SQLiteLocalStore?
    private var syncEngine: SyncEngine?
    private var incrementalSyncRunner: IncrementalSyncRunner?
    private var approvedTypes = AppSettings.default.selectedTypes
    private let healthKit = HealthKitManager()
    private let normalizer = HealthNormalizer()
    private let keychain: any TokenProviding
    private let backgroundSyncScheduler = BackgroundSyncScheduler()
    private var periodicSyncTask: Task<Void, Never>?
    private var backgroundSchedulingTask: Task<Void, Never>?
    /// The one handle for the current busy operation; `stopSync()` cancels it.
    private var busyOperation: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var pendingIncrementalWaiters: [CheckedContinuation<Bool, Never>] = []
    private let apiSession: URLSession

    init(storeURL: URL? = nil, keychain: any TokenProviding = KeychainStore(), apiSession: URLSession = .shared) {
        self.storeURL = storeURL
        self.keychain = keychain
        self.apiSession = apiSession
    }

    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        do {
            let localStore = try SQLiteLocalStore(url: storeURL)
            store = localStore
            syncEngine = SyncEngine(store: localStore, uploader: APIClient(session: apiSession))
            incrementalSyncRunner = IncrementalSyncRunner(
                store: localStore, reader: healthKit, uploader: APIClient(session: apiSession, maxAttempts: 1)
            )
            settings = try await localStore.loadSettings()
            approvedTypes = settings.selectedTypes
            hasStoredToken = try DevelopmentKeychainBypass.hasStoredToken {
                try hasTokenForCurrentStorageMode()
            }
            hostedAgentToken = try DevelopmentKeychainBypass.hostedAgentToken {
                try keychain.readHostedAgentToken()
            }
            shouldShowOnboarding = !settings.hasRequestedHealthPermissions
            permissionSummary = healthKit.isHealthDataAvailable
                ? (settings.hasRequestedHealthPermissions ? "Requested" : "Not requested")
                : "Unavailable"
            try await localStore.pruneUploaded(olderThan: Date().addingTimeInterval(-7 * 24 * 60 * 60))
            await refresh()
            await startObserversIfPossible()
            restartPeriodicSync()
        } catch {
            lastError = userMessage(from: error)
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            status = try await store.syncStatus()
            logs = try await store.recentLogs()
        } catch {
            lastError = userMessage(from: error)
        }
    }

    /// True once the user explicitly chose a storage destination and its credentials are saved.
    var hasChosenStorageDestination: Bool {
        hasUsableUploadConfiguration()
    }

    func connectAppleHealth() async {
        guard !isSavingSettings else { return }
        var completedInitialSetup = false
        await runBusy { [self] in
            guard settings.storageMode != nil else { throw APIClientError.noStorageDestination }
            let types = settings.selectedTypes
            if types.isEmpty {
                guard settings.hasRequestedHealthPermissions else { throw HealthKitManagerError.noDataTypesSelected }
            } else {
                try await healthKit.requestReadPermissions(for: types)
            }
            let isInitialSetup = !settings.hasRequestedHealthPermissions
            try await saveHealthSelection(types)
            completedInitialSetup = isInitialSetup
            shouldShowOnboarding = false
            permissionSummary = "Requested"
            actionFeedback = types.isEmpty
                ? HealthActionFeedback(kind: .info, message: "No health categories selected. Unsent samples were removed.")
                : .permissionRequested
            await startObserversIfPossible()
            restartPeriodicSync()
            await refresh()
        }
        if completedInitialSetup && !isBusy && !Task.isCancelled {
            await syncAutomatically()
        }
    }

    func set(type: HealthDataType, enabled: Bool) {
        if enabled {
            settings.selectedTypes.insert(type)
        } else {
            settings.selectedTypes.remove(type)
        }
    }

    var hasHostedIngestToken: Bool {
        !((try? readUploadToken(for: .hostedHealthSync)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCustomToken: Bool {
        !((try? readUploadToken(for: .customBackend)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveDestination(_ save: () async throws -> Bool) async -> Bool {
        guard !isSavingSettings, !isTestingConnection, !isBusy || canStopSync else { return false }
        isSavingSettings = true
        backendFeedback = nil
        lastError = nil
        defer { isSavingSettings = false }

        do {
            let stoppedSync = try await save()
            var message = "Settings saved."
            if stoppedSync {
                message += " The running sync was stopped so new uploads use this destination."
            }
            backendFeedback = HealthActionFeedback(kind: .success, message: message)
            await startObserversIfPossible()
            restartPeriodicSync()
            await refresh()
            return true
        } catch {
            let message = userMessage(from: error)
            lastError = message
            backendFeedback = .failure("Could not save the destination: \(message)")
            return false
        }
    }

    @discardableResult
    func createHostedStorage() async -> Bool {
        await saveDestination { try await createHostedWorkspace() }
    }

    @discardableResult
    func useHostedStorage() async -> Bool {
        await saveDestination {
            guard hasHostedIngestToken else { throw APIClientError.missingToken }
            var candidate = settings
            candidate.storageMode = .hostedHealthSync
            return try await commitDestination(candidate)
        }
    }

    /// Tests the backend URL and token the user entered and, only when the backend accepts the test upload,
    /// saves them as the upload destination. Returns whether the destination was saved.
    func useOwnBackend(backendURL: String, tokenDraft: String) async -> Bool {
        await saveDestination {
            let configuration = try await customUploadConfiguration(backendURL: backendURL, tokenDraft: tokenDraft)
            try await sendConnectionTest(configuration: configuration)

            let previousToken = try readUploadToken(for: .customBackend)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentialsChanged = configuration.destination != UploadConfiguration.destinationKey(for: settings.backendURL)
                || configuration.token != previousToken
            var candidate = settings
            candidate.backendURL = backendURL
            candidate.storageMode = .customBackend
            return try await commitDestination(candidate, uploadToken: credentialsChanged ? configuration.token : nil)
        }
    }

    private func customUploadConfiguration(backendURL: String, tokenDraft: String) async throws -> UploadConfiguration {
        guard let store else { throw APIClientError.invalidResponse }
        var candidate = settings
        candidate.storageMode = .customBackend
        candidate.backendURL = backendURL
        let baseURL = candidate.effectiveBackendURL
        _ = try APIClient.validatedRootURL(from: baseURL)
        let draft = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A different backend must not receive the token saved for the current endpoint.
        let sameEndpoint = UploadConfiguration.destinationKey(for: baseURL)
            == UploadConfiguration.destinationKey(for: settings.backendURL)
        let token = draft.isEmpty && sameEndpoint
            ? (try readUploadToken(for: .customBackend) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : draft
        guard !token.isEmpty else { throw APIClientError.missingToken }
        return UploadConfiguration(baseURL: baseURL, token: token, deviceID: try await store.deviceID(), appVersion: Self.appVersion)
    }

    private func commitDestination(_ candidate: AppSettings, uploadToken: String? = nil) async throws -> Bool {
        guard let store else { throw APIClientError.invalidResponse }
        var candidate = candidate
        candidate.migrateHostedEndpoints()
        let replacingAuthorization = uploadToken != nil || settings.storageMode != candidate.storageMode
            || settings.uploadDestination != candidate.uploadDestination
        let stoppedSync = replacingAuthorization && canStopSync
        if stoppedSync { await stopSync() }

        // A staged item is unreadable by the exporter until SQLite commits its reference and clears the old queue.
        let newID = uploadToken.map { _ in UUID() }
        var oldID: UUID?
        if let uploadToken, let newID {
            try keychain.saveUploadToken(uploadToken, id: newID)
            if candidate.storageMode == .hostedHealthSync {
                oldID = candidate.hostedIngestTokenID
                candidate.hostedIngestTokenID = newID
            } else {
                oldID = candidate.customTokenID
                candidate.customTokenID = newID
            }
        }
        candidate.selectedTypes = approvedTypes
        let discarded: Int
        do {
            discarded = try await store.saveDestination(candidate, replacingAuthorization: replacingAuthorization)
        } catch {
            if let newID { try? keychain.deleteUploadToken(id: newID) }
            throw error
        }
        if let oldID { try? keychain.deleteUploadToken(id: oldID) }
        candidate.selectedTypes = settings.selectedTypes // Keep unsaved UI edits as drafts.
        settings = candidate
        hasStoredToken = try hasTokenForCurrentStorageMode()

        if discarded > 0 {
            let host = UploadConfiguration.host(of: candidate.uploadDestination ?? "")
            try? await store.appendLog(SyncLogEntry(
                level: .info,
                message: "Discarded \(discarded) queued uploads while configuring \(host). Those records won't be re-sent from the queue."
            ))
        }
        return stoppedSync
    }

    func resetHostedStorage() async {
        guard !isSavingSettings else { return }
        await runBusy { [self] in
            let ingestToken = (try readUploadToken(for: .hostedHealthSync) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if ingestToken.isEmpty {
                _ = try await createHostedWorkspace()
            } else {
                do {
                    let response = try await APIClient(session: apiSession, maxAttempts: 1).resetHostedWorkspace(
                        baseURL: AppSettings.hostedBackendURL,
                        token: ingestToken,
                        label: "Personal Health"
                    )
                    _ = try await applyHostedWorkspace(response)
                } catch APIClientError.authRejected {
                    _ = try await createHostedWorkspace()
                }
            }

            await startObserversIfPossible()
            restartPeriodicSync()
        }
    }

    func refreshHostedAgentToken() async {
        guard !isSavingSettings else { return }
        await runBusy { [self] in
            guard let store else { throw APIClientError.invalidResponse }
            let ingestToken = (try readUploadToken(for: .hostedHealthSync) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ingestToken.isEmpty else { throw APIClientError.missingToken }

            let response = try await APIClient(session: apiSession, maxAttempts: 1).refreshHostedAgentToken(
                baseURL: AppSettings.hostedBackendURL,
                token: ingestToken
            )
            settings.hostedWorkspaceID = response.workspaceID
            settings.hostedAgentEndpoint = response.agentEndpoint
            try keychain.saveHostedAgentToken(response.agentToken)
            hostedAgentToken = response.agentToken
            try await store.updateSettings {
                $0.hostedWorkspaceID = response.workspaceID
                $0.hostedAgentEndpoint = response.agentEndpoint
            }
        }
    }

    private func applyHostedWorkspace(_ response: HostedWorkspaceProvisioningResponse) async throws -> Bool {
        var candidate = settings
        candidate.storageMode = .hostedHealthSync
        candidate.hostedWorkspaceID = response.workspaceID
        candidate.hostedAgentEndpoint = response.agentEndpoint
        let stoppedSync = try await commitDestination(candidate, uploadToken: response.ingestToken)
        try keychain.saveHostedAgentToken(response.agentToken)
        hostedAgentToken = response.agentToken
        return stoppedSync
    }

    private func createHostedWorkspace() async throws -> Bool {
        let response = try await APIClient(session: apiSession, maxAttempts: 1).provisionHostedWorkspace(
            baseURL: AppSettings.hostedBackendURL,
            label: "Personal Health"
        )
        return try await applyHostedWorkspace(response)
    }

    func testConnection(backendURL: String? = nil, tokenDraft: String = "") async {
        guard !isTestingConnection, !isSavingSettings else { return }
        isTestingConnection = true
        backendFeedback = nil
        defer { isTestingConnection = false }

        let testedMode = settings.storageMode
        let feedback: HealthActionFeedback
        do {
            let configuration: UploadConfiguration
            if let backendURL {
                configuration = try await customUploadConfiguration(backendURL: backendURL, tokenDraft: tokenDraft)
            } else {
                configuration = try await uploadConfiguration()
            }
            try await sendConnectionTest(configuration: configuration)
            feedback = HealthActionFeedback(kind: .success, message: "Connection works. The backend accepted a test upload.")
        } catch {
            let message = userMessage(from: error)
            feedback = .failure("Connection test failed: \(message)")
            try? await store?.appendLog(SyncLogEntry(level: .error, message: message))
        }
        if settings.storageMode == testedMode {
            backendFeedback = feedback
        }
        await refresh()
    }

    private func sendConnectionTest(configuration: UploadConfiguration) async throws {
        guard let store else { throw APIClientError.invalidResponse }
        let now = Date()
        let payload = SyncPayload.empty(
            deviceID: configuration.deviceID,
            dateRange: SyncDateRange(start: now, end: now),
            timezone: TimeZone.current.identifier
        )
        let batch = SyncBatch(payload: payload, destination: configuration.destination)
        let result = try await APIClient(session: apiSession, maxAttempts: 1).upload(batch: batch, configuration: configuration)
        guard result.ok else { throw APIClientError.invalidResponse }
        let host = UploadConfiguration.host(of: configuration.destination)
        try await store.appendLog(
            SyncLogEntry(level: .success, message: "Connection to \(host) accepted (\(result.received) received, \(result.duplicates) duplicates).")
        )
    }

    func syncLast24Hours() async {
        let end = Date()
        let start = end.addingTimeInterval(-24 * 60 * 60)
        await runBusy(stoppable: true) { [self] in
            let uploaded = try await syncDateRangeThrowing(start: start, end: end)
            actionFeedback = uploaded ? .syncCompleted : .noSamples
        }
    }

    func backfill(start: Date, end: Date, mode: BackfillDataMode = .dailySummary) async {
        guard end > start else { return }
        backfillProgress = 0
        backfillError = nil
        await runBusy(stoppable: true) { [self] in
            let chunks = BackfillSync.chunks(start: start, end: end)
            let total = Double(chunks.count)
            var uploadedAny = false
            for (index, chunk) in chunks.enumerated() {
                do {
                    guard let store else { throw APIClientError.invalidResponse }
                    let configuration = try await uploadConfiguration()
                    try await ensureHealthPermissionsRequested()
                    let deviceID = try await store.deviceID()
                    try await healthKit.forEachBackfillBatch(
                        types: approvedTypes, start: chunk.start, end: chunk.end, mode: mode
                    ) { fetchResult in
                        let uploaded = try await self.uploadFetchResult(
                            fetchResult, deviceID: deviceID, start: chunk.start, end: chunk.end,
                            configuration: configuration
                        )
                        uploadedAny = uploadedAny || uploaded
                    }
                } catch {
                    if !Task.isCancelled {
                        backfillError = userMessage(from: error)
                    }
                    throw error
                }
                backfillProgress = min(1, Double(index + 1) / total)
            }
            if !uploadedAny {
                try await store?.appendLog(SyncLogEntry(level: .info, message: HealthSyncUserMessages.noSamplesFoundForDateRange))
            }
            backfillProgress = 1
            await refresh()
        }
    }

    @discardableResult
    func syncIncremental() async -> Bool {
        guard !isSavingSettings else { return false }
        guard BusyOperation.canStart(isBusy: isBusy) else {
            return await withCheckedContinuation { continuation in
                pendingIncrementalWaiters.append(continuation)
            }
        }

        var succeeded = false
        await runBusy(stoppable: true) { [self] in
            try await syncIncrementalThrowing()
            succeeded = true
        }
        return succeeded
    }

    /// Cancels the current sync or backfill and waits for it to end. Already queued batches
    /// stay in the pending queue, and incremental sync requests waiting on this run are dropped.
    func stopSync() async {
        guard canStopSync, let busyOperation else { return }
        isStoppingSync = true
        busyOperation.cancel()
        await busyOperation.value
    }

    /// Discards queued batches that have not been uploaded, for example after
    /// changing destination or narrowing the selected data types.
    func clearPendingQueue() async {
        await runBusy { [self] in
            guard let store else { throw APIClientError.invalidResponse }
            let cleared = try await store.clearPendingBatches()
            let message = "Cleared pending queue: discarded \(PendingQueueLabel.records(cleared.records)) in \(PendingQueueLabel.batches(cleared.batches))."
            try await store.appendLog(SyncLogEntry(level: .info, message: message))
            actionFeedback = HealthActionFeedback(kind: .info, message: message)
        }
    }

    func retryPendingQueue() async {
        await runBusy(stoppable: true) { [self] in
            guard let incrementalSyncRunner else { throw APIClientError.invalidResponse }
            let configuration = try await uploadConfiguration()
            let result = try await incrementalSyncRunner.retryAllPending(configuration: configuration)
            try Task.checkCancellation()
            if result.failedCount > 0 {
                try BackfillSync.validateUpload(result)
            }
            actionFeedback = result.uploadedCount > 0
                ? HealthActionFeedback(kind: .success, message: "Pending uploads completed.")
                : HealthActionFeedback(kind: .info, message: "No pending uploads for this destination.")
        }
    }

    /// Manual only pauses automatic sync at once; other cadences apply with "Apply frequency".
    func setSyncFrequency(_ frequency: SyncFrequency) async {
        guard !isSavingSettings else { return }
        settings.syncFrequency = frequency
        guard frequency == .manualOnly else { return }
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        backgroundSchedulingTask?.cancel()
        backgroundSyncScheduler.cancel()
        await healthKit.stopObserverQueries(disabling: Set(HealthDataType.allCases))
        await applySyncFrequency()
    }

    func applySyncFrequency() async {
        guard let store, !isSavingSettings else { return }
        isSavingSettings = true
        defer { isSavingSettings = false }
        do {
            let frequency = settings.syncFrequency
            try await store.updateSettings { $0.syncFrequency = frequency }
            backendFeedback = HealthActionFeedback(kind: .success, message: "Background sync frequency saved.")
            await startObserversIfPossible()
            backgroundSchedulingTask?.cancel()
            backgroundSyncScheduler.cancel()
            restartPeriodicSync()
        } catch {
            backendFeedback = .failure(userMessage(from: error))
        }
    }

    func performBackgroundSync() async {
        await bootstrap()
        restartPeriodicSync()
        await backgroundSchedulingTask?.value
        guard !Task.isCancelled else { return }
        await syncAutomatically()
    }

    func sceneDidBecomeActive() async {
        await bootstrap()
        restartPeriodicSync()
        await syncAutomatically()
    }

    func sceneDidEnterBackground() {
        restartPeriodicSync()
    }

    private func syncAutomatically() async {
        guard canRunAutomaticSync else { return }
        _ = await syncIncremental()
    }

    private func syncIncrementalThrowing() async throws {
        guard let incrementalSyncRunner else { throw APIClientError.invalidResponse }
        try Task.checkCancellation()
        let configuration = try await uploadConfiguration()
        try await ensureHealthPermissionsRequested()
        try await incrementalSyncRunner.run(types: approvedTypes, configuration: configuration)
        await refresh()
    }

    private func syncDateRangeThrowing(
        start: Date,
        end: Date
    ) async throws -> Bool {
        guard let store else { throw APIClientError.invalidResponse }
        let configuration = try await uploadConfiguration()
        try await ensureHealthPermissionsRequested()
        let fetchResult = try await healthKit.fetchSamples(types: approvedTypes, start: start, end: end)
        let uploaded = try await uploadFetchResult(
            fetchResult, deviceID: try await store.deviceID(), start: start, end: end,
            configuration: configuration
        )
        if !uploaded {
            try await store.appendLog(SyncLogEntry(level: .info, message: HealthSyncUserMessages.noSamplesFoundForDateRange))
        }
        await refresh()
        return uploaded
    }

    // Shared by recent exports and streaming history; each page is queued and
    // acknowledged before the next HealthKit page is requested.
    private func uploadFetchResult(
        _ fetchResult: HealthKitFetchResult, deviceID: String, start: Date, end: Date,
        configuration: UploadConfiguration
    ) async throws -> Bool {
        guard let syncEngine else { throw APIClientError.invalidResponse }
        let payload = try normalizer.payload(
            deviceID: deviceID,
            dateRange: SyncDateRange(start: start, end: end),
            timezone: TimeZone.current.identifier,
            quantitySamples: fetchResult.quantitySamples,
            sleepSamples: fetchResult.sleepSamples,
            categorySamples: fetchResult.categorySamples,
            workoutSamples: fetchResult.workoutSamples
        )
        guard BackfillSync.shouldUpload(payload) else { return false }
        for uploadPayload in BackfillSync.uploadPayloads(for: payload) {
            try Task.checkCancellation()
            let batch = try await syncEngine.queue(payload: uploadPayload, destination: configuration.destination)
            let result = await syncEngine.uploadQueuedBatch(batch, configuration: configuration)
            try BackfillSync.validateUpload(result)
        }
        return true
    }

    private func saveHealthSelection(_ types: Set<HealthDataType>) async throws {
        guard let store else { throw APIClientError.invalidResponse }
        try await store.saveHealthSelection(types)
        approvedTypes = types
        settings.hasRequestedHealthPermissions = true
    }

    private func ensureHealthPermissionsRequested() async throws {
        guard !settings.hasRequestedHealthPermissions else { return }
        try await healthKit.requestReadPermissions(for: approvedTypes)
        try Task.checkCancellation()
        try await saveHealthSelection(approvedTypes)
        shouldShowOnboarding = false
        permissionSummary = "Requested"
        await startObserversIfPossible()
        restartPeriodicSync()
    }

    private func uploadConfiguration() async throws -> UploadConfiguration {
        guard let store else { throw APIClientError.invalidResponse }
        guard let mode = settings.storageMode else { throw APIClientError.noStorageDestination }
        let baseURL = settings.effectiveBackendURL
        _ = try APIClient.validatedRootURL(from: baseURL)
        guard let token = try readUploadToken(for: mode), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIClientError.missingToken
        }
        return UploadConfiguration(
            baseURL: baseURL,
            token: token,
            deviceID: try await store.deviceID(),
            appVersion: Self.appVersion
        )
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func readUploadToken(for mode: StorageMode) throws -> String? {
        let id = mode == .customBackend ? settings.customTokenID : settings.hostedIngestTokenID
        if let id { return try keychain.readUploadToken(id: id) }
        // The old custom credential had no trustworthy binding to its separately saved URL.
        return mode == .hostedHealthSync ? try keychain.readHostedIngestToken() : nil
    }

    private func hasTokenForCurrentStorageMode() throws -> Bool {
        guard let mode = settings.storageMode else { return false }
        let token = try readUploadToken(for: mode)
        return !(token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startObserversIfPossible() async {
        guard settings.hasRequestedHealthPermissions else {
            await healthKit.stopObserverQueries()
            return
        }
        guard settings.syncFrequency != .manualOnly, hasUsableUploadConfiguration() else {
            await healthKit.stopObserverQueries(disabling: Set(HealthDataType.allCases))
            return
        }
        do {
            try await healthKit.startObserverQueries(
                types: approvedTypes,
                frequency: settings.syncFrequency
            ) { [weak self] _ in
                await self?.syncAutomatically()
            }
        } catch {
            lastError = userMessage(from: error)
        }
    }

    private func restartPeriodicSync() {
        periodicSyncTask?.cancel()
        backgroundSchedulingTask?.cancel()
        guard canRunAutomaticSync, let interval = settings.syncFrequency.intervalSeconds else {
            backgroundSyncScheduler.cancel()
            return
        }
        let frequency = settings.syncFrequency
        backgroundSchedulingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await backgroundSyncScheduler.scheduleIfNeeded(for: frequency)
            } catch where !Task.isCancelled {
                let message = "iOS could not schedule the next background sync: \(error.localizedDescription)"
                try? await store?.appendLog(SyncLogEntry(level: .error, message: message))
            } catch {
                // A newer scheduling request superseded this one.
            }
        }
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled else { return }
                // Restarting the timer must not cancel a sync it already started.
                await Task { await self?.syncAutomatically() }.value
            }
        }
    }

    private func hasUsableUploadConfiguration() -> Bool {
        guard settings.storageMode != nil,
              (try? APIClient.validatedRootURL(from: settings.effectiveBackendURL)) != nil else {
            return false
        }
        return (try? hasTokenForCurrentStorageMode()) == true
    }

    private var canRunAutomaticSync: Bool {
        settings.hasRequestedHealthPermissions
            && settings.syncFrequency != .manualOnly
            && hasUsableUploadConfiguration()
    }

    /// Runs `operation` as the busy operation in a stored task so `stopSync()` can cancel it.
    /// Cancelling the calling task (for example, at background task expiry) cancels it quietly.
    /// `stoppable` marks a sync or backfill that the user can stop.
    private func runBusy(stoppable: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) async {
        guard !isSavingSettings, BusyOperation.canStart(isBusy: isBusy) else { return }
        isBusy = true
        canStopSync = stoppable
        lastError = nil
        actionFeedback = nil
        let task = Task { @MainActor in
            await self.performBusyOperation(operation)
        }
        busyOperation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performBusyOperation(_ operation: () async throws -> Void) async {
        defer {
            let waiters = pendingIncrementalWaiters
            pendingIncrementalWaiters.removeAll()
            let shouldRerun = BusyOperation.shouldRerunPendingSync(
                hasWaiters: !waiters.isEmpty, stopRequested: isStoppingSync
            )
            isBusy = false
            busyOperation = nil
            canStopSync = false
            isStoppingSync = false
            if shouldRerun {
                Task { @MainActor [weak self] in
                    let succeeded = await self?.syncIncremental() ?? false
                    waiters.forEach { $0.resume(returning: succeeded) }
                }
            } else {
                waiters.forEach { $0.resume(returning: false) }
            }
        }
        do {
            try await operation()
        } catch where !Task.isCancelled && !(error is CancellationError) {
            let message = userMessage(from: error)
            lastError = message
            actionFeedback = .failure(message)
            try? await store?.appendLog(SyncLogEntry(level: .error, message: message))
        } catch {
            // Cancellation alone is not a user stop.
        }
        await refresh()
        if isStoppingSync {
            actionFeedback = .syncStopped
            try? await store?.appendLog(SyncLogEntry(level: .info, message: "Sync stopped."))
            await refresh()
        }
    }

    private func userMessage(from error: Error) -> String {
        if let apiError = error as? APIClientError {
            return apiError.userMessage
        }
        return error.localizedDescription
    }
}
