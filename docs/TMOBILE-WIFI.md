# Wi-Fi and router settings

Open **Network → T-Mobile gateway → Wi-Fi & router settings**, or
**Settings → Monitor → In the panel → Network → T-Mobile gateway options →
Wi-Fi & router settings**.

Sign in with the gateway's **admin** password, which is different from the
Wi-Fi password and T-Mobile account password. Sign-in loads configuration only;
it does not change the gateway. Admin access lasts for the open settings window.
The app does not save admin credentials, bearer tokens, current Wi-Fi passwords
or complete router configuration in preferences, Keychain, logs, history or
portable backups. Closing the window or signing out discards the session.

The G4AR's usual local URL uses HTTP. The sign-in screen explains that admin
credentials and Wi-Fi configuration travel without encryption over that local
network, and requires acknowledgment that it is a trusted private network.
HTTPS uses normal system certificate validation. Only a validated private IPv4
gateway origin is accepted; redirects, proxies, cookies and saved HTTP
credentials are disabled. There is no cloud account sign-in.

## Available controls

For existing networks, fields present in the gateway response can be edited:

- Network name (SSID), with a maximum of 32 UTF-8 bytes.
- Replacement Wi-Fi password, 8–63 printable ASCII characters, preserving spaces.
- Broadcast network name (the inverse of hiding a network).
- Guest network flag.

Current passwords stay hidden. Replacement starts blank and requires an
explicit **Replace Wi-Fi password** choice; leaving it off preserves the
existing password. Unknown or unavailable fields cannot be edited.

Frequency flags, WPA version and encryption are shown for each network. The
radio section shows available 2.4/5 GHz enable state, channel, bandwidth, Wi-Fi
mode, transmit power, maximum clients, MU-MIMO, WMM, airtime fairness and band
steering. Missing values remain **Not reported**.

The owner's G4AR resource has an existing local write path for the four fields
above. It has no verified local write contract for radio controls, frequency
flags, WPA choices, creating/deleting networks or restarting the gateway.
Those values remain read-only here. Do not infer G4AR write support from an
example for a different gateway model.

[T-Mobile's T-Life guide](https://www.t-mobile.com/support/home-internet/app)
provides frequency/WPA options, additional networks and gateway restart.
The settings window links to that guide and the configured gateway web page.
The documented G4AR firmware is automatic-channel-only and exposes no local
DHCP, firewall or port-forward controls. Firmware updates are carrier-managed;
[T-Mobile's G4AR guide](https://www.t-mobile.com/support/home-internet/5g-gateway-g4ar)
explains that they cannot be manually requested.

## Review, apply and restore

Administration opens in its own window, so closing the menu popover or opening
a guide does not discard the session. The window cannot be closed during the
apply/readback transaction. Quitting the app or losing the network can still
leave an outcome unconfirmed.

Edits remain drafts until **Review changes** and the final **Apply changes**
confirmation. Review identifies the exact gateway and changed fields, with
password values hidden. Wi-Fi name/password changes can disconnect devices;
Ethernet provides a separate way to reach the gateway while making changes.

The app preserves the complete fetched configuration, including unknown and
unchanged fields. Immediately before applying, it reads the gateway again and
rejects a changed baseline. One configuration POST is sent; the app never
automatically retries it. A successful response alone is insufficient: a fresh
read must confirm the requested result and preserved settings.

If the connection drops or a result cannot be checked, the app reports an
unconfirmed outcome. Reconnect to the gateway's network and use **Check pending
change** in the same session before another write. Signing in again, signing
out or closing the window discards pending verification and restore state. If
authentication expired, sign in again to read the current settings before
preparing any new change. It does not claim success or automatically replay a previous full
configuration. The gateway has no verified server-side compare-and-swap
contract, so a narrow race with another administrator remains possible.

After a confirmed change, **Review restore of previous settings** can restore
the touched fields while this window remains open and the previous values are
available. If the gateway masked a previous password, replacing it cannot
offer a restore of that unknown password. Restore checks the current
configuration, preserves other fields and requires a separate confirmation and
readback. The previous values stay only in session memory; closing the window
discards this restore option.

The public signal reader, menu pins and local history remain credential-free
and do not receive the admin configuration. No router write is made during
development validation: network tests intercept synthetic requests.
