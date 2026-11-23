# Core workflow eval results — November 16, 2026

The [November 17 comparison](#november-17-album-and-library-comparison) records the subsequent physical-device trials.

## Scope and baseline

Plan committed as `a02adf2` on `codex/core-workflow-evals`. The tested build includes the existing uncommitted discovery diagnostic changes; this is not a claim that only the committed main tree was tested.

Two new dedicated iPhone 17 / iOS 27.2 simulators were created: one for offline tests and one for live evals. Existing simulators and the physical phone were not erased. Offline tests used their per-run isolated fixtures and disposable Keychain items. The fresh live installation reached signed-out UI; after authentication, it showed no connected album or automatic configuration. Full Photos permission was granted in that simulator. The library contains standard simulator sample photos plus the authorized app screenshot; no existing In Process album was connected.

## Results

| Check | Result | Evidence / limit |
|---|---|---|
| Offline core regression | PASS | 90 tests, zero failures. |
| Offline UI regression | PASS | 25 tests, zero failures, including immediate Publish and sign-in/setup/recovery. |
| Live email-code sign-in | PASS | Code requested to the authorized account and entered; authenticated UI identified the expected artist and showed a valid upload session. |
| Immediate relaunch persistence | PASS | App terminated and relaunched without another code; authenticated Upload status returned. |
| Beyond-one-hour authenticated access | PASS | Sign-in completed 11:47:10 Pacific; relaunch restored the saved artist credential and fresh identity/destination requests returned HTTP 200 at 12:48:00–12:48:02. No further OTP or artist-key creation occurred. |
| Live manual publication | PASS | One Publish tap began activity without confirmation and reached Published. Read-only timeline returned exactly one matching operation across its single result page. |
| Image preservation | PASS | Public media readback matches the source screenshot byte-for-byte; metadata points to that image. |
| Default price | PASS | Service readback reports 1,000,000 USDC base units; review UI showed Process collection and 1 USDC, with title/description blank. |
| Manual-to-album deduplication | NOT ESTABLISHED | Picker omitted asset identifier; the app displayed its warning. No later album upload was attempted. |
| Physical PhotoKit background eval | FAIL — observed window | With Test Mode on, the backgrounded host discovered and queued the screenshot at 12:19:31. No subsequent extension invocation or publication was observed before diagnostics retrieval at 12:48. This does not prove an indefinite failure or an OS wake deadline. Later log reanalysis (below) indicates the last extension run preceded the album addition, so this run exercised the membership-only case rather than a clean AUTO-NEW. |

The fixture is a screenshot of the app's signed-out screen with no email/code entered. It was imported before live manual selection. A fresh simulator includes Apple's sample images; only the authorized screenshot was selected and published.

The live result remains published, and the simulator remains signed in for the elapsed-hour persistence check. Automatic uploads are unconfigured there. No remote key revocation or destructive cleanup was performed. Do not reset this simulator between persistence steps.

Raw screenshots, test output, and timeline readback remain ignored in `docs/verification/core-evals-2026-11-16/`. Credentials and OTPs are not recorded in this report. No phone or normal-mode background success is claimed.

## Physical background eval baseline (12:02–12:05 Pacific)

- Inspected existing host: signed in, automatic uploads enabled but connected album missing. Paused uploads before reset. All six visible history entries were Published; no pending/uncertain entry was visible.
- Signed out through the UI. Initially remote removal was pending, then the UI confirmed this iPhone's sign-in key was removed from the service. This is server acknowledgment, not an independent rejected-key probe.
- Inspected the complete personal Albums list in Photos: no In Process album existed. No album or library photo was deleted.
- Signed Debug device build succeeded. Uninstalled only In Process and installed the new build. Both host and extension signatures have development debugging enabled and the shared App Group.
- Changed Settings > Developer > Photos > Resource Upload Test Mode from OFF to ON and visually verified it.
- Ran the host from Xcode on the phone, then ran the extension scheme with In Process as host. Xcode reported Running InProcessUploadExtension. A debugger detach notice occurred during scheme switching and was dismissed; this is not evidence of a PhotoKit job invocation.
- Fresh host console confirms authorized=false, configured=false, count=0, pending=0, uploading=0, enabled=false. No active session, connected album, or retained queue was restored.
- Real first-time Photos permission prompt appeared and remains unanswered. No new sign-in, album creation, upload or publication occurred during baseline preparation.
- Newly observed UI issue: prompt appears on initial signed-out launch, before the user enters background setup. Track separately; the expected setup ordering is not passing.
- The dedicated live Simulator session/key remains untouched for the beyond-hour check after 12:48 Pacific.

### Mirroring input recovery

At phone sign-in, clicks focused the code field (visible cursor), but type, individual key, and paste actions produced no characters. The same symptom had affected Settings/Spotlight text earlier. Quitting and reopening iPhone Mirroring restored input: synthetic digits appeared in the unchanged code field; they were replaced with the authorized email code and submitted. No app code, keyboard setting, or manual phone entry was used. This isolates a recoverable Mirroring-session problem but does not establish its OS-level root cause. When automation reports typing success, verify rendered text; reconnect Mirroring if clicks work but text consistently does not.

### Accelerated phone observation

- First Photos prompt was granted under existing authorization. Phone sign-in succeeded around 12:17 Pacific after reconnecting Mirroring; setup created the In Process album, enabled automatic uploads with cellular allowed, and granted notifications.
- Host was backgrounded before importing the authorized clean simulator screenshot through AirDrop. Photos confirmed the screenshot in the new In Process album (one item) around 12:19. This is the new/imported-asset case, not an isolated existing-asset membership case.
- Read-only timeline checks through 12:33 showed no new publication. The host was not reopened to export diagnostics during that window.
- Restored the missing Mac device-log capture dependency and began a filtered live stream at about 12:36. System events are arriving; no extension invocation has been captured yet. Capture cannot recover the earlier observation window. Persistent on-device logs remain separate.

### Retained Xcode extension console

Read the existing Xcode console without foregrounding the phone host. It contains extension invocations at 12:17:57 and 12:19:09 Pacific. Both found zero eligible assets in the connected album, loaded shared credentials successfully, received HTTP 200 for identity, and completed with no pending/registered work. The second invocation ended at 12:19:09.869, with a cancellation/connection-invalidation message immediately afterward. No later invocation was visible in that console at inspection. This establishes that the extension did run before/around the import sequence; exact album-membership commit timing was not captured precisely enough to claim a scan of a populated album. Do not equate connection invalidation after completed work with an upload failure without further evidence.

### Fresh retained diagnostics and persistence result

Retrieved the app-supported Documents/Diagnostics export after explicitly foregrounding at 12:48:16 Pacific. Export contains 719 events through 12:48:42; no file-write failure was shown. The phone was returned to Home afterward. Foregrounding/export is the end of the initial undisturbed observation window.

Verified sequence (Pacific):

- 12:18:03: host entered background.
- 12:19:09: extension ran, saw empty connected album, authenticated successfully, returned completed.
- 12:19:31: host received a library-change callback **while backgrounded**, scanned one eligible asset, and persisted one pending operation with reason waitingForExtension.
- Subsequent host library-change scans retained that same item; no further extension invocation is in retained history before the export.
- 12:48:16: explicit diagnostic foreground transition. This was not when the photo was first discovered.

Therefore this run proves background host discovery and durable enqueue, but not extension discovery of a populated album or transfer/publication. The pending item is waiting for another extension invocation; the log does not establish why iOS has not invoked it. The earlier statement that discovery was unverified is superseded by this retained-log evidence. Do not describe this run as a successful background-upload eval.

The simulator credential check passed independently: original key creation completed at 11:47:07, authentication completed 11:47:10, and relaunch after more than an hour restored authenticated UI and obtained live HTTP 200 identity and destination responses at 12:48. No new email-code verification or artist-key creation was logged during that relaunch. No additional simulator publication was requested.

### Foreground follow-up and user-ended eval

At 13:33:43 Pacific the host was foregrounded at the user's request. Fresh scans at 13:33:45 found the same one eligible asset and retained pending=1, uploading=0, enabled=true, paused=false, failed=false. No new extension invocation was captured and public timeline readback still contained no new Moment. Foregrounding did not immediately start the transfer.

The user explicitly called the eval failed and ended testing to disconnect the phone. Record FAIL for this observed accelerated run, not a claim that eventual scheduling is impossible. Stopped the owned live device capture. No reset, sign-out, retry, new photo, or publication was initiated at shutdown; automatic uploads remain enabled and the pending item may still complete later. The >1-hour simulator credential eval remains PASS. Resume from these retained logs and the pending operation rather than adding another fixture blindly.

## Post-run log reanalysis (same day, read-only)

Source: the retained `phone-diagnostics-1248.jsonl` export, the `scheduler-events.jsonl` device capture (started 12:36), application source, and Apple's background-upload guide. No device, simulator, service, or ledger state was touched. Times are Pacific.

### Ordering of import, wake, and album addition

| Time | Retained event |
|---|---|
| 12:17:41 | Album created, extension enabled. |
| 12:17:57 | First extension invocation (new process): empty album, `completed`. |
| 12:18:03 | Host backgrounded. |
| 12:18:42–12:18:47 | Four host library-change callbacks; scans still find zero album members. Consistent with the AirDrop import landing in the library. |
| 12:19:07 | Host library-change callback; zero members. |
| 12:19:09 | Second extension invocation (same process): empty album, `completed`. |
| 12:19:31 | Host library-change callback; scan finds one album member and enqueues it (`waitingForExtension`). |
| 12:19:31 → 13:33 | No further extension invocation in retained history or capture. |

The last extension run therefore **preceded** the album addition by about 22 seconds. The import (a new library asset) is the likely trigger for the 12:19:09 run; that attribution is inferred from timing and is not proven. The 12:19:31 addition was then a membership change on an asset already in the library. This run is the membership-only case documented in [the discovery investigation](background-discovery-investigation.md), now observed with Test Mode on over roughly 74 minutes, not a clean AUTO-NEW execution and not evidence of a new transfer or publication fault. No job was ever registered, so the transfer path was not exercised.

Under the plan's result labels this is closer to **Not observed within window** (last evidenced stage: host enqueue; no extension discovery) than to a concrete Failure. The user's FAIL call for the accelerated run stands as recorded above; this section only narrows what failed.

Import followed by a separate add-to-album step is also the ordinary user flow. AUTO-NEW can pass only when the wake happens to arrive after the album addition, so the membership-only wake is on the main product path rather than an edge case.

### Confounds found

- **Debugger-held processes.** The capture shows the extension carrying a `DeveloperToolsDebugging` assertion from 12:38 to at least 13:32, after it had logged termination at 12:19:09. Whether a debugger-held extension process affects re-invocation is unknown. The host also kept receiving library callbacks while backgrounded (through 12:33), probably for the same reason. The earlier statement that this run "proves background host discovery" should be read as discovery by a debugger-attached host; a suspended host would not be expected to scan.
- **Unattributed validation errors.** At 12:40:51 `assetsd` logged three `extension record validation failed … missing valid a Info.plist BaseURL key` errors (Photos error 50207) for the background-upload extension point. The lines do not name the extension. The In Process extension declares `BackgroundUploadURLBase` as Apple documents and had already been invoked twice, so another installed record (for example the AlbumWakeRepro diagnostic) is possible. Unresolved.
- **Late capture.** The device stream began at 12:36, after both invocations and the album addition. It contains no system-side record of a launch decision, so it cannot distinguish "change did not create eligibility" from "eligible but deferred".
- **Test Mode scope.** Apple's guide states the mode takes effect only when both host and extension are built and run from Xcode with development signing. Once the phone was disconnected the pending item is under whatever scheduling applies without that session; later completion must not be recorded as a Test Mode result.

### Documentation points relevant to this run

Apple's guide says `.completed` puts the system into monitoring mode for library changes, without listing which changes cause a later call. `.processing` is to be returned only when the invocation made progress. Job creation is described as happening inside the extension. None of this confirms or rules out membership changes as a wake trigger.

Next steps are recorded in [the eval plan](core-workflow-evals.md#next-investigation-steps--november-16-2026).

## Evening clean-baseline repeat — FAIL within one-hour target

The user authorized a fresh baseline and an unattended monitored repeat, with the debugger disconnected. This is an existing-asset album-membership test, not a new-library-asset test.

- Reconciled public timeline before reset: twelve Moments, no new publication from the earlier pending screenshot. Signed out with remote installation-key revocation acknowledged, deleted only the In Process album (library assets retained), and uninstalled/reinstalled the same development build.
- Started a broader sanitized system/app log stream before fresh launch and setup. No Xcode run or debugger attachment was used. The premature first-time Photos prompt reappeared (known IP-002); granted the already-authorized access, signed in, created a fresh empty album, enabled uploads, and allowed notifications.
- Initial extension invocation at 19:16:47–19:16:48 Pacific scanned the empty album and completed. Host entered background at 19:16:57; system records show it suspended with `debug:none` shortly afterward.
- Resource Upload Test Mode was visibly ON and left unchanged. Because this repeat deliberately avoids an attached Xcode launch/session, accelerated scheduling is not established merely by the switch. Do not label it a verified accelerated-mode pass or a normal-mode run.
- Added the existing authorized clean sign-in screenshot to the new album at approximately 19:19; Photos visibly showed exactly one item. Returned to Home without reopening In Process. No new library asset was imported for this step.
- At 19:26 the public timeline still contained twelve Moments; no post-addition extension event had been captured. System log capture remained active.

The monitored acceptance deadline is 20:19:30 Pacific (one hour from the approximate album-addition time). Read-only public timeline polling and existing wired log capture do not launch the host. A missed deadline is an eval failure against the one-hour target, not proof that eventual execution is impossible. Any later completion must be recorded separately. Raw snapshots and monitor records remain ignored under `docs/verification/core-evals-2026-11-16-evening/`. Final outcome: **FAIL against the one-hour publication target**, as detailed below.


### Final evening result, 20:19:30 Pacific

**FAIL (one-hour acceptance window missed).** The authorized screenshot did not produce a new Moment by the deadline. All 53 read-only timeline checks from the start of the monitor through the deadline succeeded and returned the same twelve Moments with no changed records. This is a completed evaluation result, not a claim that eventual background execution is impossible.

The live system capture continued through 20:19:30. No post-addition extension event was captured; the last app event was the host entering background at 19:16:57. The initial empty-album extension invocation is present, establishing that the capture could observe this extension before the test. System records show the host suspended without a debugger, with a brief system-reported background-active interval near 19:50 followed by suspension again; that interval is not evidence of user foregrounding or extension execution. No post-addition foreground transition or DeveloperToolsDebugging assertion was found in the filtered lifecycle evidence. We did not reopen In Process, add another asset, or change settings during observation.

The earlier spoken claim that live capture stopped before the deadline was incorrect: capture-file timestamps and continuously received system events establish that it remained active throughout this window. The owned timeline monitor completed and the owned live device stream was stopped only after the deadline and evidence review. No raw evidence was added to Git.

Interpretation: removing the attached debugger did **not** make this existing-asset membership-only case pass within one hour. We still cannot distinguish an unsupported membership trigger from delayed system eligibility/execution. Do not call this a proven transfer failure: no post-addition extension scan or registered upload job was observed. The Test Mode switch remained ON, but the Xcode launch condition for acceleration was deliberately not re-established, so acceleration remains unverified.

Phone state left intact: signed in, automatic uploads enabled, screenshot still in the connected album, Test Mode ON, app not deliberately foregrounded. The item may publish later. We did not open the app to inspect/export its private retained history at the end, because that would introduce a foreground scan. No active overnight monitor is claimed; the bounded one-hour determination is complete and saved here.

Next investigation should start with a read-only timeline check and retained/system evidence, recording any later completion separately. Before another live experiment, reconcile this asset rather than adding another blindly. A useful next controlled comparison is a new-library-asset wake versus this membership-only change, while preserving the same debugger-free baseline; that comparison was not performed during this run. Resolve the Test Mode launch-versus-detach conditions explicitly before describing future results as accelerated.

### Morning follow-up — November 17, about 07:42 Pacific

Checked the public timeline **before** reopening the phone app: twelve Moments, exactly unchanged from the deadline readback. No overnight publication was found. Retrieved a device system archive (approximately 320 MiB, requested one day with a 500 MB cap) before foregrounding. The targeted archive query returned only recent network/CommCenter references; it supplied no overnight extension launch or scheduler decision. Do not represent that archive as complete overnight scheduling evidence.

Foregrounded the host at 07:42:35 solely to access Development diagnostics, exported the complete retained snapshot through the supported Documents path, then returned to Home. The snapshot contains 437 events beginning with the fresh install at 19:15:16 the previous evening, with zero file-write failures reported by the current process. Its sole recorded extension invocation remains 19:16:47–19:16:48, before the album addition. There is no retained app/extension event between the host's 19:16:57 background transition and this morning's foreground transition.

At **07:42:35**, the foreground scan found one eligible item and created its first pending ledger entry, reason `waitingForExtension`. Subsequent scans retained pending=1, uploading=0, enabled=true, paused=false, failed=false. The UI showed valid credentials and full Photos access. Thus this debugger-free repeat did **not** record background discovery/enqueue overnight, unlike the debugger-held afternoon run. No post-addition PhotoKit registration or transfer is evidenced. Today's foreground-assisted enqueue must not be attributed to overnight background activity.

The one-hour FAIL remains, with no eventual publication by the morning pre-foreground check (roughly twelve hours after album addition). The evidence still does not explain why the extension did not run again. App and settings remain intact; automatic uploads are enabled and the newly queued item can complete later. Raw archive, retained log, and timeline response are local and ignored in `docs/verification/core-evals-2026-11-17/`. No new photo, manual publish, retry, code change, commit, or merge was made for this follow-up.

### Late publication and the role of power — November 17

**The screenshot published at 10:54:07 a.m. Pacific, about 15 hours 35 minutes after it was added to the album.** The timeline gained one Moment (twelve to thirteen). The downloaded image matched the test PNG byte for byte. The one-hour end-to-end eval remains **FAIL**.

**Evening power and discovery.** The phone was connected to power at the start. Device scheduler evaluations for other activities repeatedly recorded a plugged-in state from 7:15 to 8:18 p.m., corroborating the observed setup. The initial extension run saw an empty album. After the screenshot was added, the retained log shows no further invocation or queue entry until the foreground scan at 7:42 a.m. There was no recorded transfer for this screenshot for external power to help overnight. Continuous power and the scheduler’s energy budget through the rest of the night are unknown. The reason Photos did not wake the extension to discover the album change remains unresolved.

| November 17, Pacific | Evidence for the queued screenshot |
|---|---|
| 10:45–10:53 a.m. | The device scheduler repeatedly deferred the specific network task that later completed the photo upload. Its decisions cited battery-life pressure and an exhausted energy budget. |
| 10:53:53–58 | iOS reported external power connecting. The next decision cited a full background networking pool. Within four seconds the scheduler approved the task, and Photos recorded upload success one second later. |
| 10:54:00–07 | Photos found work for its upload extension runner, the scheduler approved it immediately, and the In Process extension launched. Photos logged developer mode engaged for this invocation. The Moment appeared on the timeline. |
| 10:54:14 onward | The Mac logged iPhone Mirroring reopening. The phone recorded the host app visible at 10:54:33. Both followed publication. |

The job-specific decisions support external power as a likely contributor to the **morning transfer** resuming. Transfer completion then gave Photos work for the extension. The logs explain this 10:54 wake only, not the earlier invocation that registered the job (see the review below); the morning foreground scan had already discovered the screenshot. The device archive, scheduler decisions, Mac Mirroring events and timeline readback are retained locally under `docs/verification/core-evals-2026-11-17/late/`.

### Review of the evening, overnight and late-publication findings — November 17

Read-only check of the sections above against the retained export and the `late/` extracts. No device or service state was touched. Where this review and an earlier sentence disagree, this review states the correction; earlier text is otherwise left as written.

**Confirmed against raw evidence.** The morning export contains one extension invocation (19:16:47, before the album addition), nothing between the 19:16:57 background transition and the 07:42:35 foreground, and the first queue entry at 07:42:35. The upload task was deferred from 10:45 to 10:53 on battery-life and energy-budget policies, power connected at 10:53:53, the task was approved at 10:53:57, and Photos logged upload success at 10:53:58. Photos found extension-runner work at 10:54:00 and launched the extension within a second. The newest timeline Moment is stamped 10:54:07.

**Corrections and gaps.**

1. **An unrecorded extension invocation registered the job, apparently around 08:08.** The scheduler's record for the upload task gives its window as 08:08:00 November 17 to 08:08:00 November 24. Upload jobs are created only inside the extension, so an invocation must have discovered the queued item and registered the job by then, roughly 26 minutes after the 07:42:35 foreground scan. Treating 08:08 as the registration time is an inference from the task window. This is the first extension run after the album addition, and its trigger is unknown. The late-publication table begins at 10:45 and does not cover it.
2. **No app diagnostics were exported after publication.** `late/export.jsonl` is byte-identical to the 07:42 export. The retrieved system archive reaches back only to about 10:45. A fresh Development diagnostics export is the available evidence for the 08:08 and 10:54 invocations and should be retrieved before the retained history rolls over.
3. **Developer mode was engaged without an Xcode session.** At 10:54:00 Photos logged developer mode engaged for this extension, with no Xcode launch since the previous evening's reinstall. This conflicts with the evening section's statement that acceleration was not established because the Xcode launch condition was not re-established. Whether the mode was in effect at the 19:19 album addition is not logged. If it was, the overnight absence of a wake occurred under accelerated scheduling and is a stronger negative than stated; this is not established either way.
4. **The transfer ran as a maintenance-priority task with a seven-day window.** Off external power it was deferred at least from 10:45 to 10:53, and possibly from registration. Separately from the wake question, a one-hour publication target may not be attainable on battery once a job is registered. One observation; not a characterization of every transfer.
5. **Battery state was not recorded.** The deferrals cite a battery-life challenge, but battery level and Low Power Mode state during the morning are not in the evidence. Record both in future runs.
6. **Process identifier in the afternoon reanalysis.** The earlier wording that the extension process had "one pid throughout" was wrong: the number cited identifies the Photos daemon hosting the extension. The sentence has been corrected; the developer-tools assertion finding is unchanged.

**Resulting picture.** Two distinct delays were observed in this run: no extension wake for about twelve hours after a membership-only change, then a registered transfer waiting for power. The first post-addition wake followed a host foreground scan by about 26 minutes, whereas the November 16 afternoon foregrounds at 12:48 and 13:33 were not followed by an observed wake. What caused the 08:08 invocation is the next question to answer, starting from a fresh diagnostics export.

### Post-publication diagnostics export — November 17, 11:18 Pacific

Retrieved to answer the open question in the review above. The host was foregrounded at 11:18:15 through iPhone Mirroring solely to open Development diagnostics, which wrote a fresh snapshot; the Share action was not needed. The phone was returned to Home afterward. This foreground is outside any observation window. The snapshot holds 765 events through 11:18:21 with zero file-write failures reported, and is stored locally and ignored under `docs/verification/core-evals-2026-11-17/post-publication/`. No photo, setting, retry or publication was initiated.

| November 17, Pacific | Retained event |
|---|---|
| 07:42:35 | Host foreground scan enqueues the screenshot (already recorded above). |
| 07:42:54.8 | Host enters background. |
| 07:42:56.1 | Host records one library-change callback. Its cause is not identified. |
| 08:07:56.7 | Extension process starts and is invoked. It finds the one pending item, authenticates, and registers the PhotoKit job at 08:07:58.6 (state `registered`). Returns `processing`. |
| 08:07:58 → 10:54:01 | No app or extension event. |
| 10:54:01 | New extension process. The job is reported `succeeded` at 10:54:02.9, acknowledged, metadata uploaded, Moment created; the record reaches `published` at 10:54:08.0. Returns `processing`. |
| 10:54:08.1 | Immediate follow-up invocation finds no eligible work and returns `completed`. |
| 10:54:33 | A fresh host process starts in the foreground (the Mirroring reopen noted above), restores the session, and re-applies extension options. It follows publication. |

**What this establishes.**

- The inferred registration invocation is confirmed, at 08:07:56–08:07:58. It was the first extension run after the album addition, about 12 hours 49 minutes later, and it worked from the ledger entry the 07:42:35 foreground scan had created.
- The registered job then waited 2 hours 46 minutes (08:07:58 to the transfer approval at 10:53:57) with no extension activity. Combined with the scheduler evidence above, the wait after registration was in the system transfer, not in the app.
- Once the transfer completed, the remaining chain ran in about seven seconds within one invocation.

**Timing observation, not a conclusion.** The 08:07:56.7 invocation began 25 minutes 0.6 seconds after the 07:42:56.1 library-change callback, and 25 minutes 1.8 seconds after the host backgrounded. An interval that close to a round figure suggests a fixed scheduling delay keyed to one of those two events. It is a single observation. The evening album addition at about 19:19, made while the host was suspended, was not followed by an invocation 25 minutes later or at any point overnight. What the 07:42:56 change was, and whether host activity or that change started the interval, are unknown.

**Next controlled test suggested by this.** With the same debugger-free setup and the phone on power, add an existing still to the album, confirm no wake over a declared window, then foreground the host briefly and background it. Record the background time and any library-change callback, and time the next extension invocation. A repeat of roughly 25 minutes would indicate a host-driven path to a wake; its absence would point back at the unidentified library change. Record battery level, Low Power Mode and charger state.

### Host foreground-then-wait trial — November 17, 11:18–11:52 Pacific

Purpose: test whether opening and closing the host is by itself followed by an extension invocation about 25 minutes later, as the 08:07:56 timing suggested. No photo was added, removed or edited, and nothing could publish: the queue was empty and the only album member was already published. The system cannot see the app's queue, so an invocation is measurable without pending work.

- Host foregrounded 11:18:15 (the diagnostics export above) and backgrounded at **11:18:38.99**. The host logged a library-change callback at 11:18:14.9, just before foregrounding, and none after backgrounding.
- The phone and In Process were then left untouched by this session for the window. iPhone Mirroring showed a paused connection when revisited and resumed on a click.
- Host foregrounded again at **11:52:26** only to write a new diagnostics snapshot (796 events, zero file-write failures reported), then returned to Home. Snapshot stored locally and ignored as `post-publication/retained-log-1152.jsonl`.
- **Result: no extension invocation** between 11:18:39 and 11:52:26, a window of 33 minutes 47 seconds. The latest retained invocation remains 10:54:08.
- The earlier background at 10:54:41 was also not followed by an invocation before the 11:18:15 foreground, but that interval was only about 23.5 minutes and is inconclusive.

**Conditions.** Debugger-free. The user states the phone was plugged in to power for the whole trial. Battery about 70 percent by the status-bar icon with no Low Power Mode colouring visible; the icon showed no charging indicator through Mirroring, so that visual cue is not a reliable power reading. Test Mode switch not rechecked. No system log capture was running, so the result rests on the app's retained log.

**Reading.** Opening and closing the host did not, in this one trial, produce a wake within about 34 minutes. Two things differed from the morning case that did: at 07:42:56 a library change was recorded about a second after the host backgrounded, and none was recorded here; and nothing else is known to have differed. Because this trial ran on external power, lack of power does not explain the missing wake. This points away from host activity alone and toward the unidentified 07:42:56 library change as what preceded the 08:07:56 invocation. Power state at 07:42–08:08 is not logged; the scheduler evidence above shows external power connecting at 10:53:53, so the phone was not on power continuously that morning. One negative trial does not rule the host path out.

**Next discriminating test.** The on-power host open-and-close case is the trial above. What remains is the library-change case: on external power, ideally with a system log stream running from before the first step, add one new still to the library outside the album and wait 30 minutes for an extension invocation. Record battery, Low Power Mode and charger state.

## November 17 album and library comparison

We compared three changes on the same physical iPhone. In Process stayed in the background, the debugger was detached, and the phone was connected to external power. Resource Upload Test Mode was on. Photos logged that mode as engaged on the two runs with a recorded wake. Device logs established when Photos accepted each change and when the extension ran. Read-only service queries established whether a Moment appeared. All times are Pacific.

| What changed | What the extension did | Timeline result |
|---|---|---|
| **New image outside the album.** At 13:11:06 a screenshot entered the general library. The monitored album still held one previously published photo. | The extension started within one second, scanned the album, found no eligible work, and exited. No further invocation appeared through 13:41:06. | Stayed at 13 Moments throughout the 30-minute control. |
| **New image added to the album.** Calculator entered the library at 13:42:56. Photos confirmed its addition to the album at 13:43:10. | The extension started at 13:48:14, discovered Calculator, and registered one transfer by 13:48:16. It observed transfer success at 13:51:26 and recorded publication at 13:51:31. Its queue drained. | Exactly one new Moment, stamped 13:51:30, **8 minutes 20 seconds after album addition**. The downloaded PNG matched all 334,072 source bytes. |
| **Existing image added to the album.** Photos confirmed the addition of the November 8 blue-and-yellow diagnostic image at 14:02:35. The album grew from two items to three. No asset was imported for this trial. | No extension invocation was recorded before the user ended observation at 14:30:04, about 27½ minutes later. No host foreground was recorded. | Stayed at 14 Moments. The one-hour target was **unevaluated** for this run. The image remained in the album with uploads enabled at cutoff. |

**What caused the Calculator wake?** An extra lock-screen capture entered the general library at 13:42:03 and stayed outside the monitored album. At 13:42:04 iOS scheduled the runner that later processed Calculator. The runner was already scheduled before Calculator entered the library or album. This trial verifies background discovery, transfer, and publication once the extension runs. It leaves the album change's independent effect on scheduling unresolved.

The existing-image trial adds a second observation window to the earlier debugger-free one-hour miss. In both, Photos accepted the membership change and no extension wake was recorded during observation. Neither trial establishes an upper bound on scheduling delay. The successful Calculator run establishes timing under Test Mode only.

### After the existing-photo observation ended

The phone’s retained log shows that opening the host at 14:30:39 first queued the existing photo. At 14:32:35 iCloud Photos applied three asset updates; their contents and originating device were not identified. The host went back into the background at 14:32:58. At 14:48:28 a separate iCloud batch brought in a new asset. Photos submitted an extension runner three seconds later, and iOS approved it at 14:48:45 with Test Mode engaged. The extension found the existing pending record, registered its transfer and observed success at 14:48:54. The timeline gained exactly one Moment at 14:49:00; the image matched all 2,952 fixture bytes.

Publication took 46 minutes 25 seconds from album addition. The foreground visit explains discovery. The later cloud import immediately preceded scheduling, but the logs cannot attribute the wake to the iPad deletions or album membership alone. Use the [wake scenario matrix](photokit-wake-evals.md) to test those explanations independently.
