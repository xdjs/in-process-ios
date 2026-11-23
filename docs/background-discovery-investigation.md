# Background photo discovery: goal, evidence, and unresolved behavior

Updated November 17, 2026. The standalone reproduction below was run on November 9.

## What we are trying to build

In Process is an iPhone app that publishes photos to an existing In Process account. Users sign in, connect an Apple Photos album, and enable automatic uploads. After setup, adding a still photo to that album in Apple Photos should be enough to have it discovered, uploaded, and published without reopening In Process.

This must include **existing library photos newly added to the album**, not just newly captured or imported photos. The app may rarely be opened. A status screen reports pending, successful, paused, and failed work, with links to published results. Manual publication remains available.

The app targets iOS 27 and uses the PhotoKit background resource upload extension. Uploads preserve supported formats, dimensions, and metadata, including HEIC, and use the current edited rendition where applicable. Videos are outside the current scope. Artist API keys provide longer-lived authentication; hourly email-sign-in token expiry is no longer the intended steady-state credential model.

## Current situation

Background transfer and publication have succeeded on a physical iPhone. We have also observed the extension discover and publish an eligible album photo without foregrounding the host app. However, that successful discovery followed a new asset entering the photo library, so it does not establish that adding an existing asset to an album alone caused the invocation.

The unresolved product requirement is reliable background discovery after an **existing-photo album membership change**. In controlled observation windows, Photos recorded the album change but no subsequent extension invocation was observed. Reopening the host app then discovered the photo immediately. Once execution occurred, the upload and publication path could proceed.

We have reproduced this observation in a separate minimal app, without the production authentication, coordinator, upload ledger, service client, or publication code. That narrows the investigation to the interaction between the extension configuration, library changes, and system execution opportunities. It does not establish a root cause.

### November 17 device findings

