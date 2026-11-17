# Installing on a device

You need a **signed** `.ipa` (see [BUILDING.md](BUILDING.md#4-signing)) whose
provisioning profile includes your device's UDID.

## USB (xtool)

```bash
xtool device list                          # confirm the device is visible
xtool device install xtool/Retronaut.ipa
```

Preconditions on the device, in order:

1. **Developer Mode** on — Settings → Privacy & Security → Developer Mode → On,
   then reboot and confirm.
2. **Unlocked screen** during install.
3. Tap **Trust** on the “Trust This Computer?” prompt.

If install stalls with `opTimeout`, it is almost always one of those three:
locked screen, Developer Mode off, or the trust prompt dismissed.

## AltStore / SideStore

Install AltStore with your Apple ID once, then open the `.ipa` from Files and
choose *Install*. This path re-signs the app for you and, on a free account,
re-signs it before the 7-day profile expires.

## OTA (itms-services)

Requires **HTTPS with a certificate the device trusts** and a manifest:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>items</key><array><dict>
    <key>assets</key><array>
      <dict>
        <key>kind</key><string>software-package</string>
        <key>url</key><string>https://example.com/Retronaut.ipa</string>
      </dict>
    </array>
    <key>metadata</key><dict>
      <key>bundle-identifier</key><string>YOUR.BUNDLE.ID</string>
      <key>bundle-version</key><string>1.0.0</string>
      <key>kind</key><string>software</string>
      <key>title</key><string>Retronaut</string>
    </dict>
  </dict></array>
</dict></plist>
```

Link the manifest as `itms-services://?action=download-manifest&url=https://…/manifest.plist`
and open it in **Safari** on the device. The `bundle-identifier` must match the
signed app exactly, and the profile must contain that device's UDID.

## Trusting the developer

After the first install: Settings → General → VPN & Device Management → your
Apple ID → **Trust**. Then launch.

## Removing

Delete the app like any other. Saves and imported packs live in the app's
Documents container and go with it.
