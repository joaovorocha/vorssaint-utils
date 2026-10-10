# Advanced radio details

Shadow Utilities beta.5 shows available readings only in the T-Mobile dropdown.
RSRP, RSRQ and SINR carry green/yellow/red guidance and text ratings. A missing
LTE or 5G radio has no empty section. Firmware and endpoint support determine
which fields appear; an API field in a synthetic test is not proof that a
particular gateway returns it.

Open **Network → T-Mobile gateway → More radio & tower details…**. The separate
window has **Radio**, **History & towers**, **OpenCelliD** and **Websites** tabs.
It is also reachable from Monitor settings via **Configure gateway → Radio &
tower details…**. Public readings share the existing reader while this window
is open, subject to the gateway feature opt-in.

In Radio, expand **Sign in for additional radio readings** to read
administrator-only serving-cell telemetry. Enter the gateway admin
password in the secure field. This differs from the Wi-Fi password and T-Mobile
account password. For HTTP gateways, acknowledge the trusted private network
notice: credentials travel without encryption on that local connection.

The session allows only `POST /TMI/v1/auth/login` and
`GET /TMI/v1/network/telemetry?get=cell`, using the configured private IPv4
gateway. Redirects, cookies, credential storage and proxies are disabled.
Requests and response sizes are bounded. There is no polling or automatic retry;
use **Refresh readings**. Authentication expiry, closing the window, signing out
or changing the address clears the session. Old readings disappear while a
refresh loads or fails.

Available flat/sector aliases are normalized for bars, bands, RSRP, RSRQ, RSSI,
SINR, antenna, bandwidth, EARFCN/NR-ARFCN, PCI, TAC, CQI, cell ID, explicitly
reported eNB/gNB IDs and ECGI. **Supported bands (capability)** is a separate
inventory; it never establishes a connected band or enters the menu indicator.
No node identity is derived from an ambiguous cell ID. The response is not a
verified neighboring-cell list.

Credentials, bearer tokens and advanced reports remain in memory for this
window. They do not enter the public monitor, portable settings or recorded
signal history. GPS, SIM, client lists and unknown fields are excluded. This
window sends no Wi-Fi, band-lock, restart or other configuration changes.

**Local tower records** uses only manual pins and local imports. Matching an
explicit reported identity to a saved record does not independently verify its
physical coordinates. No identifiers or coordinates are sent to a lookup
service by the local matcher. See [Local history and towers](TMOBILE-LOCAL-HISTORY.md) for import
formats and provenance.

## Optional online lookup

The OpenCelliD tab sends one selected full cell identity only when you enter a
token, confirm the displayed identifiers and choose the lookup button. Enter
MCC, MNC, TAC and a complete LTE ECI or NR NCI manually. An ambiguous gateway
`cid`, sector ID, PCI or node ID is not automatically promoted to a full cell
identity. The token and results remain in this window's memory; no automatic
lookup, measurements upload or area scan runs.

The fixed HTTPS endpoint is `https://opencellid.org/cell/get`. The response's
radio and full identity must match the requested values before coordinates can
be shown. Community coordinates are a database reference, not an independently
verified serving-tower position. Attribution and the CC BY-SA 4.0 link appear
beside the result. [Official API contract](https://wiki.opencellid.org/docs/api/cell-position),
[attribution requirements](https://wiki.opencellid.org/docs/attribution).

Websites opens AntennaSearch and the user-selected FCC map in the browser.
Search areas are entered on those sites; gateway identifiers and credentials
are not automatically appended to browser links.

Automated checks use synthetic values and intercepted requests:

```sh
./build.sh --fork --test-suite=tmobile
zsh Tests/TMobileCellTelemetryServiceTests.sh
zsh Tests/TMobileGatewayMonitorTests.sh
zsh Tests/TMobileWiFiServiceTests.sh
```

Administrator sign-in and the extra fields need a separate human test on the
gateway. Do not paste credentials or raw private responses into test reports.