A fresh import outside the monitored album woke the extension in under one second and produced no Moment. In the next trial, the extension discovered and published a newly added album member in 8 minutes 20 seconds. Its runner had already been scheduled before that photo entered the album. Adding an existing diagnostic image with no import produced no recorded wake or publication in 27½ minutes. The final trial ended early. See the [device timings, controls, and readbacks](core-workflow-eval-results-2026-11-16.md#november-17-album-and-library-comparison).

### How a photo becomes pending

When the host or extension scans, it enumerates still images in the configured album and compares each Photos asset identifier with the signed-in account's upload records. It creates a pending record if there is no matching noncanceled record. A successful scan also cancels an automatic draft removed from the album before upload starts. Manual uploads participate in matching when the picker supplied their asset identifier. A pending record means discovery succeeded. PhotoKit job registration, transfer, and timeline publication are separate observable steps.

Today, opening the app or tapping **Check now** can scan and queue photos. The extension processes eligible work when Photos invokes it. One proposed foreground improvement is to start eligible pending uploads automatically after a scan or on reopening the app, honoring pause and network preferences and the existing cross-process publication lock. This is a proposal. It would help already-discovered work while the host is running. Discovery while the host is suspended still requires an opportunity for the extension to execute.

## What is established—and what is not

| Observation | Supported conclusion | Limit |
|---|---|---|
| Physical background transfers and publications succeeded. | The extension and service can complete the transfer/publication path. | This does not prove album-only discovery. |
| A background invocation discovered an eligible photo after a new library asset appeared. | Discovery need not run in the foreground host. | The specific event responsible for the wake is not proven. |
| Existing-photo album additions were followed by windows with no observed extension entry. | The requested behavior did not occur within those windows. | This is not proof that such changes can never trigger execution. |
| Foreground reconciliation found the added photo. | The app can recognize the album membership when allowed to execute. | Opening the app changes the experiment and cannot count as background discovery. |
| A standalone extension reproduced the missing invocation. | Production authentication, upload, and queue code are not necessary to reproduce the observation. | Diagnostic configuration and normal scheduling remain possible factors. |

Separate lifecycle bugs were corrected: blocked or unfinished work could previously be reported as completed. Those fixes have regression coverage, but have not established a fix for the album-membership wake behavior. Likewise, longer-lived credentials remove an authentication obstacle without solving discovery scheduling.

## Standalone reproduction

The [minimal reproduction and runbook](../diagnostics/AlbumWakeRepro/README.md) describe a separate host app and extension with their own bundle identifiers and App Group. Its extension logs initialization and processing entry, reads album/history counts, and returns completion. It creates no upload jobs, performs no service requests, reads no production credentials, and publishes nothing. It has no observers or timers. An earlier in-app diagnostic retained Photos observers and also failed to demonstrate the required wake.

The standalone run used an existing synthetic test card and a separate album. No new photo was created for the membership change. All times below are Pacific time on November 9, 2026.

| Time | Event |
|---|---|
| 1:05:12 p.m. | The actual extension initialized, read the empty album, returned completion, and terminated. System logs identified the diagnostic worker. |
| 1:05:29 p.m. | The diagnostic host entered the background. |
| 1:06:25 p.m. | The existing card was added to the separate album through Apple Photos. |
| 1:07:01–1:12:13 p.m. | Membership was verified and a bounded observation of just over five minutes followed. Retained events show no host activity or extension entry during the window. |
| 1:12:36 p.m. | The host was reopened for export/readback, after the observation ended. |
| 1:12:50 p.m. | Foreground history inspection confirmed the album change and one member, with zero inserted/deleted assets and one updated asset. This readback is not background discovery evidence. |
| 1:13–1:14 p.m. | The diagnostic was disabled and only the card's album membership was removed. The original library asset was preserved. |

Resource Upload Test Mode was last visually verified off before the run and was not changed. Mirroring was left open but showed a paused connection at readback; uninterrupted connectivity or disconnected idle conditions are not claimed. Host lifecycle events establish the background interval independently.

Isolation checks and Simulator, unsigned device, and signed device builds passed. Actual extension behavior was tested on the phone; Simulator compilation cannot validate PhotoKit extension scheduling.

## Experimental limits

- A five-minute observation cannot establish a maximum scheduling delay or rule out a later invocation.
- The minimal extension has no resource jobs and declares a non-routable URL base. Initial execution succeeded, but that does not prove these choices are irrelevant to every subsequent scheduling decision.
- Retained extension events and scoped system logs support the observed sequence. Absence of an entry does not expose the scheduler's internal reason.
- Photos history reported an updated asset as well as the collection change. That count alone does not prove a resource edit; there were no newly inserted assets in this run.
- An earlier run was confounded by a video imported on a synced iPad. It is not evidence of an album-only trigger.

## Documentation findings

The reviewed [Apple background-upload guide](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background) describes library monitoring after a completed processing cycle and system-controlled scheduling. It does not explicitly enumerate existing-asset album membership changes as a wake trigger or give a maximum delay.

The reviewed options and SDK expose network policy rather than an album-specific wake subscription. Persistent history lets code recover changes once it executes. Observer registration and saved history tokens are not documented guarantees that a suspended process will be launched. The runbook links the reviewed API and observer references in detail.

These are documentation findings, not confirmation from Apple that membership-only changes are unsupported.

## Questions still needing answers

1. Is an existing asset's album membership change intended to make a completed PhotoKit upload extension eligible to run again?
2. If so, are any configuration or lifecycle requirements missing from the reduced example?
3. Does a zero-job extension or its declared URL base affect subsequent monitoring eligibility?
4. Which diagnostics can distinguish an event that does not create eligibility from an eligible invocation deferred by scheduling?
5. What behavior can an app reasonably promise for an album-driven workflow under normal scheduling?

Another identical short wait would add limited information. Further testing should address a specific question above, with one controlled change and a declared observation window. A longer window could demonstrate delayed execution, but another negative window would still not prove impossibility. Platform clarification may be needed; this report has not been sent anywhere.

## Acceptance and current disposition

The acceptance test remains: establish an idle extension, keep the host backgrounded, add an existing still to the connected album externally without introducing new assets or edits, and observe extension discovery followed by authorized upload/publication without reopening, reinstalling, or re-enabling the app. Record normal Test Mode state, lifecycle boundaries, scheduling evidence, and publication readback. Repeated successful runs would build confidence but would not create a system timing guarantee.

The standalone diagnostic is disabled, its album is empty, and its original test asset remains in the library. It did not replace or reconfigure the production app. No publication occurred during that reproduction. Commits, merges, and pushes remain on hold while the requested behavior is unresolved.

Detailed chronology is retained in [the background upload plan](background-upload-plan.md). Raw device evidence remains local and ignored under `docs/verification/`; it is not embedded in this report. This document intentionally excludes credentials, account readbacks, private photos, and raw device logs.

## Addendum — November 16, 2026

A production-app run with Resource Upload Test Mode on reproduced the same observation over a longer window. A newly imported still entered the library, the extension ran about 25 seconds later and found the connected album empty, and the photo was added to the album about 22 seconds after that run. No further extension invocation was retained over roughly 74 minutes. The trigger for the run before the addition is inferred from timing, not proven, and the extension process was held by developer tools during the window, which is an unresolved confound.

This shows the import-then-add sequence can reduce to the membership-only case whenever the wake arrives first, so the question above applies to the ordinary new-photo flow as well. It does not establish that membership changes can never trigger execution. Details and proposed next steps: [reanalysis](core-workflow-eval-results-2026-11-16.md#post-run-log-reanalysis-same-day-read-only), [next steps](core-workflow-evals.md#next-investigation-steps--november-16-2026).
