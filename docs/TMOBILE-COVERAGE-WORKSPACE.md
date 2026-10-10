# T-Mobile Coverage workspace

Open **Settings → Monitor → T-Mobile Coverage → Open Coverage…**, or **Coverage, radio & towers…** from the T-Mobile section. Settings search also finds “Coverage” and “Recording.” The window combines live available radio metrics, saved sessions, four linked charts, Apple Maps, local tower references and optional OpenCelliD lookup. Existing gateway and Wi-Fi controls remain available.

The Settings card exposes the existing **Show T-Mobile gateway** switch and gateway configuration. This switch shows live readings in the Network panel. Recording starts with **Start recording** inside Coverage, or at app launch when **Automatically start recording** is enabled. **Open Coverage…** remains available with the switch off so saved sessions can still be viewed. Opening Settings does not start recording or request location access. Automatic launch recording also respects availability of the Network feature; the separate gateway-display switch does not control recording.

## Menu-bar appearance

In Settings → Monitor → In the menu bar, open the T-Mobile connection options. Select **Technology**, **Signal bars** and **Bands** independently. At least one stays selected; the existing item checkmark hides the whole indicator. Technology follows the current reported LTE/5G connection, with 5G UC inferred from the active radio’s reported bands. Screen readers retain the complete connection summary even when a visual component is hidden.

## Band explanations

The **ⓘ** beside **Bands** and **Supported bands (capability)** opens a guide for the bands in that row. This is available in public/administrator radio details and the sample inspector’s available radio details. The guide gives the band’s familiar frequency, general uses, and coverage/capacity tradeoffs. Supported bands describe gateway capability; they do not establish a current connection or local carrier deployment. Recorded band rows describe their saved reading. Unknown bands retain their identifier without a guessed frequency or performance rating.

