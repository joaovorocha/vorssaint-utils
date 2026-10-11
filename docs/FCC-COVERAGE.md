# FCC mobile coverage

Reviewed October 10, 2026. The app targets T-Mobile provider ID 130403, with California selected initially and 57 state/DC/territory choices. Nationwide selection does not imply that FCC publishes a matching T-Mobile file for every territory.

## Account and workflow

Generate your own token on the [FCC National Broadband Map](https://broadbandmap.fcc.gov/login): account menu → Manage API Access → Generate. The account owner handles FCC sign-in and the FCC disclaimer. The app needs the FCC account email and generated token, not the account password.

In Coverage → Data & settings:

1. Choose the comparison area on the map.
2. Select **Load coverage for this area**. The app quietly checks its exact saved FCC Keychain item before asking for access. If none is available, enter the FCC email and token once; Load saves them on this Mac.
3. The same action checks the latest availability date, downloads or reuses the matching state ZIP, extracts the chosen map area locally and returns to Map after successful persistence.

Coverage options, FCC access and local-file import are secondary disclosures. Existing source state/category values seed the next selection. California remains the initial state when there is no prior source; all 57 choices remain available. Loading continues across workspace tabs with status and cancellation visible on Map. Closing the window cancels its pending FCC work and clears volatile credentials; it does not stop coverage recording.

The primary flow uses an app-managed cache instead of a Save panel, so an existing filename in Downloads cannot block it. Cache identity includes FCC file ID, availability date, state, provider, technology, tier and other catalogue fields. Each reuse checks the recorded byte count and streaming SHA-256 plus ZIP prefix, within the existing download limit. ZIP structure/CRC and GeoPackage/category/geometry validation still run during import. Local hashes establish integrity against the recorded download, not an FCC digital signature. Byte-invalid entries are replaced only after a new download is complete. Structural archive or GeoPackage corruption invalidates only that source entry, so the next explicit load downloads again. Cancellation, an oversized map area, absent coverage or a category mismatch do not discard the cache. Failures and cancellation retain the current map overlay.

FCC access uses one app-owned local generic-password Keychain item. Constructors and app startup perform no lookup. Opening the FCC flow makes one quiet exact-scope probe per workspace; a locked or approval-required item offers **Unlock saved access** rather than immediately asking for another token. The quiet probe suppresses both Data Protection and legacy Keychain UI and restores the legacy interaction setting on return. Explicit unlock may show normal macOS approval. This replaces the previous manual-only FCC lookup at the owner's request; no enumeration, shared access group or broad ACL is added.

The owner-run `zsh Tools/SaveFCCAccess.sh` helper remains compatible with the same JSON payload and exact scope. Secrets never become shell arguments or log files. The app asks for replacement access only when missing, unreadable or rejected; it does not open an FCC login page automatically.

## API boundary

The client follows the [official API specification](https://us-fcc.app.box.com/v/bdc-public-data-api-spec), revision 1.7 dated June 8, 2026, and the [official Swagger](https://us-fcc.app.box.com/v/bdc-public-data-api-swagger). It uses only HTTPS `broadbandmap.fcc.gov/api/public`:

- `GET /map/listAsOfDates`
- `GET /map/downloads/listAvailabilityData/{as_of_date}?category=Provider&technology_type=Mobile%20Broadband`
- `GET /map/downloads/downloadFile/availability/{file_id}/2` for GeoPackage ZIP

Headers are `username` and `hash_value`. Provider/state/category filtering occurs locally over the documented listing. The PDF examples use `bdc.fcc.gov` while Swagger names `broadbandmap.fcc.gov`; the client never forwards credentials to an alternate host. Every redirect is refused. Sessions are ephemeral, without cookies, cache or a shared credential store. No automatic retries or polling occur. A shared monotonic limiter permits at most 10 request starts per minute. Metadata is limited to 32 MiB and ZIP downloads to 512 MiB; partial downloads are private and removed on failure/cancellation. Existing destination files are never overwritten.

Requests reveal account email/token, selected download and ordinary network information to FCC. Precise map bounds, recordings, gateway credentials and local files are not sent. Bounds filtering occurs locally.

## Geometry and provenance

The [FCC download-format specification](https://us-fcc.app.box.com/v/bdc-data-downloads-output), revision 2.4.3 dated August 11, 2026, defines raw mobile propagation polygons. They are carrier-reported models, not measurements or physical tower locations. Coverage schema fields include provider, technology, minimum modeled speed, modeled signal and environment; there are no band or serving-cell identifiers.

Availability **as-of date**, ZIP update date and inner GeoPackage timestamp can differ. Retain the availability date in the overlay. Local imports use an owner-entered date and declared origin. Fresh downloads and integrity-checked app-cache reuse retain API file ID/state. External ZIPs are local imports because their contents may have changed.

FCC environment 0 is outdoor stationary only; 1 is both outdoor stationary and in vehicle. The app’s derived selection 2 means union(0,1), never an FCC stored value. Outdoor stationary imports both categories; In vehicle imports 1.

The offline reader accepts only compatible raw 2D WGS84 Polygon/MultiPolygon GeoPackages and uses a validated native RTree for candidate selection. Each intersecting polygon component retains all vertices and holes. Distant components can be omitted; intersecting components are neither clipped nor simplified. More than 5 MB of generated GeoJSON, 1,000 polygons or 100,000 coordinates fails with a zoom-in message. SQL runs read-only with extension loading unavailable, a restrictive authorizer, bounds and a cancellation/deadline handler. The ZIP extractor accepts one regular `.gpkg` entry, checks structure, sizes and CRC, and never invokes an external extractor. Unsupported ZIP64, encrypted, multi-entry or descriptor archives require another supported download.

H3 downloads are unsupported by the polygon reader. Their hex IDs are grid indexes, never cellular cell IDs. Existing bounded GeoJSON imports remain whole-file imports. Legacy saved references without provenance or modeled signal remain readable. The reader retains the optional `minsignal` field as an allowlisted `fccMinimumSignalDBm` property. [FCC defines LTE/NR minimum signal as predicted RSRP](https://help.bdc.fcc.gov/hc/en-us/articles/6047425308187-Formatting-Mobile-Broadband-Availability-Coverage-Maps), with allowed values from −120 to −50 dBm. Null/absent values remain unknown. Each MultiPolygon component receives its feature’s value; saved layer arrays must match polygon count and pass range/finite checks. Invalid values fail without replacing the previous layer. Other source properties are discarded.

The map uses a blue predicted-signal gradient, with uniform blue for unknown/legacy values. Measured 50 m bins use a separate green/amber/red quality scale and draw above the model. Pins show local references or community cell estimates. The three layers default on; their legends and source details remain explicit. FCC coverage cannot supply tower coordinates, bands or maximum site capacity.

## Other sources reviewed

| Source | Finding |
| --- | --- |
| [FCC ASR](https://www.fcc.gov/wireless/systems-utilities/antenna-structure-registration) | Registered structures can provide physical references, not proof of T-Mobile tenancy or serving-cell attachment. Registration is not universal. Later checks reached the [official bulk directory](https://data.fcc.gov/download/pub/uls/complete/) and `r_tower.zip`; landing pages still refused access. Archive availability is verified; the current inner schema and an ASR importer remain unverified. |
| [FCC ULS public files](https://www.fcc.gov/wireless/data/public-access-files-database-downloads) | Licensing records answer license/site/market questions. Market licenses may lack specific sites. ASR and ULS tables have different schemas; tower registration joins do not establish a gateway cell identity. |
| [api-evangelist FCC](https://github.com/api-evangelist/fcc) | Independent API directory. Its BDC link points to the [FCC filer challenge tool](https://github.com/FCC/bdcapi), whose purpose differs from public mobile coverage downloads. |
| [Spectrum Dashboard directory entry](https://apis.io/apis/fcc/spectrum-dashboard/) | Spectrum allocation/ownership context differs from coverage geometry. The linked [FCC developer page](https://www.fcc.gov/reports-research/developers/spectrum-dashboard-api) displayed Content Display Disabled during live review. Production API availability is unverified. |
| [FCC Public Files developer](https://publicfiles.fcc.gov/developer) | Broadcast, cable and satellite public-file APIs and broadcast contours. [FCC describes its scope](https://publicfiles.fcc.gov/about); it does not supply T-Mobile LTE/NR propagation models. |
| [OpenCelliD downloads](https://www.opencellid.org/downloads.php) | Supported country/world/daily exports require the owner's token. [CSV fields](https://docs.opencellid.org/docs/downloads/database-format) describe logical cells with estimated positions, samples and timestamps, not surveyed tower locations. [Current limits](https://docs.opencellid.org/docs/getting-started/access-and-limits) publish 1,000 API credits per user/day and two downloads per file/day; exports cover 18 months. Preserve [CC BY-SA 4.0 attribution and applicable ShareAlike](https://docs.opencellid.org/docs/attribution). Bulk CSV import is a future addition, separate from the existing area lookup. |
| [CellMapper](https://www.cellmapper.net/map) | Useful external reference map. No documented official public extraction API or bulk export was found. Its [published terms](https://www.cellmapper.net/TOS) grant personal viewing and restrict transfer/mirroring; obtain operator permission before a public-app data integration. |

Do not merge historic U.S. Cellular records into T-Mobile coverage or infer current tenancy from ownership. Keep each reference’s source/date/type separate.

On October 10, a bounded unauthenticated HEAD request to [FCC's ASR registration ZIP](https://data.fcc.gov/download/pub/uls/complete/r_tower.zip) returned HTTP 200, `application/zip`, 37,781,438 bytes, last modified October 4, 2026. The archive body was not downloaded. The supplied ASR/ULS landing-page URLs were inaccessible, so page failure must not be reported as failure of every bulk endpoint. ASR/ULS registration/license identifiers and community MCC/MNC/cell identities are different schemas; there is no universal tower ID or shared CSV layout.

## Validation and public release

Isolated scripts are `Tests/FCCCoverageClientTests.sh`, `Tests/TMobileFCCArchiveTests.sh`, `Tests/TMobileFCCGeoPackageTests.sh`, `Tests/TMobileFCCWorkflowTests.sh`, `Tests/TMobileFCCDownloadCacheTests.sh` and `Tests/TMobileFCCAutomaticLoadTests.sh`. They use intercepted responses, synthetic credentials and temporary folders. No real Keychain item is read by tests.

The official portal download for California/T-Mobile/5G NR 35/3 as of December 31, 2025 was independently obtained; its ZIP update date was September 29, 2026. The 59,946,574-byte ZIP contains a 304,394,240-byte GeoPackage. It declares POLYGON metadata but includes valid MultiPolygon rows, so both validated geometry types are accepted. A generic Sacramento area exercises actual raw geometry and the app’s existing GeoJSON parser.

Both canonical metadata routes returned HTTP 401/application-json without credentials, confirming route reachability and authentication requirement. An explicit live check using the owner’s exact saved FCC Keychain item then succeeded: latest availability December 31, 2025, six supported California T-Mobile files, and authenticated raw 5G NR 35/3 GeoPackage ZIP download. The token/email were never printed or written to files. This verifies the production client against live authenticated responses; saving a token alone would not establish acceptance.

The optional owner-run `zsh Tools/CheckFCCAccess.sh [NEW_ZIP_DESTINATION]` reads only that exact item, refuses interactive Keychain access, and uses the production FCC client. There is no credential enumeration or alternate-host fallback. It reports fixed safe failures and public dataset metadata. `--help` performs no credential or network access.

The final helper run compiled successfully and returned **UNVERIFIED** (exit 2): the saved item requires normal macOS access approval. Its process-local interaction guard suppresses both legacy and Data Protection Keychain UI and restores the previous setting. This limitation does not invalidate the earlier authenticated client check; the signed app's explicit **Use saved access** action and first-use approval still need native verification.

Native offscreen review renders the production controls at 480 and 900 points in light/dark mode, using isolated stores. The full public ZIP → native GeoPackage → regional geometry → persisted reference pipeline is also exercised. Before public distribution, validate the signed app’s Keychain access prompt and native check/download actions, update/no-file/authentication/rate-limit states, map overlay at supported window sizes, signed/notarized packaging, and current FCC specification compatibility. Do not embed the developer’s token in a release.
