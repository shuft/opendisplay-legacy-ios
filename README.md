# LegacyDisplay

An unofficial [OpenDisplay](https://github.com/peetzweg/opendisplay) receiver
for **jailbroken iOS 12 iPads**: use an old iPad as a real extended display
for your Mac, over the Lightning cable or Wi-Fi, with touch and a live cursor.

OpenDisplay's own iPad app needs iPadOS 15 or later. This app implements the
same wire protocol for the devices that were left behind, and because it's
installed as a jailbreak package, **there's no Apple ID signing and no 7-day
expiry**.

> **Status:** early, but working. Tested on an iPad mini 2 (iPad4,4) on
> iOS 12.5.8 with Chimera, against OpenDisplay 1.24.0 on macOS 26: USB and
> Wi-Fi, failover when the cable is pulled, rotation, touch and cursor. The
> A7's decode budget holds the stream to 2048×1536 at 42 fps.

## How it fits together

```
Mac: OpenDisplay (unmodified, notarized)          iPad: LegacyDisplay
  virtual display → ScreenCaptureKit               listens on TCP 9000,
  → VideoToolbox H.264 ──── USB (usbmuxd) ────►    advertises _opensidecar._tcp
                       └─── Wi-Fi (Bonjour) ──►    → hardware H.264 decode
  touch / scroll / pings ◄──────────────────────   → AVSampleBufferDisplayLayer
```

The Mac side is the stock OpenDisplay app. It creates the virtual display
itself, so no BetterDisplay or similar is needed.

## Install

### On your Mac

Install [OpenDisplay](https://github.com/peetzweg/opendisplay/releases/latest):
download `OpenDisplay.dmg` and drag the app into Applications. Open it, allow
**Screen Recording** and **Accessibility** when asked, then quit it (⌘Q) and
open it again.

### On your iPad

You need a 64-bit iPad or iPhone (A7 or newer) with a rootful jailbreak on
iOS 12 or later, such as Chimera, unc0ver or checkra1n.

- **Easiest:** open **https://shuft.github.io/opendisplay-legacy-ios/** in
  Safari on the iPad, tap the button for Sileo, Zebra or Cydia, then install
  **LegacyDisplay**. You can also add that URL as a source by hand. Updates
  then arrive through your package manager like any other tweak.
- **Or** download the `.deb` from
  [Releases](https://github.com/shuft/opendisplay-legacy-ios/releases/latest)
  and open it in Filza.

## Using it

1. Open OpenDisplay on the Mac.
2. Open LegacyDisplay on the iPad. With the cable plugged in, the Mac connects
   over USB; otherwise it finds the iPad on the same Wi-Fi.
3. The iPad shows up as a display in System Settings › Displays. Arrange it
   like any other monitor.

On the iPad: one finger clicks and drags, two fingers scroll, and a
three-finger tap toggles a stats overlay (transport, frame rate, bitrate,
round-trip time).

**After a reboot:** re-run your jailbreak (for Chimera, open the Chimera
app) before opening LegacyDisplay. The app itself never expires.

## Building from source

You only need the macOS Command Line Tools (`xcode-select --install`), not Xcode.

```bash
scripts/bootstrap.sh                   # theos, iOS 14.5 SDK and ldid into .local/
IPAD=192.168.1.50 scripts/install.sh   # build the .deb, install it over SSH
```

The device needs OpenSSH. `install.sh` runs `dpkg -i` and `uicache` on it, so
the icon appears without a respring. With `.local/ssh/config` defining a
`Host ipad`, you can leave `IPAD` unset.

## Releasing

1. Bump `Version` in `control` and `CFBundleShortVersionString` in
   `Resources/Info.plist`. The release script refuses to build if they differ.
2. Commit, tag and push: `git tag v0.2.0 && git push origin main v0.2.0`.

The [Release workflow](.github/workflows/release.yml) then builds on macOS,
attaches the `.deb` to a GitHub Release, and publishes the package source to
GitHub Pages (Settings › Pages › Source must be set to **GitHub Actions**). The
source carries only the latest version. `scripts/release.sh` does the same
build locally into `dist/`.

## Protocol support

Written against OpenDisplay's [PROTOCOL.md](https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md), `pv` 3:

| Feature | Status |
|---|---|
| `hello` (panel, scale, `id`, `pv`, `videoCaps`, `displayMaxFrameRate`), re-sent on rotation | ✅ |
| Bonjour TXT `id` and `pv` | ✅ |
| H.264 Annex B, telemetry prefix, SPS/PPS changes, `kf` recovery | ✅ |
| `ping`/`pong` liveness and clock sync, 5 s silence timeout | ✅ |
| `touch` (with `t` in the sender's clock), `scroll` in video pixels | ✅ |
| `cursor` (with sequence numbers) and `cursorImg` | ✅ |
| `welcome`, `updateRequired`, `streamConfig`, `sleeping`, `closing`, `stats` | ✅ |
| Newcomer connections adopted only after they send bytes | ✅ |
| H.264 decode budget for A7/A8 chips (`maxPixelsPerSecond`) | ✅ |
| HEVC | ❌ not offered: no hardware decoder on these chips |
| UDP cursor side channel (§6.3) | ❌ not yet: the cursor rides TCP |
| `pencil`, `proximity`, `power` | ❌ not applicable |

## Troubleshooting

- **Logs:** `idevicesyslog -m LegacyDisplay` (from `brew install libimobiledevice`)
  with the device on USB. The Mac app logs our `stats` messages as `PHONE-STATS`.
- **Build fails with "redefinition of module 'SwiftBridging'":** that's a
  known problem with some Command Line Tools installs. The Makefile already
  builds without Clang modules to avoid it; if you add code that uses
  `@import`, switch it to `#import`.
- **Nothing connects over Wi-Fi:** Bonjour (mDNS) has to be allowed on the
  network, and both devices need to be on the same subnet.

## Credits

- [OpenDisplay](https://github.com/peetzweg/opendisplay) by Philip Poloczek
  and contributors (GPL-3.0): the Mac app and the protocol specification this
  receiver implements. LegacyDisplay contains no OpenDisplay code.
- [ipad-iphone-second-monitor-ios12-free](https://github.com/cuongpham1/ipad-iphone-second-monitor-ios12-free)
  by cuongpham1 (MIT): the Swift iOS 12 client this app was ported from and
  extended.

This project isn't affiliated with OpenDisplay. Please report problems here,
not to them.

## License

MIT, see [LICENSE](LICENSE).
