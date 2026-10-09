# Shadow Utilities fork updates

Start by reviewing and merging the fork setup into `joaovorocha/vorssaint-utils:main`. This pipeline is being prepared on the stacked `codex/fork-updates` branch; it is **not active on main yet**, and no signing certificate, GitHub environment, secret, tag or release has been created by this change.

Shadow Utilities is the personal macOS fork. Its app is `Shadow Utilities.app`, executable is `ShadowUtilities`, and bundle identifier is `io.github.joaovorocha.shadowutils`. The official Vorssaint identity and official release workflows remain unchanged.

The fork disables the original publisher's feedback and temporary sharing services. Fork updates use only the personal repository and the fork owner's signer; ad-hoc or incorrectly signed builds fail closed for automatic updates. No upstream signing identity is reused.

## Two separate update paths

| Path | Trigger | Result | Human decision |
| --- | --- | --- | --- |
| Upstream source sync | Monday 11:17 UTC or manual **Review upstream updates** | Fetches `vorssaint/vorssaint-utils:main` and opens a review PR into the personal fork | Review, run Fork CI, resolve conflicts, merge |
| Fork binary release | Manual **Fork release draft** on `main` | Tests an existing fork version tag, signs and notarizes app/DMG, creates a draft | Approve protected signing job, smoke-test and manually publish draft |
| Installed app update | Check for updates in a signed Shadow Utilities build | Downloads from this fork and validates the fork bundle and Apple Team | Install the offered fork update |

Source sync never publishes binaries or updates the installed app. No workflow automatically merges a PR or publishes a release. A conflicted upstream merge is aborted, a deduplicated attention issue is opened, and the workflow fails visibly. Existing proposal branches are preserved rather than force-pushed.

For bot-created PRs using `GITHUB_TOKEN`, GitHub starts the PR's CI in an approval-required state. Select **Approve workflows to run** in the PR banner and inspect the results before merging. Bot pushes alone do not trigger push workflows. If the approval banner is unavailable, open **Actions → Fork CI → Run workflow** and select the proposed sync branch. This keeps source sync independent of personal access tokens. [GitHub: triggering a workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).

GitHub may also reject a bot push that changes workflow files or violates a repository rule. That produces a failed run and attention issue. The owner should review and push that proposal manually; the pipeline does not widen token permissions or bypass branch protection.

## Independent fork versions

`Resources/Fork/version.txt` is the fork's version source, initially `0.1.0-beta.1`. `./build.sh --fork` stamps it into the fork app. Keep the upstream `Resources/Info.plist` version and upstream `CHANGELOG.md` unchanged when releasing a fork-only patch.

Release tags are `v<fork version>`, for example `v0.1.0-beta.1`. Supported versions are three numeric components, optionally followed by `-alpha.N`, `-beta.N`, or `-rc.N`, with one prerelease counter. Bump the fork version for each binary update, including changes made without any upstream update. Never move a published version tag or reuse an existing draft automatically.

## Prepare a Developer ID certificate

