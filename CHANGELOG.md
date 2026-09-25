# Changelog

## 1.1.0

- **Fan speed** in the menu, on Macs with fans: share of the maximum speed and actual RPM, or "Off" when the fans are stopped.
- **More accurate CPU temperature**: it now averages the CPU core sensors. On an M3 Pro, 1.0.0 read a power-management sensor that stays 15–20 °C cooler than the cores under load.
- **Temperatures on more Macs**: sensor tables for M1, M2, M3, M4 and M5 chips and Intel Macs. It adds, for example, the GPU sensors of M2 Macs, where 1.0.0 showed no GPU temperature. Chips newer than the tables still get a reading when possible.
- **Tidier menu**: fans right below CPU and GPU, percentages right-aligned in one column so rows don't shift as values change, and rows aligned with the menu items below.
- Automated, tested releases on GitHub.

## 1.0.0

First public release.

- Menu bar icon that fills like a liquid as your Mac comes under pressure: neutral when calm, amber to orange under sustained load or low memory, red when memory is critically short or macOS throttles for heat.
- Menu with CPU and GPU load and temperature, RAM used, and disk activity.
- The apps using the most CPU (35% or more), and the app using the most memory when memory runs low.
- Launch at Login, turned on at first launch and switchable from the menu.
- Update check: automatic once a day, or on demand with Check for Updates. A new version is announced with a notification and in the menu.
- Universal app for Apple Silicon and Intel Macs, macOS 14 Sonoma or later. Tested on Apple Silicon (M3 Pro).
