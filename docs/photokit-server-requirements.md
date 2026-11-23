# PhotoKit upload endpoint: requirement, evidence, and ownership

Investigation date: November 8, 2026 Pacific. Initial read-only follow-up to synthetic media probes, updated after the separately authorized one-image physical diagnostic. No backend implementation or deployment was performed.

## Decision supported by the evidence

The existing endpoint accepted three separately authorized operations using one generated PNG through the actual iOS 27.2 PhotoKit extension/resource-job path, and all downloaded bytes matched the Photos resource. The diagnostic observed raw OPTIONS 200 without `Upload-Limit`, yet the job succeeded. An adapter is therefore **not established as necessary** for this transfer. The documented capability advertisement and broader lifecycle behavior remain unverified; these tiny transfers do not prove resumability or every resource case. Production automatic setup now accepts this observed generic preflight only through a narrowly pinned compatibility exception for the tested HTTPS host and `in_process_files` object-upload route. The request must remain POST with a UUID photo filename, JPEG/PNG/HEIC MIME and matching extension, the normal public credential in both authentication headers, and `x-upsert: false`; the response must be 200 without Upload-Limit at the exact requested URL. Other generic endpoints, redirects, authorization failures, unsupported content and malformed limits remain rejected. Documented 501 or positive Upload-Limit capability responses retain their separate path. This correction allows normal user-consented album setup; it does not claim large-file/resumable or full Moment publication validation. Existing byte reconciliation and publication checkpoints are unchanged.

## Completed physical diagnostic

See [the phone result and evidence checklist](phone-diagnostic-checklist.md). The initial diagnostic created one synthetic asset and submitted one operation; two later authorized operations reused that same asset. No Moment or metadata was created. The extension recorded terminal success/no error. Public readback returned HTTP 200, image/png, 2,952 bytes with matching SHA-256. This GET status is not the numerical POST status, which the harness did not capture. The initial operation had Test Mode off and Mirroring connected, with xcodebuild/devicectl launch. Later, Test Mode was enabled at the user’s request and host/extension Run actions were exercised in Xcode with development signing. Two additional minimal operations passed after host backgrounding (Mirroring connected) and after Mirroring disconnection with device passcode required. Normal-mode disconnected/locked scheduling, larger files, full publication and interrupted/resumable behavior remain open.

## Apple's contract

Apple's [Uploading asset resources in the background](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background) guide describes two paths:

- A resumable server responds to OPTIONS with HTTP 200 and `Upload-Limit`, and provides HTTP 104 plus `Location` during the upload for in-band feature detection. An OPTIONS advertisement alone does not prove resumable behavior.
- A server without that resumable protocol responds to OPTIONS with HTTP 501. This is the documented non-resumable path to test first if resumability is unnecessary.

PhotoKit uses the IETF HTTP resumable-upload draft described by Apple. Supabase's separate [resumable endpoint](https://supabase.com/docs/guides/storage/uploads/resumable-uploads) uses TUS; the word “resumable” does not establish protocol interoperability. No TUS or alternate-host probe was made here.

The extension must declare `BackgroundUploadURLBase`. An adapter on a different origin requires changing that declaration and its upload-request construction, then verifying redirects, authorization, and ancillary metadata/create networking on the device. The installed iOS 27.2 SDK supplies the async `PHBackgroundResourceUploadJobExtension` and current host enable/options APIs. Simulator compilation does not execute this extension.

## Actual existing endpoint observation

Local source: `docs/verification/media-compatibility-2026-11-08/probe.py`, `http-results.json`. Exact paths/URLs are intentionally kept in ignored evidence. The one OPTIONS request was at **2026-11-09 02:33:20 UTC**:

```http
OPTIONS /storage/v1/object/in_process_files/<synthetic-probe-prefix>/synthetic.heic
Host: zzgteesackezhtnuqfyw.supabase.co
User-Agent: InProcess-Synthetic-Media-Compatibility-Probe/1.0
```

No body, `Origin`, `Access-Control-Request-Method`, `apikey`, or `Authorization` header was supplied to OPTIONS. This was a raw HTTP diagnostic request, not a browser-generated CORS preflight and not an observed PhotoKit request.

Recorded response:

```http
HTTP 200
Content-Length: 0
Allow: GET, HEAD, POST, OPTIONS
Access-Control-Allow-Methods: GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS,TRACE,CONNECT
Server: cloudflare
```

No `Upload-Limit` or `Location` was recorded. The probe records a selected response-header subset, not a full network trace. Generic method/CORS allowance is not a statement of support for Apple's upload protocol. Responses could depend on PhotoKit's actual headers, routing, or server capability caching; those were not exercised. Ordinary authenticated POST and public GET for the generated HEIC, JPEG, PNG and metadata all succeeded. They do not establish PhotoKit execution or capture HTTP 104 informational responses.

## Conditional operator questions and possible change

