import XCTest
import HealthKit
import SwiftUI
@testable import HealthSync

final actor SyncEngineTestsStore: BatchPersisting {
    private(set) var batches: [SyncBatch] = []
    private(set) var logs: [SyncLogEntry] = []
    private(set) var lastAttemptedSyncAt: Date?
    private(set) var lastSuccessfulSyncAt: Date?

    func enqueueBatch(_ batch: SyncBatch) async throws {
        batches.append(batch)
    }

    func pendingBatches() async throws -> [SyncBatch] {
        batches.filter { $0.uploadedAt == nil }
    }

    func markBatchUploaded(id: UUID, result: UploadResult) async throws {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        batches[index].uploadedAt = Date()
        batches[index].lastError = nil
    }

    func markBatchFailed(id: UUID, errorMessage: String, attemptedAt: Date) async throws {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        batches[index].attemptCount += 1
        batches[index].lastError = errorMessage
    }

    func appendLog(_ log: SyncLogEntry) async throws {
        logs.append(log)
    }

    func recordSyncAttempt(at date: Date) async throws {
        lastAttemptedSyncAt = date
    }

    func recordSyncSuccess(at date: Date) async throws {
        lastSuccessfulSyncAt = date
    }
}

final actor FailingUploader: SyncUploading {
    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        throw APIClientError.transientFailure("network unavailable")
    }
}

final actor SucceedingUploader: SyncUploading {
    private(set) var uploadedIDs: [UUID] = []

    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        uploadedIDs.append(batch.id)
        return UploadResult(ok: true, received: batch.payload.metrics.count + batch.payload.workouts.count, duplicates: 0)
    }
}

final actor FailingForDateRangeStartUploader: SyncUploading {
    let failingStart: Date
    private(set) var uploadedIDs: [UUID] = []

    init(failingStart: Date) {
        self.failingStart = failingStart
    }

    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        uploadedIDs.append(batch.id)
        if batch.payload.dateRange.start == failingStart {
            throw APIClientError.transientFailure("old batch failed")
        }
        return UploadResult(ok: true, received: batch.payload.metrics.count + batch.payload.workouts.count, duplicates: 0)
    }
}

