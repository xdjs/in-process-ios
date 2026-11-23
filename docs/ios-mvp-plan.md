# In Process iOS MVP plan

Date: November 8, 2026

Status: Native MVP implemented. A real simulator journey completed on November 8, 2026: email OTP sign-in → Apple photo picker → review → one publication → live timeline readback. Bundle identifier: `com.xdjs.InProcess`. Physical-device acceptance checks remain. The original plan below is retained as the product specification; the verification record at the end supersedes its planning-only status statements.

## Subsequent automatic-upload implementation

The app now targets iOS 27 throughout and includes the album setup/status workflow, shared durable queue, and PhotoKit extension adapter described in [the background-upload plan](background-upload-plan.md). Manual publishing keeps its immediate single Publish tap. Supported image bytes, formats, dimensions, orientation and embedded metadata are retained rather than routinely converted/resized/stripped; old verification entries below remain historical evidence. Offline tests cover both workflows, while production automatic enablement and physical-device acceptance remain subject to the [server compatibility gate](photokit-server-requirements.md). No new live Moment was created during this implementation. A separately authorized [one-image physical PhotoKit diagnostic](phone-diagnostic-checklist.md) succeeded with exact source/readback bytes, Test Mode off, and Mirroring connected; two later authorized operations also passed with Test Mode ON, host backgrounded and then Mirroring disconnected/phone locked, using Xcode development runs. The user subsequently confirmed the full album-to-publication chain with Test Mode ON. A separate photo remained Pending overnight with Test Mode OFF; normal-mode scheduling remains unresolved, and that investigation is paused pending a fresh diagnostic export.

## Goal

Let an existing In Process user publish one deliberately selected photo from their iPhone to their existing In Process timeline, with a short review step and clear confirmation.

The first release follows this journey:

**Sign in → choose one photo → review → publish → confirmation → view timeline.**

In Process currently handles storage and publication costs, as confirmed by the project owner. The MVP needs no payment, wallet-funding, or cost-management flow for the uploading user. The Moment's collect price is a separate setting for people collecting it.

## What we observed on the website

We walked through the live website together, with the user operating the site and screen snapshots confirming each stage:

1. Privy presents an email sign-in form, then a six-digit email confirmation code and a resend option.
2. Successful sign-in returns to the collective timeline with the user's existing account name displayed.
3. Create opens New Moment. The form has media selection, collection, title, price, description, and an Advanced section.
4. For this account, collection displayed Process and price defaulted to 1 USD. Title and description were initially blank.
5. Selecting an image produced a large preview and a Set Preview control. The user manually entered the title “just noodling.” This does not establish what would happen with an empty title.
6. Advanced showed Total Supply, Mint Time, and Revenue Splits. The supply placeholder explicitly said leaving it empty means an open edition. Mint Time was empty and no split recipients were shown.
7. The user left description and advanced settings untouched and clicked Create. The button changed to “creating…” before navigating to a success page.
8. The success page showed the image, title, a collect price of 1 USDC, Share, Visit timeline, and an optional Airdrop section.
9. Visit timeline opened the user's timeline, with the new Moment first in the Process collection.

This verifies the website journey for an existing account. It does not yet verify native iOS authentication, the API write flow, new-account onboarding, empty-title support, or the precise stored values behind omitted advanced fields.

## MVP scope

Target iPhone only, in portrait orientation. Native iPad layouts and testing are out of scope for this MVP; this does not prevent possible iPad compatibility-mode execution.

### Sign-in

- Use Privy email and verification-code sign-in, connected to the user's existing In Process identity and timeline.
- Include resend, incorrect/expired-code handling, session restoration, and sign-out.
- Verify how a native client uses the appropriate Privy application configuration and resolves the existing artist/wallet identity. A separate Privy integration must not silently create a different identity.
- Focus the first release on existing In Process users. Determine the behavior for an unrecognized account before implementation; do not silently invent a new-account provisioning flow.

### Photo selection

- Select one still image through Apple's system photo picker.
- Access only the selected photo; do not request full photo-library access for this manual flow.
- Show a preview and allow replacement or removal before publishing.
- Handle cancellation and photos that must first be fetched from iCloud.
- Verify accepted formats and limits. Plan a compatible image conversion path for iPhone photos where needed; preserve orientation and define quality and metadata handling before implementation.

### Review and publication defaults

| Setting | MVP behavior | Verification needed |
| --- | --- | --- |
| Photo | Show the selected image as the main preview | Confirm whether the service needs a separately generated preview asset |
| Title | Optional editable field, as agreed for the product | Verify empty-title support; if unsupported, agree on a fallback before building |
| Description | Optional editable field | Website creation succeeded with it blank |
| Collection | Use the user's Process collection by default and show the destination | Resolve the correct collection for each account and handle a missing collection |
| Collect price | Match the observed default: 1 USDC | Verify the API currency and amount corresponding to the website's 1 USD display |
| Supply | Open edition | Verify the API representation of this default |
| Mint time | No user-selected schedule | Verify the meaning of omission; do not assume it represents the photo's capture date |
| Revenue splits | No user-added split recipients | Verify service defaults and any existing protocol allocation |

