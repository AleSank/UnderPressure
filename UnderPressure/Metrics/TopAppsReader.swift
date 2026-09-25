import Darwin

/// An app (all its processes together) and what it uses.
struct AppUsage {
    let name: String
    /// CPU: share of the whole CPU (0…100, same scale as the menu's CPU row).
    /// Memory: footprint in bytes.
    let value: Double
}

/// Heaviest apps by CPU and by memory, via `proc_pid_rusage` — answers "who is it?"
/// when the icon turns amber.
///
/// Processes are grouped by app: the outermost `.app` bundle in the executable path of
/// the process or, failing that, of its nearest ancestor. So helpers count toward their
/// app (every "Google Chrome Helper" → Google Chrome), and command-line tools toward
/// the app that started them (a compiler run by Xcode → Xcode; a command typed in a
/// terminal → Terminal or the editor hosting it). Only processes with no app among their
/// ancestors (background daemons) keep their executable name.
///
/// Walks every pid (≈ 2 ms), so it runs only while the menu is open. Only the user's
/// own processes are readable without root; system daemons (`kernel_task`,
/// `WindowServer`, …) are skipped, which also keeps the list to things the user can
/// act on. CPU is a delta between two walks; the first walk only sets the baseline.
struct TopAppsReader {
    private struct Usage {
        let cpuTime: UInt64
        let footprint: UInt64
    }

    /// `ri_user_time`/`ri_system_time` are Mach time units (not ns on Apple Silicon).
    private let nanosPerTick: Double = {
        var timebase = mach_timebase_info()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    private let logicalCores = Double(sysconf(_SC_NPROCESSORS_ONLN))

    private var previous: [pid_t: UInt64] = [:]
    private var previousUptime: UInt64 = 0
    /// pid → app name, so paths are resolved once per process while the menu is open.
    private var appNames: [pid_t: String] = [:]

    /// Top `count` apps by CPU share (needs a previous walk) and the top app by memory.
    /// `hasCPUDelta` is false on the first walk, when CPU shares can't be computed yet.
    mutating func sample(count: Int) -> (cpu: [AppUsage], hasCPUDelta: Bool, memory: AppUsage?) {
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let capacity = Double(uptime &- previousUptime) * max(logicalCores, 1)
        let hasBaseline = !previous.isEmpty && capacity > 0

        var current: [pid_t: UInt64] = [:]
        var cpuByApp: [String: UInt64] = [:]
        var memoryByApp: [String: UInt64] = [:]
        var names: [pid_t: String] = [:]

        for pid in Self.allPIDs() {
            guard let usage = Self.usage(of: pid) else { continue }
            let app = appNames[pid] ?? Self.appName(of: pid)
            names[pid] = app
            current[pid] = usage.cpuTime
            if let before = previous[pid], usage.cpuTime >= before {
                cpuByApp[app, default: 0] += usage.cpuTime - before
            }
            memoryByApp[app, default: 0] += usage.footprint
        }

        previous = current
        previousUptime = uptime
        appNames = names

        let cpu = hasBaseline
            ? cpuByApp.sorted { $0.value > $1.value }.prefix(count).map {
                AppUsage(name: $0.key, value: Double($0.value) * nanosPerTick / capacity * 100)
            }
            : []
        let memory = memoryByApp.max { $0.value < $1.value }.map {
            AppUsage(name: $0.key, value: Double($0.value))
        }
        return (cpu, hasBaseline, memory)
    }

    /// Drops the per-pid tables while the menu is closed.
    mutating func reset() {
        previous = [:]
        appNames = [:]
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func usage(of pid: pid_t) -> Usage? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return Usage(cpuTime: info.ri_user_time &+ info.ri_system_time, footprint: info.ri_phys_footprint)
    }

    /// Ancestors checked for an app bundle (shell → terminal → app is usually 3–5 deep).
    private static let maxAncestorDepth = 12

    /// App bundle of the process or its nearest ancestor, else the executable name.
    private static func appName(of pid: pid_t) -> String {
        var current = pid
        for _ in 0..<maxAncestorDepth {
            if let bundle = executablePath(of: current).flatMap(bundleName(in:)) {
                return bundle
            }
            // launchd (1) and the kernel (0) end the chain: nothing above is an app.
            guard let parent = parent(of: current), parent > 1 else { break }
            current = parent
        }
        if let executable = executablePath(of: pid)?.split(separator: "/").last {
            return String(executable)
        }
        return processName(of: pid)
    }

    /// Outermost `.app` in a path: `/Applications/Xcode.app/…/clang.app/…` → `Xcode`.
    static func bundleName(in path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(".app".count)) }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Parent pid via `sysctl` `KERN_PROC_PID`, readable for every process (unlike
    /// `proc_pidinfo`), so chains through root-owned processes such as `login` work.
    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func processName(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
