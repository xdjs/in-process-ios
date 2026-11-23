# In Process iOS

## Purpose and scope

Native SwiftUI app for existing In Process users: email-code sign-in, immediate single-tap manual publication, and opt-in automatic publication from a connected Apple Photos album. The automatic workflow and preservation policy are authorized; unrelated timeline, video, payments, and cross-device features remain out of scope. See docs/background-upload-plan.md and docs/photokit-server-requirements.md for implementation status and the explicit server/device gate.

The app bundle identifier must remain exactly `com.xdjs.InProcess`. Require iOS 27 app-wide, including manual uploads and tests. Target iPhone only (`TARGETED_DEVICE_FAMILY = 1`) with portrait orientation. Native iPad layouts are out of scope; iPad compatibility-mode execution may still be possible. Keep this device scope in the generator and all project configurations.

## Structure

- `InProcess/App/AppModel.swift`: observable main-actor state, authentication, draft lifecycle, publication and reconciliation.
- `InProcess/Views/RootView.swift`: sign-in, system Photos picker, review, progress/errors, and success views.
- `InProcess/Services/InProcessAPI.swift`: URLSession API and storage requests.
- `InProcess/Models/Models.swift`: request/response models, defaults, durable publication stages.
- `InProcess/Services/ArtistCredentials.swift`: shared device-only credential vault, checkpointed OTP-to-artist-key bootstrap, revision-checked promotion, and exact installation-key revocation. Never retry ambiguous key creation automatically. Sign-out persists local stop first; unfinished remote revocation retains only nonsecret metadata for same-account cleanup. Never revoke a replacement or another installation key.
- `InProcess/Services/Persistence.swift`: Keychain sessions and local draft storage. Shared access group must resolve from the actual built host and extension Info.plists; an entitlement or build setting alone is insufficient. Keep explicit Info.plist entries in both targets. Never fall back to a placeholder access group.
- `InProcessTests/KeychainIntegrationTests.swift`: real SecItem add/read/update/protection/delete using UUID-scoped disposable items, plus built host/extension group consistency. Production items must never be used for these tests.
- `InProcess/Services/PhotoProcessor.swift`: validates and preserves JPEG/PNG/HEIC bytes, dimensions, orientation and metadata. No routine conversion, resizing, or stripping. The 100 MiB manual preparation guard is an app memory bound, not a service limit.
- `InProcess/Automatic/UploadState.swift`: account-scoped ledger, short transactional file lock and separate cross-process publication lease. Do not replace these with an in-memory-only actor or timeout lease that permits duplicate creates.
- `InProcess/Automatic/UploadCoordinator.swift`: discovery, incident deduplication, safe checkpoints/retry/reconciliation, pause/network/auth rules. Inject all adapters in tests. Also the foreground upload pass described under Build and validation; UI fixtures disable it except the `foregroundUpload` scenario.
- `InProcess/Automatic/PhotosAlbumAccess.swift`: connected-album-only scan; current full-size edited still resource, original still when unedited; never fall back to the pre-edit original. No video upload.
- `InProcess/Automatic/PhotoKitTransfer.swift`: real iOS 27 resource jobs, stable destination mapping and terminal acknowledgment. Treat generic OPTIONS 200 as inconclusive except for the narrowly pinned service/bucket/request policy backed by the three successful physical PhotoKit transfers; retain strict rejection tests.
- `InProcess/Automatic/PhotoDiagnostic.swift`: Debug-only one-generated-photo physical diagnostic. Never run it as an ordinary regression, create its asset, or upload its public object without explicit authorization. It cannot create a Moment; Simulator/XCTest calls fail closed. See docs/phone-diagnostic-checklist.md.
- `InProcessUploadExtension/`: ExtensionFoundation entry point, URL-base declaration and bounded coordinator invocation. The actual extension does not run on Simulator.
- `InProcess/Views/AutomaticViews.swift`: authenticated home, one-screen automatic setup and the Configuration sheet. Once an album is connected the home has a counter of uploaded photos with a line for what is pending, the "Automatic uploading" switch (the only upload control; there is no user-facing pause), a thumbnail grid of every still in the album (published photos in colour, everything else grey and faint), and a floating add button (`addToAlbum`; system multi-select picker; picked photos are added to the album with no confirm step, which publishes them). Tapping a thumbnail opens its details (retry, publication check, link). Pending and failed photos can be removed from the album (an X on the thumbnail, a link in the details, and a confirmed "Remove all"); removal never deletes a photo, and uploading, uploaded or uncertain photos are never removable here. Removing a failed photo cancels its record so a later re-add starts a fresh upload. A status line appears only for problems; the grid rescans whenever the screen appears and on pull-to-refresh. Manual upload is offered only on the fresh-install home. Its photo picker opens over the current screen and the photo is loaded there; New Moment opens only once a photo is ready, and "Remove photo" returns home. New Moment must never be shown or reachable without a photo; isolated UI-test launches take a generated photo in place of the system picker. The gear is on every signed-in home screen and opens Configuration (cellular, details, Developer, and Account with Sign out; a toolbar Sign out remains only when upload storage is unavailable). Setup is a two-step wizard with no album list. Step 1 explains Photos access and the album and asks for access from its OK button; step 2 offers automatic background uploading (off by default) and its Finish button creates an "In Process" album or reuses an existing one. With automatic uploading off, album photos are shown as waiting for approval and are not queued until approved (per photo in its details, or "Approve all" with a confirmation) or the home switch is turned on. Turning the switch off returns queued photos whose upload has not started (draft stage only) to waiting; an approval can likewise be taken back with Un-approve until its upload starts. `paused` remains an internal state set after a failure or by developer tooling, surfaced on home as a problem with "Resume uploads". An existing "In Process" album that holds photos (a reinstall or a second phone) is connected only with automatic uploading off: step 2 says so and locks its switch, and the photos wait for approval. Turning the home switch on while photos wait asks for confirmation first. The app keeps no record of what was published before a setup, so approving such a photo publishes it again; detecting those duplicates is not built yet and must be addressed (see docs/background-upload-plan.md, "Known gap: duplicates after reconnecting an album"). Do not remove the forced-off mode or the confirmation until it is. RootView gates every route on authentication, including notification entry and expired configured accounts.
- `InProcessTests/AutomaticUploadTests.swift`: offline queue, resource-selection, preservation, authorization and failure/restart tests.
- `InProcessUITests/AutomaticUploadUITests.swift`: actual setup/status/recovery views with generated state and injected adapters.
- `InProcessTests/PublishingTests.swift`: isolated publishing/recovery/defaults/image tests.
- `InProcessUITests/SignInUITests.swift`: signed-out email validation without sending a code.
- `InProcessUITests/PublishUITests.swift`: real review-to-success UI regression using the isolated `InProcess/Testing/PublishUITestService.swift` fixture.
- `InProcessUITests/AuthorizedLiveDriver.swift`: opt-in UI driver; skipped unless explicitly configured through `INPROCESS_LIVE_DRIVER_DIRECTORY`.
- `docs/ios-mvp-plan.md`: product scope, verified integration results, and remaining limitations.