final actor PausingUploader: SyncUploading {
    private(set) var uploadCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        uploadCount += 1
        resumeSatisfiedWaiters()
        await withCheckedContinuation { continuation in
            releases.append(continuation)
        }
        return UploadResult(ok: true, received: batch.payload.metrics.count + batch.payload.workouts.count, duplicates: 0)
    }

    func waitForUploadCount(_ count: Int) async {
        if uploadCount >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func releaseUploads() {
        let pending = releases
        releases.removeAll()
        pending.forEach { $0.resume() }
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if uploadCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

/// Holds every upload open until the calling task is cancelled, like a stalled request.
final actor StallingUploader: SyncUploading {
    private(set) var attempts = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        attempts += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return UploadResult(ok: true, received: batch.payload.metrics.count, duplicates: 0)
    }

    func waitUntilUploadStarts() async {
        if attempts > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

final class SyncEngineTests: XCTestCase {
    func testNegativeAcknowledgementKeepsBatchQueued() async throws {
        let store = SyncEngineTestsStore()
        let engine = SyncEngine(store: store, uploader: NegativeAcknowledgementUploader())
        let batch = try await engine.queue(payload: .empty(deviceID: "device", dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC"), destination: "https://example.com")
        let result = await engine.uploadPending(configuration: UploadConfiguration(baseURL: "https://example.com", token: "token", deviceID: "device", appVersion: "1.0"))
        let pending = try await store.pendingBatches()
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(pending.map(\.id), [batch.id])
    }

    func testCancellationStopsBeforeAttemptingQueuedBatches() async throws {
        let store = SyncEngineTestsStore()
        let uploader = SucceedingUploader()
        let engine = SyncEngine(store: store, uploader: uploader)
        _ = try await engine.queue(payload: .empty(deviceID: "device", dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC"), destination: "https://example.com")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.uploadPending(configuration: UploadConfiguration(baseURL: "https://example.com", token: "token", deviceID: "device", appVersion: "1.0"))
        }
        _ = await task.value
        let uploadedIDs = await uploader.uploadedIDs
        let pending = try await store.pendingBatches()
        XCTAssertTrue(uploadedIDs.isEmpty)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attemptCount, 0)
    }

    func testStopDuringUploadEndsPromptlyAndLeavesEveryBatchQueued() async throws {
        let store = SyncEngineTestsStore()
        let uploader = StallingUploader()
        let engine = SyncEngine(store: store, uploader: uploader)
        for _ in 0..<3 {
            _ = try await engine.queue(payload: .empty(deviceID: "device", dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC"), destination: "https://example.com")
        }
        let startedAt = Date()
        let task = Task {
            await engine.uploadPending(configuration: UploadConfiguration(baseURL: "https://example.com", token: "token", deviceID: "device", appVersion: "1.0"))
        }
        await uploader.waitUntilUploadStarts()
        task.cancel()
        let result = await task.value

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
        XCTAssertEqual(result.uploadedCount, 0)
        XCTAssertEqual(result.messages, ["Sync cancelled. Queued uploads will retry."])
        let attempts = await uploader.attempts
        XCTAssertEqual(attempts, 1)
        let pending = try await store.pendingBatches()
        XCTAssertEqual(pending.count, 3)
        XCTAssertTrue(pending.allSatisfy { $0.attemptCount == 0 && $0.lastError == nil })
    }

    func testBusyOperationRejectsSecondStart() {
        XCTAssertTrue(BusyOperation.canStart(isBusy: false))
        XCTAssertFalse(BusyOperation.canStart(isBusy: true))
    }

    func testPendingSyncIsDroppedOnlyForUserStop() async {
        XCTAssertFalse(BusyOperation.shouldRerunPendingSync(hasWaiters: false, stopRequested: false))
        XCTAssertTrue(BusyOperation.shouldRerunPendingSync(hasWaiters: true, stopRequested: false))

        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            XCTAssertTrue(BusyOperation.shouldRerunPendingSync(hasWaiters: true, stopRequested: false))
            XCTAssertFalse(BusyOperation.shouldRerunPendingSync(hasWaiters: true, stopRequested: true))
        }.value
    }

    func testFailedUploadKeepsBatchQueuedForRetry() async throws {
        let store = SyncEngineTestsStore()
        let engine = SyncEngine(store: store, uploader: FailingUploader())
        let payload = SyncPayload.empty(
            deviceID: "device-123",
            dateRange: SyncDateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60)),
            timezone: "Asia/Kolkata"
        )

        let batch = try await engine.queue(payload: payload, destination: "https://example.com")
        let result = await engine.uploadPending(
            configuration: UploadConfiguration(baseURL: "https://example.com", token: "secret-token", deviceID: "device-123", appVersion: "1.0")
        )
        let pending = try await store.pendingBatches()

        XCTAssertEqual(result.uploadedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(pending.map(\.id), [batch.id])
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertFalse((pending.first?.lastError ?? "").contains("secret-token"))
    }

    func testSuccessfulUploadMarksBatchUploadedAndAvoidsResending() async throws {
        let store = SyncEngineTestsStore()
        let uploader = SucceedingUploader()
        let engine = SyncEngine(store: store, uploader: uploader)
        let payload = SyncPayload.empty(
            deviceID: "device-123",
            dateRange: SyncDateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60)),
            timezone: "Asia/Kolkata"
        )

        let batch = try await engine.queue(payload: payload, destination: "https://example.com")
        _ = await engine.uploadPending(
            configuration: UploadConfiguration(baseURL: "https://example.com", token: "secret-token", deviceID: "device-123", appVersion: "1.0")
        )
        _ = await engine.uploadPending(
            configuration: UploadConfiguration(baseURL: "https://example.com", token: "secret-token", deviceID: "device-123", appVersion: "1.0")
        )

        let uploadedIDs = await uploader.uploadedIDs
        let pending = try await store.pendingBatches()
        let lastSuccessfulSyncAt = await store.lastSuccessfulSyncAt

        XCTAssertEqual(uploadedIDs, [batch.id])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNotNil(lastSuccessfulSyncAt)
    }

    func testUploadingSpecificBackfillBatchDoesNotRetryOlderPendingFailures() async throws {
        let store = SyncEngineTestsStore()
        let staleStart = Date(timeIntervalSince1970: 0)
        let currentStart = Date(timeIntervalSince1970: 60)
        let uploader = FailingForDateRangeStartUploader(failingStart: staleStart)
        let engine = SyncEngine(store: store, uploader: uploader)
        let stalePayload = SyncPayload.empty(
            deviceID: "device-123",
            dateRange: SyncDateRange(start: staleStart, end: currentStart),
            timezone: "Asia/Kolkata"
        )
        let currentPayload = SyncPayload.empty(
            deviceID: "device-123",
            dateRange: SyncDateRange(start: currentStart, end: Date(timeIntervalSince1970: 120)),
            timezone: "Asia/Kolkata"
        )
        let staleBatch = try await engine.queue(payload: stalePayload, destination: "https://example.com")
        let currentBatch = try await engine.queue(payload: currentPayload, destination: "https://example.com")

        let result = await engine.uploadQueuedBatch(
            currentBatch,
            configuration: UploadConfiguration(baseURL: "https://example.com", token: "secret-token", deviceID: "device-123", appVersion: "1.0")
        )

        let uploadedIDs = await uploader.uploadedIDs
        let pending = try await store.pendingBatches()

        XCTAssertEqual(result.uploadedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(uploadedIDs, [currentBatch.id])
        XCTAssertEqual(pending.map(\.id), [staleBatch.id])
    }

    func testSuccessfulUploadLogIncludesWorkspaceWhenBackendReturnsIt() async throws {
        let store = SyncEngineTestsStore()
        let engine = SyncEngine(store: store, uploader: WorkspaceIdentifyingUploader())
        let payload = SyncPayload.empty(
            deviceID: "device-123",
            dateRange: SyncDateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60)),
            timezone: "Asia/Kolkata"
        )

        _ = try await engine.queue(payload: payload, destination: "https://example.com")
        _ = await engine.uploadPending(
            configuration: UploadConfiguration(baseURL: "https://example.com", token: "secret-token", deviceID: "device-123", appVersion: "1.0")
        )

        let logs = await store.logs
        XCTAssertTrue(logs.contains { $0.message.contains("workspace wk_test") })
        XCTAssertFalse(logs.contains { $0.message.contains("secret-token") })
    }

    func testConcurrentUploadPendingDoesNotUploadSameBatchTwice() async throws {
        let store = SyncEngineTestsStore()
        let uploader = PausingUploader()
        let engine = SyncEngine(store: store, uploader: uploader)
        let payload = SyncPayload.empty(
            deviceID: "device-123",
            dateRange: SyncDateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60)),
            timezone: "Asia/Kolkata"
        )

        try await engine.queue(payload: payload, destination: "https://example.com")
        let firstRun = Task {
            await engine.uploadPending(
                configuration: UploadConfiguration(baseURL: "https://example.com", token: "secret-token", deviceID: "device-123", appVersion: "1.0")
            )
        }
        await uploader.waitForUploadCount(1)

        let secondRun = Task {
            await engine.uploadPending(
                configuration: UploadConfiguration(baseURL: "https://example.com", token: "secret-token", deviceID: "device-123", appVersion: "1.0")
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let uploadCountWhileFirstRunIsActive = await uploader.uploadCount
        await uploader.releaseUploads()
        let firstResult = await firstRun.value
        let secondResult = await secondRun.value

        XCTAssertEqual(uploadCountWhileFirstRunIsActive, 1)
        XCTAssertEqual(firstResult.uploadedCount, 1)
        XCTAssertEqual(secondResult.uploadedCount, 0)
    }

    func testBackgroundScheduleUsesConfiguredBestEffortCadence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(BackgroundSyncSchedule.earliestBeginDate(for: .manualOnly, now: now))
        XCTAssertEqual(
            BackgroundSyncSchedule.earliestBeginDate(for: .hourlyBestEffort, now: now),
            now.addingTimeInterval(60 * 60)
        )
        XCTAssertEqual(
            BackgroundSyncSchedule.earliestBeginDate(for: .dailyBestEffort, now: now),
            now.addingTimeInterval(24 * 60 * 60)
        )
    }
}

private actor NegativeAcknowledgementUploader: SyncUploading {
    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        UploadResult(ok: false, received: 0, duplicates: 0)
    }
}