Signing needs an exportable **Developer ID Application** certificate paired with its private key. If a valid certificate already exists, export its identity as an encrypted `.p12` from the Mac that created it, or restore an existing encrypted backup. Downloading the `.cer` again does not recover the private key. Create a new certificate only if that key is unavailable. Apple lists Account Holder as the required role. A Developer ID Installer certificate is for installer packages; this DMG contains a signed app. [Apple: Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

1. Open **Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority**. Enter your account email and a recognizable key name, leave CA email blank, and save the CSR to disk. [Apple: create a CSR](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request/).
2. In **Apple Developer → Certificates, Identifiers & Profiles → Certificates → +**, choose **Developer ID Application**, upload that CSR, and download the certificate.
3. Open the downloaded `.cer` on the same Mac. In **Keychain Access → My Certificates**, confirm the certificate expands to show its private key. Export the certificate and private key as an encrypted `.p12`; save its password in your password manager.
4. Find your own ten-character **Team ID** under Apple Developer membership details. This value is a public identity pin. Keep the certificate/private key, `.p12` password and API `.p8` key private.

Keep encrypted backups outside the repository. The `.cer` alone cannot sign a release; exporting the paired private key is required for CI.

## Set up notarization and the protected GitHub environment

1. In **App Store Connect → Users and Access → Integrations → App Store Connect API**, request API access if needed, then create a dedicated **team API key** with the access needed for notarization. Download its `.p8` once and retain its Key ID and Issuer ID securely. This workflow uses a team key and issuer, not an individual key. [Apple: App Store Connect API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).
2. In the personal fork, create **Settings → Environments → `fork-release-signing`**. Restrict deployment branches to `main`, require a human reviewer, and enable protection against bypass where your GitHub plan supports it. The release dispatcher must be `joaovorocha`. If reviewer protection is unavailable, leave signing secrets unconfigured until you choose an equivalent owner-controlled release process. [GitHub: environment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
3. Add the variable and environment secrets below **only to `fork-release-signing`**, not repository-wide. Base64-encode the `.p12` and `.p8` locally into the secret-entry flow; do not paste their values into chats, source, issue reports, logs, or command arguments.
4. Enable Actions for the fork. Under **Settings → Actions → General**, allow GitHub Actions to create pull requests. Protect `main` with review and required Fork CI checks. Confirm the first manual signing run pauses for its environment review before using credentials.

| Protected environment item | Type | Value source |
| --- | --- | --- |
| `SHADOW_UPDATE_TEAM_ID` | Variable | Your Apple Team ID; required and embedded in signed builds |
| `SHADOW_SIGNING_CERT_P12` | Secret | Base64 of your encrypted exported Developer ID Application `.p12` |
| `SHADOW_SIGNING_CERT_PASSWORD` | Secret | Password protecting that `.p12` |
| `SHADOW_NOTARY_API_KEY_P8` | Secret | Base64 of the notarization team API `.p8` key |
| `SHADOW_NOTARY_KEY_ID` | Secret | That API key's Key ID |
| `SHADOW_NOTARY_ISSUER_ID` | Secret | Team API issuer UUID |

The release job reuses `Tools/ci-setup-signing.sh` and `Tools/notarize.sh`; secrets are mapped into those helpers only in their relevant protected steps. Missing credentials fail the release. The temporary signing keychain is removed after the job. The separate draft-creation job receives a repository token and verified artifacts, never Apple credentials.

## Release a reviewed fork version

1. Bump `Resources/Fork/version.txt` in a review PR, include the fork release notes in the PR, and merge after Fork CI passes.
2. Create and push its matching tag on the reviewed `main` commit. For the initial version, that is `v0.1.0-beta.1`. The pipeline does not create tags or move refs for you.
3. Open **Actions → Fork release draft → Run workflow**, select branch `main`, and enter the existing tag. Preflight runs its verifier from the trusted main dispatch commit, resolves and inspects the tag without executing tag code, and proves its exact commit is on fork `main` with a matching independent version file. Only then does it check out that verified SHA and run tests without Apple credentials.
4. Review the exact source SHA and approve the `fork-release-signing` environment. The workflow builds with `./build.sh --fork`, validates the fork bundle and Team pin, notarizes the app, builds/signs/notarizes a `ShadowUtilities-<version>.dmg`, and checks the mounted app again. It creates a draft after those checks pass.
5. Download and install the draft DMG for a smoke test. Confirm Shadow Utilities opens, the T-Mobile card works on your local gateway, and the update feed belongs to the personal fork. Complete the draft's release notes and publish it manually when ready. Mark a prerelease appropriately; stable-only update channels may not offer prerelease builds.

The initial ad-hoc build cannot participate in trusted automatic updates. Install the first signed fork release manually; later signed releases keep the same bundle and Team identity. Preserve the same Team across certificate renewals. Changing Teams requires a deliberate trust migration and a new manual install, not a source-sync shortcut.

## Local checks and rollback

`./build.sh --fork` produces `build/stage/Shadow Utilities.app`; `./build.sh --fork --test` runs the test harness. Setting `SHADOW_UPDATE_TEAM_ID` while building embeds the intended signer pin; a releasable build still requires the matching real Developer ID certificate and successful signature/notarization checks. `Tools/fork-package.sh` refuses an unsigned or incorrectly identified app.

Use Shadow Utilities’ in-app uninstall to remove this fork. The inherited `Tools/uninstall.sh` targets the original Vorssaint installation.

If an upstream proposal breaks a feature, leave its PR unmerged, resolve on its proposal branch or close it, and retain the last known-good fork `main`. If a draft is wrong, leave it unpublished and correct the source in a new version. If an already-published release is faulty, stop offering it and install a prior known-good signed DMG manually; do not replace its assets or silently retag another binary.

Validation of this source change does not create the certificate, configure GitHub protections, exercise Apple notarization, or publish an artifact. Those remain explicit owner setup/release steps. GitHub Actions pins were checked against the official action repositories on 2026-10-08: `actions/checkout` v7 `3d3c42e5aac5ba805825da76410c181273ba90b1`, `actions/upload-artifact` v7 `cf430e030ddbb5b0abf93d22962f4752f3646cd9`, and `actions/download-artifact` v7 `37930b1c2abaa49bbe596cd826c3c89aef350131`.