The completed transfer does not justify deploying a gateway. The following are conditional investigation options if a concrete protocol/lifecycle problem is reproduced, not prerequisites proven necessary by generic OPTIONS alone.

1. Have the storage/API operator confirm whether this route can return the documented 501 non-resumable response to PhotoKit's OPTIONS request. First validate the 501 path with the actual extension on a controlled endpoint and a synthetic iPhone asset. Also record the actual PhotoKit OPTIONS headers and final upload result, without logging credentials. No new production mutations are authorized by this document.
2. If the existing managed endpoint cannot be configured, the smallest candidate is an upload gateway that handles OPTIONS appropriately and streams POST bytes to the existing bucket. Keep deterministic per-operation object names, real MIME, existing public readback, scoped authorization, and safe interrupted-upload reconciliation. Do not claim a generic redirect solves authorization, URL-base validation, or preflight caching without testing.
3. A route in `sweetmantech/in_process_api` is a possible control-plane/code home, **not automatically a suitable byte-stream host**. Its Vercel deployment configuration is visible. Standard [Vercel Functions](https://vercel.com/docs/functions/limitations#request-body-size) have a 4.5 MB request-body limit; routing full original photos through such a function would reintroduce a restrictive limit. Select a suitable streaming service or infrastructure-level forwarding path before implementing a body relay. Merely changing CORS headers on the API origin does not affect the Supabase-origin request.
4. A complete IETF resumable implementation is a larger alternative, requiring upload lifecycle/offset semantics and a transport that forwards informational responses. Do not add a fake `Upload-Limit` header to claim this works.

An ordinary background URLSession path can be investigated separately, but it does not automatically supply album discovery/wake opportunities. Replacing the Photos extension with foreground-only uploads or opportunistic scanning would change the agreed product behavior and requires an explicit decision.

## Ownership that was established

| Surface | Evidence | Who must act / what remains unknown |
| --- | --- | --- |
| API code | [sweetmantech/in_process_api](https://github.com/sweetmantech/in_process_api), GitHub owner type User, repository homepage `https://api.inprocess.world`. Connected permissions report pull true, push/maintain/admin false. | A maintainer with write access to that repository. No specific human contact or authority to deploy was established. |
| API deployment | Public [vercel.json](https://github.com/sweetmantech/in_process_api/blob/0b4935411294f7f9aea6899529152524b307daf8/vercel.json) contains Fluid Compute and cron configuration; live API responses identify Vercel. A connected Vercel project query filtered by the repository URL returned no matches in its visible scope. | The actual Vercel project/team administrator. Absence from this connection does not prove the project is absent; team/project identity and rights remain unknown. |
| Existing object endpoint | App configuration points to Supabase project ref `zzgteesackezhtnuqfyw`, bucket `in_process_files`. It was absent from the projects visible to the connected Supabase account. | That project's administrator, potentially with Supabase support for managed gateway behavior; organization/account owner unknown. |
| iOS integration | This repository owns request construction, extension URL base, queue and tests. | Local changes are authorized. Backend edits/deployment are not. |

No one was contacted, no credentials were searched for, and no server configuration was changed. The next decision is who has administrative access to the storage project/API deployment and can authorize a controlled endpoint test or a specific server change after the test result. Repository ownership is evidence about the code namespace, not proof of a particular person's production permissions.

## Does removal exist?

Supabase supports [Storage API object deletion](https://supabase.com/docs/guides/storage/management/delete-objects), subject to access policies. The earlier exact-four-object cleanup attempt using the app's normal public `anon` credential returned HTTP 200 with `[]`; fresh cache-busting reads still returned the objects unchanged. This demonstrates **no successful removal under that role**, consistent with insufficient applicable deletion/selection policy. We did not inspect RLS, so the precise policy cause is not established. Upload permission and public readability do not imply deletion permission.

The API source has internal [deleteFileFromSupabase](https://github.com/sweetmantech/in_process_api/blob/0b4935411294f7f9aea6899529152524b307daf8/src/lib/supabase/storage/deleteFileFromSupabase.ts) and [removeSupabaseStoragePaths](https://github.com/sweetmantech/in_process_api/blob/0b4935411294f7f9aea6899529152524b307daf8/src/lib/media/removeSupabaseStoragePaths.ts) helpers. Internal helpers do not establish a public client deletion route. The reviewed [OpenAPI schema](https://github.com/sweetmantech/in_process_docs/blob/main/api-reference/openapi.json) documents DELETE for `/moment/permission`, `/artists/wallets`, and `/phones`, **not arbitrary uploaded media/object deletion**. Removing a Moment permission is not evidence of deleting its media or reversing publication.

The four synthetic objects and any service-managed proxy derivatives may remain. Their exact paths are in ignored `probe-state.json` / `cleanup.json`. Do not broaden public deletion permissions or seek privileged credentials to clean them up; a project administrator can evaluate narrowly scoped cleanup separately. Removing an album member or a storage object is not a promise to erase a published or cached Moment.