final class BackfillSyncTests: XCTestCase {
    func testLargeBackfillPayloadSplitsIntoServerSizedUploads() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 60)
        let metrics = (0..<205).map { index in
            HealthMetric(
                id: "healthkit:metric-\(index)",
                type: "step_count",
                value: Double(index),
                unit: "count",
                startAt: start,
                endAt: end,
                sourceName: "Codex",
                sourceBundleID: nil,
                metadata: [:]
            )
        }
        let payload = SyncPayload(
            deviceID: "device-123",
            exportID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            generatedAt: start,
            timezone: "Asia/Kolkata",
            source: "ios-healthkit",
            schemaVersion: 1,
            dateRange: SyncDateRange(start: start, end: end),
            metrics: metrics,
            workouts: []
        )

        let chunks = BackfillSync.uploadPayloads(for: payload)

        XCTAssertEqual(chunks.map(\.metrics.count), [100, 100, 5])
        XCTAssertTrue(chunks.allSatisfy(\.workouts.isEmpty))
        XCTAssertEqual(Set(chunks.map(\.exportID)).count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.dateRange == payload.dateRange })
    }

    func testDeletionOnlyPayloadIsUploadableAndChunked() {
        let payload = SyncPayload(
            deviceID: "device-123",
            exportID: UUID(),
            generatedAt: Date(timeIntervalSince1970: 0),
            timezone: "Asia/Kolkata",
            source: "ios-healthkit",
            schemaVersion: 2,
            dateRange: SyncDateRange(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 60)
            ),
            metrics: [],
            workouts: [],
            deletions: (0..<205).map {
                HealthRecordDeletion(id: "healthkit:deleted-\($0)", kind: $0.isMultiple(of: 2) ? .metric : .workout)
            }
        )

        let chunks = payload.chunked(maxRecords: 100)

        XCTAssertFalse(payload.isEmpty)
        XCTAssertEqual(chunks.map(\.deletions.count), [100, 100, 5])
        XCTAssertTrue(chunks.allSatisfy(\.metrics.isEmpty))
        XCTAssertTrue(chunks.allSatisfy(\.workouts.isEmpty))
    }

    func testEmptyBackfillPayloadDoesNotNeedUpload() {
        let payload = SyncPayload.empty(
            deviceID: "device-123",
            dateRange: SyncDateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60)),
            timezone: "Asia/Kolkata"
        )

        XCTAssertFalse(BackfillSync.shouldUpload(payload))
    }

    func testBusyUploaderDoesNotAcknowledgeAnUnuploadedPage() {
        XCTAssertThrowsError(try BackfillSync.validateUpload(.empty))
        XCTAssertNoThrow(try BackfillSync.validateUpload(SyncRunResult(uploadedCount: 1, failedCount: 0, messages: [])))
    }

    func testBackfillUploadFailureThrowsInsteadOfAllowingSuccess() {
        let result = SyncRunResult(
            uploadedCount: 0,
            failedCount: 1,
            messages: ["Cannot connect to the backend."]
        )

        XCTAssertThrowsError(try BackfillSync.validateUpload(result)) { error in
            XCTAssertEqual(error.localizedDescription, "Cannot connect to the backend.")
        }
    }

    func testBackfillUsesMonthSizedChunksForOptimizedHistoricalUploads() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 17))!

        let chunks = BackfillSync.chunks(start: start, end: end)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].start, start)
        XCTAssertEqual(chunks[0].end, calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!)
        XCTAssertEqual(chunks[1].end, calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!)
        XCTAssertEqual(chunks[2].end, end)
    }
}

final actor WorkspaceIdentifyingUploader: SyncUploading {
    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        UploadResult(
            ok: true,
            received: batch.payload.metrics.count + batch.payload.workouts.count,
            duplicates: 0,
            workspaceID: "wk_test",
            exportID: batch.payload.exportID.uuidString
        )
    }
}

private actor MaintenanceHealthReader: HealthKitSyncReading {
    var incremental: HealthKitIncrementalResult
    var raw: HealthKitFetchResult = .empty
    var readError = false
    private(set) var rawRequests: [(Set<HealthDataType>, Date, Date)] = []
    private(set) var receivedAnchors: [[HealthDataType: String]] = []

    init(incremental: HealthKitIncrementalResult = HealthKitIncrementalResult(fetchResult: .empty, anchors: [:], deletions: [])) {
        self.incremental = incremental
    }

    func setRaw(_ result: HealthKitFetchResult, fail: Bool = false) {
        raw = result
        readError = fail
    }

    func fetchIncremental(types: Set<HealthDataType>, anchors: [HealthDataType: String]) async throws -> HealthKitIncrementalResult {
        receivedAnchors.append(anchors)
        let result = incremental
        incremental = HealthKitIncrementalResult(fetchResult: .empty, anchors: [:], deletions: [])
        return result
    }

    func fetchSamples(types: Set<HealthDataType>, start: Date, end: Date) async throws -> HealthKitFetchResult {
        rawRequests.append((types, start, end))
        if readError { throw URLError(.notConnectedToInternet) }
        return raw
    }
}

private actor MaintenanceUploader: SyncUploading {
    private(set) var payloads: [SyncPayload] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }

    func upload(batch: SyncBatch, configuration: UploadConfiguration) async throws -> UploadResult {
        payloads.append(batch.payload)
        if fails { throw URLError(.timedOut) }
        return UploadResult(ok: true, received: batch.payload.metrics.count + batch.payload.workouts.count, duplicates: 0)
    }
}