The dependency-free Xcode project is generated by `python3 scripts/generate-project.py`. Run it after adding/removing Swift source files. Change build settings in that script as well as the generated project so regeneration preserves them. It embeds the ExtensionFoundation extension. The signing team is not in the project or the generator: the app and extension targets take `Config/Signing.xcconfig` as their base configuration, and that file includes `Config/Local.xcconfig` when it exists. `Config/Local.xcconfig` is ignored by git and holds `DEVELOPMENT_TEAM = <team>`; create it to build for a device, and never commit a team ID. The diagnostics project under `diagnostics/AlbumWakeRepro` uses the same file. App and extension need the group.com.xdjs.InProcess App Group and shared Keychain signing capability. Keep the shared scheme in Git.

## Build and validation

Run from the project root with Xcode selected:

```sh
xcodebuild -project InProcess.xcodeproj -scheme InProcess -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedData build
xcodebuild -project InProcess.xcodeproj -scheme InProcess -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath .build/DerivedData -parallel-testing-enabled NO -only-testing:InProcessTests test
```

Use an available simulator name from `xcrun simctl list devices available` if needed. For sign-in UI validation use `-only-testing:InProcessUITests/SignInUITests`; it now injects an isolated signed-out fixture. Never clear a user’s live session to make a test pass. The regular tests must not send sign-in emails or publish real content.

For Publish behavior regressions, run the mocked XCUITest, or combine it with the core suite:

```sh
xcodebuild -project InProcess.xcodeproj -scheme InProcess -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath .build/DerivedData -parallel-testing-enabled NO -only-testing:InProcessUITests/PublishUITests test
xcodebuild -project InProcess.xcodeproj -scheme InProcess -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath .build/DerivedData -parallel-testing-enabled NO -only-testing:InProcessTests -only-testing:InProcessUITests/PublishUITests test
```

