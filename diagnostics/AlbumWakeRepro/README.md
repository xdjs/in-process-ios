# Album membership wake reproduction

Independent iPhone/iOS 27 host and PhotoKit upload extension for observing whether adding an **existing** asset to an album produces a later extension invocation. This is a non-publishing diagnostic, not an automatic-upload implementation or proof of a scheduling guarantee.

The production app remains `com.xdjs.InProcess`. This project uses `com.xdjs.AlbumWakeRepro`, its `.WakeExtension` child, and `group.com.xdjs.AlbumWakeRepro`. It compiles only three Swift files. It has no production source, API client, Keychain capability, upload ledger, resource reads, upload/download jobs, background task requests or observer registrations. Its host can create one explicitly requested empty test album; all asset membership changes are performed separately in Apple Photos.

`WakeExtension.swift` logs initialization and `processJobs` entry, reads counts through `Probe.snapshot`, logs completion and returns `.completed`. Errors return `.failure`. It never returns `.processing`. There is no timer or retained observer. The private configuration stores only the test album identifier and a baseline Photos token. Counts are always relative to that baseline; snapshots do not advance it. Exported JSONL contains process UUIDs, role, timestamps, fixed event names, counts, flags and numeric errors, not Photos identifiers or tokens.

## Build and isolation checks

From the repository root:

```sh
python3 diagnostics/AlbumWakeRepro/generate-project.py
python3 diagnostics/AlbumWakeRepro/verify-isolation.py
xcodebuild -project diagnostics/AlbumWakeRepro/AlbumWakeRepro.xcodeproj -scheme AlbumWakeRepro -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .build/AlbumWakeReproDevice CODE_SIGNING_ALLOWED=NO build
```

The generated project preserves iOS 27, iPhone-only and portrait settings. For device signing, select your development team and provision **these separate identifiers and App Group**. The checked-in generator uses this repository's existing team. Never substitute production bundle IDs, groups or profiles. The Simulator can compile the UI, but every Photos action fails closed there; the actual extension requires a physical device.

The extension declares `https://example.invalid` as the required URL base. There is no destination request or resource job, and no app-originated server traffic. A successful initial invocation establishes that this declaration did not prevent initial registration/execution; it does not prove every possible later scheduling policy or server interoperability.

## Controlled run

1. Start a scoped device log capture for subsystem `com.xdjs.AlbumWakeRepro`, Photos' background-upload runner and relevant scheduler events. Record Test Mode, power/network state and Mirroring state. Keep new assets/edits on all iCloud-synced devices out of the observation interval.
2. Launch the separate app. Explicitly request full Photos access, then create its empty **Album Wake Repro** album. The app saves the new album identifier and reuses it on subsequent launches. It neither chooses a preexisting user album by name nor changes album members.
3. Tap **Enable once and set baseline**. This explicit action disables this diagnostic extension if already enabled, saves a fresh token and enables it once with default network policy. It requires an empty album. Do not use this button during an observation.
4. Export the event log. Require actual `role=extension` initialization, `processJobs.begin`, an empty snapshot, `processJobs.completed` and termination. Correlate the Photos worker with the diagnostic bundle. Enabling alone is insufficient.
5. Open Apple Photos, leaving the diagnostic host backgrounded. Add only the existing authorized synthetic card to the isolated album; do not duplicate, edit or save a new asset. Verify one album member. Return Home. Record the mutation and observation boundaries.
6. Observe for a declared finite interval without foregrounding/reinstalling/re-enabling either diagnostic target. Mirroring may remain connected if recorded; this then tests host-background execution, not uninterrupted disconnected idle conditions. An observed wake can end the window early. Absence within the window is not a maximum-delay guarantee.
7. After the end boundary, reopen the host and export retained events **before** tapping **Inspect Photos history now**. Then inspect and export again. Check no host activation inside the window, whether any extension invocation occurred, whether the watched collection changed, member count and global inserted/deleted asset counts. Three updated assets, for example, do not by themselves prove three resource edits.
8. Remove only the test card's album membership in Photos, preserving its library asset. Disable the reproduction extension and export cleanup evidence. Preserve the empty test album and all production data; uninstalling or deleting albums is not required.

Export uses supported app-data access only:

```sh
xcrun devicectl device copy from --device DEVICE_ID --domain-type appDataContainer --domain-identifier com.xdjs.AlbumWakeRepro --source Documents/WakeEvents.jsonl --destination docs/verification/album-wake-minimal-2026-11-09/events.jsonl
```

Each process writes a separate JSONL file, capped at 1,000 events; export accepts at most 100 files of 1 MB each. It excludes an incomplete trailing line and private configuration. File errors also appear in OSLog. The capture can omit events, so compare retained files. An export does not inspect Photos or enable the extension. Timestamps have one-second precision; exports group by process, so sort parsed timestamps for analysis. No automatic retention deletion or production-container copying occurs.

## What Apple specifies

The [background-upload guide](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background) describes returning `.completed` when processing is finished and entering library monitoring; normal scheduling also depends on device, power and network conditions. Its inline skeleton returns `.completed` with no job creation. The guide provides inline examples rather than a downloadable sample package. It does not enumerate album-membership changes as a wake trigger or state a maximum scheduling delay. Its URL-base declaration validates network access; resumable preflight is described in connection with actual uploads. This zero-job reproduction tests invocation, not that protocol.

The iOS 27.2 SDK and [`PHAssetResourceUploadJobOptions`](https://developer.apple.com/documentation/photos/phassetresourceuploadjoboptions) expose expensive-network policy, not an album ID, predicate or observer subscription. The enable call accepts options, not a persistent token. Tokens recover committed history when code executes; this project intentionally does not confuse a foreground history read with a wake.

[`register(_:)`](https://developer.apple.com/documentation/photos/phphotolibrary/register(_:)-7lhue) weakly retains a persistent-change observer and delivers committed-change callbacks on a serial queue. An [Apple Frameworks Engineer](https://developer.apple.com/forums/thread/833067) describes it as lightweight persistent-history notification, with no coalescing guarantee. Neither source specifies that registration launches a suspended or terminated app/extension. Keeping an observer object alive is different from obtaining execution time. The earlier in-app probe retained both ordinary and persistent observers; this reduced extension intentionally has neither.

The remaining contract question is whether **membership changes to an existing asset**, without new resource/job work, are intended to make a completed upload extension eligible for another invocation, and under what conditions. Missing invocation cannot distinguish an unrecognized trigger from deferred eligibility. The documentation does not justify claiming that membership is categorically unsupported, nor that a client observer/token change guarantees it.

A BackgroundTasks scan would be opportunistic ([Apple background execution guidance](https://developer.apple.com/forums/thread/685525)), and the production app's current transfer adapter still requires its PhotoKit extension to register jobs. A separately designed background transport could reduce that dependency but would not create a guaranteed wake deadline. Explicit foreground check/share workflows change the hands-off product requirement. No such fallback is implemented here.

Current physical results and cleanup state are recorded in [the implementation plan](../../docs/background-upload-plan.md). Raw evidence remains ignored under `docs/verification/album-wake-minimal-2026-11-09/`. This README is a local runbook; no Apple feedback or external correspondence was drafted or sent.
