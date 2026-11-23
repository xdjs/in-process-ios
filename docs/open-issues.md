# Open issues

## IP-001 — Manual photo selection lacks an asset identifier

**Status:** Open. Recorded November 16, 2026. Root cause not established.

**Observed:** During the live manual-upload eval on a fresh iPhone 17 / iOS 27.2 simulator, the user-authorized screenshot was imported into Photos and selected through the app's system picker. Full Photos access had been granted. The review screen displayed the missing-asset-identifier warning. Publication succeeded, but the draft did not have a source asset identifier.

**Impact:** The app cannot reliably match this manual publication to the same asset if it is later added to the connected In Process album. A duplicate automatic publication is possible; it was not attempted or observed in this run. Successful manual publication does not pass manual-to-background deduplication acceptance.

**Code path:** `RootView` constructs `PhotosPicker`; `AppModel.loadPhoto` passes its optional `itemIdentifier` into `acceptPhoto`, which stores it as `Draft.sourceAssetID`. The upload ledger matches source asset identifiers. The observed missing value does not establish whether the cause is picker configuration, platform behavior, or the simulator environment.

**Investigation:** Check the picker's library configuration and identifier delivery under full/limited/no library permission. Reproduce with an imported screenshot and an existing photo; distinguish simulator behavior from physical-device behavior. Preserve the current live session while its persistence eval is pending.

**Closure criteria:** Add regression coverage for identifier propagation and missing-identifier handling. With a known Photos asset manually published, later adding that same asset to the connected album must not create a second Moment. Prefer mocked publication for the duplicate check; separately validate actual picker identity on device when needed. Document any unavoidable missing-identifier case and its explicit product behavior. Do not resolve this by silently dropping the warning or claiming deduplication without evidence.

**Evidence:** [Live eval results](core-workflow-eval-results-2026-11-16.md). Raw artifacts remain local and ignored under `docs/verification/core-evals-2026-11-16/`.

## IP-002 — Photos access prompt appears before sign-in/setup

Status: observed, unresolved (2026-11-16).

A clean physical-device install launched from Xcode immediately presents the real Photos access dialog over the signed-out screen. No sign-in or Configure Background Uploads action preceded it. The desired flow requests full library access when the user opts into background setup. Logs confirm Photos authorization was not determined and the app had no account, configuration, or queue.

Investigate eager PhotoKit observer registration and extension-enabled queries during initialization/status refresh. These are leads, not an established cause. Closure requires a clean-install regression proving no prompt at signed-out launch, followed by exactly the expected prompt when setup requests access. Preserve manual picker use without full-library permission.
