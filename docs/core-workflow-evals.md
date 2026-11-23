# Core workflow evaluations

For physical-device wake experiments, use the [scenario matrix and per-scenario evals](photokit-wake-evals.md).

Draft acceptance plan, November 16, 2026.

Only still photos in the connected In Process album are eligible for automatic publication. Manual selection remains independent of album membership. Adding an existing photo means adding album membership, not moving or deleting the library original. Videos remain out of scope.

## Cases

| ID | Scenario | Required result |
|---|---|---|
| AUTH-1 | Complete email-code sign-in and artist-key setup. Relaunch, then access the account after the original one-hour session lifetime. | Same account remains usable without another email code. Verify authenticated service access, not merely a cached signed-in screen. |
| MANUAL-1 | Select an authorized still from Photos and tap Publish once. | Progress begins without confirmation; exactly one Moment is created with agreed defaults and the correct image. The result link opens that Moment. |
| AUTO-NEW | With setup complete and the host backgrounded, capture or import a new still and add it to the connected album through Photos. | Extension discovers it, transfers it, and publishes exactly once without foregrounding the host. |
| AUTO-EXISTING | With setup complete and the host backgrounded, add an existing library still to the connected album through Photos. Do not create or edit another asset on any synced device. | Same discovery-to-publication result, without an unrelated new-asset event or host foregrounding. |
| AUTO-OUTSIDE | Add a new still to the library but leave it outside the connected album. | That photo is never queued or published by this app. An extension invocation is allowed and is not itself a failure. |
| AUTO-DEDUP | Re-scan or deliver events again for a photo already published through this app. | No duplicate publication. |

AUTO-NEW validates the combined new-asset-plus-album workflow; it does not prove which event caused an invocation. AUTO-EXISTING isolates the membership-only path and must pass independently.

## Execution order: accelerated baseline first

Before evaluating normal scheduling, run a controlled physical-device smoke test with **Settings → Developer → Photos → Resource Upload Test Mode** enabled. Verify the applicable development-launch requirements against the current Apple guidance before running; the switch alone must not be treated as proof that acceleration is active. The app cannot read this system switch, so record its observed setting externally.

Use one explicitly authorized still added to the connected album while the host stays backgrounded. Verify the full chain: extension invocation, discovery, transfer, publication, and read-only result verification. Do not count a photo queued by a foreground host scan as proof of background discovery. Record whether the asset was newly imported or already in the library.

This is the first baseline gate, not acceptance of normal scheduling. If it fails, investigate that failure before spending an hour on a normal-mode run. If it passes, test both AUTO-NEW and AUTO-EXISTING with Test Mode off under the provisional one-hour window. Do not assume Test Mode provides an exact wake deadline. Prior development-mode successes are historical evidence, not a new execution of this eval.

## Known-state setup and teardown

Every independent test/eval must define, establish, and verify its starting state rather than inherit an unknown prior session. The user requested this policy for both Simulator and physical-device runs. This document does not itself perform a reset.

- **Before reset:** stop test drivers and disable automatic scheduling; inspect outstanding transfers and uncertain publications. Reconcile or explicitly quarantine unresolved operations before clearing any ledger. Never erase duplicate-prevention evidence while work could still publish. Capture relevant diagnostic evidence first.
- **Photos:** if the connected In Process album exists, remove its members so the verified starting count is zero; preserve the original photos/videos in the library and reuse the empty album. Do not delete library assets, unrelated albums, or erase the phone. Record that album membership changes can sync through iCloud. Prepare the authorized screenshot fixture outside the album before establishing the background observation baseline.
- **Authentication:** AUTH-1 begins signed out with installation-key cleanup handled through the existing sign-out/revocation flow. MANUAL-1 and automatic cases explicitly establish and verify the intended authenticated account. Never clear unrelated Keychain entries. Offline tests retain their isolated fixtures and disposable storage.
- **Application state:** clear only safely resolved test drafts/queue state using a scoped reset, set known upload enablement and cellular policy, and record Photos/notification permissions. Do not assume reinstalling clears Keychain or permissions. If no safe reset facility exists, implement and test one before calling the baseline clean.
- **Environment:** record build, OS, network/power, Test Mode, and Mirroring state. Verify the selected album, fixture, credentials, and expected empty queue before starting the measured steps.
- **Within an eval:** preserve state needed for the assertion. In particular, do not reset between sign-in, relaunch, and the beyond-one-hour check, or between registration and recovery/deduplication steps.
- **Afterward:** retain the result and sanitized evidence, stop test scheduling, and remove test album memberships. Do not delete published Moments or public media as an implicit cleanup step. Report any unresolved transfer, publication, or remote key cleanup rather than treating it as reset success.

