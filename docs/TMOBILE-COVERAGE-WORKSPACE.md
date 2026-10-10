# T-Mobile Coverage workspace

Open **Coverage, radio & towers…** from the T-Mobile section. The window combines live available radio metrics, saved sessions, four linked charts, Apple Maps, local tower references and optional OpenCelliD lookup. Existing gateway and Wi-Fi controls remain available.

## Recording

Choose a session name and **Start recording**. Location permission is requested only after this action or **Use Mac location**. The Mac's Core Location position may come from Wi-Fi; it is not presented as a dedicated GPS receiver. Original source, timestamp and reported accuracy are retained. Latitude/longitude corrections append revisions without replacing the original fix.

Each fresh public gateway poll creates an observation. Missing radio fields remain absent. Sleep, display sleep and a closed laptop lid pause recording and cancel speed tests; reopening and display wake resume with fresh context. Quitting closes the session. A crash leaves an explicitly unfinished session, and relaunch never starts recording automatically. No service keeps the Mac awake.

The app requests fresh stationary positions every 20 seconds while recording. The provider can still return imprecise or unavailable locations. A manual correction can place an already saved reading on the map; it does not invent an automatic location for a speed test.

## Parked speed tests

The automatic-test toggle defaults on for an explicitly started session. Tests require two minutes of stable fixes no older than 30 seconds and within ±100 m. A new stop must be more than 250 m away after accounting for both locations' uncertainty. There is a 15-minute cooldown. Attempts are saved before network activity so relaunch or a failed test does not repeatedly test the same stop. Moving to a different stop permits a later revisit.

Coverage tests use the existing Cloudflare test service with three-second transfer windows, requesting a maximum 20 MB download and 5 MB upload per test, plus small latency requests and transport overhead. The service receives the network address. A manual test requires an active session and fresh radio observation. Cancel, sleep and lid closure stop the test. Movement, stale location or changed radio context excludes a combined score. Tests retain their own actual start/end locations and times.

## Maps and analysis

Switch map colors between RSRP, SINR, tested download and Connection Score. **Samples** shows located readings; **Heat view** shows median values in measured approximately 50 m bins. Unvisited space is left unmeasured. Four time graphs remain visible together. Selecting a sample in a chart, map or readings picker updates the inspector.

RSRP and SINR colors use the existing radio guide. Download guidance uses green at 100 Mbps, yellow at 25 Mbps and red below; the custom score uses 70/40. Colors are comparison guidance. Missing values are never shown as zero. Speed points use the test's own location and never move with a manually corrected radio reading.

`balanced-v1` averages equal-weight normalized RSRP (−120…−80 dBm), SINR (−5…25 dB) and tested download (0…150 Mbps), each capped at 0…100. It requires all components and matching precise original/test locations. Upload and latency stay available separately. This custom score is versioned and is not a carrier or industry rating.

## Tower and FCC references

Local tower JSON/CSV and manual pins share the map. OpenCelliD lookup remains manual, requires full verified network identifiers and a token entered in the window, and sends only that request to the provider. **Save estimate to reference map** explicitly retains the returned position, radio/full cell identity, MCC/MNC/TAC, lookup date and reported range/sample count. Credentials are never included. Saved positions remain unverified references with OpenCelliD/CC BY-SA attribution; range is not measured coverage.

FCC reference import accepts local Polygon/MultiPolygon GeoJSON FeatureCollections up to 5 MB, 1,000 polygons and 100,000 coordinates. Enter the dataset publication date. Properties are discarded, geometry and date are saved locally, and purple boundaries identify this separate carrier-reported modeled layer. File origin is operator-declared; there is no automatic FCC download or verification. The supplied FCC and AntennaSearch research links open in the browser when selected. Apple Maps supplies the basemap through MapKit.

## Storage and future Shadow connection

Sessions stay on this Mac until explicitly deleted. Export writes JSON to a chosen path and retains the archive. Exports include original locations, corrections and radio identifiers. The versioned cursor/batch contract supports a future Shadow server connector, but there is no server endpoint, uploader or automatic sync. Future remote access must remain client-owned and tailnet-only.

See [archive format and recovery](TMOBILE-COVERAGE-ARCHIVE.md). Advanced administrator radio readings remain window-scoped and are not added to the public measurement archive. Existing rolling history remains a separate legacy archive.

## Checks

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh --fork --test-suite=tmobile --test-suite=network`
- `zsh Tests/TMobileCoverageStoreTests.sh`
- `bash Tests/TMobileCoverageMapChartsTests.sh`

These checks use synthetic readings and intercepted test traffic. Live Mac permission/accuracy, real parked detection, physical sleep/lid transitions, map rendering and gateway/provider responses require a supervised app run.

### Accessibility crash regression (beta.7)

Beta.6 could overflow the main-thread stack when an accessibility reader queried the inspector after starting a recording. LLDB captured repeated `AccessibilityNode.accessibilityLabel` / `NSAccessibilityGetObjectValueForAttribute` calls; the native object was `SwiftUI.AppKitTextInteractionView`, with value `RSRP`. A custom label on a selectable row inherited onto its native text child and recursively resolved `AXDescription`.

Both custom-labeled inspector row containers now use `.accessibilityElement(children: .ignore)` before their complete label/value/quality summary. The inspector retains text selection. Keep the summary on the row element rather than applying it to inherited selectable children.

Runtime regression procedure (an app build and calculation tests alone do not cover this):

1. Open Coverage with a saved session and read its accessibility tree.
2. Start a named verification session; repeatedly read the tree while fresh gateway samples update RSRP and SINR.
3. Expand **Available radio details** and confirm complete metric summaries. Check text copying and keyboard access to controls.
4. Stop recording, close/reopen Coverage several times, switch saved sessions, and repeat accessibility reads.
5. Relaunch the app and confirm recording stays off and the saved sessions remain available.