Keep advanced settings out of the initial review screen, as agreed. Default price and collection need not become full editing workflows in this release. Make the publication destination and collect price understandable before the user taps Publish.

Publishing starts immediately when the user taps Publish Moment (or Continue publishing) after review; there is no additional confirmation popup. The app should explain succinctly that this publishes a Moment and stores the media permanently; it should not suggest that uploaded photos are private backups or can necessarily be deleted from permanent storage.

### Progress, recovery, and completion

- Prevent repeated taps while publishing.
- Retain enough local draft and operation state to recover from network interruptions or an app restart.
- Distinguish preparing the photo, transferring media, creating the Moment, and confirmed completion where the integration exposes those stages. Do not invent percentage progress for stages without it.
- Reconcile uncertain results before retrying creation so an interrupted response does not cause duplicate Moments. Verify whether the API supports idempotency or another reliable reconciliation mechanism.
- Show a success screen with the photo, confirmation, and a link to the published Moment or the user's timeline, plus an action to select another photo.
- Use the website for viewing the timeline in the first release; a native timeline browser is not required.
- Investigate continuation of a user-initiated transfer when the app leaves the foreground. Do not promise uninterrupted background publication until the full upload, authentication, and creation sequence has been tested on a device.

## Out of scope for the first release

- Watching a Photos album or automatically uploading new photos.
- Whole-camera-roll backup, bulk uploads, videos, Live Photo motion, and other media types.
- Creating or managing collections, changing advanced mint settings, and configuring revenue splits.
- Collecting, airdrops, payments, social features, and a native timeline feed.
- A full editor, custom preview editor, or new-account onboarding flow.

## Integration discovery before implementation

The documentation describes separate media/metadata storage and Moment creation stages. Confirm the currently supported production flow rather than treating the web examples as a complete native-client contract.

1. **Identity:** Confirm Privy iOS support and configuration, session/token handling, account-to-artist mapping, and authorization for creating on the existing timeline.
2. **Upload:** Confirm the supported upload service, required media and metadata structure, preview handling, file limits, and how In Process supplies storage funding. Do not embed a shared privileged storage key in the app.
3. **Creation:** Confirm the current endpoint/domain, authentication, whether a signature is needed, existing-collection support, price/currency units, and defaults. The reviewed creation documentation used an older domain than other pages, so examples need reconciliation with the live service.
4. **Metadata:** Resolve optional-title behavior, image formats, EXIF/location handling, and whether any capture date should be preserved separately from publication time.
5. **Reliability:** Establish idempotency or reconciliation, publication status, indexing delay, and how to construct a valid viewing link.
6. **Architecture:** Prefer a native SwiftUI client using the system photo picker and supported authentication/upload interfaces. Add a small server component only if the supported integration requires protected credentials or server-side orchestration; this is not yet an architecture decision.

## Implementation sequence after authorization to build

1. Resolve the integration questions and record the verified request/response contract and default values.
2. Build sign-in and confirm the expected existing identity and destination collection.
3. Build single-photo selection and the review screen with optional title and description.
4. Implement upload, metadata creation, Moment publication, progress, and recovery without duplicates.
5. Add confirmation and viewing links, then verify the complete journey on a physical iPhone.

## Acceptance criteria

- An existing user signs in with email and verification code and reaches the correct In Process identity.
- The user selects one image without granting full-library access, sees a correctly oriented preview, and can replace or cancel it.
- Title and description can be omitted in the product flow, with any API-required fallback explicitly resolved first.
- Publishing uses the correct Process collection and agreed defaults without a funding or payment step.
- The resulting Moment appears on the correct timeline with the selected image, submitted metadata, and expected collect price.
- The app confirms completion and opens a valid viewing link.
- Errors leave a recoverable state; retries and repeated taps do not create duplicates.
- Device verification covers an iCloud-only photo, an unsupported or oversized image, offline/interrupted networking, expired authentication, and leaving/reopening the app during publication.

These are future checks, not tests performed during this planning session. The completed verification was the live website walkthrough.

## Later: designated Photos album

The subsequent workshop decisions are recorded in [Automatic uploads from a Photos album](background-upload-plan.md). That separate planning document preserves the manual workflow and defines the proposed automatic-upload iteration. Its shared media policy calls for uploading current visible Photos edits in both paths while preserving compatible format, rendition dimensions and embedded metadata where feasible. Verified necessary format conversion is automatic without notification; other necessary alterations still require notification. That media policy is now implemented as described above; the JPEG preparation and verification record below describes the earlier MVP, not the current implementation.