final class IncrementalMaintenanceTests: XCTestCase {
    private let configuration = UploadConfiguration(baseURL: "https://example.com", token: "token", deviceID: "existing-device", appVersion: "1.0.1")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_792_166_400)

    private func databaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Maintenance-\(UUID()).sqlite")
    }

    private func samples(_ count: Int) -> HealthKitFetchResult {
        HealthKitFetchResult(quantitySamples: (0..<count).map { index in
            HealthQuantitySampleDTO(uuid: UUID(), type: .stepCount, value: Double(index), unit: .count,
                startAt: now.addingTimeInterval(-60), endAt: now, sourceName: "Mi Fitness",
                sourceBundleIdentifier: "com.example.fitness", metadata: [:])
        }, categorySamples: [], sleepSamples: [], workoutSamples: [])
    }

    func testStopCancelsIncrementalRunMidUploadWithoutMarkingBatchesFailed() async throws {
        let store = try SQLiteLocalStore(url: databaseURL())
        let reader = MaintenanceHealthReader(incremental: HealthKitIncrementalResult(
            fetchResult: samples(205), anchors: [.stepCount: "after-read"], deletions: []))
        let uploader = StallingUploader()
        let runner = IncrementalSyncRunner(store: store, reader: reader, uploader: uploader)
        let startedAt = Date()
        let task = Task {
            try await runner.run(types: [.stepCount], configuration: configuration, now: now, calendar: calendar)
        }
        await uploader.waitUntilUploadStarts()
        task.cancel()
        let result = await task.result

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let attempts = await uploader.attempts
        XCTAssertEqual(attempts, 1)
        let pending = try await store.pendingBatches()
        XCTAssertEqual(pending.map(\.payload.metrics.count).sorted(), [5, 100, 100])
        XCTAssertTrue(pending.allSatisfy { $0.attemptCount == 0 })
    }

    func testFreshDeletionSuppressesOldAdditionWhileRetainingUnrelatedQueuedData() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        let oldSamples = samples(2)
        let oldPayload = try HealthNormalizer().payload(deviceID: configuration.deviceID,
            dateRange: SyncDateRange(start: now, end: now), timezone: "UTC",
            quantitySamples: oldSamples.quantitySamples, sleepSamples: [], workoutSamples: [])
        try await store.enqueueBatch(SyncBatch(payload: oldPayload, destination: "https://example.com", attemptCount: 2))
        let deletedID = oldPayload.metrics[0].id
        let reader = MaintenanceHealthReader(incremental: HealthKitIncrementalResult(fetchResult: .empty,
            anchors: [.heartRate: "after-delete"], deletions: [HealthRecordDeletion(id: deletedID, kind: .metric)]))
        do {
            try await IncrementalSyncRunner(store: store, reader: reader, uploader: MaintenanceUploader(fails: true))
                .run(types: [.heartRate], configuration: configuration, now: now, calendar: calendar)
            XCTFail("The failed deletion must remain queued")
        } catch {}
        let reopened = try SQLiteLocalStore(url: url)
        let pending = try await reopened.pendingBatches()
        XCTAssertFalse(pending.flatMap { $0.payload.metrics }.contains { $0.id == deletedID })
        XCTAssertTrue(pending.flatMap { $0.payload.metrics }.contains { $0.id == oldPayload.metrics[1].id })
        XCTAssertEqual(pending.flatMap { $0.payload.deletions }.map(\.id), [deletedID])
        let uploader = MaintenanceUploader()
        try await IncrementalSyncRunner(store: reopened, reader: MaintenanceHealthReader(), uploader: uploader)
            .run(types: [.heartRate], configuration: configuration, now: now.addingTimeInterval(15 * 60), calendar: calendar)
        let retried = await uploader.payloads
        XCTAssertFalse(retried.flatMap(\.metrics).contains { $0.id == deletedID })
        let remaining = try await reopened.pendingBatches()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testNewerSampleCannotBeOverwrittenByAnOlderPendingSnapshot() async throws {
        let store = try SQLiteLocalStore(url: databaseURL())
        let old = samples(1).quantitySamples[0]
        let oldPayload = try HealthNormalizer().payload(deviceID: configuration.deviceID,
            dateRange: SyncDateRange(start: now, end: now), timezone: "UTC", quantitySamples: [old], sleepSamples: [], workoutSamples: [])
        try await store.enqueueBatch(SyncBatch(payload: oldPayload, destination: "https://example.com", attemptCount: 2))
        let newer = HealthQuantitySampleDTO(uuid: old.uuid, type: old.type, value: 999, unit: old.unit,
            startAt: old.startAt, endAt: old.endAt, sourceName: old.sourceName,
            sourceBundleIdentifier: old.sourceBundleIdentifier, metadata: [:])
        let reader = MaintenanceHealthReader(incremental: HealthKitIncrementalResult(
            fetchResult: HealthKitFetchResult(quantitySamples: [newer], categorySamples: [], sleepSamples: [], workoutSamples: []),
            anchors: [:], deletions: []))
        let uploader = MaintenanceUploader()
        try await IncrementalSyncRunner(store: store, reader: reader, uploader: uploader)
            .run(types: [.heartRate], configuration: configuration, now: now, calendar: calendar)
        let payloads = await uploader.payloads
        XCTAssertEqual(payloads.flatMap(\.metrics).map(\.value), [999])
    }

    func testFreshIncrementalIsChunkedBeforeStaleRetryAndAnchorsSurviveRestart() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        let stale = SyncBatch(payload: .empty(deviceID: configuration.deviceID, dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC"), destination: "https://example.com", attemptCount: 2)
        try await store.enqueueBatch(stale)
        let reader = MaintenanceHealthReader(incremental: HealthKitIncrementalResult(fetchResult: samples(205), anchors: [.stepCount: "new-anchor"], deletions: [HealthRecordDeletion(id: "healthkit:deleted", kind: .metric)]))
        let uploader = MaintenanceUploader()
        let runner = IncrementalSyncRunner(store: store, reader: reader, uploader: uploader)
        try await runner.run(types: [.stepCount], configuration: configuration, now: now, calendar: calendar)
        let payloads = await uploader.payloads
        XCTAssertEqual(payloads.prefix(3).map(\.metrics.count), [100, 100, 5])
        XCTAssertEqual(payloads[3].deletions.count, 1)
        XCTAssertEqual(payloads.last?.exportID, stale.payload.exportID)
        XCTAssertTrue(payloads.allSatisfy { $0.metrics.count + $0.workouts.count + $0.deletions.count <= 100 })
        let reopened = try SQLiteLocalStore(url: url)
        let anchor = try await reopened.loadAnchor(for: .stepCount)
        let pending = try await reopened.pendingBatches()
        XCTAssertEqual(anchor, "new-anchor")
        XCTAssertTrue(pending.isEmpty)
    }

    func testTimeoutKeepsEveryChunkAndReplaysSameExportAfterRestart() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        let reader = MaintenanceHealthReader(incremental: HealthKitIncrementalResult(fetchResult: samples(205), anchors: [.heartRate: "saved-anchor"], deletions: []))
        let failing = MaintenanceUploader(fails: true)
        do {
            try await IncrementalSyncRunner(store: store, reader: reader, uploader: failing).run(types: [.heartRate], configuration: configuration, now: now, calendar: calendar)
            XCTFail("A timed-out upload must remain visibly unsuccessful")
        } catch {}
        let attempted = await failing.payloads
        let pending = try await store.pendingBatches()
        XCTAssertEqual(attempted.count, 1)
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending.reduce(0) { $0 + $1.payload.metrics.count }, 205)
        let reopened = try SQLiteLocalStore(url: url)
        let succeeding = MaintenanceUploader()
        let resumedReader = MaintenanceHealthReader()
        try await IncrementalSyncRunner(store: reopened, reader: resumedReader, uploader: succeeding).run(types: [.heartRate], configuration: configuration, now: now.addingTimeInterval(15 * 60), calendar: calendar)
        let replayed = await succeeding.payloads
        let receivedAnchors = await resumedReader.receivedAnchors
        let remaining = try await reopened.pendingBatches()
        XCTAssertTrue(replayed.contains { $0.exportID == attempted.first?.exportID })
        XCTAssertEqual(receivedAnchors.first?[.heartRate], "saved-anchor")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRollingReadPreservesSourceAndRunsOncePerLocalDayAcrossRestart() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        let reader = MaintenanceHealthReader()
        let raw = samples(1)
        await reader.setRaw(raw)
        let uploader = MaintenanceUploader()
        try await IncrementalSyncRunner(store: store, reader: reader, uploader: uploader).run(types: [.stepCount, .sleepAnalysis, .workouts, .heartRate], configuration: configuration, now: now, calendar: calendar)
        let reopened = try SQLiteLocalStore(url: url)
        let runner = IncrementalSyncRunner(store: reopened, reader: reader, uploader: uploader)
        try await runner.run(types: [.stepCount, .sleepAnalysis, .workouts, .heartRate], configuration: configuration, now: now.addingTimeInterval(3600), calendar: calendar)
        let requests = await reader.rawRequests
        let sent = await uploader.payloads
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, [.stepCount, .sleepAnalysis, .workouts])
        XCTAssertEqual(requests.first?.1, calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(sent.first?.metrics.first?.id, "healthkit:\(raw.quantitySamples[0].uuid.uuidString)")
        XCTAssertEqual(sent.first?.metrics.first?.sourceName, "Mi Fitness")
        XCTAssertEqual(sent.first?.metrics.first?.sourceBundleID, "com.example.fitness")
        try await runner.run(types: [.stepCount], configuration: configuration, now: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar)
        let nextRequests = await reader.rawRequests
        XCTAssertEqual(nextRequests.count, 2)
    }

    func testFailedReconciliationDoesNotRepeatOnEveryWake() async throws {
        let store = try SQLiteLocalStore(url: databaseURL())
        let reader = MaintenanceHealthReader()
        await reader.setRaw(.empty, fail: true)
        let runner = IncrementalSyncRunner(store: store, reader: reader, uploader: MaintenanceUploader())
        do {
            try await runner.run(types: [.stepCount], configuration: configuration, now: now, calendar: calendar)
            XCTFail("Read error must be surfaced")
        } catch {}
        try await runner.run(types: [.stepCount], configuration: configuration, now: now.addingTimeInterval(3600), calendar: calendar)
        let requests = await reader.rawRequests
        XCTAssertEqual(requests.count, 1)
    }

    func testFailedReconciliationUploadsPendingBatchBeforeRethrowingReadError() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        let batch = SyncBatch(payload: .empty(deviceID: configuration.deviceID,
            dateRange: SyncDateRange(start: now, end: now), timezone: "UTC"), destination: "https://example.com", attemptCount: 2)
        try await store.enqueueBatch(batch)
        let reader = MaintenanceHealthReader()
        await reader.setRaw(.empty, fail: true)
        let uploader = MaintenanceUploader()
        let runner = IncrementalSyncRunner(store: store, reader: reader, uploader: uploader)

        do {
            try await runner.run(types: [.stepCount], configuration: configuration, now: now, calendar: calendar)
            XCTFail("Read error must be surfaced after retrying pending uploads")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        let reopened = try SQLiteLocalStore(url: url)
        let pending = try await reopened.pendingBatches()
        XCTAssertTrue(pending.isEmpty)
        let payloads = await uploader.payloads
        XCTAssertEqual(payloads.map(\.exportID), [batch.payload.exportID])
        try await IncrementalSyncRunner(store: reopened, reader: reader, uploader: uploader)
            .run(types: [.stepCount], configuration: configuration, now: now.addingTimeInterval(3600), calendar: calendar)
        let requests = await reader.rawRequests
        XCTAssertEqual(requests.count, 1)
    }

    func testFailedReconciliationPreservesReadErrorWhenPendingRetryFails() async throws {
        let store = try SQLiteLocalStore(url: databaseURL())
        let batch = SyncBatch(payload: .empty(deviceID: configuration.deviceID,
            dateRange: SyncDateRange(start: now, end: now), timezone: "UTC"), destination: "https://example.com", attemptCount: 2)
        try await store.enqueueBatch(batch)
        let reader = MaintenanceHealthReader()
        await reader.setRaw(.empty, fail: true)
        let uploader = MaintenanceUploader(fails: true)
        let runner = IncrementalSyncRunner(store: store, reader: reader, uploader: uploader)

        do {
            try await runner.run(types: [.stepCount], configuration: configuration, now: now, calendar: calendar)
            XCTFail("Read error must be preserved when retrying also fails")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        let pending = try await store.pendingBatches()
        XCTAssertEqual(pending.map(\.id), [batch.id])
        XCTAssertEqual(pending.first?.attemptCount, 3)
        try await runner.run(types: [.stepCount], configuration: configuration, now: now.addingTimeInterval(60), calendar: calendar)
        let payloads = await uploader.payloads
        XCTAssertEqual(payloads.map(\.exportID), [batch.payload.exportID])
    }

    func testBacklogRetriesMultipleBatchesTheSameDayWithDurableCooldown() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        for index in 0..<4 {
            try await store.enqueueBatch(SyncBatch(payload: .empty(deviceID: configuration.deviceID, dateRange: SyncDateRange(start: now, end: now), timezone: "UTC"), destination: "https://example.com", createdAt: now.addingTimeInterval(Double(index)), attemptCount: 2))
        }
        let reader = MaintenanceHealthReader()
        let uploader = MaintenanceUploader(fails: true)
        let runner = IncrementalSyncRunner(store: store, reader: reader, uploader: uploader)
        do { try await runner.run(types: [.heartRate], configuration: configuration, now: now, calendar: calendar) } catch {}
        let firstRun = await uploader.payloads
        XCTAssertEqual(firstRun.count, 3)

        let reopened = try SQLiteLocalStore(url: url)
        let succeeding = MaintenanceUploader()
        let resumed = IncrementalSyncRunner(store: reopened, reader: reader, uploader: succeeding)
        try await resumed.run(types: [.heartRate], configuration: configuration, now: now.addingTimeInterval(60), calendar: calendar)
        let secondRun = await succeeding.payloads
        XCTAssertEqual(secondRun.count, 1)
        XCTAssertFalse(firstRun.contains { $0.exportID == secondRun.first?.exportID })

        try await resumed.run(types: [.heartRate], configuration: configuration, now: now.addingTimeInterval(15 * 60), calendar: calendar)
        let recovered = await succeeding.payloads
        let pending = try await reopened.pendingBatches()
        XCTAssertEqual(Set(recovered.dropFirst().map(\.exportID)), Set(firstRun.map(\.exportID)))
        XCTAssertTrue(pending.isEmpty)
    }

    func testFailedNewUploadStillDrainsOlderQueuedBatches() async throws {
        let store = try SQLiteLocalStore(url: databaseURL())
        let payload = SyncPayload.empty(deviceID: configuration.deviceID,
            dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC")
        let unattempted = SyncBatch(payload: payload, destination: configuration.destination, createdAt: .distantPast)
        let failed = SyncBatch(payload: .empty(deviceID: configuration.deviceID, dateRange: payload.dateRange, timezone: "UTC"),
            destination: configuration.destination, createdAt: .distantPast, attemptCount: 2)
        try await store.enqueueBatch(unattempted)
        try await store.enqueueBatch(failed)
        let reader = MaintenanceHealthReader(incremental: HealthKitIncrementalResult(fetchResult: samples(1), anchors: [:], deletions: []))
        let uploader = FailingForDateRangeStartUploader(failingStart: now)
        let runner = IncrementalSyncRunner(store: store, reader: reader, uploader: uploader)

        do {
            try await runner.run(types: [.heartRate], configuration: configuration, now: now, calendar: calendar)
            XCTFail("New upload failure must remain visible")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("old batch failed"))
        }

        let attempted = await uploader.uploadedIDs
        let remaining = try await store.pendingBatches()
        XCTAssertEqual(Array(attempted.dropFirst()), [unattempted.id, failed.id])
        XCTAssertEqual(remaining.map(\.id), Array(attempted.prefix(1)))
    }
}


