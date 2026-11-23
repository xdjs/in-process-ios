# Development diagnostics

Debug builds use one typed `DevelopmentLog` interface for Apple unified logging
(subsystem `com.xdjs.InProcess`, category per subsystem) and an App Group JSONL
journal shared by the host and Photos upload extension. Release builds do not
emit these events or show the diagnostics screen. No telemetry is sent remotely.

## Getting the file

While signed in, open the gear on the connected home screen, then **Configuration → Developer → Development diagnostics**. The screen
creates a consistent snapshot of current and rotated history, displays its last
80 events, and offers **Share log file**. **Refresh log file** creates another
snapshot. Neither action reads the upload ledger, scans Photos, retries a job,
or publishes anything. Opening/foregrounding the host still performs its normal
scan, and that lifecycle boundary is logged.

The snapshot is also written to the host's `Documents/Diagnostics/InProcess-Diagnostics.jsonl`.
Only that sanitized, bounded snapshot is exported; the session, upload ledger,
configuration, assets, and the rest of the App Group are not exposed. General
file sharing is not enabled. From a paired development Mac, after making a
snapshot, use:

```sh
xcrun devicectl device copy from --device <paired-device-id> \
  --domain-type appDataContainer --domain-identifier com.xdjs.InProcess \
  --source Documents/Diagnostics/InProcess-Diagnostics.jsonl \
  --destination docs/verification/InProcess-Diagnostics.jsonl
```

The OS may require an unlocked device. This is a snapshot, not live streaming:
extension activity after export is included only in the next export. Direct
access to private App Group paths is neither required nor bypassed. If device
container policy rejects the Documents copy, use the share sheet. Neither route
requires a broad sysdiagnose or root on the Mac. See the local verification record
for which route was demonstrated on the connected device.

## Reading events

Each line has a schema version, unique event ID, UTC timestamp with milliseconds,
process role (`host` or `uploadExtension`), app version/build, random process
lifecycle ID, event/category/severity, phase, optional span/parent, outcome, and
allowlisted fields. `begin`/`end` pairs correlate asynchronous boundaries and
carry monotonic elapsed milliseconds. UI actions that catch errors internally
end with `returned`, not an invented success: inspect their failed/auth/config
fields and child error events. An unfinished span can indicate process death,
suspension, history rotation, or a write failure; it does not prove which one.

Useful chains:

- `authCode` → `authVerify` → secure save → identity/default collection → auth gate.
  Recovery, expiry, sign-out, and navigation are recorded without account data.
- Setup entry/current permission/prompt, album listing/selection/consent,
  compatibility preflight, secure sharing, album create/reuse, configuration
  persistence, extension enablement, notification permission, scan.
- `scan` → aggregate eligible/video/other/unsupported counts → durable
  `queueEnqueue` or dedup/removal counts. `queueEnqueue` with `pending` means an
  **application ledger entry**, not a PhotoKit registration.
- `extensionInvocation` → connectivity/config/credential checks → `worker` →
  `registration` → `systemJob`. System states include `registered` and
  `systemPending`; safe operation UUID/job hashes correlate the two processes.
- Terminal transfer state → durable checkpoint → acknowledgment **before**
  PhotoKit removes tracking. Storage readback, media upload, metadata upload,
  Moment simulation, create, and reconciliation are separate stages. Retries,
  cancellation, missing albums, auth/policy/lease blocks and no eligible work
  have distinct evidence.
- Manual picker/preparation/cancel, draft checkpoints, publish/reconcile, settings
  changes, and diagnostic export have action or stage events. Picker dismissal
  without a selection may have no PhotosPicker callback; it must not be inferred
  as a preparation failure. No per-render or text-keystroke logging is added.

`serviceStage` captures semantic operations (including injected offline adapters);
`network` captures real HTTP response status and duration. A successful transport
is not necessarily successful decoding/publication. Read the enclosing stage.
PhotoKit registration success is not transfer success. The framework may not
make a job visible immediately after registration; a later enumeration supplies
the job mapping.

No extension invocation in **retained** history means none was observed there.
It is not evidence that iOS never invoked it, nor an explanation of the OS's
scheduling. Test Mode is not publicly readable by this app and is always unknown
to diagnostics. `willTerminate` is logged if delivered; jetsam/force termination
can prevent callbacks. Logs start with the new build and cannot reconstruct
missing earlier history. Foreground-assisted progress must not be reported as
idle-background success.

