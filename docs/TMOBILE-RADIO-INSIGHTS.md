# Advanced radio details

Shadow Utilities beta.5 shows available readings only in the T-Mobile dropdown.
RSRP, RSRQ and SINR carry green/yellow/red guidance and text ratings. A missing
LTE or 5G radio has no empty section. Firmware and endpoint support determine
which fields appear; an API field in a synthetic test is not proof that a
particular gateway returns it.

Open **Network → T-Mobile gateway → Advanced radio & tower info…** to read
additional administrator-only serving-cell telemetry. Enter the gateway admin
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
service. See [Local history and towers](TMOBILE-LOCAL-HISTORY.md) for import
formats and provenance.

Automated checks use synthetic values and intercepted requests:

```sh
./build.sh --fork --test-suite=tmobile
zsh Tests/TMobileCellTelemetryServiceTests.sh
zsh Tests/TMobileGatewayMonitorTests.sh
zsh Tests/TMobileWiFiServiceTests.sh
```

Administrator sign-in and the extra fields need a separate human test on the
gateway. Do not paste credentials or raw private responses into test reports.