final class PagedBackfillQueueTests: XCTestCase {
    func testFailedRawPageIsDurableAndStopsReadingUntilRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backfill.sqlite")
        let store = try SQLiteLocalStore(url: url)
        let engine = SyncEngine(store: store, uploader: FailingUploader())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(60)
        let samples = (0..<100).map { _ in
            HKQuantitySample(type: HKQuantityType(.oxygenSaturation), quantity: HKQuantity(unit: .percent(), doubleValue: 0.97), start: start, end: start)
        }
        var reads = 0
        let manager = HealthKitManager(backfillPageReader: { _, _, _, _ in
            reads += 1
            return .init(samples: samples, deletedCount: 0, anchor: HKQueryAnchor(fromValue: reads))
        })
        let configuration = UploadConfiguration(baseURL: "https://example.com", token: "fixture-token", deviceID: "fixture", appVersion: "1.0")
        do {
            try await manager.forEachBackfillBatch(types: [.oxygenSaturation], start: start, end: end, mode: .rawSamples) { page in
                let payload = try HealthNormalizer().payload(deviceID: "fixture", dateRange: SyncDateRange(start: start, end: end), timezone: "UTC",
                    quantitySamples: page.quantitySamples, sleepSamples: [], workoutSamples: [])
                for upload in BackfillSync.uploadPayloads(for: payload) {
                    let queued = try await engine.queue(payload: upload, destination: "https://example.com")
                    try BackfillSync.validateUpload(await engine.uploadQueuedBatch(queued, configuration: configuration))
                }
            }
            XCTFail("Failed upload must stop pagination")
        } catch { XCTAssertTrue(error is BackfillSyncError) }
        XCTAssertEqual(reads, 1)
        let reopened = try SQLiteLocalStore(url: url)
        let pending = try await reopened.pendingBatches()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].payload.metrics.count, 100)
        XCTAssertEqual(Set(pending[0].payload.metrics.map(\.id)), Set(samples.map { "healthkit:\($0.uuid.uuidString)" }))
        let retry = SyncEngine(store: reopened, uploader: SucceedingUploader())
        let result = await retry.uploadPending(configuration: configuration)
        XCTAssertEqual(result.uploadedCount, 1)
        let remaining = try await reopened.pendingBatches()
        XCTAssertTrue(remaining.isEmpty)
    }
}