The longer-term idea is a dedicated In Process album in Apple's Photos app. New additions would be discovered and published automatically using saved metadata and publication defaults.

That phase needs separate decisions about library permissions, which existing album items to include, deduplication, consent to automatic permanent publication, title defaults, retries, and Wi-Fi/cellular behavior. Album discovery and an already-started transfer are separate background problems. iOS controls discretionary background execution, so eventual syncing and catch-up on reopening are more realistic starting expectations than immediate continuous monitoring.

## References

- [In Process getting started](https://docs-in-process.vercel.app/getting-started)
- [Creating a Moment](https://docs-in-process.vercel.app/moment/create)
- [Upload to Arweave](https://docs-in-process.vercel.app/upload-to-arweave)
- [Browsing timelines](https://docs-in-process.vercel.app/timeline)
- [Apple system photo picker](https://developer.apple.com/videos/play/wwdc2023/10107/)
- [Apple background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple background strategies](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app)

Product decisions above come from this discussion; observed website behavior comes from the November 8 walkthrough. Native integration feasibility remains to be verified.

## Implementation and live verification — November 8, 2026

The existing SwiftUI app was preserved during the resumed validation. No new product features were added. The live test ran on iPhone 17, iOS 27.2, simulator `464C8FB4-053E-43EA-B32B-FE4040709139`.

### Confirmed app journey

All verification artifacts referenced below remain local under ignored `docs/verification/`, including the sanitized typing screenshot. Links to these files are for local use and may not resolve in a fresh checkout. The prose records the verified outcome without storing authentication secrets.

1. Entered the user-confirmed email in the app and triggered one fresh OTP request. Retrieved the matching Privy message through the authorized Gmail connector and entered the code privately. No OTP or session token was saved in these artifacts.
2. The app resolved the existing profile, its artist address, and the authenticated default Process collection on Base (8453). Account identifiers are omitted from this document.
3. Selected a user-provided HEIC photo through Apple's system picker. The picker explicitly displayed private, selected-item access. The correctly oriented app preview matched the source photo. The original file was preserved; the app prepared a bounded JPEG with image metadata removed.
4. Reviewed Process / 1 USDC with title and description blank. The creation request uses open-edition omission, no added split recipients, and no manual schedule. During this initial live test, pressed Publish Moment and its then-present Publish now confirmation once. The confirmation popup was subsequently removed at the user's request; tapping Publish Moment now starts the existing flow directly from the review screen.
5. The app completed upload, simulation, and creation and displayed Published. Its persisted draft is `published`, operation ID `17D297D3-F6D6-49E9-AD39-A8B05BF312BE`. No create retry was needed or performed.
6. Public timeline readback returned the new token first, with the expected creator, collection, metadata URI, blank name/description, and `pricePerToken: "1000000"`. The downloaded public JPEG was byte-identical to the app's prepared JPEG (SHA-256 `51555dc31d1d3a316e6745a5512aebed9c27590b9f261f27009be0744bf617f2`).
7. Opened View on In Process from the app. Safari displayed the correct photo, “moment created,” the website's display fallback “Untitled moment,” and 1 USDC. Stored metadata remains blank; the app did not invent a title. Tapped the website's Timeline link and visually confirmed the artist's timeline with the new photo first ([timeline screenshot](verification/timeline-on-website.jpg)).

Created result:

- Moment #4 in the account's default collection (link omitted)
- Transaction hash recorded locally (omitted)
- Creation indexed at November 8, 2026, 4:14:15 PM Pacific.
- [App success screenshot](verification/published-in-app.jpg), [website success screenshot](verification/published-on-website.jpg), [selected photo preview](verification/selected-photo.jpg), [public timeline response](verification/timeline-readback.json), [published metadata](verification/published-metadata.json).

### Simulator input diagnosis

XcodeBuildMCP 2.7.0's `type_text` first focuses its target with AXe's default semantic tap, then sends keyboard events. In this simulator session that default `FBSimulator tapAt` path reported success without activating the target. A home-screen app-icon tap also failed to open the app, so the failure was not specific to email validation. The same field identifier and simulator UDID were used throughout.

Using physical touch down/up focused the email field, after which the same `type_text` call visibly entered `test@example.invalid` and enabled Send sign-in code. This was reproduced after relaunch entirely through MCP with `touch({elementRef: <latest field ref>, down: true, up: true, delay: 0.1})`, followed by `type_text`. The harmless test text was cleared and verified before the live sign-in. [Typing evidence](verification/simulator-typing-confirmed.jpg).

The earlier successful sign-in UI test used XCTest's input path, which explains why typing had previously been visibly successful while the plugin's default tap path failed. The exact lower-level Apple/framework incompatibility was not established. Physical touch is the verified automation fix; no app code or user manual typing was required. Tool success messages alone must not be treated as proof that the field changed. Refresh snapshots after navigation; the Photos picker extension and Safari page contents sometimes require screenshot-based observation because their contents are absent from the tool's semantic snapshot.

### Test evidence and remaining limits

- Prior run's logs were rechecked: all nine core tests passed, and the sign-in UI validation passed. Core coverage includes exact price units/default omissions, image orientation/GPS removal, expired or mismatched accounts, upload resumption, and uncertain-create locking/reconciliation. These are isolated tests, distinct from the real live journey above. No test rerun was needed because app source did not change during this resumed validation.
- The live integration used the existing implementation's Supabase public storage route (`in_process_files`) with a verified `anon` public key, not a privileged key. This run did not invoke the quota/billing-sensitive `/upload` route. No payment or funding step occurred.
- Media and metadata are currently HTTPS Supabase objects. Unlike the earlier website reference Moment's `ar://` objects, this test does not establish Arweave permanence. Storage durability and alignment with the website's eventual archival behavior remain integration questions for later iteration.
- Physical-iPhone verification, iCloud-only media, real interrupted networking, app backgrounding during publication, and long-term session expiry remain untested end to end. Existing automated recovery tests do not replace those device checks.
- The app's Keychain session and published draft are preserved. Stop here for iteration; do not create a second Moment as a verification step.

## Manual acceptance: immediate Publish — November 8, 2026

After removing the Publish confirmation popup and changing the target to iPhone-only, the user explicitly authorized an additional real UI acceptance test. This is distinct from the earlier build/unit-test verification. The latest app was rebuilt and installed as `com.xdjs.InProcess` in the iPhone simulator. Fresh email-code login restored the correct account and previously published Moment #4.

The user changed the test image choice before publication to a waterfall (or flowers). Selected the first-row waterfall through Apple's picker and verified its app preview. Reviewed Process, 1 USDC, and blank title/description. The earlier AirDropped photo was not uploaded in this test.

Tapped **Publish Moment exactly once** using a physical touch down/up. The immediate post-action UI snapshot showed **Uploading your photo…**, with interaction controls disabled and no confirmation dialog. A subsequent screenshot showed **Saving the details…**. No second confirmation tap was made; the app proceeded automatically to **Published**. The screen recording captures review-to-progress behavior; completion is confirmed by the separate success screenshot and live readback.

The additional result is Moment #6 (link omitted), indexed at November 8, 2026, 5:50:36 PM Pacific. The first immediate timeline read missed the new index entry; a later read confirmed exactly one new token compared with the pre-tap baseline. Token #5 already existed before this test, and #4 remains present. No publication retry was performed. The new timeline entry has the correct creator, collection, blank metadata, and collect price; its public JPEG matches the app's prepared waterfall bytes exactly.

Local-only, Git-ignored evidence:

- [Screen recording](verification/direct-publish-acceptance.mp4)
- [Before tap](verification/direct-publish-before.png)
- [Progress after the single tap](verification/direct-publish-after-tap.png)
- [Published waterfall](verification/direct-publish-success.png)
- [Readback and byte-match evidence](verification/direct-publish-readback.json)

This verifies actual interaction with the simulator app and live service, not physical-iPhone behavior. The existing Supabase-versus-Arweave limitation remains. The signed-in session and new published draft are preserved. No app code changed during this acceptance test, and no new commit was made.

## Automated regression: immediate Publish — November 8, 2026

`InProcessUITests/PublishUITests.testOneTapPublishesImmediatelyWithoutConfirmation` exercises the real SwiftUI review and success screens with one Publish tap. It checks visible publication progress, disabled publishing controls, no alert/action sheet/confirmation, exactly one create call, and success only after the fake response completes. Uploads are counted separately (two). The test releases a held async continuation through a per-run Darwin notification, without sleeps or a second UI tap.

The fixture exists only in Debug simulator builds and is explicitly selected at launch. It injects a fake `InProcessServing`, a generated geometric photo and fictional identity, in-memory sign-in storage, and a UUID temporary draft folder. There are no live API, authentication, storage, or chain requests; real session/draft state is untouched. Invalid fixture configuration stops startup, and the live API refuses fixture launches. Hosted simulator unit tests also select this isolated startup and assert that live API construction is rejected. The UI test verifies fixture mode before tapping Publish. Run commands and lasting testing guidance are in root `AGENTS.md`.

Verified on iPhone 17 / iOS 27.2: the new UI test and all nine core tests passed (10/10). Temporarily restoring the former confirmation dialog made the UI test fail on its unexpected sheet assertion. Restoring immediate Publish and rerunning both suites passed again (10/10). The final XCTest result bundle includes synthetic-only screenshots of pending create and Published. This is behavioral regression coverage; it makes no new live-service integration claim.
