# HealthSync iOS app

The SwiftUI app reads selected Apple Health data through HealthKit, normalizes it to JSON, and queues uploads to the user's confirmed backend. SQLite stores preferences, the local device ID, HealthKit anchors, pending batches, and sync logs. Tokens are stored in Keychain. See the [upload contract](../backend/UPLOAD_API.md) for the wire format.

## Build and run

Open [`HealthSync.xcodeproj`](../HealthSync.xcodeproj) in Xcode 16 or later. Select the `HealthSync` scheme and an iOS 17+ simulator or iPhone. For a physical device, choose a signing team with HealthKit support; confirm HealthKit Background Delivery and Background Modes → Background fetch are enabled.

From the repository root, build for the simulator without signing:

```bash
xcodebuild build -project HealthSync.xcodeproj -scheme HealthSync \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Choose a storage destination during onboarding. For local testing, use the [persistent API](../backend/README.md) or the [non-persistent request stub](../backend_stub/README.md). On the simulator, use `http://127.0.0.1:8080`; on an iPhone on the same Wi-Fi, use the Mac's LAN address and allow Local Network access when prompted. Use HTTPS for production.

## Health data and sync

- **Core** is the default on a fresh install: steps, walking/running distance, workouts, sleep, body mass, heart rate, and active energy. **Fitness** adds activity, heart fitness, and body composition types. **Everything** selects all supported types. Workouts also request read access to related energy, distance, heart rate, and effort types when supported.
- Review the selection before granting read access. To change it later, use **Settings → Health Data → Save selection**. Saving a narrower selection removes unsent samples from disabled categories but keeps deletions that remove data already exported. It does not erase samples already uploaded. HealthKit does not disclose read-permission revocations to the app; narrow the saved app selection or clear the queue to stop pending retries.
- Incremental sync advances HealthKit anchors only after the additions and deletions are durably queued. Automatic runs retry up to three previously failed batches that have cooled down for 15 minutes and up to three previously queued batches waiting for a first attempt. Use **Dashboard → Pending queue → Retry uploads** to retry immediately without reading Apple Health again. Uploaded batches are pruned after seven days on app startup.
- The first launch after the credential-binding upgrade discards older pending batches whose approved credentials cannot be established. Existing custom backends require re-entering the token and choosing **Save and Test** once. Changing a destination or its upload token discards its pending queue, even at the same URL. HealthKit data, saved categories and local anchors are kept. Use an explicit backfill for any missing records you intend to send to the confirmed destination.
- New installs use hourly best-effort background sync. The first sync starts after the user confirms storage and completes Apple Health setup. HealthKit observers, `BGAppRefreshTask`, and in-app checks can start subsequent syncs. **Manual only** cancels scheduled app refreshes and HealthKit background delivery. Lock state, Low Power Mode, reboots, force-quitting, and system scheduling can delay background runs. Verify background delivery on an iPhone, not the simulator.

### Historical sync

**Daily summaries** is the default. **Original blood oxygen & HRV** exports individual blood oxygen and HRV samples with their IDs, timestamps, units, source, and metadata. Other quantity metrics still use HealthKit daily sums or averages. Blood oxygen records are discrete readings, not continuous monitoring.

Both modes process up to 30 days at a time. Original samples are read in pages of up to 100 records and each page is queued and uploaded before reading the next. In original mode, workouts and category samples are selected by start time and retain their full end time. Sleep still uses overlap queries. Keep the app open during a long backfill.

Backfill does not delete previously uploaded daily summaries. When reading data, distinguish original samples from daily records with both a `healthkit:aggregate:` ID and `metadata.aggregation`; do not add the two together.

## Tests

Use an installed simulator and substitute its name if needed:

```bash
xcodebuild test -project HealthSync.xcodeproj -scheme HealthSync \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Use `xcodebuild build-for-testing` instead of `xcodebuild test` to compile the tests without launching a simulator. `-only-testing:HealthSyncTests/PopulatedWorkoutExportTests` checks workout summaries with synthetic elliptical and rowing fixtures, including the final HTTP body. It neither saves workouts to Apple Health nor sends the request.

### Physical-device workout validation

`PhysicalWorkoutValidationTests` is opt-in. Grant the app HealthKit read access on the connected phone first. Use a test setup where normal app-launch behavior, including any configured sync, is acceptable.

```bash
TEST_RUNNER_HEALTHSYNC_DEVICE_VALIDATION=1 xcodebuild test \
  -project HealthSync.xcodeproj -scheme HealthSync -configuration Release \
  -destination 'id=YOUR_IPHONE_UDID' \
  -resultBundlePath /tmp/HealthSyncDeviceTests.xcresult \
  -only-testing:HealthSyncTests/PhysicalWorkoutValidationTests \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Automatic ENABLE_TESTABILITY=YES
```

The test compares up to 20 readable workouts with HealthKit statistics and exports field-availability counts to an XCTest attachment and `Library/Application Support/HealthSync/WorkoutValidation.json` in the app container. It skips on a simulator, without the opt-in flag, or when no workouts are readable. Coverage depends on the statistics recorded by the source apps on that device.