final class UploadDestinationContractTests: XCTestCase {
    private let hosted = AppSettings.hostedBackendURL
    private let own = UploadConfiguration(baseURL: "https://mine.example/", token: "token", deviceID: "device", appVersion: "1.0")

    private func emptyPayload() -> SyncPayload {
        .empty(deviceID: "device", dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC")
    }

    func testBatchesOnlyUploadToTheDestinationTheyWereQueuedForAndLogTheHost() async throws {
        let store = SyncEngineTestsStore()
        let uploader = SucceedingUploader()
        let engine = SyncEngine(store: store, uploader: uploader)
        let hostedBatch = try await engine.queue(payload: emptyPayload(), destination: hosted)

        let pendingRun = await engine.uploadPending(configuration: own)
        let directRun = await engine.uploadQueuedBatch(hostedBatch, configuration: own)

        let uploadedAfterSwitch = await uploader.uploadedIDs
        XCTAssertTrue(uploadedAfterSwitch.isEmpty)
        XCTAssertEqual(pendingRun.uploadedCount, 0)
        XCTAssertEqual(directRun.failedCount, 1)
        let stillQueued = try await store.pendingBatches()
        XCTAssertEqual(stillQueued.map(\.id), [hostedBatch.id])

        let ownBatch = try await engine.queue(payload: emptyPayload(), destination: own.destination)
        let ownRun = await engine.uploadPending(configuration: own)
        let uploaded = await uploader.uploadedIDs
        let logs = await store.logs.map(\.message)
        XCTAssertEqual(ownRun.uploadedCount, 1)
        XCTAssertEqual(uploaded, [ownBatch.id])
        XCTAssertTrue(logs.contains { $0.hasPrefix("Uploaded batch \(ownBatch.payload.exportID.uuidString) to mine.example ") }, "\(logs)")
        XCTAssertTrue(logs.contains { $0.contains("queued for api.healthysync.app") }, "\(logs)")
        XCTAssertTrue(logs.contains { $0.hasSuffix("for api.healthysync.app.") && $0.hasPrefix("Queued ") }, "\(logs)")
    }

    func testIncrementalRetryNeverSendsBatchesQueuedForAnotherDestination() async throws {
        let store = try SQLiteLocalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("Destination-\(UUID()).sqlite"))
        let hostedBatch = SyncBatch(payload: emptyPayload(), destination: hosted)
        try await store.enqueueBatch(hostedBatch)
        let uploader = MaintenanceUploader()

        try await IncrementalSyncRunner(store: store, reader: MaintenanceHealthReader(), uploader: uploader)
            .run(types: [.heartRate], configuration: own)

        let sent = await uploader.payloads
        let pending = try await store.pendingBatches()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(pending.map(\.id), [hostedBatch.id])
    }
}

private final class NetworkRecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [String] = []
    static var requests: [String] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request.url?.absoluteString ?? "") }
        guard let url = request.url else { return }
        let body: String
        switch (url.host, url.path) {
        case ("stall.example", _): return // The active sync stays in flight until Save stops it.
        case ("reject.example", _): body = #"{"ok":false,"received":0,"duplicates":0}"#
        case ("mine.example", _): body = #"{"ok":true,"received":0,"duplicates":0}"#
        case ("api.healthysync.app", "/api/hosted/agent-token"):
            body = #"{"workspace_id":"existing","agent_endpoint":"https://api.healthysync.app/api/agent/health-data","agent_token":"refreshed"}"#
        case ("api.healthysync.app", "/api/hosted/workspaces/reset"):
            body = #"{"workspace_id":"replacement","backend_url":"https://api.healthysync.app","agent_endpoint":"https://api.healthysync.app/api/agent/health-data","ingest_token":"replacement-ingest","agent_token":"replacement-agent"}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MemoryKeychain: TokenProviding {
    var tokens: [UUID: String] = [:]
    var hostedIngestToken: String?
    var hostedAgentToken: String?

    func readUploadToken(id: UUID) -> String? { tokens[id] }
    func saveUploadToken(_ token: String, id: UUID) { tokens[id] = token }
    func deleteUploadToken(id: UUID) { tokens[id] = nil }
    func readHostedIngestToken() -> String? { hostedIngestToken }
    func readHostedAgentToken() -> String? { hostedAgentToken }
    func saveHostedAgentToken(_ token: String) { hostedAgentToken = token }
}

@MainActor
final class StorageOptInAppStateTests: XCTestCase {
    private let customTokenID = UUID()

    override func setUp() {
        super.setUp()
        NetworkRecordingURLProtocol.reset()
    }

