# Eval results — November 18, 2026

One pass over the [core workflow evals](core-workflow-evals.md) and the drivable rows of the [wake matrix](photokit-wake-evals.md). Each result is one run; none is a reliability claim. Times are Pacific. Raw logs, readbacks and fixtures stay ignored under `docs/verification/evals-2026-11-18/`.

**Headline.** An existing photo added to the album was discovered and published by the extension alone in 8 min 9 s (row 6). An identical membership-only wait after a fresh import produced no wake in 15 minutes (row 5), and neither did opening and closing the host (row 10). The membership-only wake therefore happens but is not dependable inside 15 minutes.

## Core workflow evals

| ID | Result | Evidence |
|---|---|---|
| Offline regression | PASS | 115 tests, zero failures: 90 unit, 25 UI. Mocked services only. |
| AUTH-1 | PASS, persistence only | The live Simulator, signed in November 16 at 11:47:10, relaunched without a code. The identity request on the saved key returned HTTP 200 at 13:14:57, about 49 h 28 m after sign-in. No new sign-in was run, so the email-code step itself was not re-tested. |
| MANUAL-1 | PASS, live | One Publish tap on a fresh app screenshot showed progress with no confirmation and reached Published. Readback: exactly one new Moment (token 16), image byte-identical to the fixture, blank title and description, price 1,000,000 base units. The result link was not opened. |
| AUTO-OUTSIDE | PASS, device | Wake row 3. |
| AUTO-EXISTING | PASS, device, 15-minute window, Test Mode engaged | Wake row 6. |
| AUTO-NEW | Not observed within 15 minutes | Wake rows 5 and 10. Published late, 37 m 24 s after the album add, after the host had queued it. |
| AUTO-DEDUP | PASS, offline only | Covered by the offline suite. Not exercised on the device beyond rescans that enqueued nothing twice. |

## Device conditions

- iPhone Air on external power and Wi-Fi, signed in, uploads enabled, cellular allowed.
- iPhone Mirroring connected for the whole run. The phone was never unlocked by hand.
- No debugger. The system log printed "Developer mode engaged" for the upload runner on every run, so treat these as Test Mode results.
- Baseline at 13:24: nothing pending or uploading. The album was not emptied; it held two already-published photos.
- Earlier the same day, before this session, the extension ran at 07:32, 07:33 and 11:29 with nothing to do. Causes are unknown.
- Each window is 15 minutes, not the plan's one hour.

## Wake matrix rows

| Row | Intervention | Wake | First discovery | Publication |
|---|---|---|---|---|
| 1. Quiet phone | Host backgrounded 13:25:43; no change until 13:41:15 | None, and no runner request, in 15 m 32 s | Not applicable | None, as required |
| 3. Import outside the album | Fixture A dropped into the library at about 13:42:35 | Extension entered 13:45:17, 2 m 42 s later | Not applicable; the outside photo was skipped (eligible count stayed 2) | None, as required |
| 6. Existing photo added | Fixture A added to the album at about 13:58:22 | Extension entered 14:06:19, 7 m 57 s later | Extension | One Moment (token 17) at 14:06:31, byte-identical, 8 m 9 s after the add |
| 11. Transfer finishes | Followed row 6's job | Extension re-entered 14:06:26, about 5 s after registration | Not applicable | Same Moment; job acknowledged, then created once |
| 5. New photo, then album | Fixture B imported about 14:14:23, added to the album about 14:14:42 | Import woke the extension at 14:14:24; that run ended 14:14:26, before the add. No wake from then to 14:29:53 | None by the cutoff | Absent at cutoff |
| 10. Open and background host | Opened 14:30:37, backgrounded 14:30:47 | None from then to 14:45:55 | Host, at 14:30:37 (pending, waiting for the extension) | Absent at cutoff |

Rows 2, 4, 7, 8, 9, 12, 13 and 14 were not run. They need the camera, a second iCloud device, a power change, an unlock or a test endpoint.

## Late publication of fixture B

The phone was left untouched after 14:30:47. Photos signalled upload-runner work at 14:51:44 and submitted the runner at 14:51:47. The extension entered at 14:51:54, registered the job, re-entered at 14:52:00 when the transfer finished, and published at 14:52:06. Readback shows exactly one new Moment (token 18), byte-identical to fixture B.

- 37 m 24 s after the album add (about 14:14:42).
- 21 m 29 s after the host queued it (14:30:37).
- First discovery was by the host, so this is foreground-assisted discovery with background publication. It does not count as an AUTO-NEW pass.
- As in row 6, the capture does not show what raised the signal. This session made no library change and did not open the app in that interval; activity on other iCloud devices is not known.

Two album additions today were followed by an unexplained runner signal, 7 m 49 s and about 37 m after the add. Both fit a membership change that is noticed late, and both fit an unrelated library event. One more capture that includes Photos library-change lines would separate these.

## What the scheduler log adds

- **Row 3 delay.** Photos submitted the runner activity at the moment of import (13:42:35). The scheduler held it at 13:44:00 on Thermal Policy and started it at 13:45:02. The 2 m 42 s gap was scheduler deferral, not a missing trigger.
- **Row 5 import.** Submitted 14:14:23.6, started 14:14:23.9, extension entered 14:14:24.4. With no deferral an import wakes the extension in under a second.
- **Row 6 trigger.** Photos logged "Signaled background processing needed" for the upload runner at 14:06:11, 7 m 49 s after the album add, then submitted and started the runner at 14:06:18. The capture does not show what raised that signal. The album add itself produced no runner submission at 13:58.
- **Rows 5 and 10.** No runner submission appears after 14:14:26. The capture was still receiving other device lines at 14:45:59.

## Open after this run

- What raised the 14:06:11 signal. Candidates not ruled out: delayed processing of the membership change, or iCloud upload of the new asset changing it. Photos showed "Syncing Paused" at 13:42 and "Syncing 1 Item" at 14:14.
- The timeline now reports `ar://` metadata links for tokens 14–17. Token 16 read back as an HTTPS link one minute after creation and as `ar://` by 14:46, so the service appears to move content to Arweave after publication. The project notes describe public Supabase HTTPS objects only.
- Fixtures A and B remain in the phone library and the In Process album. Nothing was deleted. Nothing is pending on the phone.
