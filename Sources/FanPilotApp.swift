import SwiftUI
import AppKit
import ServiceManagement

struct Fan: Decodable, Identifiable {
    let id: Int
    let rpm, min, max, target: Double
    let manual: Bool
}

struct Status: Decodable {
    let cpuAvg, cpuMax, gpuAvg, gpuMax: Double
    let fans: [Fan]
}

enum Mode: String, CaseIterable, Identifiable {
    case normal = "Normal", boost = "Boost", pro = "Pro", max = "Max", custom = "Custom"
    var id: String { rawValue }
}

struct Memory {
    let used, total, swapUsed: Double   // bytes

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

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        return Memory(used: used, total: Double(ProcessInfo.processInfo.physicalMemory), swapUsed: Double(swap.xsu_used))
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

    private let bundledFanctl = Bundle.main.url(forAuxiliaryExecutable: "fanctl")!.path
    /// Root-owned setuid copy, installed once with a single admin prompt.
    static let helperDir = "/usr/local/libexec/fanpilot"
    static let helper = helperDir + "/fanctl"
    private var timer: Timer?

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
    }

    func refresh() {
        let (_, data) = run(bundledFanctl, ["status"])
        status = try? JSONDecoder().decode(Status.self, from: data)
        memory = Memory.read()
        guard let s = status else { return }
        if !modeRestored { restoreMode(from: s); return }
        guard mode != .normal, helperIsCurrent else { return }
        if mode == .pro {
            let target = proRPM(for: s)
            if abs(target - lastProRPM) >= 150 { setFans(target) }
        } else if s.fans.contains(where: { !$0.manual }) {
            apply(mode)   // macOS took the fans back (e.g. after sleep) — reassert the chosen mode.
        }
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

    func apply(_ newMode: Mode) {
        let args: [String]
        switch newMode {
        case .normal: args = ["auto"]
        case .max: args = ["set", "max"]
        case .boost: args = ["set", "\(Int(rpm(forPercent: 65)))"]
        case .custom: args = ["set", "\(Int(rpm(forPercent: customPercent)))"]
        case .pro:
            guard let s = status else { return }
            lastProRPM = proRPM(for: s)
            args = ["set", "\(Int(lastProRPM))"]
        }
        if runPrivileged(args) { mode = newMode }
        refresh()
    }

    /// Target RPM for Pro mode, driven by the hottest CPU core.
    func proRPM(for s: Status) -> Double {
        let span = max(proFull - proStart, 1)
        let t = min(max((s.cpuMax - proStart) / span, 0), 1)
        return rpm(forPercent: proFloor + (100 - proFloor) * t)
    }

    private func setFans(_ rpm: Double) {
        lastProRPM = rpm
        runPrivileged(["set", "\(Int(rpm))"])
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
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
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.helper),
              (attrs[.ownerAccountID] as? Int) == 0,
              let perms = attrs[.posixPermissions] as? Int, perms & 0o4000 != 0,
              let installed = FileManager.default.contents(atPath: Self.helper),
              let bundled = FileManager.default.contents(atPath: bundledFanctl) else { return false }
        return installed == bundled
    }

    /// Runs fanctl as root via the setuid helper, installing (or updating) it first if needed.
    @discardableResult
    func runPrivileged(_ args: [String]) -> Bool {
        if !helperIsCurrent && !installHelper() { return false }
        let (code, _) = run(Self.helper, args)
        error = code == 0 ? nil : "Fan control failed (exit \(code))."
        return code == 0
    }

    /// The only password prompt: copies fanctl to a root-owned dir and marks it setuid root.
    private func installHelper() -> Bool {
        let src = bundledFanctl.replacingOccurrences(of: "'", with: "'\\''")
        let sh = "mkdir -p \(Self.helperDir) && chown root:wheel \(Self.helperDir) && chmod 755 \(Self.helperDir) && " +
                 "cp '\(src)' \(Self.helper) && chown root:wheel \(Self.helper) && chmod 4755 \(Self.helper)"
        return admin(sh)
    }

    func uninstallHelper() {
        if admin("\(Self.helper) auto; rm -rf \(Self.helperDir)") { mode = .normal }
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
        error = nil
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
    @StateObject private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            let t = model.status.map { "\(Int($0.cpuAvg))°" } ?? ""
            Label(t, systemImage: model.mode == .normal ? "fan" : "fan.fill")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