Use disposable simulator state where possible. Physical-device resets are scoped to In Process and its test album; they are not whole-device resets. A run with an unverifiable or unsafe baseline is blocked, not counted as a pass or silently continued.

## Execution environment policy

Run all feasible tests and evaluations in Simulator. AUTH-1 and MANUAL-1 can run end to end there against the real service when explicitly authorized; ordinary regressions use injected offline services. Simulator Photos can contain the synthetic screenshot fixture.

Only actual PhotoKit extension execution and scheduling require a physical iPhone. Use iPhone Mirroring to operate the phone for those evaluations when available. Mirroring is a control convenience, not an Apple runtime requirement; record whether it is connected during each observation. Mocked automatic-upload logic and UI coverage remain in Simulator.

## Two validation layers

1. **Offline automated tests:** injected service, Photos, transfer, clock, and credential adapters exercise real application logic and UI. Cover sign-in persistence with time advanced beyond one hour, single-tap publication, album filtering, existing/new asset discovery when invoked, checkpoint recovery, and deduplication. Use disposable Keychain items for storage integration. These tests never send OTPs, upload real media, or create Moments.
2. **Physical-device acceptance:** verify actual PhotoKit scheduling, discovery, and transfer, plus separately authorized service publication. Use normal scheduling with Resource Upload Test Mode off. Test Mode runs are development diagnostics and cannot substitute for normal-mode results. The actual extension cannot be validated in Simulator.

The real-time AUTH-1 check must retain the originally issued artist key across the elapsed hour; acquiring a replacement before the readback does not pass persistence. Offline clock advancement is useful regression coverage but does not establish live service longevity.

## Device procedure and evidence

- Record build, OS, account readiness without secrets, selected album, network/power conditions, Test Mode, and Mirroring state.
- Verify the extension is enabled, the baseline queue is understood, and authentication is usable before backgrounding.
- Record the host-background time and the external Photos addition time. Keep In Process backgrounded for the entire observation. Do not reinstall, re-enable, or foreground it to obtain a pass.
- Capture logs without opening the app. Correlate extension entry, asset discovery, job registration, transfer completion, and publication readback. Record time to each stage separately.
- Verify the published result through read-only service access. Do not republish to verify it.
- If opening the host is needed afterward for diagnostics, end the observation window first and label subsequent activity separately.
- Record Mirroring consistently. Backgrounded while mirrored and disconnected/locked are different conditions; neither can be silently substituted for the other.
- Use only explicitly authorized test photos. Prefer mocked or non-publishing diagnostics while investigating failures. Keep raw logs, account readbacks, screenshots, and photos under ignored `docs/verification/`.

## Result labels

- **Pass:** every required stage has evidence within the agreed acceptance window, with no host foregrounding for automatic cases.
- **Not observed within window:** no end-to-end completion by the cutoff; record the last evidenced stage. This does not establish that iOS will never schedule it.
- **Failure:** a concrete incorrect result, such as duplicate publication, outside-album publication, or a reproducible application error.
- **Invalid run:** a confounding library change, host foregrounding, changed Test Mode, or missing baseline prevents the intended conclusion.

Each report must identify whether evidence is mocked, real storage integration, physical PhotoKit execution, or live service behavior. Do not combine those into a single unqualified success claim.

## Decisions before physical execution

The provisional normal-mode background completion window is **one hour from the confirmed addition to the connected album through confirmed publication**. This is a user-selected product acceptance threshold, not an iOS scheduling guarantee, and may be revised as platform behavior becomes clearer. At the cutoff, record incomplete work as "Not observed within window" with the last evidenced stage; do not infer permanent failure or automatically retry publication. Retain later completion timing separately. The number of repeat runs and the initial Mirroring/locked-phone condition should also be recorded before execution.

This plan does not resolve the outstanding membership-only discovery issue. Existing findings remain in [the discovery investigation](background-discovery-investigation.md). No live test was initiated by writing this plan.

