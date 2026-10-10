# FCC mobile coverage

Reviewed October 10, 2026. The app targets T-Mobile provider ID 130403, with California selected initially and 57 state/DC/territory choices. Nationwide selection does not imply that FCC publishes a matching T-Mobile file for every territory.

## Account and workflow

Generate your own token on the [FCC National Broadband Map](https://broadbandmap.fcc.gov/login): account menu → Manage API Access → Generate. The account owner handles FCC sign-in and the FCC disclaimer. The app needs the FCC account email and generated token, not the account password.

In Coverage → Tower pins & reference coverage → FCC modeled coverage:

1. Choose a state, LTE/5G NR, NR speed tier and environment.
2. Open FCC API access; enter email/token or explicitly Use saved access.
3. Check for updates to obtain the latest availability date and matching files.
4. Zoom the map to the comparison area and Download & load map area.

Save/Use/Forget access operates one app-owned local generic-password Keychain item. No constructor or launch reads it. The owner-run `zsh Tools/SaveFCCAccess.sh` helper prompts from the controlling terminal with token echo disabled and stores the same JSON payload and exact scope. Secrets never become shell arguments or files. macOS may request app access approval when an item created by the temporary helper is first read by the signed app. The helper does not grant a broad ACL.

## API boundary

The client follows the [official API specification](https://us-fcc.app.box.com/v/bdc-public-data-api-spec), revision 1.7 dated June 8, 2026, and the [official Swagger](https://us-fcc.app.box.com/v/bdc-public-data-api-swagger). It uses only HTTPS `broadbandmap.fcc.gov/api/public`:

- `GET /map/listAsOfDates`
- `GET /map/downloads/listAvailabilityData/{as_of_date}?category=Provider&technology_type=Mobile%20Broadband`
- `GET /map/downloads/downloadFile/availability/{file_id}/2` for GeoPackage ZIP

Headers are `username` and `hash_value`. Provider/state/category filtering occurs locally over the documented listing. The PDF examples use `bdc.fcc.gov` while Swagger names `broadbandmap.fcc.gov`; the client never forwards credentials to an alternate host. Every redirect is refused. Sessions are ephemeral, without cookies, cache or a shared credential store. No automatic retries or polling occur. A shared monotonic limiter permits at most 10 request starts per minute. Metadata is limited to 32 MiB and ZIP downloads to 512 MiB; partial downloads are private and removed on failure/cancellation. Existing destination files are never overwritten.

Requests reveal account email/token, selected download and ordinary network information to FCC. Precise map bounds, recordings, gateway credentials and local files are not sent. Bounds filtering occurs locally.

## Geometry and provenance

The [FCC download-format specification](https://us-fcc.app.box.com/v/bdc-data-downloads-output), revision 2.4.3 dated August 11, 2026, defines raw mobile propagation polygons. They are carrier-reported models, not measurements or physical tower locations. Coverage schema fields include provider, technology, minimum modeled speed, modeled signal and environment; there are no band or serving-cell identifiers.

Availability **as-of date**, ZIP update date and inner GeoPackage timestamp can differ. Retain the availability date in the overlay. Local imports use an owner-entered date and declared origin. Fresh downloads retain API file ID/state. Reloaded external ZIPs are local imports because their contents may have changed.

FCC environment 0 is outdoor stationary only; 1 is both outdoor stationary and in vehicle. The app’s derived selection 2 means union(0,1), never an FCC stored value. Outdoor stationary imports both categories; In vehicle imports 1.

The offline reader accepts only compatible raw 2D WGS84 Polygon/MultiPolygon GeoPackages and uses a validated native RTree for candidate selection. Each intersecting polygon component retains all vertices and holes. Distant components can be omitted; intersecting components are neither clipped nor simplified. More than 5 MB of generated GeoJSON, 1,000 polygons or 100,000 coordinates fails with a zoom-in message. SQL runs read-only with extension loading unavailable, a restrictive authorizer, bounds and a cancellation/deadline handler. The ZIP extractor accepts one regular `.gpkg` entry, checks structure, sizes and CRC, and never invokes an external extractor. Unsupported ZIP64, encrypted, multi-entry or descriptor archives require another supported download.

H3 downloads are unsupported by the polygon reader. Their hex IDs are grid indexes, never cellular cell IDs. Existing bounded GeoJSON imports remain whole-file imports. Legacy saved references without the new provenance field remain readable.

## Other sources reviewed

| Source | Finding |
| --- | --- |
| [FCC ASR](https://www.fcc.gov/wireless/systems-utilities/antenna-structure-registration) | Registered structures can provide physical references, not proof of T-Mobile tenancy or serving-cell attachment. Registration is not universal. Current bulk downloads were unavailable during this review; no current-schema ASR importer is claimed. |
| [FCC ULS public files](https://www.fcc.gov/wireless/data/public-access-files-database-downloads) | Licensing records answer license/site/market questions. Market licenses may lack specific sites. ASR and ULS tables have different schemas; tower registration joins do not establish a gateway cell identity. |
| [api-evangelist FCC](https://github.com/api-evangelist/fcc) | Independent API directory. Its BDC link points to the [FCC filer challenge tool](https://github.com/FCC/bdcapi), whose purpose differs from public mobile coverage downloads. |
| [Spectrum Dashboard directory entry](https://apis.io/apis/fcc/spectrum-dashboard/) | Spectrum allocation/ownership context differs from coverage geometry. The linked [FCC developer page](https://www.fcc.gov/reports-research/developers/spectrum-dashboard-api) displayed Content Display Disabled during live review. Production API availability is unverified. |
| [FCC Public Files developer](https://publicfiles.fcc.gov/developer) | Broadcast, cable and satellite public-file APIs and broadcast contours. [FCC describes its scope](https://publicfiles.fcc.gov/about); it does not supply T-Mobile LTE/NR propagation models. |

Do not merge historic U.S. Cellular records into T-Mobile coverage or infer current tenancy from ownership. Keep each reference’s source/date/type separate.

## Validation and public release

Isolated scripts are `Tests/FCCCoverageClientTests.sh`, `Tests/TMobileFCCArchiveTests.sh`, `Tests/TMobileFCCGeoPackageTests.sh` and `Tests/TMobileFCCWorkflowTests.sh`. They use intercepted responses, synthetic credentials and temporary folders. No real Keychain item is read by tests.

The official portal download for California/T-Mobile/5G NR 35/3 as of December 31, 2025 was independently obtained; its ZIP update date was September 29, 2026. The 59,946,574-byte ZIP contains a 304,394,240-byte GeoPackage. It declares POLYGON metadata but includes valid MultiPolygon rows, so both validated geometry types are accepted. A generic Sacramento area exercises actual raw geometry and the app’s existing GeoJSON parser.

Both canonical metadata routes returned HTTP 401/application-json without credentials, confirming route reachability and authentication requirement. An explicit live check using the owner’s exact saved FCC Keychain item then succeeded: latest availability December 31, 2025, six supported California T-Mobile files, and authenticated raw 5G NR 35/3 GeoPackage ZIP download. The token/email were never printed or written to files. This verifies the production client against live authenticated responses; saving a token alone would not establish acceptance.

The optional owner-run `zsh Tools/CheckFCCAccess.sh [NEW_ZIP_DESTINATION]` reads only that exact item, refuses interactive Keychain access, and uses the production FCC client. There is no credential enumeration or alternate-host fallback. It reports fixed safe failures and public dataset metadata. `--help` performs no credential or network access.

The final helper run compiled successfully and returned **UNVERIFIED** (exit 2): the saved item requires normal macOS access approval. Its process-local interaction guard suppresses both legacy and Data Protection Keychain UI and restores the previous setting. This limitation does not invalidate the earlier authenticated client check; the signed app's explicit **Use saved access** action and first-use approval still need native verification.

Native offscreen review renders the production controls at 480 and 900 points in light/dark mode, using isolated stores. The full public ZIP → native GeoPackage → regional geometry → persisted reference pipeline is also exercised. Before public distribution, validate the signed app’s Keychain access prompt and native check/download actions, update/no-file/authentication/rate-limit states, map overlay at supported window sizes, signed/notarized packaging, and current FCC specification compatibility. Do not embed the developer’s token in a release.
