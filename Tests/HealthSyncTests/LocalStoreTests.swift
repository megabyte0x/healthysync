import XCTest
import SQLite3
@testable import HealthSync

final class LocalStoreTests: XCTestCase {
    func testLegacyHostedSettingsMoveToCloudflareAndPersistWithoutResettingLocalState() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        var original = AppSettings.default
        original.storageMode = .hostedHealthSync
        original.backendURL = "https://dtzydnjnqkruxaacgkio.supabase.co/functions/v1/healthsync"
        original.hostedAgentEndpoint = original.backendURL + "/api/agent/health-data?limit=50&tag=a%2Fb"
        original.hostedWorkspaceID = "wk_existing_migration_fixture"
        original.selectedTypes = [.stepCount, .heartRate]
        original.syncFrequency = .manualOnly
        original.hasRequestedHealthPermissions = true
        try await store.saveSettings(original)
        let deviceID = try await store.deviceID()
        try await store.saveAnchor("existing-anchor", for: .stepCount)
        let queued = legacyBatch()
        try await store.enqueueBatch(queued)

        var expected = original
        expected.backendURL = "https://api.healthysync.app"
        expected.hostedAgentEndpoint = "https://api.healthysync.app/api/agent/health-data?limit=50&tag=a%2Fb"
        let migrated = try await store.loadSettings()
        XCTAssertEqual(migrated, expected)
        XCTAssertEqual(try persistedSettings(at: url), expected)