## Reset dry-run review — November 16, 2026

Read-only source inspection completed; no simulator or phone state was changed. No simulator was booted at inspection time.

- Existing pause persists the paused policy and attempts to disable the extension. Verify its result; a request to pause does not prove all in-flight work has stopped.
- Existing sign-out clears local access and attempts remote installation-key revocation, retaining pending cleanup when necessary. Do not call it in a read-only dry run.
- Offline fixtures already isolate storage and adapters. A dedicated disposable simulator is appropriate for live simulator evals rather than erasing an existing user's simulator.
- No general-purpose, safe test reset for the production upload ledger was found in the inspected coordinator/store. Sign-out preserves upload records; it is not a full reset. Do not directly delete the ledger as a substitute.
- Album membership cleanup can be performed in Photos after outstanding work is understood; preserve the library originals.
- Physical baseline cannot be certified from source review. Before execution, inspect current pending/uncertain work and verify quiescence, permissions, account, album count, Test Mode, and the selected fixture.

Next implementation need: define and test a scoped eval reset/preflight path that refuses unresolved publication or transfer state. Until then, physical-device reset is not an automated, verified capability.

## Execution order update — November 16, 2026

The user requested deferring the beyond-one-hour persistence readback until after the background evaluations. Preserve the live simulator session and its original key while proceeding to the physical-phone baseline and Test Mode ON evaluation. Do not reset that simulator in the meantime.

The user subsequently authorized running the persistence elapsed-time interval concurrently with phone evaluation preparation. Preserve the original simulator key from approximately 11:47 a.m. Pacific; perform the authenticated relaunch/readback after 12:48 p.m. No new sign-in or replacement key is needed to start this interval.

## Next investigation steps — November 16, 2026

Proposed after the [post-run log reanalysis](core-workflow-eval-results-2026-11-16.md#post-run-log-reanalysis-same-day-read-only). Nothing below has been executed. Each step that touches the phone, creates a library asset, or can lead to publication needs the usual explicit authorization.

1. **Recover persisted device logs for 12:17–12:20 Pacific.** Collect a log archive from the phone and look for Photos-backend and scheduler entries around the 12:19:09 launch and the 12:19:31 album addition, and identify which extension record produced the 12:40:51 validation errors. Time-sensitive: persisted logs age out and lower-level entries may not have been kept. Read-only.
2. **Check the pending operation's current state.** Read-only timeline readback first. If the host must be opened to export diagnostics, label that as outside any observation window and record whether an extension invocation occurred since 13:33.
3. **Nudge test on the retained pending item.** With the host backgrounded, add one unrelated new still to the library and leave it outside the connected album (the AUTO-OUTSIDE shape). Declare the window and record whether Test Mode is actually in effect.
   - Extension wakes, discovers the pending album member, transfers and publishes it exactly once: supports "new assets wake the extension, membership changes do not", and shows the rest of the chain works. The outside photo must not be queued.
   - No wake: something other than the trigger type is stuck. Investigate the debugger-held extension process and the validation errors before any further waits.
4. **Capture before mutating.** Start the device stream before enabling the extension, without the bundle-name filter for the Photos backend and scheduler processes, so a positive-control launch shows what a launch decision looks like in system logs. Then look for that entry, or an explicit deferral, after a membership-only addition. This targets question 4 of the discovery investigation.
5. **Remove the debugger confound where possible.** For normal-mode runs, launch without Xcode attached and confirm the host actually suspends. For Test Mode runs, record that both targets were run from Xcode and treat a lingering debugger-held extension process as a recorded condition.
6. **If step 3 confirms the model, stop repeating waits.** The open item becomes platform clarification using the standalone AlbumWakeRepro project, plus a product decision on what an album-driven workflow can promise. No correspondence has been drafted or sent.

### Procedure changes for automatic cases

- Record three separate times: asset enters the library, extension invocation(s), and album membership confirmed. Host backgrounding and the Photos addition time alone are not enough.
- Classify by ordering, not by intent. If the last extension invocation precedes the album addition, the run exercises the membership-only path (AUTO-EXISTING), regardless of whether the asset was newly imported. Do not record it as AUTO-NEW.
- A host scan performed while a debugger keeps the host running is not background discovery evidence for a suspended host.
- Start log capture before the first measured step; a capture that begins after the mutation cannot support a scheduling conclusion.