`testOneTapPublishesImmediatelyWithoutConfirmation` taps the real SwiftUI Publish button once, requires progress with no alert/action sheet or second confirmation, checks exactly one service create call (separate from two uploads), then verifies Published. A continuation holds the fake create response until the test releases it with a per-run Darwin notification; do not replace this with timing sleeps. Restoring the old confirmation dialog was verified to fail this test; restoring immediate Publish passed.

The test launches with `--ui-test-publish` and a UUID `INPROCESS_UI_TEST_RUN_ID`. The Debug-simulator-only fixture injects `InProcessServing`, a generated photo/test identity, in-memory sessions, and a UUID temporary draft directory. It never calls live API, Privy, Supabase, or chain services, and never reads/clears the real Keychain session or saved draft. Missing fixture configuration fails closed; `InProcessAPI` rejects this launch mode. Hosted simulator unit tests also select the isolated fixture and reject live API construction. Preserve these guarantees and the fixture-mode assertion before any Publish tap. Use mocked UI tests for behavior regressions; run separately authorized live tests only when validating real service integration.

The automatic UI fixture uses `--ui-test-automatic`, a UUID `INPROCESS_UI_TEST_RUN_ID`, and an optional scenario (`setup`, `expired`, `denied`, `incompatible`, `signedOut`, `configuration`, `restored`, `restoredConfigured`, `accountRecovery`, `noAlbums`, `albumWithPhotos`, `emptyAlbum`, `firstGrant`, `limited`, `settingsGrant`, `albumReadFailure`, `albumGrid`, `foregroundUpload`). It injects fake library, transfer, notification, session and API adapters with isolated temporary storage. `InProcessAPI` rejects every `--ui-test-` launch before reading service configuration. Hosted unit tests likewise reject live construction. The explicitly named Keychain integration tests are the exception to fake storage: they use only disposable UUID-scoped Keychain services/accounts and clean up those exact items. The `secureSaveFailure` fixture exercises retained selection and retry after a shared credential save failure. Already-authorized setup must check existing albums on entry without a permission request; the permission prompt appears only from step 1's OK button, and Settings-return tests cover the recheck. Opening the setup screen or reaching step 2 never creates an album or enables uploads; only step 2's Finish button does. Fixture scenarios start with no album except `albumWithPhotos` and `emptyAlbum`. `albumGrid` seeds a connected album with published, failed and unscanned photos. The fixture supplies a generated two-photo selection in place of the system photo picker. Never instantiate real PhotoKit/Keychain/connectivity adapters in those fixtures. `SignInUITests` uses this mode too; tests do not request real OTPs.

Run the complete offline regression set with:

```sh
xcodebuild -project InProcess.xcodeproj -scheme InProcess -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath .build/DerivedData -parallel-testing-enabled NO -only-testing:InProcessTests -only-testing:InProcessUITests/PublishUITests -only-testing:InProcessUITests/AutomaticUploadUITests -only-testing:InProcessUITests/SignInUITests test
xcodebuild -project InProcess.xcodeproj -scheme InProcess -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceValidation CODE_SIGNING_ALLOWED=NO build
```

The unsigned device build catches SDK branches excluded from Simulator. A signed Debug build and embedded entitlements/profiles were separately verified for the connected phone; one synthetic PNG has also completed through the actual extension with matching source/readback hashes. See the phone diagnostic result for conditions and limits. Production automatic enablement must pass the endpoint gate, including the narrow device-verified service exception documented in docs/photokit-server-requirements.md. Do not universally accept generic OPTIONS 200. Foreground uploading is a deliberate, user-approved part of the album flow (decided 2026-11-22), not a silent fallback: while the host app is frontmost, `UploadCoordinator` uploads queued photos itself, one at a time, through the same checkpoints, lease and reconciliation as the extension. It must take only photos that have not started or that carry its own `viaApp` mark, never one whose transfer Photos may hold; start nothing new once the app leaves the foreground; and release the publication lease before suspension. Do not add timers or polling to this path; it runs on foregrounding and on explicit user actions (approve, add, turning automatic on, retry). A compatible preflight alone does not establish complete device interoperability. Backend work is currently read-only investigation only; no backend edits/deployments are authorized. The four prior synthetic objects remain recorded locally; do not escalate credentials to delete them.

Run checks appropriate to changes and inspect rendered UI when changing the UI. Separate unit/UI-test results from live integration claims. Physical-device, iCloud-only-photo, real network-interruption, and background-publication behavior remain unverified end to end.