        let reopened = try SQLiteLocalStore(url: url)
        let afterRestart = try await reopened.loadSettings()
        let restoredDeviceID = try await reopened.deviceID()
        let restoredAnchor = try await reopened.loadAnchor(for: .stepCount)
        let restoredQueue = try await reopened.pendingBatches()
        XCTAssertEqual(afterRestart, expected)
        XCTAssertEqual(restoredDeviceID, deviceID)
        XCTAssertEqual(restoredAnchor, "existing-anchor")
        XCTAssertEqual(restoredQueue, [queued])
    }

    func testLegacyAgentPathsAndEncodedFiltersMigrateButUnrelatedEndpointsDoNot() async throws {
        let store = try SQLiteLocalStore(url: temporaryDatabaseURL())
        let old = "https://dtzydnjnqkruxaacgkio.supabase.co/functions/v1/healthsync"
        for path in ["health-data", "metrics", "workouts", "syncs"] {
            var settings = AppSettings.default
            settings.hostedAgentEndpoint = old + "/api/agent/\(path)?from=2026-10-01&tag=a%2Fb#details"
            try await store.saveSettings(settings)
            let migrated = try await store.loadSettings()
            XCTAssertEqual(migrated.hostedAgentEndpoint, "https://api.healthysync.app/api/agent/\(path)?from=2026-10-01&tag=a%2Fb#details")
        }
        for endpoint in [
            "https://my-server.example/api/agent/health-data",
            "https://another-project.supabase.co/functions/v1/healthsync/api/agent/health-data",
            old + "/api/agent/health-data-other",
            old + "/api/hosted/agent-token",
            "https://user:password@dtzydnjnqkruxaacgkio.supabase.co/functions/v1/healthsync/api/agent/health-data",
            "https://api.healthysync.app/api/agent/health-data"
        ] {
            var settings = AppSettings.default
            settings.hostedAgentEndpoint = endpoint
            try await store.saveSettings(settings)
            let unchanged = try await store.loadSettings()
            XCTAssertEqual(unchanged, settings)
        }
    }

    func testSettingsMigrationKeepsCredentialsUsableWhenPersistenceFailsAndRetriesOnReload() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        var original = AppSettings.default
        original.backendURL = "https://dtzydnjnqkruxaacgkio.supabase.co/functions/v1/healthsync"
        original.hostedAgentEndpoint = original.backendURL + "/api/agent/health-data"
        original.hostedWorkspaceID = "wk_existing_migration_fixture"
        try await store.saveSettings(original)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_migration BEFORE UPDATE ON settings WHEN NEW.key='app_settings' BEGIN SELECT RAISE(ABORT, 'disk write failed'); END", nil, nil, nil), SQLITE_OK)

        let usable = try await store.loadSettings()
        XCTAssertEqual(usable.backendURL, "https://api.healthysync.app")
        XCTAssertEqual(usable.hostedAgentEndpoint, "https://api.healthysync.app/api/agent/health-data")
        XCTAssertEqual(usable.hostedWorkspaceID, original.hostedWorkspaceID)
        XCTAssertEqual(try persistedSettings(at: url), original)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_migration", nil, nil, nil), SQLITE_OK)
        let retried = try await store.loadSettings()
        XCTAssertEqual(retried, usable)
        XCTAssertEqual(try persistedSettings(at: url), usable)
    }

    private func persistedSettings(at url: URL) throws -> AppSettings {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteStoreError.encodingFailed }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key='app_settings'", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.encodingFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw SQLiteStoreError.encodingFailed
        }
        return try JSONDecoder().decode(AppSettings.self, from: Data(String(cString: text).utf8))
    }

    func testOversizedLegacyQueueIsReplacedAtomicallyAndChunksRemainStableAfterRestart() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        let original = legacyBatch()
        try await store.enqueueBatch(original)
        try await store.splitOversizedPendingBatches(maxRecords: 100)
        let chunks = try await store.pendingBatches()
        let reopened = try SQLiteLocalStore(url: url)
        try await reopened.splitOversizedPendingBatches(maxRecords: 100)
        let afterRestart = try await reopened.pendingBatches()

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(afterRestart, chunks)
        XCTAssertFalse(chunks.contains { $0.id == original.id })
        XCTAssertEqual(Set(chunks.flatMap { $0.payload.metrics.map(\.id) }), Set(original.payload.metrics.map(\.id)))
        XCTAssertTrue(chunks.allSatisfy { $0.payload.metrics.count <= 100 && $0.attemptCount == 0 })
        XCTAssertTrue(chunks.allSatisfy { $0.payload.deviceID == original.payload.deviceID && $0.payload.schemaVersion == 1 })
        XCTAssertTrue(chunks.flatMap { $0.payload.metrics }.allSatisfy { $0.sourceBundleID == "com.example.fitness" })
    }

    func testFailedLegacyQueueReplacementRollsBackEveryPartialChunk() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        let original = legacyBatch()
        try await store.enqueueBatch(original)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_chunk BEFORE INSERT ON batches WHEN (SELECT count(*) FROM batches) >= 2 BEGIN SELECT RAISE(ABORT, 'disk write failed'); END", nil, nil, nil), SQLITE_OK)

        do {
            try await store.splitOversizedPendingBatches(maxRecords: 100)
            XCTFail("A failed chunk write must abort the replacement")
        } catch {}
        let reopened = try SQLiteLocalStore(url: url)
        let pending = try await reopened.pendingBatches()
        XCTAssertEqual(pending, [original])
    }

    func testExistingLegacyDeletionWinsBeforeAttemptCountReordering() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        let original = legacyBatch()
        try await store.enqueueBatch(original)
        let deletion = SyncPayload(deviceID: original.payload.deviceID, exportID: UUID(), generatedAt: original.createdAt,
            timezone: "UTC", source: "ios-healthkit", schemaVersion: 2, dateRange: original.payload.dateRange,
            metrics: [], workouts: [], deletions: [HealthRecordDeletion(id: original.payload.metrics[0].id, kind: .metric)])
        let json = String(data: try PayloadJSON.encoder.encode(deletion), encoding: .utf8)!
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO batches (id, payload_json, created_at, uploaded_at, attempt_count, last_error, destination) VALUES (?, ?, ?, NULL, 1, 'Timed out', '\(original.destination)')", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, json, -1, transient)
        sqlite3_bind_double(statement, 3, original.createdAt.timeIntervalSince1970)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        try await store.splitOversizedPendingBatches(maxRecords: 100)
        let pending = try await store.pendingBatches()
        XCTAssertFalse(pending.flatMap { $0.payload.metrics }.contains { $0.id == original.payload.metrics[0].id })
        XCTAssertEqual(pending.flatMap { $0.payload.metrics }.count, 204)
        XCTAssertEqual(pending.flatMap { $0.payload.deletions }, deletion.deletions)
    }

    func testFailedSupersedingWriteRetainsOriginalPendingBatch() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        let original = legacyBatch()
        try await store.enqueueBatch(original)
        let metric = original.payload.metrics[0]
        let replacement = HealthMetric(id: metric.id, type: metric.type, value: 999, unit: metric.unit,
            startAt: metric.startAt, endAt: metric.endAt, sourceName: metric.sourceName,
            sourceBundleID: metric.sourceBundleID, metadata: ["test": "reject-new"])
        let newPayload = SyncPayload(deviceID: original.payload.deviceID, exportID: UUID(), generatedAt: metric.endAt,
            timezone: "UTC", source: "ios-healthkit", schemaVersion: 1, dateRange: original.payload.dateRange,
            metrics: [replacement], workouts: [])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_new BEFORE INSERT ON batches WHEN NEW.payload_json LIKE '%reject-new%' BEGIN SELECT RAISE(ABORT, 'disk write failed'); END", nil, nil, nil), SQLITE_OK)
        do {
            try await store.enqueueBatch(SyncBatch(payload: newPayload, destination: "https://example.com"))
            XCTFail("A failed replacement must leave the older data durable")
        } catch {}
        let reopened = try SQLiteLocalStore(url: url)
        let pending = try await reopened.pendingBatches()
        XCTAssertEqual(pending, [original])
    }

    func testDailyMaintenanceUsesCalendarDaysAcrossDaylightSavingTime() async throws {
        let store = try SQLiteLocalStore(url: temporaryDatabaseURL())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let first = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 30))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 30))!
        let firstClaim = try await store.claimDailyMaintenance("test", now: first, calendar: calendar)
        let sameDayClaim = try await store.claimDailyMaintenance("test", now: later, calendar: calendar)
        let nextDayClaim = try await store.claimDailyMaintenance("test", now: nextDay, calendar: calendar)
        XCTAssertTrue(firstClaim)
        XCTAssertFalse(sameDayClaim)
        XCTAssertTrue(nextDayClaim)
        XCTAssertEqual(nextDay.timeIntervalSince(first), 23 * 3600)
    }

    private func legacyBatch() -> SyncBatch {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let metrics = (0..<205).map { index in
            HealthMetric(id: "healthkit:\(index)", type: "step_count", value: Double(index), unit: "count",
                startAt: start, endAt: start, sourceName: "Mi Fitness", sourceBundleID: "com.example.fitness", metadata: [:])
        }
        return SyncBatch(payload: SyncPayload(deviceID: "existing-device", exportID: UUID(), generatedAt: start,
            timezone: "UTC", source: "ios-healthkit", schemaVersion: 1, dateRange: SyncDateRange(start: start, end: start),
            metrics: metrics, workouts: []), destination: "https://example.com", createdAt: start, attemptCount: 8, lastError: "Timed out")
    }

    func testFreshBatchesPrecedeFailedBatchesAndSurviveReopening() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        let payload = SyncPayload.empty(deviceID: "existing-device", dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC")
        let stale = SyncBatch(payload: payload, destination: "https://example.com", createdAt: Date(timeIntervalSince1970: 1), attemptCount: 2)
        let fresh = SyncBatch(payload: payload, destination: "https://example.com", createdAt: Date(timeIntervalSince1970: 2))
        try await store.enqueueBatch(stale)
        try await store.enqueueBatch(fresh)
        try await store.saveAnchor("existing-anchor", for: .workouts)
        let deviceID = try await store.deviceID()

        let reopened = try SQLiteLocalStore(url: url)
        let pending = try await reopened.pendingBatches()
        let anchor = try await reopened.loadAnchor(for: .workouts)
        let reopenedDeviceID = try await reopened.deviceID()

        XCTAssertEqual(pending.map(\.id), [fresh.id, stale.id])
        XCTAssertEqual(pending.last?.attemptCount, 2)
        XCTAssertEqual(pending.last?.payload.exportID, stale.payload.exportID)
        XCTAssertEqual(anchor, "existing-anchor")
        XCTAssertEqual(reopenedDeviceID, deviceID)
    }

    func testSyncStatusDoesNotShowStaleErrorAfterLaterSuccess() async throws {
        let store = try SQLiteLocalStore(url: temporaryDatabaseURL())
        try await store.appendLog(
            SyncLogEntry(
                level: .error,
                message: "Network unavailable"
            )
        )
        try await store.appendLog(
            SyncLogEntry(
                level: .success,
                message: "Uploaded batch"
            )
        )

        let status = try await store.syncStatus()

        XCTAssertNil(status.lastError)
    }

    func testSettingsPersistHostedStorageMode() async throws {
        let store = try SQLiteLocalStore(url: temporaryDatabaseURL())
        var settings = AppSettings.default
        settings.storageMode = .hostedHealthSync
        settings.hostedWorkspaceID = "wk_test"
        settings.hostedAgentEndpoint = "https://api.example.com/api/agent/health-data"

        try await store.saveSettings(settings)
        let loaded = try await store.loadSettings()

        XCTAssertEqual(loaded.storageMode, .hostedHealthSync)
        XCTAssertEqual(loaded.hostedWorkspaceID, "wk_test")
        XCTAssertEqual(loaded.hostedAgentEndpoint, "https://api.example.com/api/agent/health-data")
    }

    func testClearingPendingQueueRemovesOnlyUnsentBatchesAndCountsRecords() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func payload(metricIDs: [String], deletionIDs: [String] = []) -> SyncPayload {
            SyncPayload(deviceID: "existing-device", exportID: UUID(), generatedAt: start, timezone: "UTC",
                source: "ios-healthkit", schemaVersion: 1, dateRange: SyncDateRange(start: start, end: start),
                metrics: metricIDs.map {
                    HealthMetric(id: $0, type: "step_count", value: 1, unit: "count", startAt: start, endAt: start,
                        sourceName: "iPhone", sourceBundleID: nil, metadata: [:])
                },
                workouts: [],
                deletions: deletionIDs.map { HealthRecordDeletion(id: $0, kind: .metric) })
        }
        let uploaded = SyncBatch(payload: payload(metricIDs: ["uploaded:1", "uploaded:2", "uploaded:3"]),
            destination: AppSettings.hostedBackendURL)
        try await store.enqueueBatch(uploaded)
        try await store.markBatchUploaded(id: uploaded.id, result: UploadResult(ok: true, received: 3, duplicates: 0))
        try await store.enqueueBatch(legacyBatch())
        try await store.enqueueBatch(SyncBatch(payload: payload(metricIDs: [], deletionIDs: ["gone:1", "gone:2"]),
            destination: AppSettings.hostedBackendURL))
        try await store.saveAnchor("kept-anchor", for: .stepCount)

        let before = try await store.syncStatus()
        XCTAssertEqual(before.pendingUploadCount, 2)
        XCTAssertEqual(before.pendingRecordCount, 207)

        let cleared = try await store.clearPendingBatches()
        XCTAssertEqual(cleared.batches, 2)
        XCTAssertEqual(cleared.records, 207)

        let reopened = try SQLiteLocalStore(url: url)
        let pending = try await reopened.pendingBatches()
        let after = try await reopened.syncStatus()
        let anchor = try await reopened.loadAnchor(for: .stepCount)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(after.pendingUploadCount, 0)
        XCTAssertEqual(after.pendingRecordCount, 0)
        XCTAssertEqual(anchor, "kept-anchor")
        XCTAssertEqual(try storedBatchIDs(at: url), [uploaded.id.uuidString])
    }

    private func storedBatchIDs(at url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteStoreError.encodingFailed }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM batches", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.encodingFailed
        }
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            ids.append(String(cString: text))
        }
        return ids
    }

    func testUpgradeDropsUnboundPendingBatchesWithoutTouchingUploadedHistory() async throws {
        let url = temporaryDatabaseURL()
        var settings = AppSettings.default
        settings.storageMode = .hostedHealthSync
        let settingsJSON = String(data: try JSONEncoder().encode(settings), encoding: .utf8)!
        let payload = SyncPayload.empty(deviceID: "existing-device", dateRange: SyncDateRange(start: .distantPast, end: .distantPast), timezone: "UTC")
        let payloadJSON = String(data: try PayloadJSON.encoder.encode(payload), encoding: .utf8)!
        let uploadedID = UUID()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for sql in [
            "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE TABLE batches (id TEXT PRIMARY KEY, payload_json TEXT NOT NULL, created_at REAL NOT NULL, uploaded_at REAL, attempt_count INTEGER NOT NULL, last_error TEXT)",
            "INSERT INTO settings VALUES ('app_settings', '\(settingsJSON)')",
            "INSERT INTO batches VALUES ('\(UUID().uuidString)', '\(payloadJSON)', 1, NULL, 0, NULL)",
            "INSERT INTO batches VALUES ('\(uploadedID.uuidString)', '\(payloadJSON)', 2, 3, 0, NULL)"
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)

        let store = try SQLiteLocalStore(url: url)
        let migrated = try await store.pendingBatches()
        XCTAssertTrue(migrated.isEmpty)
        XCTAssertEqual(try storedBatchIDs(at: url), [uploadedID.uuidString])
        let restoredSettings = try await store.loadSettings()
        XCTAssertEqual(restoredSettings, settings)

        try await store.enqueueBatch(SyncBatch(payload: payload, destination: "https://mine.example"))
        let reopened = try SQLiteLocalStore(url: url)
        let remaining = try await reopened.pendingBatches()
        XCTAssertEqual(remaining.map(\.destination), ["https://mine.example"])
    }

    func testRetryMigrationPreservesPreviouslyBoundPendingUploads() async throws {
        let url = temporaryDatabaseURL()
        let batch = legacyBatch()
        let payload = String(decoding: try PayloadJSON.encoder.encode(batch.payload), as: UTF8.self)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for sql in [
            "CREATE TABLE batches (id TEXT PRIMARY KEY, payload_json TEXT NOT NULL, created_at REAL NOT NULL, uploaded_at REAL, attempt_count INTEGER NOT NULL, last_error TEXT, destination TEXT NOT NULL)",
            "INSERT INTO batches VALUES ('\(batch.id.uuidString)', '\(payload)', 1, NULL, 1, 'Timed out', '\(batch.destination)')",
            "PRAGMA user_version = 1"
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)

        let store = try SQLiteLocalStore(url: url)
        let eligible = try await store.pendingRetries(destination: batch.destination, failed: true, now: Date(), createdBefore: nil, limit: 3)
        XCTAssertEqual(eligible.map(\.id), [batch.id])
        XCTAssertEqual(eligible.first?.payload, batch.payload)
        XCTAssertEqual(eligible.first?.attemptCount, 1)
    }

    func testSavingNarrowerSelectionPermanentlyFiltersPendingSamplesButKeepsDeletions() async throws {
        let url = temporaryDatabaseURL()
        let store = try SQLiteLocalStore(url: url)
        var settings = AppSettings.default
        settings.selectedTypes = [.stepCount, .heartRate, .workouts]
        try await store.saveSettings(settings)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let deletion = HealthRecordDeletion(id: "old-workout", kind: .workout)
        let payload = SyncPayload(deviceID: "device", exportID: UUID(), generatedAt: date, timezone: "UTC",
            source: "ios-healthkit", schemaVersion: 1, dateRange: SyncDateRange(start: date, end: date),
            metrics: [HealthDataType.heartRate, .stepCount].map { type in
                HealthMetric(id: type.rawValue, type: type.rawValue, value: 1, unit: "count", startAt: date,
                    endAt: date, sourceName: "Fixture", sourceBundleID: nil, metadata: [:])
            }, workouts: [], deletions: [deletion])
        try await store.enqueueBatch(SyncBatch(payload: payload, destination: AppSettings.hostedBackendURL, attemptCount: 2))

        try await store.saveHealthSelection([.stepCount])
        let reopened = try SQLiteLocalStore(url: url)
        let saved = try await reopened.loadSettings()
        XCTAssertEqual(saved.selectedTypes, [.stepCount])
        let pending = try await reopened.pendingBatches()
        let batch = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(batch.payload.metrics.map(\.id), ["step_count"])
        XCTAssertEqual(batch.payload.deletions, [deletion])
        XCTAssertEqual(batch.attemptCount, 2)
        XCTAssertNotEqual(batch.payload.exportID, payload.exportID)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthSyncTests-\(UUID().uuidString).sqlite")
    }
}
