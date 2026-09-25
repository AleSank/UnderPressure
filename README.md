# UnderPressure

A tiny macOS menu bar app that shows, at a glance, how hard your Mac is working.

A single circle in the menu bar fills like a liquid as the system comes under pressure. When everything is fine it stays quiet and blends in with the other menu bar icons. When your Mac starts to struggle, the liquid rises, the waves start moving and the color shifts to amber, orange and finally red.

Click the icon for the details: CPU, GPU, memory and disk load, temperatures, and which apps are responsible.

## Reading the icon

| Icon | Meaning |
|------|---------|
| White or black (matches your menu bar), still | Normal: nothing to worry about |
| Amber to orange, gently moving waves | Working hard: sustained heavy load, or memory running low |
| Orange to red, fast choppy waves | Struggling: memory is critically short, or macOS is slowing the Mac down to cool it |

The level reacts within seconds. Short spikes don't change the color, but about half a minute of full load does, and the icon returns to normal a few seconds after the load ends.

UnderPressure measures how much your Mac is **struggling**, not just how busy it is:

- **Memory** counts the most. The icon turns amber as your apps fill the RAM (from about 83% used) and orange near 100%. It also reacts when macOS itself reports memory pressure, which can start earlier, and only then can it turn red: that's when you get beach balls and slowdowns.
- **Sustained CPU or GPU load** (a long build, a video export, a game) turns the icon amber, but never red: your Mac is working, not failing.
- **Heat** counts only when macOS actually throttles performance to cool down. The temperatures in the menu are there for information.
- **Disk activity** alone (backups, Spotlight indexing) barely moves the icon.

## The menu

```
CPU:    24% · 45°
GPU:     3% · 41°
Fans:   34% · 2317 rpm
RAM:    52%
Disk:    0%
```

- **CPU / GPU**: current load and average temperature of the CPU cores and of the GPU.
- **Fans**: speed as a share of the fans' maximum, then the actual speed (averaged over the fans). Only on Macs that have fans. On Apple Silicon the fans often stop when the Mac is cool: the row then reads **0% · Off**.
- **RAM**: memory used by your apps and the system, the same figure as "Memory Used" in Activity Monitor (files macOS merely caches are not counted). It turns orange from 90% or when macOS reports memory pressure, and red when that pressure is critical.
- **Disk**: how busy the system disk is (not how full it is).

UnderPressure starts automatically when you log in. You can turn this off with **Launch at Login** in the menu, or in System Settings → General → Login Items.

Extra rows appear only when there is something worth knowing:

- **Top apps**: apps using at least 35% of the whole CPU. Helper processes and command-line tools count toward the app that started them. For example, a compiler run by Xcode counts as Xcode.
- **Memory pressure**: shown when memory is high or critical, with the app using the most memory.
- **Thermal state**: shown when macOS is throttling because of heat.

## Install

1. Download `UnderPressure-<version>.zip` from the [latest release](https://github.com/AleSank/UnderPressure/releases/latest), unzip it and move **UnderPressure** to your Applications folder.
2. Open it. The first time, macOS blocks it, because the app isn't notarized by Apple (see below). Click **Done**, then go to **System Settings → Privacy & Security**, scroll down to the message about UnderPressure and click **Open Anyway**. You only need to do this once per version.
3. The icon appears in the menu bar. There is no window and no Dock icon.

Advanced users can skip step 2 with `xattr -dr com.apple.quarantine /Applications/UnderPressure.app`.

**Updates:** UnderPressure checks for new versions once a day, and you can check any time with **Check for Updates…** in the menu. When a new version is out, you get a notification (macOS asks for permission the first time) and the menu shows **Update Available**; both open the download page. Replace the app in Applications with the new one (and repeat step 2).

## Requirements and compatibility

- macOS 14 Sonoma or later.
- Universal app: runs natively on Apple Silicon and Intel Macs.
- Load, memory, disk and thermal state use public macOS interfaces and work on every supported Mac.
- Temperatures and fans come from hardware sensors whose names change with every chip. UnderPressure knows the sensors of M1, M2, M3, M4 and M5 chips and of Intel Macs, but it has been tested only on an M3 Pro. If a sensor isn't available on your Mac, its value shows as `—` and everything else keeps working. [Open an issue](https://github.com/AleSank/UnderPressure/issues) with your Mac model if that happens.

## Privacy

UnderPressure reads system statistics locally, on your Mac, and collects nothing. The list of top apps is read only while the menu is open.

Its only network access is the update check: about once a day, or when you choose Check for Updates, it asks the public GitHub API for the latest release of UnderPressure. The request contains no personal data (like any web request, GitHub sees your IP address), and the app never downloads or installs anything by itself.

## Why it isn't on the Mac App Store, and why macOS warns you

Temperatures on a Mac can only be read through private system interfaces, which aren't allowed in sandboxed App Store apps, so UnderPressure is distributed on GitHub. It is also not notarized: that requires a paid Apple Developer account. This is why macOS asks you to confirm the first time you open it. The full source code is here if you prefer to build it yourself.

## Building from source

Requires Xcode 16 or later.

```bash
git clone https://github.com/AleSank/UnderPressure.git
cd UnderPressure
xcodebuild -scheme UnderPressure -configuration Release \
  -derivedDataPath ./DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
open ./DerivedData/Build/Products/Release/UnderPressure.app
```

Or open `UnderPressure.xcodeproj` in Xcode and press ⌘R. The app lives only in the menu bar: it has no Dock icon and no main window.

To run the tests: `xcodebuild test -scheme UnderPressure -destination 'platform=macOS'`, or ⌘U in Xcode.

## Contributing

Architecture, measurement details and coding conventions are documented in [AGENTS.md](AGENTS.md).

## License

UnderPressure is released under the [MIT License](LICENSE).
