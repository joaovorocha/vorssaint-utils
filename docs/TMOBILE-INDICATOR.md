# Connected radio and dropdown metrics

Shadow Utilities beta.4 replaces the separate T-Mobile menu bar pins with one
**T-Mobile connection** choice in **Settings → Monitor → In the menu bar**.
The indicator combines an LTE, 5G or 5G UC badge, rounded signal bars and the
selected radio's reported bands, for example `5G UC ▂▄▆█ n41`. The native
artwork follows the supplied visual references without embedding their website,
scripts or background images. It retains the gateway's actual 0–5 signal scale.

The status response has a generic registration field but no per-radio connected
flag or measurement timestamp. The indicator requires a recognized `registered`
state and a finite serving RSRP between −160 and −20 dBm. It prefers reported
5G, then LTE; a radio object or leftover band metadata alone does not establish
a connection. Unknown registration or missing serving signal shows an unavailable
dash. An LTE anchor can remain connected alongside the selected 5G radio in NSA
mode; both radios stay available in the dropdown.

Only the selected radio's bands appear in the menu bar. Multiple reported bands
share that indicator in gateway order; the app does not invent a primary carrier.
Band identifiers such as n41 describe a frequency band, not the exact current
center frequency in MHz. A missing band remains unavailable. This display does
not lock a band or change the modem configuration.

The 5G UC badge is inferred from a reported n2, n25, n41, n258, n260 or n261 band
when roaming is not reported. These bands are listed as Ultra Capacity by
[T-Mobile's network table](https://www.t-mobile.com/support/coverage/t-mobile-network).
It is a band-based label, not a gateway-reported UC flag or a speed guarantee.
Other bands retain the plain 5G badge.

## All radio metrics

Click the connection indicator, then expand **All radio metrics** in the
**T-Mobile gateway** block. Separate 5G and LTE / 4G sections show every radio
field the existing public-status parser supports: bars, bands, RSRP, RSRQ,
RSSI, SINR, antenna, bandwidth, channel (NR-ARFCN or EARFCN), PCI, TAC, CQI,
gNB ID, eNB ID, cell ID, ECGI and supported-band capability when returned.
In beta.5, missing fields and entirely absent radio sections are hidden. Real
zero readings remain visible. Values can be selected and copied. Cell IDs do
not supply tower coordinates.

RSRP, RSRQ and SINR show a rating and color: good/excellent is green, fair is
yellow and poor is red. RSSI and identifiers remain neutral. Bar color follows
RSRP placement guidance while the count stays exactly as the gateway reports.
These are approximate app ratings, not T-Mobile ratings or a speed prediction;
the boundaries are documented in [Signal readings](TMOBILE-SIGNAL-GUIDE.md).

The disclosure remains available during initial loading or a failed request,
with an explanatory empty state. The existing refresh, signal guide, local
history/tower map and Wi-Fi controls remain available. The dropdown continues
to use the public reader. **Advanced radio & tower info…** opens an optional
administrator session for the additional serving-cell endpoint, described in
[Advanced radio details](TMOBILE-RADIO-INSIGHTS.md).

## Preference compatibility and verification

Existing radio pins collapse at their first saved menu position. A one-time
local migration preserves any existing radio-pin opt-in, while new profiles
stay off. Turning the connection indicator off later remains respected even
if old saved pin flags still exist. Local gateway consent and the migration
marker are excluded from portable settings backups. Old keys remain intact
for rollback to beta.3.

Validate with the `tmobile`, `metrics`, `preferences`, `app-management`,
`features`, `settings`, `switcher-model` and `localization` groups, plus
`zsh Tests/TMobileGatewayMonitorTests.sh`. Tests use fabricated values or mocked
requests. Live display needs a separate native check on the installed app;
missing firmware fields must never be reported as verified live readings.