## File behavior and privacy

The journal has four generations of at most 512 KiB (2 MiB total); the fixed
export adds at most another 2 MiB. A stable `flock` inode coordinates independent
writers, rotation, and snapshots. Each append commits a whole JSONL generation
using atomic replacement, avoiding torn trailing records if killed. Rotation
copies older generations before replacing current, so a crash during rotation
may duplicate historical event IDs, never silently overwrite newer committed
history. Treat event IDs as deduplication keys. Normal rotation intentionally
expires the oldest events. Snapshots hold the same lock and are chronological
in normal operation; UTC clock changes can affect wall-clock order.

Lock contention is bounded at 250 ms; logging failure never throws into upload
work or recursively logs itself. The event still goes to unified logging and a
process-local file-failure counter appears in diagnostics. A crash loses that
counter. Synchronous file I/O has development-only overhead; diagnostics cannot
be used to establish production scheduling/performance equivalence.

Files and the lock use `completeUntilFirstUserAuthentication`, folders are
excluded from backup, and no sandbox or global protection settings are weakened.
Before first unlock, file availability is not promised. Simulator does not
expose the real iOS Data Protection attribute.

The API accepts closed event/field/tag enums, numbers, booleans, random operation
UUIDs and hashed PhotoKit identifiers. Neither sink accepts arbitrary messages,
URLs, request/response bodies, headers, credential values, email/OTP contents,
user/collection names or addresses, filenames, EXIF/GPS, or photo bytes. Errors
retain only an allowlisted domain classification and numeric code; arbitrary
NSError descriptions, domains, userInfo and failing URLs are never serialized.
Logger privacy annotations alone do not sanitize the file: both sinks receive
the same source-sanitized record. Do not add free-form string fields.

## Offline verification

`DevelopmentLogFileTests` exercises real append/snapshot/export, bounded rotation,
independent concurrent writer instances with separate lock fds, role merging,
synthetic secret-bearing errors/values, export isolation, and failure handling.
`DevelopmentLogFlowTests` covers injected auth/setup/album creation, pending vs
registration, transfer/metadata/create/ack, no-work, and auth/secure-save errors.
The diagnostics UI test exercises the authenticated export screen and share
control. These do not simulate a real Photos extension scheduler.

Run the core suite and targeted UI tests following AGENTS.md. Keep exports and
verification artifacts under ignored `docs/verification/`. Do not populate logs
by creating live albums/photos/uploads or requesting real sign-in codes.

## Verified on November 8, 2026

The signed Debug build was installed over the existing app, preserving sign-in,
configuration and the photo queued at 20:30 Pacific. Foreground launches at
20:44 and 20:45 were recorded separately from the prior idle experiment. The
phone's authenticated diagnostics screen produced a 189-event valid JSONL file,
and the exact Documents-copy command above retrieved it without administrator
privileges. The file persisted across the subsequent development install.
The screen reported zero file-write failures. The host recorded two eligible
stills, one skipped video, one Pending item and zero uploading items. No new
extension invocation occurred in this retained phone history; physical merging
of a new extension invocation therefore remains unobserved. Independent-writer
file tests verified merged host/extension roles without dropped/malformed rows.

The final core suite passed 51 tests. Six distinct targeted UI tests passed
across runs (diagnostics, secure-save recovery, publication, authentication,
first Photos permission and setup/settings): 57 distinct passing tests, not a
claim of a complete UI-suite run. Signed Debug-device, Debug-simulator and
Release-device builds passed. Evidence remains ignored in
`docs/verification/development-logging-2026-11-08/`.

## Artist-key authentication

Credential creation/list/revocation emit only typed stage names and status/outcome fields. The raw key, JWT, OTP, email, installation label and key ID are never diagnostic fields. Credential transport uses an ephemeral session without persistent cache/cookies/credential storage. Key issuance checkpoints and revocation tickets live in the device-only Keychain envelope, never the diagnostic JSONL or queue. An unreadable vault cannot be interpreted as confirmed remote revocation. Do not create or revoke live keys just to generate diagnostic events.
