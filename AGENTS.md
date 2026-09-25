# AGENTS.md — UnderPressure

Guide for humans and coding agents maintaining this repo. Read it before changing code.

## What this is

UnderPressure is a macOS **menubar-only** system monitor (`LSUIElement`, no Dock icon). A single
18×18 pt circle glyph fills like a liquid with the Mac's **final hardware stress** (0–100%). Its
waves get faster and choppier, and its color moves from menubar white to amber, orange, then
red as stress rises. Clicking it opens an `NSMenu` showing live CPU % + temp, GPU % + temp,
on Macs with fans the fan speed, RAM used % and disk busy % (in that order). RAM and Disk intentionally show **percentage
only** (product decision).

- macOS 14+, universal binary (arm64 + x86_64), Swift 6 language mode.
- **Pure AppKit + Core Animation. No SwiftUI.** SwiftUI was removed on purpose to keep the
  resident footprint small (see [Performance rules](#performance-rules)). Do not add it back.
- App Sandbox is **off** because the temperature code uses private IOHID symbols and AppleSMC.
  That rules out the Mac App Store. Never claim otherwise.

## Build & run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme UnderPressure -configuration Release \
  -derivedDataPath ./DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
open ./DerivedData/Build/Products/Release/UnderPressure.app
```

- The build must have **zero warnings**. Swift 6 strict concurrency is on.
- Sources live in *file-system synchronized groups*: to add or remove a `.swift` file under
  `UnderPressure/` or `UnderPressureTests/`, just create or delete it. Do **not** edit
  `project.pbxproj` for that.
- **Tests** (Swift Testing, target `UnderPressureTests`, hosted by the app; the shared scheme
  runs them): `xcodebuild test -scheme UnderPressure -destination 'platform=macOS'` or ⌘U.
  Every change to the stress formula, the sustained average, the icon mapping or the glyph
  geometry must keep them green; add a case for new behavior. When hosted by tests the app
  skips its status item and login item (`XCTestConfigurationFilePath` check in `AppDelegate`).
  Reader tests run against the real hardware and accept `nil` where a sensor may be missing.
  Reference cases: all components at 50 → 50; CPU 100 sustained 100 → 70; CPU 100 with
  sustained 20 (a spike) → 35; same two cases for GPU → 70 / 35; disk 100 alone → 10; kernel
  pressure 60 → 60 and 90 → 90; RAM used 70% → 40, 83% → ≈ 53, 90% → 60, 100% → 85;
  thermal state serious → at least 75; critical → 100.

## Architecture

```
UnderPressureApp.swift          @main → NSApplication + AppDelegate, minimal main menu (⌘W/⌘Q)
LaunchAtLogin.swift        SMAppService.mainApp: on by default at first launch, menu toggle
UpdateChecker.swift        GitHub releases/latest check (launch + menu open ≤ 1 per 24 h, or on demand)
UpdateNotifier.swift       One macOS notification per new release (automatic checks only)
StatusItemController.swift NSStatusItem + NSMenu; forwards monitor.stress to the animator
LiquidIconAnimator.swift   Core Animation layer tree inside the status button (the icon)
UnderPressureIconRenderer.swift StressAppearance (stress → color/wave) + shared glyph geometry,
                           liquid path (also used by Tools/AppIcon for the app icon)
MenuCopy.swift             Row strings (fixed-width formats) + warning tones
AboutView.swift            AboutPanelController (NSPanel) + AboutView (NSStackView)
Metrics/
  UnderPressureMonitor.swift    Adaptive sampling clock (3.0 s / 1.5 s) → final stress
  UnderPressureScore.swift      Pure stress formula (weights, bottleneck, thermal override)
  SustainedAverage.swift   Time-weighted moving average (sustained CPU/GPU load), pure
  CPUReader.swift          host_statistics HOST_CPU_LOAD_INFO, tick deltas
  MemoryReader.swift       HOST_VM_INFO64 used % (Activity Monitor formula): menu + stress
  MemoryPressureReader.swift  Native kernel memory pressure (sysctl), banded, for the stress
  GPUReader.swift          IOAccelerator "PerformanceStatistics"
  DiskReader.swift         IOBlockStorageDriver "Statistics" busy time (disk0, else busiest)
  TemperatureReader.swift  CPU/GPU °C: IOHID core sensors → SMC keys per chip → fallbacks
  TemperatureKeys.swift    Chip detection + SMC temperature key tables (M1…M5, A18 Pro, Intel)
  FanReader.swift          Fan RPM and share of max (FNum, F<n>Ac, F<n>Mx), menu-only
  SMCClient.swift          AppleSMC user client (80-byte SMCKeyData struct, typed decoding)
  TopAppsReader.swift      Heaviest apps by CPU share and memory (proc_pid_rusage), menu-only
  IORegistry.swift         IOKit helpers + RescanGate (rate-limited rediscovery)
```

Data flow: `UnderPressureMonitor.tick()` (main run loop, `.common` mode) → readers →
`UnderPressureScore.finalStress` → `stress` → `onUpdate()` → `StatusItemController` calls
`LiquidIconAnimator.setStress` and refreshes the metric rows (only while the menu is open) →
the animator updates layer properties inside a 0.5 s `CATransaction`.

Everything runs on the main actor (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). What the
stress needs costs a few µs per tick once devices are cached (measured: CPU 1 µs, GPU 28 µs,
disk 11 µs, RAM used 1 µs, RAM pressure 2 µs), so a background queue isn't worth the extra complexity.
Display-only values are read **only while the menu is open** (`showsMenuDetails`):
temperatures ≈ 7–10 ms per read on an M3 Pro (≈ 25 ms the first time, while keys are
resolved), fans < 0.1 ms, the top-apps walk ≈ 0.8 ms. Types that must be touched from a `deinit` (e.g.
`IORegistry`) are marked `nonisolated`.

## Stress engine

`UnderPressureScore.finalStress`, all components on a 0–100 scale (missing = 0):

```
memory     = max(RAM used curve, kernel memory pressure)      // UnderPressureScore.memoryStress
base       = CPU × 0.35 + GPU × 0.35 + memory × 0.20 + Disk I/O × 0.10
saturation = max(sustained CPU × 0.7, sustained GPU × 0.7, memory)  // bottleneck
final      = max(base, saturation)
thermal state serious → final = max(final, 75);  critical → final = 100
```

Stress means the Mac is **struggling, not merely busy**. That drives every rule:

- `base` uses instant loads, so the fill level reacts on the next sample. CPU and GPU act as a
  bottleneck through their **sustained** load, so spikes of a few seconds don't color the icon
  but half a minute of full load does: Warning (amber) after ≈ 28 s, ≈ 70 at steady state
  (clearly amber/orange, never red: the Mac is working hard, not failing), back to Normal
  ≈ 9 s after the load stops. CPU and GPU are treated the same on purpose: a long export or
  a game loads the Mac as much as a build, and the icon should show it.
- Disk counts only in `base` (disk 100 alone → 10): its busy % saturates under ordinary queued
  I/O (backups, Spotlight) that users don't feel. A 1-minute load average was tried
  and dropped: it needed ≈ 2 min to reach Warning and lingered as long after, so the icon
  didn't reflect what was happening.
- Memory counts at full value, as the worse of two signals (**product decision**):
  - **RAM used** (what the user's apps hold; file cache excluded): 70% → 40 (still Normal),
    90% → 60 (Warning; amber from ≈ 83% with the icon hysteresis), 100% → 85 (orange). Little
    headroom is pressure the user should see, even if macOS still copes by compressing.
  - **Kernel memory pressure** (warning ≥ 60, critical ≥ 90 → red): catches swapping that
    starts before usage looks extreme. Only it can reach red.
- Heat uses `ProcessInfo.thermalState` (is macOS throttling?), a public API that works the same
  on every Mac. Fixed °C thresholds were dropped: Apple Silicon dies routinely run above 95 °C
  under load without throttling, and sensors differ per chip. Temperatures are display-only.

Signals:

- **CPU:** aggregate active ticks across all cores over the sampling interval.
- **Sustained CPU / GPU:** `SustainedAverage` of CPU % and GPU %, time constant 20 s, weighted
  by the real elapsed time (same result at 3.0 s and 1.5 s ticks).
- **GPU:** accelerator utilization; the max across GPUs (integrated + discrete).
- **RAM used:** Activity Monitor "Memory Used" / physical memory (see Metric sources); file
  cache and purgeable memory are excluded, so it is what the user's work holds.
- **Kernel memory pressure:** the kernel's native memory-pressure state. It comes from `kern.memorystatus_vm_pressure_level` (1 normal,
  2 warning, 4 critical), which selects the band: normal 0–40, warning 60–85, critical 90–100.
  The position inside the band comes from `kern.memorystatus_level` (% of memory the kernel
  considers available), the same data behind Activity Monitor's pressure graph. It is **not**
  in `VM_STATISTICS64`, so don't go looking there.
- **Disk I/O:** Δ(read+write total time ns) / Δ wall on the system disk, capped at 100.
  The counters sum each request's service time, so overlapping requests add up: this is the
  average number of requests in flight (Little's law), not true device busy time like Linux
  `iostat` `%util`, and it hits 100 under sustained queued I/O. macOS doesn't expose an SSD's
  maximum throughput, so bytes/s relative to a guessed maximum is deliberately **not** used.
  Storage space used plays no role.

**Adaptive polling:** 3.0 s when calm, 1.5 s when active (final stress ≥ 50 or a thermal
state above nominal). The timer is only rescheduled when the interval actually changes.
CPU and disk are delta-based, so their values average over whatever interval elapsed.

The menu RAM row shows **used %** (Activity Monitor's "Memory Used" / physical memory). Its
color and the "Memory pressure: high/critical · <app> n GB" row follow the same memory stress
as the icon: orange from 60 (RAM used ≥ 90% or kernel warning), red from 90 (kernel critical).

**Top apps (menu only):** while the menu is open, `TopAppsReader` walks every pid with
`proc_pid_rusage` (≈ 2 ms) on each tick, plus once 0.75 s after opening, since CPU needs two
walks. Processes are grouped by app: the outermost `.app` in the executable path of the process
or of its nearest ancestor (parent pids via `sysctl` `KERN_PROC_PID`, readable even through
root-owned processes like `login`). Helpers count toward their app, command-line tools toward
the app that started them (a compiler run by Xcode → Xcode, a command in a terminal → Terminal
or the editor hosting it). Only processes with no app ancestor (daemons) keep their executable
name. Apps are listed only from **35% of the whole CPU** (so at most 2): the list is for
"what is loading the system", not background noise. CPU is the **share of the whole CPU**,
the same scale as the CPU row, so listed apps never add up to more than it. CPU times are Mach
time units, converted with `mach_timebase_info` (125/3 on Apple Silicon). Without root only the
user's own processes are readable, so system daemons never appear. That's intended: it lists
things the user can act on. The tables are dropped on close. It does not affect stress.

## Icon (visual mapping)

| Final stress | State    | Color                            | Waves (speed rad/s, choppiness, amplitude ×) |
|--------------|----------|----------------------------------|----------------------------------------------|
| 0–50         | Normal   | menubar label color (white/black, like a template icon) | **still** (no loop), 0, 1.0 — calm, smooth |
| 50–80        | Warning  | amber → orange                   | ramps to 3.5, 0.6, 1.3                       |
| 80–100       | Critical | orange → solid red at 100        | ramps to 6.5, 1.0, 1.5                       |

- Fill level = final stress / 100. No bubbles or particles.
- `LiquidIconAnimator` owns the icon as a **Core Animation layer tree** in the status button:
  `liquidLayer` (masked by the circle) → `levelLayer` (y = surface) → `waveLayer` (periodic
  wave strip), plus `ringLayer`. The strip is one wavelength wider than the oval and loops
  forever by translating exactly one wavelength, so there's no seam.
- **Motion only above 50% (product decision, for energy):** in the Normal band the wave holds
  its phase and changes only through the per-sample easing. Above 50 it loops in **discrete
  12 fps steps** (`CAKeyframeAnimation`, `.discrete`). Stress changes smaller than 1.5 points
  (under half a Retina pixel) don't touch the layers at all.
- **Hysteresis at 50:** color and wave switch to Warning at ≥ 53 and back to Normal at ≤ 47,
  so stress hovering near 50 doesn't flicker or start/stop the loop. The fill level always
  follows the real stress. The 80 boundary is continuous (same color and speed on both sides)
  and needs none.
- **Decoupled from sampling:** on each sample, level, wave shape (amplitude/choppiness) and
  color change inside a 0.5 s ease-in-out `CATransaction`. The wave loop restarts at the new
  speed from its current on-screen phase (`timeOffset`), so there's no visible jump. It is only
  restarted if the speed changes by more than 5%.
- Normal state uses `NSColor.labelColor` resolved in the button's `effectiveAppearance`, and is
  re-resolved on appearance changes (light/dark menubar). Shape layers get `contentsScale` from
  the window's backing scale (otherwise they blur on Retina).
- The host view returns `nil` from `hitTest`, so clicks go to the status button.
- The system may draw its own rounded highlight behind the status button (e.g. on hover). That
  isn't part of our layers.

## Performance rules

This app runs all day, so every per-frame and per-tick cost matters. Measured history (Release,
3 minutes at rest, `ps cputime`):

| Version | CPU | Footprint |
|---|---|---|
| Original (HID client per tick, two timers, SwiftUI) | ~3.6% | grew 18 → 28 MB |
| Optimized 1 Hz sampling, static icon | ~1.5% | flat at 23 MB |
| Icon drawn by the app at 20 fps (rejected) | ~8.4% | flat at 23 MB |
| Core Animation loop, always on, smooth (rejected) | app ~0.15%, **WindowServer +19% of a core** | flat at 13 MB |
| Core Animation loop, always on, 12 fps discrete (rejected) | WindowServer +9% of a core | flat at 13 MB |
| Adaptive 3 s / 1.5 s, wave moves only above 50% | app ~0.12%, WindowServer ≈ no measurable change at rest | flat at 13 MB |
| **Current:** + temperatures / top apps read only while the menu is open | app ~0.03% (menu closed; `top` idle wake-ups 33 → 2) | flat at 13 MB |

Measure the WindowServer too, not just the app: menubar animation cost shows up there
(`ps -o cputime= -p $(pgrep -x WindowServer)` over 60–90 s, with vs. without the app).

1. **Never animate the icon from the app, and don't animate at rest.** Don't redraw an
   `NSImage` or call `setNeedsDisplay` on a frame timer. Continuous motion lives in Core
   Animation, only above 50% stress, in discrete 12 fps steps. The menubar ignores
   `preferredFrameRateRange`, and every visible change re-composites the menubar
   (≈ 0.75% of a core per fps). Touch layers only when a new sample arrives.
2. **One sampling timer.** Only `UnderPressureMonitor` schedules one. The UI subscribes via
   `onUpdate`. Keep `timer.tolerance` (lets macOS coalesce wake-ups) and `.common` mode (so it
   keeps firing while the menu is open).
3. **Discover once, read per tick.** IOKit services (accelerators, disk driver), the
   `IOHIDEventSystemClient` and its classified sensors, the working SMC key, and the sysctl
   MIBs are resolved once and cached. Rediscovery happens only when reads fail, and is
   rate-limited with `RescanGate` (30–60 s). **Never create an `IOHIDEventSystemClient` per
   sample**: it retains kernel resources and made the footprint grow.
4. **Read single properties.** Use `IORegistry.property(_:_:)` (`IORegistryEntryCreateCFProperty`)
   and cast to `NSDictionary`. Do not use `IORegistryEntryCreateCFProperties`: it copies the
   whole property table, and `as? [String: Any]` then bridges every entry.
5. **Menu-only work happens only while the menu is open** (`menuWillOpen` … `menuDidClose`):
   row updates, temperatures and the top-apps walk (`showsMenuDetails`). Never
   move a display-only reading back into the always-on tick; the CPU temperature alone would
   add ≈ 17 ms every 1.5–3 s.
6. **Release what's rarely used.** The About panel is released on close (`windowWillClose`).
7. **No SwiftUI / no Combine / no `@Observable`.** Nothing observes the monitor; a closure is
   enough.
8. **Balance IOKit ownership.** Every `io_object_t` returned by `IORegistry.services`/`children`
   is owned by the caller: release it, or store it and release it in `deinit`.

To check a change, launch the Release build and compare footprint and CPU over a few minutes:

```bash
pid=$(pgrep -n -x UnderPressure); footprint -p $pid | grep -m1 Footprint; ps -o rss=,cputime= -p $pid
```

Footprint must stay flat over time. A steady climb means a leak.

## Metric sources

| Signal | Source | Notes |
|---|---|---|
| CPU % | `HOST_CPU_LOAD_INFO` tick deltas | user+system+nice / total; first sample is `nil` |
| GPU % | IOAccelerator `PerformanceStatistics` | Key allowlist, then fuzzy "util/activity" scan; max across GPUs |
| RAM used % (menu + stress) | `HOST_VM_INFO64` | Activity Monitor "Memory Used": (internal − purgeable) + wired + compressor pages, × `host_page_size` |
| Sustained CPU / GPU (stress) | `SustainedAverage` of CPU % / GPU %, τ = 20 s | Bottleneck only; `base` uses instant loads |
| Kernel memory pressure (stress) | `sysctl` `kern.memorystatus_vm_pressure_level` + `kern.memorystatus_level` | Banded 0–40 / 60–85 / 90–100 |
| Thermal state (stress, tones) | `ProcessInfo.thermalState` | serious → ≥ 75, critical → 100 |
| Top apps (menu) | `proc_listallpids` + `proc_pid_rusage` v2 + `proc_pidpath` | User processes only, grouped by `.app` of the process or an ancestor; CPU as share of the whole CPU, memory as `ri_phys_footprint` |
| Disk % | `IOBlockStorageDriver` `Statistics` | Δ(read+write total time ns) / Δwall; cached `disk0` driver |
| CPU temp | IOHID `pACC`/`eACC MTR` (M1/M2) → SMC core keys for the chip (`TemperatureKeys`) → IOHID `PMU tdie…` | Average of plausible sensors (10–110 °C); Intel: first of `TCAD`, `TC0P`, `TC0D`… |
| GPU temp | IOHID `GPU MTR` (M1/M2) → SMC GPU keys for the chip → any `Tg…` key (newer chips) | Average of plausible sensors; Intel: `TG0D`, `TGDD` (AMD), `TG0P`, `TCGC` (Intel iGPU) |
| Fans (menu) | SMC `FNum`, `F<n>Ac` (actual), `F<n>Mx` (max) | `flt ` on Apple Silicon, `fpe2` on Intel; % = actual / max; row hidden without fans; 0 rpm → "Off" |

The last good CPU %, GPU %, disk %, and CPU/GPU temperature values are kept if a single read
returns `nil`.

## UI conventions

- The menu is plain AppKit `NSMenu`. Metric rows are **custom-view items** (disabled, fixed
  width, clipping, monospaced digits), so they never highlight and the menu width never
  changes while it's open. Only Check for Updates, Launch at Login (checkmark), About and Quit
  are real, selectable items. Metric rows are as tall as a standard menu item (measured once at
  runtime, since it varies by macOS version), with no spacer, so the gap above CPU equals the
  gap below Quit.
- Row order: CPU, GPU, Fan(s), RAM, Disk. The fan row exists only on Macs with fans (fanless
  MacBook Airs never show it). Labels: acronyms uppercase (`CPU`, `GPU`, `RAM`), words
  title-case (`Fans`, `Disk`).
- **Columns, not spaces** (settled with the owner on screen): rows are `label ⇥ value ⇥ detail`
  (`MenuCopy.columns`; top apps `⇥ percentage ⇥ app`), rendered with one shared paragraph
  style (`StatusItemController.rowStyle`): values **right-aligned** in a column that fits
  "100%" (6 pt after the widest label in `MenuCopy.columnLabels`), so a row never changes
  length as its value grows; details start **one space** after that column, so CPU, GPU and
  Fans read `7% · 45°` with equal space around the separator, and separators line up.
  Rejected: left-aligned values (separators land at different x), and a fixed detail column
  far from the value (the dot looks glued to the detail). Formats: `CPU/GPU ⇥ n% ⇥ · n°`,
  `Fans ⇥ n% ⇥ · n rpm` (share of max · actual, averaged; `Fan:` with one fan; `· Off` when
  stopped), `RAM/Disk ⇥ n%`. Add any new label to `columnLabels`.
- Metric text starts 28 pt in (`metricLeadingInset`), aligned with the titles of the real items
  below, which reserve a checkmark column (measured on screen).
- Below Disk, small secondary rows (`MenuCopy.DetailRow`) appear only when relevant, in this order:
  `Top apps (CPU)` followed by up to 2 rows `n%  <app>` (share of the whole CPU, same scale as
  the CPU row; only apps at 35% or more), `Memory pressure: high/critical ·
  <app> n GB`, `Thermal state: serious/critical (throttling)`, and the missing-sensors
  notice. They start hidden on each opening; once revealed they **stay until the menu
  closes** and keep updating (e.g. "Memory pressure: normal", an app dropping to 20%), so the
  menu never shrinks or jumps under the pointer. CPU/GPU rows turn orange/red with the thermal
  state (serious/critical), not at fixed °C; the RAM row with memory stress.
- Glyph geometry lives only in `UnderPressureIconRenderer` (`geometry(side:lineWidth:)`,
  `liquidPath(...)`), shared by the animated menubar layers and the app icon generator
  (`Tools/AppIcon`). It is defined at 18 pt and scaled uniformly; only the stroke can be
  overridden (the app icon uses 34 px at a 560 px glyph, since the scaled stroke reads too
  heavy), and the oval inset follows the stroke. Wave: amplitude 0.75 pt at reference size,
  wavelength 0.9 × oval width, and a 2nd harmonic for choppiness. It flattens near 0% and 100%.
- The About panel shows the **app icon** (`NSApp.applicationIconImage`, 64 pt), so there is one
  visual identity and no separate About drawing. It follows the system light/dark appearance
  and has a fixed 320×240 content size.

## Private API & hardware caveats

- IOHID temperature symbols (`IOHIDEventSystemClientCreate`, `IOHIDServiceClientCopyEvent`, …)
  are resolved with `dlsym`, so a missing symbol degrades to `nil` and never crashes.
  `IOHIDServiceClientCopyEvent`'s signature is `(service, int64 type, int32 options, int64 timestamp)`.
- SMC: 80-byte struct, selector 2; command 9 = key info, 5 = read bytes, 8 = key at index
  (`data32`); `#KEY` (`ui32`, big-endian) is the key count. `SMCClient.keys(withPrefix:)`
  enumerates all keys once (≈ 20–40 ms, cached) for the GPU discovery fallback. Decoded types:
  `flt ` (little-endian), `sp78`, `fpe2`, `ui8/16/32` (big-endian); `SMCClient.decode` is pure
  and unit tested. Temperatures outside 10…110 °C are treated as "not a sensor".
- **Temperature keys differ per chip generation, and no generic rule is safe.** On an M3 Pro
  some keys hold constants (`Tf16` = 77, `Tf12` = −11) and some `Tp…` keys fall under load, so a
  blind "hottest key with prefix X" picks garbage. That's why `TemperatureKeys` holds curated
  tables per chip (source: Stats, `Modules/Sensors/values.swift`, plus keys measured on an
  M3 Pro that rise under a full CPU load), and groups report the **average** of plausible keys.
  Chips newer than the tables get the union of all Apple Silicon tables, and the GPU a `Tg…`
  scan as last resort. HID `PMU tdie…` sensors are the power-manager die, ≈ 15–20 °C cooler
  than the cores under load: last resort only. When a new chip ships, add its keys (check
  them the same way: idle vs. 20 s of `yes` on every core).
- Every reader must return `nil` instead of trapping when hardware or keys are missing.
  The UI shows `—`.
- Verified on an M3 Pro (all readings, fans included). An M2 MacBook Air runs the app; its GPU
  temperature was missing before the per-chip tables (to confirm). Other chips and Intel /
  discrete-GPU Macs follow the public tables but are untested.

## Coding conventions

- Swift 6, main-actor by default, no force-unwraps except compile-time-constant URLs.
- Small `final class` readers own their cached IOKit state. Plain `struct`s are used when
  there's no resource to release (`CPUReader`, `MemoryReader`, `MemoryPressureReader`).
- `///` doc comments on types and non-obvious members explain the *why* (units, sources,
  trade-offs). Keep that density.
- Named `static let` constants for tunables (weights, thresholds, intervals, speeds, sizes).
  No magic numbers inline.
- Keep `README.md` user-facing and this file maintainer-facing. When behavior changes, update both.

## Updates and releases

- **Update check** (`UpdateChecker`): at launch, then when the menu opens if the last check is
  older than 24 h, and on demand from **Check for Updates…** (always answers with an alert:
  available → Download/Later, up to date, or failed). No timer (the notice is only visible in
  the menu anyway). One anonymous
  request to `api.github.com/repos/AleSank/UnderPressure/releases/latest` (drafts and
  pre-releases excluded); automatic checks are silent on failure. Once a newer version is
  found, the same menu item reads "Update Available: x.y.z…" and opens the release page.
- **Notification** (`UpdateNotifier`): when an *automatic* check finds a new release, one macOS
  notification per version (clicking it opens the release page). Notification permission is
  requested only then, never at launch; if declined, the menu item is the only sign. A manual
  check answers with an alert instead and marks that version as seen, so it is never
  announced twice (`lastAnnouncedUpdateVersion` in `UserDefaults`). The delegate is set at
  launch so clicks on earlier notifications still work. The app never downloads or installs anything itself. This is
  the app's **only** network access: keep it that way and keep README → Privacy accurate.
- **Versioning:** `MARKETING_VERSION` in the project is the single source (About shows it, the
  update check compares it). Release tags must be `v<MARKETING_VERSION>` (e.g. `v1.0.1`),
  numeric only: a tag the checker can't parse is ignored.
- **Distribution:** GitHub releases only, not notarized (no Developer ID yet). The build is
  ad-hoc signed with the hardened runtime. README → Install explains the first-open steps.
- **Making a release** (automated):
  1. `Tools/bump-version.sh 1.2.0` sets `MARKETING_VERSION` (app + tests), increments
     `CURRENT_PROJECT_VERSION` and adds a `## 1.2.0` section to `CHANGELOG.md`.
  2. Describe the changes in that section (the placeholder line makes the release fail).
  3. Commit, `git push origin main`, then `git tag v1.2.0 && git push origin v1.2.0` as a
     **separate** push. (For v1.1.0, pushing branch and tag together — in the push that first
     added the workflows — created no tag event and the release didn't start; re-pushing the
     tag fixed it.)
  4. `.github/workflows/release.yml` (runner `macos-26`, Xcode 26.x) checks the tag equals
     `v<MARKETING_VERSION>`, extracts the notes (`Tools/changelog-section.sh`), runs
     `Tools/make-release.sh` (tests, universal Release build, arch/version/signature checks,
     `dist/UnderPressure-<version>.zip`) and publishes the GitHub release with the zip.
  Run `Tools/make-release.sh` locally to check a release before tagging. `ci.yml` builds and
  tests every push to `main` and every pull request. CI uses Xcode 26 while development here
  uses Xcode 27: keep the project and Swift code buildable with the CI's Xcode.
  `build/` and `dist/` are git-ignored.

## Housekeeping

- `DerivedData/`, `xcuserdata/`, and `.DS_Store` are git-ignored (and untracked).
- Bundle ID `it.alesank.UnderPressure` (tests: `it.alesank.UnderPressureTests`). Don't change it
  after release: macOS keys preferences and the login item on it.
- `AppIcon` in the asset catalog is **generated**: edit `Tools/AppIcon/main.swift` (it reuses
  `UnderPressureIconRenderer`) and run `Tools/render-app-icon.sh`. Don't edit the PNGs by hand.
- Launch at Login is turned on once at first launch (`didEnableLaunchAtLoginByDefault` in
  `UserDefaults`); after that only the user changes it. `SMAppService` registers the bundle at
  its current path, so a copy run from `DerivedData` registers that copy.
- Category `public.app-category.utilities`; copyright and MIT license in `LICENSE`.
