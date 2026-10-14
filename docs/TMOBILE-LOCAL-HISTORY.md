# Local T-Mobile history and towers

Enable recording under **Network → T-Mobile gateway → History & towers** or
**Settings → Monitor → Network → Configure gateway → Local history & tower map**.
Recording is off by default. One successful reading per minute is kept, up to
seven days or 10,000 samples, while the app runs and the Network feature is on.
Live selected menu bar readings still refresh every 15 seconds. Failed reads
do not become zero readings. History remains visible when recording is off.

Data lives outside Documents in the current app's local Application Support
folder, under `T-Mobile/history.json`. Directory permissions are 0700; file
permissions are 0600. The file contains normalized signal/device fields and
manual coordinates, never the raw response, router address, SIM, GPS, serial
number, credentials or client list. Recording consent and menu bar polling
choices are excluded from portable settings backups.

The offline map plots longitude horizontally and latitude vertically. It has
zoom, drag and Fit all controls, with a text list of the first 50 tower pins.
It contains no online tiles, streets, terrain or coverage estimates. Pins are
owner-supplied references, not verified serving towers. Cell ID alone is not
enough to establish tower coordinates or a current connection.

**Add tower** accepts a name and decimal latitude/longitude. Bands and a cell
ID reference are optional. **Measurement location** manually tags future
samples at the entered coordinate until **Stop tagging new readings** is used.
No device location permission is requested. No coordinates or IDs are sent
to a lookup service.

Import accepts UTF-8 CSV with this exact header (quoted commas are supported):

```csv
name,latitude,longitude,bands,cellID
Example tower,40,-100,n41,12345
```

Or a JSON array:

```json
[{"name":"Example tower","latitude":40,"longitude":-100,"bands":"n41","cellID":"12345"}]
```

JSON bands/cellID are optional. Imports add records and never overwrite current
pins. Maximum 2 MB per file and 5,000 total towers; invalid records reject the
entire import. Latitude must be −90…90, longitude −180…180. Examples above are
illustrative, not a real tower dataset. Import only files you are allowed to use.

Search saved pins by name, band or cell ID. Removing a pin offers Undo until
another pin is removed or the app closes. Clearing readings requires a separate
confirmation and preserves tower pins. Retention is checked on load and every
minute even when recording is off.

Monthly T-Mobile account usage, customer account information and carrier tower
coordinates are unavailable from the credential-free gateway status endpoint.
Official support and coverage links open only when selected and contain no
local coordinates or serving-cell identifiers.
