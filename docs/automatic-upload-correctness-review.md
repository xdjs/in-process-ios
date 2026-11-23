# Automatic upload correctness review

Date: November 9, 2026. Branch `codex/discovery-lifecycle`, including uncommitted changes.

Requirements used: the "What we are trying to build" section of [background-discovery-investigation.md](background-discovery-investigation.md).

Method: read-through of the source. No tests were run and no code was changed. Findings marked "unverified" depend on platform behavior that was not confirmed.

## Verdict

The implementation is strong on not publishing twice and weak on eventually publishing once without the user. Measured against the requirement that adding a still photo to the album should be enough and that the app may rarely be opened, it does not pass. Several failure paths end in a state only a foreground user can clear.

## Findings, most severe first

### 1. Existing-photo album adds are never discovered in the background, and opening the app does not upload them either

- The extension is the only place that scans in the background, and Photos does not invoke it for album-membership changes (see "Supporting evidence" below).
- The host only ever calls `scan()` (`InProcess/App/InProcessApp.swift` lines 77, 95, 103), which enqueues records as Pending.
- `submit` in `InProcess/Automatic/PhotoKitTransfer.swift` refuses to run outside the extension ("Waiting for Photos to schedule the upload extension"), and nothing in the host asks Photos to run it.
- A photo found by opening the app therefore still waits for the next unrelated library insert.

### 2. Three failures in a record's lifetime stop it permanently, and terminations count as failures

- The per-record catch marks the record failed and increments `attempts` before it rethrows cancellation (`InProcess/Automatic/UploadCoordinator.swift` lines 430-435).
- A `willTerminate` during metadata upload or simulate therefore burns an attempt, as does any transient network or 5xx error at those stages.
- At three attempts the record is filtered out for good (line 360). `attempts` is never reset when a stage succeeds.
- No notification is sent: `notify` is only reached through `block` for auth, permission, album and owner problems. A user who rarely opens the app will not learn the photo was dropped.

### 3. An "uncertain" record can never be resolved if the create did not happen, and it makes every later invocation report failure

- After an ambiguous create, the only exit is `reconcile` finding the Moment in the timeline (`UploadCoordinator.swift` lines 369-375).
- If the request never landed, the record stays uncertain forever. The status screen offers only "Check publication status" (`InProcess/Views/AutomaticViews.swift` lines 154-157), with no discard or re-publish.
- While any such record exists, `processForExtension` returns `.failure` (lines 305-307), so the extension never reports `.completed` again. How Photos schedules after repeated `.failure` is not documented.

### 4. A photo whose modification date changes after registration can reach an unrecoverable state

- Once a record is past the draft stage, a revision mismatch throws (`UploadCoordinator.swift` lines 388-390). The revision is the asset's `modificationDate`.
- If the in-flight job then fails, every retry re-throws the same error. Manual `retry` resets `attempts` but not the stage or revision (lines 257-262), so it loops back to the same failure.
- Edits certainly change that date. Whether favorites or album changes also do is unverified, and would make this much more common.

### 5. Work per invocation grows with the total size of the album, not with new photos

- Every scan enumerates the whole album and calls `PHAssetResource.assetResources` for each still (`photos(in:)` in `InProcess/Automatic/PhotosAlbumAccess.swift`).
- The worker repeats that full enumeration once per unsent record, up to eight times per invocation (`UploadCoordinator.swift` line 379).
- Deduplication is a linear search of all records per photo (line 240), and `read()` rewrites the ledger file on every call (`InProcess/Automatic/UploadState.swift` line 95).
- Published photos stay in the album, so this only gets slower, inside an extension with a runtime limit.

### 6. Job-queue capacity can leak, and hitting the limit is treated as an ordinary failure

- Terminal jobs whose URL does not map to an operation, or whose record is missing, are skipped and never acknowledged (`UploadCoordinator.swift` line 339, and `events()` in `PhotoKitTransfer.swift`). They count against `jobLimit` indefinitely.
- A `limitExceeded` error from job creation falls into the generic catch and consumes an attempt (finding 2). Apple's guide says to return `.processing` and wait instead.

### 7. Failed-transfer recovery loads the whole photo twice into extension memory

- For each failed job, `events()` reads the full resource and downloads the stored object to compare them.
- Apple warns that extensions using excessive memory are terminated, and a termination here feeds finding 2.

### 8. Smaller issues

- A photo removed from the album after its transfer finished is still published. Removal is only honoured before the media upload completes (`UploadCoordinator.swift` lines 235 and 378-387).
- Every successful scan clears `blocker`, including ones it did not set, such as "could not be enabled" (line 232). The status screen can then show "Paused" with no reason.
- `configure` accepts any currently valid session (line 112). If the artist-key bootstrap had failed, automatic uploads would be enabled on an hourly token. Whether that path is reachable is unverified.
- `.processing` is returned while waiting on an already-registered job with no progress made (line 304). Apple's guide says to return it only on progress; the scheduling consequence is unknown.

## What holds up

- Publication state is persisted before the create call, and a possibly-sent create is never retried.
- The cross-process lease and the locked ledger prevent the host and extension from publishing the same record.
- A late success for a cancelled job is ignored, and a failed job whose bytes did land is recovered by readback.
- Resource selection picks the edited full-size still when edits exist and never falls back to the pre-edit original. Videos are excluded.
- The status screen covers pending, uploading, published, failed, cancelled and paused, with links to results.

## Test coverage gaps

The only test found by name for these paths is `testCanceledOperationIgnoresLateTransferSuccess`. No tests were found for termination consuming attempts, stuck uncertain records, post-registration edits, or orphan jobs.

## Supporting evidence for finding 1

From the local device captures under `docs/verification/` (November 9, PST). `assetsd` logs which background workers each library change signals:

| Event | Workers `assetsd` signaled | Runner task submitted to scheduler |
|---|---|---|
| Extension enabled (12:27:41, 12:46:12, 13:05:12) | `AssetResourceUploadExtensionRunner`, `AssetResourceUploadJob` | Yes, started within a second |
| New PNG saved to library (12:07:41.474) | Runner signaled 4 ms later | Yes |
| iPad video synced in (12:41:25) | Runner signaled | Yes |
| Existing card added to album (about 12:40:43) | `FeatureAvailability` only | No |
| Existing card added to album (about 12:47:51) | `FeatureAvailability`, `LowPrioritySearchIndexing` | No |
| Existing card added to album, minimal repro (13:06:25.991) | `HighPrioritySearchIndexing`, `FeatureAvailability` | No |

Limits: this is inferred from private daemon logs on one device and one OS build (iOS 27.2), not a documented contract. Other change types (edits, favorites, removals) were not tested. One runner submission at 12:44:02, ten seconds after an album removal, has no matching `assetsd` signal in the capture; it carries a different configuration UUID and is believed, but not confirmed, to be the diagnostic being re-armed.
