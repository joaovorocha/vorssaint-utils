# T-Mobile gateway monitor

For beta.4's combined menu bar indicator and complete dropdown readings, see
[Connected radio and dropdown metrics](TMOBILE-INDICATOR.md). Administrator
Wi-Fi controls are described separately in [Wi-Fi and router settings](TMOBILE-WIFI.md).

Vorssaint can show signal and connection status from a compatible T-Mobile
G4AR gateway on the Mac’s local network. This optional feature reads the
credential-free `GET /TMI/v1/gateway?get=all` endpoint.

A credential-free status read was verified against a TMO-G4AR running firmware
1.00.18. The automated suite uses fabricated fixtures. The native panel's live
display and hide/show behavior still need interactive verification; builds and
selftests alone do not establish those interactions on a particular Mac.

## Setup

1. Connect the Mac to the same local network as the gateway.
2. Open **Settings > Monitor > Network** and enable the **T-Mobile gateway**
   tile (or **Show T-Mobile gateway** in the row layout).
3. Open the tile's options, choose **Configure gateway** in the row layout, or use the gear icon in the network
   panel’s **T-Mobile gateway** block, to open the address popover.
4. Enter the gateway’s private IPv4 base address and choose **Save address**.
   The default is `http://192.168.12.1`.

The address must identify a private IPv4 host, such as an address in `10.0.0.0/8`,
`172.16.0.0/12` or `192.168.0.0/16`, using HTTP or HTTPS. Public addresses,
hostnames, embedded credentials, custom paths, queries and fragments are rejected.
Vorssaint adds the fixed endpoint path itself and does not follow redirects.
Address validation does not prove that the gateway is reachable on the current
network.

Access starts only after you enable the feature. macOS may also ask for local
network permission. Turning the feature off stops requests. The configured
address and opt-in consent are machine-specific preferences and are excluded
from settings backup, so restoring settings does not grant local gateway access
on another Mac.

## Readings and refresh

The network panel’s T-Mobile block shows the available device model, firmware
and uptime, plus separate LTE and 5G signal readings: RSRP, RSRQ, RSSI, SINR,
bands and signal bars. Network
registration and roaming status are shown when the gateway reports them. Fields
that the firmware omits remain unavailable or unknown; missing values are never
treated as zero or as a successful connection.

Polling runs while the enabled network panel is visible or the menu bar
connection indicator is enabled. Both share one reader. Successful requests
refresh about every 15 seconds. Failures back
off to a maximum of 120 seconds, and **Retry** starts another request. Closing
the panel stops its polling demand; an enabled menu bar indicator continues.
Errors clear live readings so an old sample cannot appear to be current.
Gateway status stays in memory. Optional local history stores allowlisted
samples only when separately enabled.

Public signal monitoring has no account credentials or login flow. Firmware
that responds with HTTP 401 or 403 requires authentication and is unsupported
by this credential-free reader.
Unreachable gateways, denied local network access and unsupported responses
show an unavailable or error state. Check the address, local connection and
macOS permission before retrying.

The local endpoint does not provide verified plan or billing usage, so the
panel explicitly marks plan usage as unavailable. This feature does not read
connected clients, SIM identifiers or GPS data, and it does not change router
settings, restart the gateway or send other router writes. The separate Wi-Fi
window uses an explicit administrator session and reviewed changes.

## Development checks

From the repository root:

```sh
./build.sh --dev
./build/VorssaintDeveloper --selftest
./build.sh --test-suite=tmobile
```

The Developer build uses separate app preferences and permissions. These checks
cover compilation, app health and the gateway suite. A live test must separately
record the gateway model, firmware, macOS version and which visible readings
were confirmed. Do not include gateway credentials, identifiers or raw private
responses in a report.
