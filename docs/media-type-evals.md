# Media type evals

Evals for each media type the In Process service supports, measured against what the iOS app does with it. Defined November 18, 2026. The Simulator layer has been run once ([results](#simulator-layer-results--november-18-2026)); no device or live row has.

## What the service supports

The [API docs](https://docs.inprocess.world/) give no allow-list of file types. They describe three shapes of Moment:

- **Image:** metadata carries `image` and `content: { mime, uri }`. Examples use `image/png` and `image/jpeg`.
- **Audio or video:** the same, plus `animation_url` and a separate cover `image`. The stream endpoint serves `audio/*` and `video/*`.
- **Writing:** a text Moment made through `POST /moment/writing` with `tokenContent`.

Uploads through `POST /upload` are free under 5 MB for the first 11 a month per artist; larger or later uploads are paid from the artist's smart wallet and can return `402`. The iOS app does not use this route; it writes to public storage directly.

The concrete type list comes from the service's own web source, not the docs (`in_process_web`: `lib/fileSelect/inferFileMimeType.ts`, `lib/protocolSdk/ipfs/mimeTypes.ts`, and the bulk upload picker, which accepts `image/*, video/*, .pdf, audio/*, .glb, .gltf`):

| Category | Types named in the web source |
|---|---|
| Image | JPEG, PNG, GIF, WebP, HEIC, SVG, TIFF |
| Video | MP4, QuickTime (MOV), WebM, M4V |
| Audio | MP3, WAV, M4A, AAC, FLAC, OGG, AIFF |
| Document | PDF |
| 3D model | GLB, glTF |
| Writing | Plain text and Markdown, through the writing endpoint |

## What the iOS app supports

`PhotoProcessor.format` accepts JPEG, PNG, HEIC and HEIF, and uploads the bytes unchanged. Everything else is refused with a message. The manual picker shows images only. The album scan counts videos and other non-image assets as skipped and keeps unsupported stills visible with an item error. Video, Live Photo motion and other media types are out of scope by decision ([MVP plan](ios-mvp-plan.md), "Out of scope for the first release"). GIF, WebP and TIFF are refused for a different reason: they have not been verified for publication, and the app will not convert them.

## Evals: types the app publishes

Each case runs twice: once through manual upload (MANUAL) and once through the connected album (AUTO). Required result for all four: exactly one Moment, public media byte-identical to the source, metadata `content.mime` equal to the listed type, dimensions and orientation unchanged, and the image displays on the In Process web timeline.

| ID | Fixture | Extra check | Where it runs |
|---|---|---|---|
| MEDIA-JPEG | Camera-style JPEG with EXIF orientation and location | Orientation and location metadata survive | Preservation logic: Simulator. MANUAL live: Simulator. AUTO: device |
| MEDIA-PNG | App screenshot PNG | None | Same |
| MEDIA-HEIC | iPhone camera HEIC | A newly published HEIC Moment renders on the web timeline. Earlier checks in [the upload plan](background-upload-plan.md) showed the image proxy converting stored HEIC for display, but not a complete published Moment | Preservation logic: Simulator. MANUAL live: Simulator if a HEIC fixture can be added, else device. AUTO: device |
| MEDIA-HEIF | A `.heif` still | Automatic setup's endpoint check accepts only JPEG, PNG and HEIC content types, so confirm whether an `image/heif` album photo transfers or fails with a clear item error | Logic: Simulator. AUTO: device |

MEDIA-PNG already has live evidence in both paths from the November 16–18 runs. MEDIA-JPEG and MEDIA-HEIC have offline preservation tests (`testPhotoPreparationPreservesSupportedJPEGBytes`, `testPreservesPNGAndHEICDimensionsMetadataAndBytes`) and no recorded live run. MEDIA-HEIF has no test found.

## Evals: types the service supports and the app does not

Required result for every row: nothing is published, nothing is converted or altered, and the user sees why. In the album path the item must not block other photos in the queue.

| ID | Fixture | MANUAL expectation | AUTO expectation | Where it runs |
|---|---|---|---|---|
| MEDIA-GIF | Animated GIF | Refused with the unverified-format message; not flattened to one frame | Shown as an unsupported item; counted as `unsupported` | Logic: Simulator. AUTO: device |
| MEDIA-WEBP | WebP still | Same | Same | Same |
| MEDIA-TIFF-RAW | TIFF, or a RAW/ProRAW DNG | Same | Same | Same |
| MEDIA-VIDEO | Short MOV or MP4 | Not offered by the picker | Skipped; counted as `skippedVideo`; never queued | Scan logic: Simulator. AUTO: device |
| MEDIA-LIVE | Live Photo | The still publishes as its own type; the paired video is not uploaded | Same | Device |
| MEDIA-AUDIO | Any audio file | Cannot be selected; Photos holds no audio | Not applicable | Not applicable; record as a scope gap |
| MEDIA-PDF | Any PDF | Cannot be selected | Not applicable | Same |
| MEDIA-MODEL | GLB | Cannot be selected | Not applicable | Same |
| MEDIA-WRITING | Text only | No writing flow exists | Not applicable | Same |

## Cross-cutting cases

| ID | Scenario | Required result |
|---|---|---|
| MEDIA-EDITED | A supported photo edited in Photos, then added to the album | The current edited rendition publishes, never the pre-edit original |
| MEDIA-LARGE | A supported still over 5 MB, and one over the app's 100 MiB preparation guard | Over 5 MB publishes unchanged with no payment prompt. Over 100 MiB is refused in manual upload without resizing |
| MEDIA-MIXED | An album holding one of each fixture above | Only the JPEG, PNG and HEIC items publish, once each; every other item ends in its expected state |

## Running them

- Start with the offline layer: extend the preservation and scan tests so each row has a Simulator check, then run the device rows.
- Fixtures can reach the phone with no hands by dragging files from Finder onto Photos in iPhone Mirroring, as in the [unattended procedure](photokit-wake-evals.md). Whether Photos accepts each non-image file that way is itself unverified.
- Every publishing row creates a real public Moment. Use only fixtures the user has approved, and verify by readback, not by publishing again.
- Score each run with the labels in [the core plan](core-workflow-evals.md): Pass, Not observed within window, Failure, or Invalid run.

## Simulator layer results — November 18, 2026

Fourteen offline tests ran on the iPhone 17 Simulator with zero failures: all of `PublishingTests`, plus the PNG/HEIC preservation and endpoint-gate tests in `AutomaticUploadTests`. Three were added for this doc. These are mocked or pure-logic checks; nothing was uploaded or published.

| Eval | Simulator result | Test | Not covered here |
|---|---|---|---|
| MEDIA-JPEG | Pass: bytes, orientation and location preserved | `testPhotoPreparationPreservesSupportedJPEGBytes`, `testPhotoPreparationPreservesOrientationAndLocation` | Live publish, web display |
| MEDIA-PNG | Pass: bytes, dimensions and metadata preserved | `testPreservesPNGAndHEICDimensionsMetadataAndBytes` | None; live evidence exists from this week |
| MEDIA-HEIC | Pass: bytes, dimensions and metadata preserved; MIME `image/heic` | Same | Live publish, web display |
| MEDIA-HEIF | Mismatch confirmed: the app maps `public.heif` to `image/heif`, and the endpoint gate rejects an `image/heif` request | `testMediaTypeHEIFIsAcceptedByTheAppButNotByTheEndpointGate` (new) | What an actual HEIF album photo does on device |
| MEDIA-GIF | Pass: a single-frame and a three-frame GIF are both refused; no conversion | `testMediaTypeRejectsGIFAndTIFFBytesWithoutConversion` (new) | Album item state on device |
| MEDIA-WEBP | Pass at the type-identifier level only; ImageIO cannot encode a WebP fixture | `testMediaTypeFormatAcceptsOnlyVerifiedStillTypes` (new) | Real WebP bytes |
| MEDIA-TIFF-RAW | Pass: TIFF bytes refused; RAW refused by identifier | Both new tests | Real DNG bytes |
| MEDIA-VIDEO, -AUDIO, -PDF, -MODEL, -WRITING | Pass at the type-identifier level: each identifier is refused | `testMediaTypeFormatAcceptsOnlyVerifiedStillTypes` (new) | Album scan skipping a real video; picker behavior |
| MEDIA-LIVE, -EDITED | Resource choice passes: the still is chosen over the paired video, and the edited full-size resource over the original | `AutomaticUploadTests` resource-index assertions, not rerun in this pass | Real Live Photo and edited asset on device |
| MEDIA-LARGE, -MIXED | Not run | None | Everything |

The HEIF test records current behavior, not intended behavior. If the product answer is that HEIF should publish, that test should be changed along with the gate.

## Open questions for the product owner

- Should the app accept GIF and WebP, which the service's web client treats as ordinary images?
- Is `image/heif` meant to be publishable through the album path, where the endpoint check does not list it?