The scrollable native popover supports a Done/Escape dismissal and exposes its information button separately to assistive technology. Frequency facts use [3GPP NR band tables](https://www.etsi.org/deliver/etsi_ts/138100_138199/138104/17.13.00_60/ts_138104v171300p.pdf) and [LTE band tables](https://www.etsi.org/deliver/etsi_ts/136100_136199/136104/17.10.00_60/ts_136104v171000p.pdf). General range/penetration guidance follows [T-Mobile’s spectrum explanation](https://www.t-mobile.com/5g); shared CBRS usage follows the [FCC’s CBRS order](https://docs.fcc.gov/public/attachments/FCC-15-47A1_Rcd.pdf). These are general tendencies, not guaranteed speeds or distances. The guide does not change the connection.

## Recording

Choose a session name and **Start recording**, or enable **Automatically start recording** in Settings → Monitor → T-Mobile Coverage. This preference defaults off and starts a new local session each time the app launches when enabled, including launch at login; opening the Coverage window is unnecessary. Manual Stop lasts until the next app launch. The separate General → Launch at login preference controls whether macOS launches the app at login. Location permission is requested only after recording starts or **Use Mac location**. The Mac's Core Location position may come from Wi-Fi; it is not presented as a dedicated GPS receiver. Original source, timestamp and reported accuracy are retained. Latitude/longitude corrections append revisions without replacing the original fix.

Each fresh public gateway poll creates an observation. Missing radio fields remain absent. Sleep, display sleep and a closed laptop lid pause recording and cancel speed tests; reopening and display wake resume with fresh context. Quitting closes the session. A crash leaves an explicitly unfinished session; a later launch starts a new session only if automatic recording is enabled. No service keeps the Mac awake.

The app requests fresh stationary positions every 20 seconds while recording. The provider can still return imprecise or unavailable locations. A manual correction can place an already saved reading on the map; it does not invent an automatic location for a speed test.

## Parked speed tests

The automatic-test toggle defaults on for a recording session. Tests require two minutes of stable fixes no older than 30 seconds and within ±100 m. A new stop must be more than 250 m away after accounting for both locations' uncertainty. There is a 15-minute cooldown. Attempts are saved before network activity so relaunch or a failed test does not repeatedly test the same stop. Moving to a different stop permits a later revisit.

Coverage tests use the existing Cloudflare test service with three-second transfer windows, requesting a maximum 20 MB download and 5 MB upload per test, plus small latency requests and transport overhead. The service receives the network address. A manual test requires an active session and fresh radio observation. Cancel, sleep and lid closure stop the test. Movement, stale location or changed radio context excludes a combined score. Tests retain their own actual start/end locations and times.

## Maps and analysis

The window opens on **Map** with **FCC model**, **My readings** and **Towers & cells** enabled together. The map fills the available space; a persistent legend separates blue modeled coverage, measured quality colors and reference pins. Layer checkboxes hide each source independently. **Readings & charts** contains the four linked time graphs and full reading inspector. **Data & settings** contains recording options, FCC access/import, tower management, OpenCelliD, advanced radio readings and saved-session actions.

Switch measured colors between RSRP (the default), SINR, tested download and Connection Score. **Points** shows located readings; **Heat** shows median values in measured approximately 50 m bins. Unvisited space is left unmeasured. Selecting a sample in a chart, map or readings picker updates the inspector. Switching tabs restores the visible map area. The initial view prioritizes recorded positions and pins; **Fit all** includes the full visible model geometry.

RSRP and SINR colors use the existing radio guide. Measured map guidance uses green at 100 Mbps, amber at 25 Mbps and red below; the custom score uses 70/40. Colors are comparison guidance. Missing values are never shown as zero. Speed points use the test's own location and never move with a manually corrected radio reading.

`balanced-v1` averages equal-weight normalized RSRP (−120…−80 dBm), SINR (−5…25 dB) and tested download (0…150 Mbps), each capped at 0…100. It requires all components and matching precise original/test locations. Upload and latency stay available separately. This custom score is versioned and is not a carrier or industry rating.

## Tower and FCC references

Local tower JSON/CSV and manual pins share the map. Select a pin or sidebar reference to see its coordinates, source-declared technology and bands, plus straight-line distance/bearing from the selected measurement when available. The band ⓘ explains the declared bands using the existing guide. A reference does not establish a serving connection, active deployment, maximum speed or site capacity. Missing capabilities remain “Not provided.” OpenCelliD positions are labeled community cell estimates, with visible source/license links. Larger reference lists include name/band/cell-ID search and paging so every pin has a keyboard selection path.

For OpenCellID, paste an API key, pan the map to the desired area, select LTE or 5G and choose **Find cells near map center**. One explicit request searches a 1.8 km square, below the provider’s 4 km² limit, and returns at most 50 community estimates. The app does not page, poll, infer a serving tower or expand gateway identity fragments. Returned positions are temporary map references with source/license links; an empty result does not establish missing mobile coverage. **Advanced: look up a full cell identifier** retains the verified manual MCC/MNC/TAC/full ECI or NCI workflow. **Save estimate to reference map** explicitly retains the returned position, radio/full cell identity, MCC/MNC/TAC, lookup date and reported range/sample count. Credentials are never included. Saved positions remain unverified references with OpenCelliD/CC BY-SA attribution; range is not measured coverage.

**FCC modeled coverage** defaults to California and offers all U.S. states, DC and territories. Open **FCC API access**, enter your FCC account email and generated token (or choose **Use saved access**), then choose **Check for updates**. Select LTE or 5G NR, the NR speed tier and outdoor or in-vehicle environment. **Download & load map area…** saves a raw GeoPackage ZIP to your chosen destination and imports complete model polygons intersecting the map area. Detailed areas may require a closer zoom. There is no automatic polling, shared app token or location upload. A state with no matching T-Mobile file is reported explicitly.

Local ZIP/GeoPackage import also works without an API account. Enter the FCC **Availability Data As Of** date, rather than the ZIP modification date. The native reader supports FCC raw 2D WGS84 Polygon/MultiPolygon geometry, retains holes, and filters complete polygon components to the map area without clipping or simplification. It bounds imports to 5 MB, 1,000 polygons and 100,000 coordinates; an oversized area fails instead of producing an incomplete layer. H3, projected and 3D files are unsupported. Existing GeoJSON FeatureCollections import in full within the same geometry limits. Only validated FCC minimum signal is retained as `fccMinimumSignalDBm`; arbitrary other source properties are discarded. Each Polygon or MultiPolygon component carries its source feature’s optional predicted RSRP, bounded to −120…−50 dBm. Missing/null values stay unknown.

The blue reference overlay records availability date, technology, modeled speed and environment. Blue shading follows predicted minimum RSRP where supplied; legacy layers retain uniform footprint shading. A predicted signal or modeled 35/3 Mbps category is not a measured speed or tower capacity. A fresh API download records the FCC file ID and state. Local imports and later reloads of externally editable ZIPs retain owner-declared origin/date. **Outdoor stationary** combines FCC environment 0 (outdoor only) and 1 (outdoor and in vehicle); **In vehicle** uses 1 alone. FCC models do not identify serving towers, radio bands, indoor coverage or measured speeds. The supplied research links open in the browser when selected. Apple Maps supplies the basemap through MapKit. See [FCC workflow and sources](FCC-COVERAGE.md).

## Credentials

Both gateway administrator sign-in forms have **Remember on this Mac**, **Use saved password** and **Forget saved password**. Remember saves only after successful sign-in, scoped to the exact private gateway origin and username. Saved passwords are loaded only by the explicit Use action; sign-in remains manual. OpenCellID and FCC have separate explicit Save, Use and Forget controls. FCC stores the email and generated API token together; it never requests or stores your FCC password. Saving access does not validate it with the provider. Keys clear when their view closes. Keychain items stay local, do not sync and have no plaintext fallback. Opening the UI or changing gateway address never reads saved credentials.

## Storage and future Shadow connection

Sessions stay on this Mac until explicitly deleted. Export writes JSON to a chosen path and retains the archive. Exports include original locations, corrections and radio identifiers. The versioned cursor/batch contract supports a future Shadow server connector, but there is no server endpoint, uploader or automatic sync. Future remote access must remain client-owned and tailnet-only.

See [archive format and recovery](TMOBILE-COVERAGE-ARCHIVE.md). Advanced administrator radio readings remain window-scoped and are not added to the public measurement archive. Existing rolling history remains a separate legacy archive.

## Checks

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh --fork --test-suite=tmobile --test-suite=network`
- `zsh Tests/TMobileCoverageStoreTests.sh`
- `bash Tests/TMobileCoverageMapChartsTests.sh`
- `zsh Tests/TMobileTowerMapPresentationTests.sh`
- `zsh Tools/RenderCoverageExplorer.sh /private/tmp/coverage-previews`
- `zsh Tests/TMobileOpenCellIDServiceTests.sh`
- `zsh Tests/TMobileGatewayCredentialTests.sh`
- `zsh Tests/TMobileGatewayAppearanceTests.sh`

These checks use synthetic readings and intercepted test traffic. Live Mac permission/accuracy, real parked detection, physical sleep/lid transitions, map rendering and gateway/provider responses require a supervised app run.

### Accessibility crash regression (beta.7)

Beta.6 could overflow the main-thread stack when an accessibility reader queried the inspector after starting a recording. LLDB captured repeated `AccessibilityNode.accessibilityLabel` / `NSAccessibilityGetObjectValueForAttribute` calls; the native object was `SwiftUI.AppKitTextInteractionView`, with value `RSRP`. A custom label on a selectable row inherited onto its native text child and recursively resolved `AXDescription`.

Both custom-labeled inspector row containers now use `.accessibilityElement(children: .ignore)` before their complete label/value/quality summary. The inspector retains text selection. Keep the summary on the row element rather than applying it to inherited selectable children.

Runtime regression procedure (an app build and calculation tests alone do not cover this):

1. Open Coverage from Settings → Monitor with a saved session and read its accessibility tree. Confirm the Settings enable switch uses the existing gateway preference and Coverage remains accessible with it off.
2. Start a named verification session; repeatedly read the tree while fresh gateway samples update RSRP and SINR.
3. Expand **Available radio details** and confirm complete metric summaries. Check text copying and keyboard access to controls.
4. Stop recording, close/reopen Coverage several times, switch saved sessions, and repeat accessibility reads.
5. With automatic recording off, relaunch and confirm recording stays off. Enable automatic recording, relaunch with Coverage closed, and confirm a new session collects samples. Stop must hold until the next launch. Saved sessions must remain available.
