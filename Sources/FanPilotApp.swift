import SwiftUI
import AppKit
import ServiceManagement

struct Fan: Identifiable {
    let id: Int
    let rpm, min, max, target: Double
    let manual: Bool
}

struct Status {
    let cpuAvg, cpuMax, gpuAvg, gpuMax: Double
    let fans: [Fan]
}

enum Mode: String, CaseIterable, Identifiable {
    case normal = "Normal", boost = "Boost", pro = "Pro", max = "Max", custom = "Custom"
    var id: String { rawValue }
}

/// Reads the SMC in-process. Temperature sensor keys are discovered once, since walking the
/// full key table costs thousands of IOKit calls.
final class Sensors {
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    init?() {
        guard smc_open() else { return nil }
        cpuKeys = Self.tempKeys("Tp")
        gpuKeys = Self.tempKeys("Tg")
    }

    private static func tempKeys(_ prefix: String) -> [String] {
        var buf = [CChar](repeating: 0, count: 256 * 5)
        let n = Int(smc_temp_keys(prefix, &buf, 256))
        return (0..<n).map { i in
            String(decoding: buf[i * 5 ..< i * 5 + 4].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private func temps(_ keys: [String]) -> (avg: Double, max: Double) {
        let values = keys.map { smc_read_double($0, -1) }.filter { $0 >= 10 && $0 <= 130 }
        guard !values.isEmpty else { return (0, 0) }
        return (values.reduce(0, +) / Double(values.count), values.max()!)
    }

    func read() -> Status {
        let cpu = temps(cpuKeys), gpu = temps(gpuKeys)
        let fans = (0..<Int(smc_read_double("FNum", 0))).map { i in
            Fan(id: i,
                rpm: smc_read_double("F\(i)Ac", 0),
                min: smc_read_double("F\(i)Mn", 0),
                max: smc_read_double("F\(i)Mx", 0),
                target: smc_read_double("F\(i)Tg", 0),
                manual: smc_read_double("F\(i)Md", 0) == 1)
        }
        return Status(cpuAvg: cpu.avg, cpuMax: cpu.max, gpuAvg: gpu.avg, gpuMax: gpu.max, fans: fans)
    }
}

struct Memory {
    let used, total, swapUsed: Double   // bytes
    /// Truly free pages only — used to measure what a purge released.
    let free: Double
    /// Free + reclaimable (inactive, speculative, purgeable) — what new apps can actually get.
    let available: Double

    static func read() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        // Same formula as Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let free = Double(stats.free_count) * page
        let reclaimable = (Double(stats.inactive_count) + Double(stats.speculative_count)
                           + Double(stats.purgeable_count)) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        return Memory(used: used, total: Double(ProcessInfo.processInfo.physicalMemory),
                      swapUsed: Double(swap.xsu_used), free: free, available: free + reclaimable)
    }
}

@MainActor
final class FanModel: ObservableObject {
    @Published var status: Status?
    @Published var memory: Memory?
    @Published var mode: Mode = .normal {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var customPercent: Double = UserDefaults.standard.object(forKey: "customPercent") as? Double ?? 50 {
        didSet { UserDefaults.standard.set(customPercent, forKey: "customPercent") }
    }
    /// Pro curve: fans sit at `proFloor`% below `proStart`°C and ramp linearly to 100% at `proFull`°C.
    @Published var proStart: Double = UserDefaults.standard.object(forKey: "proStart") as? Double ?? 50 {
        didSet { UserDefaults.standard.set(proStart, forKey: "proStart") }
    }
    @Published var proFull: Double = UserDefaults.standard.object(forKey: "proFull") as? Double ?? 80 {
        didSet { UserDefaults.standard.set(proFull, forKey: "proFull") }
    }
    let proFloor: Double = 30
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var error: String?
    private var lastProRPM: Double = 0
    /// When the chosen mode was last re-sent after macOS took the fans back; throttles retries.
    private var lastReassert = Date.distantPast

    private let sensors = Sensors()
    private let bundledFanctl = Bundle.main.url(forAuxiliaryExecutable: "fanctl")!.path
    /// Root-owned setuid copy, installed once with a single admin prompt.
    static let helperDir = "/usr/local/libexec/fanpilot"
    static let helper = helperDir + "/fanctl"
    /// Cached result of the (file-reading) helper check; reset whenever we install or remove it.
    private var helperCurrentCache: Bool?
    private var timer: Timer?
    private var sigterm: DispatchSourceSignal?

    init() {
        // Start at login by default (only on first run, so turning it off sticks).
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            setLaunchAtLogin(true)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // Hand the fans back to macOS however the app ends: Quit, logout, shutdown, or SIGTERM (pkill).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreSystemFans() }
        }
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    func refresh() {
        status = sensors?.read()
        memory = Memory.read()
        guard let s = status else { return }
        if !modeRestored { restoreMode(from: s); return }
        guard mode != .normal, helperIsCurrent else { return }

        // macOS takes the fans back after sleep; re-send the chosen mode, at most every 10 s.
        let reclaimed = s.fans.contains { !$0.manual }
        if mode == .pro {
            let target = proRPM(for: s)
            if abs(target - lastProRPM) >= 150 || (reclaimed && canReassert()) { setFans(target) }
        } else if reclaimed, canReassert() {
            sendFanCommand(for: mode)
        }
    }

    private func canReassert() -> Bool {
        guard Date().timeIntervalSince(lastReassert) >= 10 else { return false }
        lastReassert = Date()
        return true
    }

    private var modeRestored = false

    /// On launch: re-apply the last mode if the helper is installed (no password needed),
    /// otherwise just reflect whatever state the fans are in.
    private func restoreMode(from s: Status) {
        modeRestored = true
        let saved = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .normal
        if helperIsCurrent {
            apply(saved)
            return
        }
        guard let f = s.fans.first, f.manual, f.max > f.min else { mode = .normal; return }
        let pct = (f.target - f.min) / (f.max - f.min) * 100
        if pct >= 99 { mode = .max }
        else if abs(pct - 65) < 1 { mode = .boost }
        else { mode = .custom; customPercent = (pct / 5).rounded() * 5 }
    }

    /// User-initiated mode change. Returns whether the fans accepted it.
    @discardableResult
    func apply(_ newMode: Mode) -> Bool {
        error = nil
        let ok = sendFanCommand(for: newMode)
        if ok { mode = newMode }
        status = sensors?.read()
        return ok
    }

    /// Sends the fan command for a mode without touching `mode` or triggering a refresh.
    @discardableResult
    private func sendFanCommand(for m: Mode) -> Bool {
        switch m {
        case .normal: return runPrivileged(["auto"], failure: "Couldn't return fans to normal.")
        case .max: return runPrivileged(["set", "max"], failure: "Couldn't set fan speed.")
        case .boost: return runPrivileged(["set", "\(Int(rpm(forPercent: 65)))"], failure: "Couldn't set fan speed.")
        case .custom: return runPrivileged(["set", "\(Int(rpm(forPercent: customPercent)))"], failure: "Couldn't set fan speed.")
        case .pro:
            guard let s = status else { return false }
            return setFans(proRPM(for: s))
        }
    }

    /// Target RPM for Pro mode, driven by the hottest CPU core.
    func proRPM(for s: Status) -> Double {
        let span = max(proFull - proStart, 1)
        let t = min(max((s.cpuMax - proStart) / span, 0), 1)
        return rpm(forPercent: proFloor + (100 - proFloor) * t)
    }

    @discardableResult
    private func setFans(_ rpm: Double) -> Bool {
        lastProRPM = rpm
        return runPrivileged(["set", "\(Int(rpm))"], failure: "Couldn't set fan speed.")
    }

    /// Returns fans to Apple's control without changing the saved mode (restored on next launch).
    func restoreSystemFans() {
        if mode != .normal, helperIsCurrent { _ = run(Self.helper, ["auto"]) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Percent of the range between the slowest fan's min and max.
    func rpm(forPercent pct: Double) -> Double {
        guard let f = status?.fans.first else { return 0 }
        return f.min + (f.max - f.min) * pct / 100
    }

    var helperInstalled: Bool { helperIsCurrent }

    /// True when the installed helper is root-owned setuid and byte-identical to the bundled fanctl.
    private var helperIsCurrent: Bool {
        if let cached = helperCurrentCache { return cached }
        let fm = FileManager.default
        var current = false
        if let attrs = try? fm.attributesOfItem(atPath: Self.helper),
           (attrs[.ownerAccountID] as? Int) == 0,
           let perms = attrs[.posixPermissions] as? Int, perms & 0o4000 != 0,
           let installed = fm.contents(atPath: Self.helper),
           let bundled = fm.contents(atPath: bundledFanctl) {
            current = installed == bundled
        }
        helperCurrentCache = current
        return current
    }

    /// Makes sure the setuid helper is installed and current (prompts for a password only when it isn't).
    func ensureHelper() -> Bool {
        helperIsCurrent || installHelper()
    }

    /// Runs fanctl as root via the setuid helper, installing (or updating) it first if needed.
    /// Only sets `error` on failure, so background updates don't wipe out unrelated messages.
    @discardableResult
    func runPrivileged(_ args: [String], failure: String) -> Bool {
        guard ensureHelper() else { return false }
        let (code, _) = run(Self.helper, args)
        if code != 0 { error = "\(failure) (exit \(code))" }
        return code == 0
    }

    /// The only password prompt: copies fanctl to a root-owned dir and marks it setuid root.
    private func installHelper() -> Bool {
        let src = bundledFanctl.replacingOccurrences(of: "'", with: "'\\''")
        let sh = "mkdir -p \(Self.helperDir) && chown root:wheel \(Self.helperDir) && chmod 755 \(Self.helperDir) && " +
                 "cp '\(src)' \(Self.helper) && chown root:wheel \(Self.helper) && chmod 4755 \(Self.helper)"
        helperCurrentCache = nil
        return admin(sh) && helperIsCurrent
    }

    func uninstallHelper() {
        if admin("\(Self.helper) auto; rm -rf \(Self.helperDir)") { mode = .normal }
        helperCurrentCache = nil
    }

    private func admin(_ sh: String) -> Bool {
        let escaped = sh.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges " +
                                           "with prompt \"FanPilot needs your password once to install its fan helper.\"")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) != -128 {  // -128 = user cancelled
                error = err[NSAppleScript.errorMessage] as? String
            }
            return false
        }
        return true
    }

    private func run(_ path: String, _ args: [String]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}


@main
struct FanPilotApp: App {
    @StateObject private var model: FanModel
    @StateObject private var tools: ToolsModel

    init() {
        let fans = FanModel()
        _model = StateObject(wrappedValue: fans)
        _tools = StateObject(wrappedValue: ToolsModel(fans: fans))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, tools: tools)
        } label: {
            let t = model.status.map { "\(Int($0.cpuAvg))°" } ?? ""
            Label(t, systemImage: tools.turbo ? "bolt.fill" : model.mode == .normal ? "fan" : "fan.fill")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