## Integration and publication

The API base is `https://api.inprocess.world/api`. Prefer current service source and `sweetmantech/in_process_docs` OpenAPI/OTP docs over stale examples. Resolve account and default collection from authenticated API responses; never hardcode a user's identity.

Current defaults: Base, authenticated default collection, 1 USDC (`1000000` base units), optional blank title/description, open edition, no added split recipients or manual schedule. In Process covers uploader costs; do not add wallet funding or payment flows. The collect price is separate from upload costs.

Live sign-in requests and external publication require user authorization; existing explicit authorization applies within its scope. Use only the authorized photo. Persist operation state before create, reconcile uncertain outcomes, and never blindly retry a possibly successful creation. Do not publish again merely to verify a result; use readback. Verifying an uploaded Moment includes opening it on In Process (the "View on In Process" link in the photo's details) and confirming the right image is shown; the app's Uploaded state alone is not sufficient.

Current media and metadata use public Supabase HTTPS objects. Successful publication does not establish Arweave permanence. The bundled `StoragePublicKey` is intentionally a public `anon` key, not a service-role secret. Do not introduce privileged credentials into the app.

## Visual design

`InProcess/Views/Theme.swift` holds the tokens, taken from inprocess.world: ink `#1B1504`, gold `#A8862F` for links, prices and bracketed actions, Spectral italic for headlines, Archivo for interface text, white cards with a hairline border and a soft low shadow. The app is light only (`UIUserInterfaceStyle` Light in the host Info.plist). The launch screen (`UILaunchScreen` in the same file) is the paper colour (`LaunchBackground`) with the squiggle centred (`LaunchLogo`, 64 pt); `LoadingView` puts its logo at the same spot so launch runs into loading without a jump. Motion is quiet: staggered fade-and-rise entrances (`appear`), animated state changes, light haptics; entrances only fade under Reduce Motion. Keep accessibility identifiers stable when restyling: the UI tests find controls by identifier, and `albumSummary` is a single element whose label is the sentence of counts.

## Simulator control

Prefer XcodeBuildMCP when available, confirm session defaults, and inspect the current UI before acting. Default semantic taps can report success without focusing or activating controls. Verified workaround: `touch({elementRef: <current ref>, down: true, up: true, delay: 0.1})`, refresh the snapshot, then `type_text`. Verify the actual field value and enabled controls; a successful tool return is insufficient. Refresh references after navigation. Photos picker and Safari content may need screenshot-based observation when missing from semantic snapshots.

## Data hygiene

Keep OTPs, session tokens, signing secrets, private photo fixtures, raw account readbacks, live driver command/response files, build output, and machine-local Xcode state out of Git and logs. Preserve Keychain sessions and saved drafts during routine work. All artifacts under `docs/verification/` remain local and ignored, including sanitized screenshots; do not force-add them or introduce exceptions.

## Development logging and retrieval

Debug-only `DevelopmentLog` emits the same source-sanitized structured events to
Apple Logger and a bounded shared host/extension JSONL file. Use only typed
allowlisted fields; never log tokens, email/code contents, request bodies,
headers, raw URLs, NSError descriptions/userInfo, filenames, or photo metadata.
Operation UUIDs and hashed Photos/job identifiers correlate lifecycle spans.
Keep logging fail-open and preserve the distinct app Pending versus PhotoKit
registered/systemPending states. Absence in retained history is not an OS
scheduling diagnosis; Resource Upload Test Mode is not readable by the app.

Authenticated Upload status → gear (Configuration) → Developer → Development diagnostics → Share log file exports
a read-only consistent snapshot. It also writes the sanitized snapshot only to
`Documents/Diagnostics/InProcess-Diagnostics.jsonl` for supported devicectl
appDataContainer copying. Do not expose the private ledger or bypass container
policy. Export must never scan, retry, or publish. Normal foreground scans must
remain identifiable in the log. See `docs/development-diagnostics.md` for bounds,
retention, error semantics, retrieval, and before-first-unlock/history limits.

Run `DevelopmentLogFileTests` and `DevelopmentLogFlowTests` with the core suite,
plus `AutomaticUploadUITests/testDevelopmentDiagnosticsExportsWithoutScanningOrPublishing`
when changing this boundary. Tests use actual file writes with independent
writers and synthetic privacy fixtures, not just a fake logger. Do not generate
live work solely to obtain logs. Preserve current sessions and pending uploads
when installing development builds; record foreground/install times separately
from idle-background evidence.