    private func databaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OptIn-\(UUID()).sqlite")
    }

    private func makeAppState(databaseURL: URL, keychain: MemoryKeychain = MemoryKeychain()) -> AppState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkRecordingURLProtocol.self]
        return AppState(storeURL: databaseURL, keychain: keychain, apiSession: URLSession(configuration: configuration))
    }

    private func pendingBatch(for destination: String) -> SyncBatch {
        SyncBatch(payload: .empty(deviceID: "device", dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC"),
                  destination: destination)
    }

    private func syncReadySettings(mode: StorageMode?, backendURL: String = "") -> AppSettings {
        var settings = AppSettings.default
        settings.storageMode = mode
        settings.backendURL = backendURL
        settings.customTokenID = mode == .customBackend ? customTokenID : nil
        settings.hasRequestedHealthPermissions = true
        // Retry a queued batch without depending on any Health samples on the simulator.
        settings.selectedTypes = []
        return settings
    }

    func testFreshInstallNeverProvisionsOrUploadsBeforeChoosingStorage() async throws {
        let url = databaseURL()
        let appState = makeAppState(databaseURL: url)
        await appState.bootstrap()
        XCTAssertNil(appState.settings.storageMode)

        await appState.connectAppleHealth()
        XCTAssertEqual(appState.lastError, APIClientError.noStorageDestination.userMessage)
        XCTAssertFalse(appState.settings.hasRequestedHealthPermissions)

        await appState.syncLast24Hours()
        await appState.backfill(start: Date().addingTimeInterval(-3 * 24 * 60 * 60), end: Date())
        let synced = await appState.syncIncremental()
        XCTAssertFalse(synced)

        XCTAssertEqual(NetworkRecordingURLProtocol.requests, [])
        XCTAssertNil(appState.settings.storageMode)
        XCTAssertFalse(appState.hasChosenStorageDestination)
        XCTAssertEqual(appState.lastError, APIClientError.noStorageDestination.userMessage)
        let reopened = try SQLiteLocalStore(url: url)
        let saved = try await reopened.loadSettings()
        XCTAssertNil(saved.storageMode)
        let pending = try await reopened.pendingBatches()
        XCTAssertNil(saved.hostedWorkspaceID)
        XCTAssertTrue(pending.isEmpty)
    }

    func testManualRetryUploadsCoolingDownBatchWithoutHealthKitAccess() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        var settings = syncReadySettings(mode: .customBackend, backendURL: "https://mine.example")
        settings.syncFrequency = .manualOnly
        settings.hasRequestedHealthPermissions = false
        try await store.saveSettings(settings)
        let batch = pendingBatch(for: "https://mine.example")
        try await store.enqueueBatch(batch)
        try await store.markBatchFailed(id: batch.id, errorMessage: "Timed out", attemptedAt: Date())
        let keychain = MemoryKeychain()
        keychain.tokens[customTokenID] = "confirmed-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()
        await appState.sceneDidBecomeActive()
        XCTAssertTrue(NetworkRecordingURLProtocol.requests.isEmpty)

        await appState.retryPendingQueue()

        XCTAssertEqual(NetworkRecordingURLProtocol.requests, ["https://mine.example/api/apple-health/sync"])
        XCTAssertEqual(appState.status.pendingUploadCount, 0)
        XCTAssertEqual(appState.actionFeedback?.message, "Pending uploads completed.")
        XCTAssertFalse(appState.settings.hasRequestedHealthPermissions)
    }

    func testAutomaticSyncDoesNotStartWithoutDestinationEvenWithHealthAccess() async throws {
        let url = databaseURL()
        let seed = try SQLiteLocalStore(url: url)
        try await seed.saveSettings(syncReadySettings(mode: nil))
        try await seed.enqueueBatch(pendingBatch(for: AppSettings.hostedBackendURL))
        let keychain = MemoryKeychain()
        keychain.hostedIngestToken = "old-hosted-token"

        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()
        appState.sceneDidEnterBackground()
        await appState.performBackgroundSync()
        await appState.sceneDidBecomeActive()
        XCTAssertTrue(appState.settings.hasRequestedHealthPermissions)
        XCTAssertNil(appState.lastError)
        XCTAssertNil(appState.status.lastAttemptedSyncAt)
        XCTAssertEqual(NetworkRecordingURLProtocol.requests, [])
    }

    func testSelectingHostedDraftAndApplyingFrequencyNeverUploadsToHosted() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        try await store.saveSettings(syncReadySettings(mode: .customBackend, backendURL: "https://mine.example"))
        try await store.enqueueBatch(pendingBatch(for: "https://mine.example"))
        try await store.enqueueBatch(pendingBatch(for: AppSettings.hostedBackendURL))
        let keychain = MemoryKeychain()
        keychain.tokens[customTokenID] = "custom-token"
        keychain.hostedIngestToken = "old-hosted-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()

        var modeDraft: StorageMode?
        let menu = SettingsStorageModeMenu(appState: appState, draft: Binding(get: { modeDraft }, set: { modeDraft = $0 }))
        menu.select(.hostedHealthSync)
        _ = await appState.syncIncremental()
        await appState.sceneDidBecomeActive()
        await appState.setSyncFrequency(.dailyBestEffort)
        await appState.applySyncFrequency()
        await appState.performBackgroundSync()

        XCTAssertEqual(modeDraft, .hostedHealthSync)
        XCTAssertEqual(NetworkRecordingURLProtocol.requests, ["https://mine.example/api/apple-health/sync"])
        XCTAssertEqual(appState.settings.storageMode, .customBackend)
        let persisted = try await store.loadSettings()
        XCTAssertEqual(persisted.storageMode, .customBackend)
        XCTAssertEqual(persisted.syncFrequency, .dailyBestEffort)

        let confirmed = await appState.useHostedStorage()
        XCTAssertTrue(confirmed)
        let hosted = try await store.loadSettings()
        XCTAssertEqual(hosted.storageMode, .hostedHealthSync)
        XCTAssertEqual(NetworkRecordingURLProtocol.requests, ["https://mine.example/api/apple-health/sync"])
    }

    func testOwnBackendNegativeAcknowledgementDoesNotSaveDestination() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        try await store.saveSettings(syncReadySettings(mode: .customBackend, backendURL: "https://mine.example"))
        try await store.enqueueBatch(pendingBatch(for: "https://mine.example"))
        let keychain = MemoryKeychain()
        keychain.tokens[customTokenID] = "original-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()

        let savedWithoutToken = await appState.useOwnBackend(backendURL: "https://reject.example", tokenDraft: "")
        XCTAssertFalse(savedWithoutToken)
        XCTAssertEqual(NetworkRecordingURLProtocol.requests, [])
        let saved = await appState.useOwnBackend(backendURL: "https://reject.example", tokenDraft: "test-token")
        XCTAssertFalse(saved)
        XCTAssertEqual(NetworkRecordingURLProtocol.requests, ["https://reject.example/api/apple-health/sync"])
        XCTAssertEqual(appState.lastError, APIClientError.invalidResponse.userMessage)
        XCTAssertEqual(appState.backendFeedback?.kind, .error)
        await appState.applySyncFrequency()
        let persisted = try await store.loadSettings()
        XCTAssertEqual(persisted.backendURL, "https://mine.example")
        XCTAssertEqual(persisted.customTokenID, customTokenID)
        XCTAssertEqual(keychain.tokens[customTokenID], "original-token")
        XCTAssertEqual(appState.status.pendingUploadCount, 1)
    }

    func testChangingOnlyTheBearerRetiresTheOldQueueAndRequiresTheCommittedKeychainItem() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        let endpoint = "https://mine.example"
        try await store.saveSettings(syncReadySettings(mode: .customBackend, backendURL: endpoint))
        try await store.enqueueBatch(pendingBatch(for: endpoint))
        let keychain = MemoryKeychain()
        keychain.tokens[customTokenID] = "original-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()

        let unchanged = await appState.useOwnBackend(backendURL: endpoint, tokenDraft: "")
        XCTAssertTrue(unchanged)
        XCTAssertEqual(appState.status.pendingUploadCount, 1)

        let replaced = await appState.useOwnBackend(backendURL: endpoint, tokenDraft: "replacement-token")
        XCTAssertTrue(replaced)
        XCTAssertEqual(appState.status.pendingUploadCount, 0)
        let saved = try await store.loadSettings()
        let id = try XCTUnwrap(saved.customTokenID)
        XCTAssertEqual(keychain.tokens[id], "replacement-token")
        XCTAssertNil(keychain.tokens[customTokenID])

        keychain.tokens[id] = nil
        keychain.tokens[UUID()] = "uncommitted-token"
        let relaunched = makeAppState(databaseURL: url, keychain: keychain)
        NetworkRecordingURLProtocol.reset()
        await relaunched.bootstrap()
        let synced = await relaunched.syncIncremental()
        XCTAssertFalse(synced)
        XCTAssertEqual(relaunched.lastError, APIClientError.missingToken.userMessage)
        XCTAssertTrue(NetworkRecordingURLProtocol.requests.isEmpty)
    }

    func testSavingNoneRemovesPendingSamplesWithoutRequestingHealthAccess() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        var settings = syncReadySettings(mode: .customBackend, backendURL: "https://mine.example")
        settings.selectedTypes = [.heartRate]
        settings.syncFrequency = .manualOnly
        try await store.saveSettings(settings)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HealthMetric(id: "sample", type: HealthDataType.heartRate.rawValue, value: 75, unit: "count/min",
            startAt: date, endAt: date, sourceName: "Fixture", sourceBundleID: nil, metadata: [:])
        let payload = SyncPayload(deviceID: "device", exportID: UUID(), generatedAt: date, timezone: "UTC",
            source: "ios-healthkit", schemaVersion: 1, dateRange: SyncDateRange(start: date, end: date),
            metrics: [sample], workouts: [])
        try await store.enqueueBatch(SyncBatch(payload: payload, destination: settings.backendURL))
        let keychain = MemoryKeychain()
        keychain.tokens[customTokenID] = "fixture-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()

        appState.set(type: .heartRate, enabled: false)
        await appState.connectAppleHealth()
        let saved = try await store.loadSettings()
        XCTAssertTrue(saved.selectedTypes.isEmpty)
        XCTAssertEqual(appState.status.pendingUploadCount, 0)
        XCTAssertTrue(NetworkRecordingURLProtocol.requests.isEmpty)
    }

    func testSwitchingDestinationDiscardsBatchesQueuedForThePreviousOneInsteadOfSendingThem() async throws {
        let url = databaseURL()
        let seed = try SQLiteLocalStore(url: url)
        var settings = AppSettings.default
        settings.storageMode = .hostedHealthSync
        try await seed.saveSettings(settings)
        try await seed.enqueueBatch(pendingBatch(for: AppSettings.hostedBackendURL))

        let appState = makeAppState(databaseURL: url)
        await appState.bootstrap()
        XCTAssertEqual(appState.status.pendingUploadCount, 1)

        let saved = await appState.useOwnBackend(backendURL: "https://mine.example", tokenDraft: "custom-token")
        XCTAssertTrue(saved)

        XCTAssertEqual(appState.status.pendingUploadCount, 0)
        XCTAssertTrue(appState.logs.contains { $0.message.hasPrefix("Discarded 1 queued uploads") && $0.message.contains("mine.example") })
        XCTAssertEqual(NetworkRecordingURLProtocol.requests, ["https://mine.example/api/apple-health/sync"])
    }

    func testSaveAndTestStayResponsiveDuringAnActiveSync() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        try await store.saveSettings(syncReadySettings(mode: .customBackend, backendURL: "https://stall.example"))
        try await store.enqueueBatch(pendingBatch(for: "https://stall.example"))
        let keychain = MemoryKeychain()
        keychain.tokens[customTokenID] = "original-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()
        let sync = Task { await appState.syncIncremental() }
        defer { sync.cancel() }
        for _ in 0..<200 where NetworkRecordingURLProtocol.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(NetworkRecordingURLProtocol.requests, ["https://stall.example/api/apple-health/sync"])
        XCTAssertTrue(appState.canStopSync)

        await appState.testConnection(backendURL: "https://mine.example", tokenDraft: "new-token")
        XCTAssertEqual(appState.backendFeedback?.kind, .success)
        XCTAssertTrue(appState.canStopSync)
        let beforeSave = try await store.loadSettings()
        XCTAssertEqual(beforeSave.backendURL, "https://stall.example")

        let saved = await appState.useOwnBackend(backendURL: "https://mine.example", tokenDraft: "new-token")
        XCTAssertTrue(saved)
        XCTAssertFalse(appState.canStopSync)
        let persisted = try await store.loadSettings()
        XCTAssertEqual(persisted.backendURL, "https://mine.example")
        XCTAssertEqual(persisted.customTokenID.flatMap { keychain.tokens[$0] }, "new-token")
        XCTAssertEqual(appState.status.pendingUploadCount, 0)
        XCTAssertTrue(appState.backendFeedback?.message.contains("running sync was stopped") == true)
    }

    func testRefreshingHostedAgentTokenDoesNotSwitchDestination() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        try await store.saveSettings(syncReadySettings(mode: .customBackend, backendURL: "https://mine.example"))
        let keychain = MemoryKeychain()
        keychain.hostedIngestToken = "old-hosted-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()
        await appState.refreshHostedAgentToken()

        XCTAssertEqual(keychain.hostedAgentToken, "refreshed")
        let saved = try await store.loadSettings()
        XCTAssertEqual(saved.storageMode, .customBackend)
        XCTAssertEqual(appState.settings.storageMode, .customBackend)
    }

    func testConfirmedHostedResetClearsPendingUploadsEvenForTheSameEndpoint() async throws {
        let url = databaseURL()
        let store = try SQLiteLocalStore(url: url)
        try await store.saveSettings(syncReadySettings(mode: .hostedHealthSync))
        try await store.enqueueBatch(pendingBatch(for: AppSettings.hostedBackendURL))
        let keychain = MemoryKeychain()
        keychain.hostedIngestToken = "old-hosted-token"
        let appState = makeAppState(databaseURL: url, keychain: keychain)
        await appState.bootstrap()
        await appState.resetHostedStorage()
        XCTAssertEqual(appState.settings.hostedWorkspaceID, "replacement")
        XCTAssertEqual(appState.status.pendingUploadCount, 0)
        XCTAssertTrue(appState.logs.contains { $0.message.contains("won't be re-sent") })
    }
}
