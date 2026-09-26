🇬🇧 [English](Core-Management-en) | 🇷🇺 [Русский](Core-Management-ru)

# Core Management

LimCore has two parts: the LuCI app is the interface, and a separate **core** binary does the actual proxying. You install and update the core from **Services → LimCore → Core & Tools → Core management** — no SSH required.

---

## The core

LimCore runs on **[sing-box-extended](https://github.com/shtorm-7/sing-box-extended)**, shtorm-7's build of sing-box with an extended set of build tags. On top of stock sing-box it adds **AmneziaWG**, **WARP**, TrustTunnel and several other protocols.

The installed binary is roughly 75 MB raw. On a **compressing** overlay (jffs2/ubifs) it occupies about 26 MB because the filesystem compresses it in place; on ext4/f2fs it needs the full size.

Which protocols appear in the node editor depends on the build tags of the core version you have — the **Core & Tools** section lists them. See [Supported Protocols](Supported-Protocols-en).

> LimCore previously also supported hiddify-core as an alternative. That support was removed: it forced the config generator to emit two dialects in parallel, and sing-box-extended covers what hiddify-core did while adding AmneziaWG, which it never supported.

---

## Installing

Core Management has a single **Install** button. It inspects the device before downloading and refuses to install something that cannot fit.

1. It reads the free space on `/overlay` (persistent flash), adjusted for whether the filesystem compresses.
2. If there isn't enough room it stops with a clear message instead of installing something broken.
3. The downloaded package is **verified against the byte count** GitHub reports before it is handed to the package manager.
4. After installation it confirms that `/usr/bin/sing-box` actually landed on disk.

### Why these checks matter

A truncated download is the most common way to end up with a broken install: `wget` can exit successfully on a short read, `apk` then registers the package, but the 75 MB binary never reaches the disk. The result is the contradictory state where the package is "installed" and diagnostics report the core "not found". Verifying the size before installing and the binary after it closes that path — and on failure the package registration is rolled back, so a retry isn't an "already installed" no-op.

A related trap is a binary **larger than the free overlay**: it gets **truncated** as it's written and then crashes with a **"bus error" (SIGBUS)** the moment it launches. That's what the free-space check is for.

---

## Storage at a glance

| Free on `/overlay` | Result |
|--------------------|--------|
| ~80 MB+ (non-compressing fs) | Installs |
| ~32 MB+ (jffs2 / ubifs) | Installs — the filesystem compresses the binary |
| Less | Not enough — free space, or bake the core into a custom firmware image |

> The installer detects the overlay type itself — trust its check over the table above.

Tight on flash but building your own image? The core fits comfortably when **baked into the SquashFS** root at image-build time (the SquashFS root is compressed and read-only), rather than installed into the writable overlay.

---

## Updating and custom cores

- **Update:** press **Install** again — it fetches the latest release and reinstalls. **Check update** next to it reports the latest available version without installing it.
- **Custom / external core:** instead of the managed install you can point LimCore at a **self-provided binary** (a build you compiled, or a version not in Releases) — it detects and uses it. The binary must be sing-box compatible; the service, the config generator and the UI all resolve the same path, so what's displayed can't drift from what's running. Advanced setups only.
- **Version / status:** the **Core management** section shows the installed core and version. If it shows all `?`, the backend (rpcd) is stale — restart it (`/etc/init.d/rpcd restart`) and reload the page.

---

## Resources & updates

The **Core & Tools** tab also has a **Resources management** section for the data files routing depends on — the GeoIP / Geosite databases and the RU rule-sets:

- **Check update** fetches the latest rule-set and geo data on demand.
- The RU routing lists also **self-refresh** on a schedule, so in normal use you don't need to touch this.
- **Subscriptions** update separately — on demand from the Subscriptions tab, or automatically on a cron; see [Subscriptions & Node Import](Subscriptions-en).

---

## Kernel modules

The proxy needs `kmod-nft-tproxy` and `kmod-tun` for transparent routing. The installer pulls these in; if routing doesn't work after a fresh install, confirm they're present.

See also: [ByeDPI](ByeDPI-en) · [Zapret](Zapret-en) · [Supported Protocols](Supported-Protocols-en) · [Troubleshooting](Troubleshooting-en)
