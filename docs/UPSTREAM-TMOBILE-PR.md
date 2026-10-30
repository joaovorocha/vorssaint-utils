# Draft upstream PR (not opened)

Target: `vorssaint/vorssaint-utils` `main`
Head: `joaovorocha/vorssaint-utils:upstream/tmobile-gateway`
Open as: **draft** (no issue discussed yet). Head commits: `9d908de8`, `15967095`.

## Title

```text
feat(network): add optional T-Mobile home internet gateway readings
```

## Body

```markdown
## Summary

Adds optional readings from a T-Mobile 5G home internet gateway (tested model:
TMO-G4AR) to Monitor, for people whose Mac is on that gateway's network.

Before: the Network section shows the Mac's own traffic only; cellular signal on
the gateway is visible only in T-Mobile's phone app or the gateway web page.

After, both off by default:

- **Network panel block.** Settings > Monitor > Network > T-Mobile gateway shows
  model, firmware, uptime, registration and roaming, plus separate 5G and LTE
  sections (bars, bands, RSRP, RSRQ, RSSI, SINR and the optional cell fields the
  same response carries). RSRP, RSRQ and SINR get an approximate rating and color;
  a **Signal guide & tips** sheet suggests placement checks.
- **Menu bar indicator.** Settings > Monitor > In the menu bar > T-Mobile
  connection pins one item such as `5G UC ▂▄▆█ n41`. Options choose technology,
  bars and bands. VoiceOver reads the full connection description.

How it reads:

- A single credential-free `GET /TMI/v1/gateway?get=all` to a private IPv4
  address the user sets (default `http://192.168.12.1`). Public addresses,
  hostnames, credentials, paths and redirects are refused; requests carry no
  cookies or auth headers.
- Only allowlisted signal/status fields are kept, in memory. SIM, client list
  and GPS fields are dropped. Nothing is written to disk.
- Panel and menu bar share one reader. It runs only while the feature is on and
  the panel is visible or the indicator is pinned, refreshes about every 15 s,
  backs off to 120 s on errors, and stops with its last consumer or when the
  Monitor network feature is turned off.
- The address, panel opt-in and menu bar pin are machine-specific and excluded
  from settings backup, so restoring a backup cannot start requests on another
  network.
- Adds `NSAllowsLocalNetworking` (internet ATS unchanged) and a localized
  `NSLocalNetworkUsageDescription` in all bundled languages. Privacy and
  Permissions docs gain an entry each.

The 5G UC badge is inferred from bands T-Mobile lists as Ultra Capacity (n2, n25,
n41, n258, n260, n261) when not roaming; it is a label, not a gateway flag.

Not included (possible follow-ups if wanted): local signal history, Wi-Fi
administration (needs gateway admin credentials), band help popovers, and
coverage mapping.

### Still missing (why this is a draft)

- All gateway text is in `TMobileGatewayStrings` for the 15 app languages, but
  the non-English wording has not been reviewed by native speakers yet.
  Corrections are welcome.
- No issue yet. Happy to open one first if you prefer to discuss scope there.

## Verification

Run on this branch (Apple Silicon Mac, macOS 27.0.1):

- `./build.sh --test` (all suites plus `Tests/TMobileGatewayMonitorTests.sh` and `Tests/TMobileGatewayAppearanceTests.sh`): 120,134 of 120,136 checks passed; the 2 `repository` failures (typewriter apostrophes, French spacing) were fixed, then `--test-suite=repository --test-suite=tmobile --test-suite=localization --test-suite=metrics --test-suite=network` passed (10,065 checks). Shell harnesses pass: 11 shared-reader checks, the grouping check and 247 appearance checks.
- `./build.sh` then `./build/Vorssaint --selftest` on the final commit: no warnings, `SELFTEST OK`

Tests use fabricated responses and intercepted requests; no real gateway is
contacted. The monitor harness checks that nothing is requested while off, that
panel and menu bar share one request, and that invalid origins never open one.

Live readings were checked earlier against a TMO-G4AR on firmware 1.00.18 from a
build of the same code in my fork. The ported branch was not driven interactively
in the UI; the panel, popover, menu bar item and VoiceOver output on this branch
remain unverified on a real Mac.
```

(Attribution line to append when the PR is actually opened:)

```text
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
