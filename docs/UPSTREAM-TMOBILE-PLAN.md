# Upstream T-Mobile gateway contribution: inventory and plan

Source: `codex/fcc-coverage` (fork PR joaovorocha/vorssaint-utils#8), 75 commits on
top of upstream `cb84ea01`. Target: `vorssaint/vorssaint-utils` `main` (`a5da7633`
at the time of the port, 274 commits newer than the fork base).
Port branch: `upstream/tmobile-gateway` (commit `9d908de8`), cut from `upstream/main`.

Upstream rules that shape the PR (CONTRIBUTING.md, docs/AI-CONTRIBUTIONS.md,
SECURITY.md, PR template):

- One focused, independently useful change; discuss a substantial feature in an
  issue first. No issue exists yet, so the PR opens as a draft and says so.
- New feature entry points obey the feature catalog's availability checks; optional
  background work stops when disabled. Here: gateway polling is gated on
  `AppFeature.monitorNetwork` and stops with the last consumer.
- Preferences join settings backup; machine-specific state is excluded explicitly.
  Here: address, panel opt-in and menu bar pin are `machineStateKeys`.
- Every locale in `AppLanguage.allCases`, including feature string catalogs.
- SPDX + copyright header on every new source file.
- Title `type(scope): lowercase imperative phrase`; no version bump, no CHANGELOG.
- `Refs #N` only, never Closes/Fixes.
- State what was verified on which Mac/macOS, and what was not.

## Inventory of `codex/fcc-coverage`

### Ported: generic gateway monitor (in `upstream/tmobile-gateway`)

| Area | Files | Changes made while porting |
| --- | --- | --- |
| Reader | `Services/Metrics/TMobileGatewayService.swift`, `TMobileGatewaySupport.swift` | Dropped `Codable` and `isValidSnapshot` (only the history archive used them). |
| Radio logic | `TMobileGatewayConnectedRadioSupport.swift`, `TMobileGatewayDiagnostics.swift`, `TMobileGatewayRadioPresentation.swift` | Unchanged. |
| Shared reader | `TMobileGatewayMonitor.swift` | Removed history store, radio window and coverage-recording consumers. |
| Menu bar | `TMobileGatewayMenuBarSupport.swift`, `App/TMobileGatewayIndicatorDrawing.swift`, `MenuBarRenderer.swift`, `StatusItemController.swift`, `UI/MenuBarMetricsPreview.swift`, `UI/Settings/MonitorSettings.swift` | Fork had 12 legacy metric cases (`tMobileLTE` ... `tMobile5GRSSI`) plus a one-time migration; upstream never shipped them, so the port has one case `tMobile` (`menuBarTMobile`) and no migration, reading enum, per-reading display or signal-style keys. Accessibility label is set only while the indicator is pinned (nil otherwise, keeping AppKit's default). |
| Panel | `UI/MenuPanel/TMobileGatewayBlock.swift`, `NetworkSection.swift`, `MenuPanelView.swift`, `MetricDetailView.swift`, `UI/Settings/MonitorPanelConfig.swift` | Removed Coverage, History & towers, and Wi-Fi buttons and the Wi-Fi pending-write guard. |
| Strings | `Core/TMobileGatewayStrings.swift` (15 locales), `Resources/Info.plist`, 14 `InfoPlist.strings` | Took the read-only local-network prompt from the first commit (`26f6df7b`), not the later one that mentions Wi-Fi writes. No location prompts. |
| Preferences | `Core/Defaults.swift`, `Core/SettingsBackupSupport.swift` | Only 4 keys: `menuBarTMobile`, `tMobileMenuBarComponents`, `monitorNetTMobile`, `tMobileGatewayAddress`. |
| Tests | `TMobileGateway{,Integration,ConnectedRadio,Indicator,RadioPresentation}Tests.swift`, `TMobileGatewayMonitorTests.sh` + harness, `TMobileGatewayAppearanceTests.sh` + harness, `TMobileMenuBarGroupsHarness.swift`; edits to `MetricsTests`, `AppManagementFeatureTests`, `SwitcherModelFeatureTests`, `MenuBarBatteryWarningTests` | History/archive and legacy-migration checks removed; monitor harness rewritten for panel + menu bar only. Appearance test no longer hard-codes `DEVELOPER_DIR`. |
| Docs | `docs/TMOBILE-GATEWAY.md` (indicator doc merged in), `docs/TMOBILE-SIGNAL-GUIDE.md`, new entries in `docs/PRIVACY.md` and `docs/PERMISSIONS.md` | Fork branding and links to Wi-Fi/history/coverage docs removed. |

### Fork-only (never upstream)

- Shadow Utilities identity: `Resources/Fork/` (NOTICE, version.txt),
  `Tools/MakeForkIcon.swift`, `Tools/fork-*.sh`, `build.sh --fork` (bundle id
  `io.github.joaovorocha.shadowutils`, `SHADOW_UTILITIES` flag, sed rebrand of
  plists, signing/team checks), `README.md` and `CHANGELOG.md` fork sections.
- Update feed / team ID logic: `Services/Update/UpdateService.swift`,
  `UpdateInstallerSupport.swift`, `UpdateServiceSupport.swift`, `ShadowUpdateTeamID`
  plist key, `docs/FORK-UPDATES.md`, `Tests/UpdateFeatureTests.swift`,
  `UpdateAdminInstallTests.swift`, `DeveloperInstallIsolationTests.sh`.
- CI: `.github/workflows/fork-ci.yml`, `fork-release.yml`, `upstream-sync.yml`,
  `issue-fix-status.yml` edits.
- Branding through `AppInfo.name`: `Core/AppInfo.swift`, `BundleMigration.swift`
  and the `\(AppInfo.name)` substitutions in ~30 string catalogs and all 14
  `Strings+*.swift` localization files; `#if SHADOW_UTILITIES` blocks in
  `Defaults.swift` (sharing off by default), Screenshot/Recording sharing,
  Feedback, FanControl XPC identity, `SwitcherModelFeatureTests` (maintainer
  social URL), `ForkSharingTests.swift`, `FanControlIdentityTests.swift`.
- Shadow server mentions: removed placeholder in `8678a3f1`; MQTT work lives on
  `codex/shadow-server-mqtt` (not touched).
- Personal build policy: `BUILD_JOBS` cap in `build.sh` (owner's two-worker limit).

### Separable later PRs (left out to keep this one small)

1. **Signal history (local)**: `TMobileGatewayHistoryStore/Support`,
   `TMobileGatewayHistoryView`, `tMobileHistoryRecording`; needs `Codable` +
   `isValidSnapshot` back. Depends on this PR.
2. **Wi-Fi administration**: `TMobileWiFiService/Support`, `TMobileWiFiSettingsView`,
   `ScopedCredentialStore`, `TMobileGatewayCredentials`. Writes router settings
   with admin credentials in Keychain; needs a maintainer decision first (security
   scope per SECURITY.md).
3. **Band help popovers**: `TMobileBandGuide`, `TMobileBandHelpView`. Small, UI-only.
4. **Authenticated cell telemetry and tower references**: `TMobileCellTelemetry*`,
   `TMobileTowerReference*`, `TMobileTowerMap*`.
5. **OpenCellID lookup**: third-party API key and network calls; privacy review.
6. **Coverage workspace + FCC model**: recorder, location permission, speed tests,
   map, FCC GeoPackage import, `Tools/*FCC*`, `Tools/RenderCoverage*`. Large,
   adds Location permission and FCC credentials; least likely to fit upstream scope.

### Personal data check

- Fixtures use synthetic values only: private RFC 1918 gateway address
  `192.168.12.1` (T-Mobile's documented default), model string `TMO-G4AR`,
  fabricated cell IDs at numeric limits, `0x310260ABCDEF` / `001-01-12345` ECGIs
  (MCC/MNC test patterns), `8.8.8.8` only as a rejected public address.
- No coordinates, serials, MACs, IMEIs, IMSIs, credentials or tokens in the ported diff.

## Known gaps for upstream review

- Several newer UI strings (menu bar option toggles, "T-Mobile connection",
  connection accessibility text, signal tips, radio field labels) are English only;
  `TMobileGatewayStrings` covers the original panel labels in all 15 locales.
  CONTRIBUTING asks for every locale, so either translate before marking ready or
  ask the maintainer.
- Live behavior: the fork's docs record a check against a TMO-G4AR (firmware
  1.00.18); not re-verified here. The ported branch itself was build/test-verified, not driven in the UI.
