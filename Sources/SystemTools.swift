import SwiftUI
import AppKit
import IOKit.pwr_mgt

struct AppMemory: Identifiable {
    let id: String          // bundle path
    let name: String
    let bytes: Double
    let icon: NSImage
    let app: NSRunningApplication?
}

/// RAM optimizer + performance controls. Privileged work goes through the FanPilot helper.
@MainActor
final class ToolsModel: ObservableObject {
    @Published var topApps: [AppMemory] = []
    @Published var cleaning = false
    @Published var cleanResult: String?
    @Published var lowPowerMode = false
    @Published var keepAwake = false { didSet { updateSleepAssertion() } }
    @Published var turbo = UserDefaults.standard.bool(forKey: "turbo")
    /// Whether the menu-bar panel is open; animations and polling stop when it isn't.
    @Published private(set) var panelVisible = false

    let fans: FanModel
    private var sleepAssertion: IOPMAssertionID = 0
    private var timer: Timer?

    init(fans: FanModel) {
        self.fans = fans
        lowPowerMode = Self.readLowPowerMode()
        if turbo {
            // Turbo survives restarts (fan mode is restored by FanModel). didSet doesn't fire inside
            // our own init, so create the sleep assertion explicitly.
            keepAwake = true
            updateSleepAssertion()
        }
    }

    /// Process lists and pmset are only polled while the panel is open.
    func setVisible(_ visible: Bool) {
        panelVisible = visible
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        topApps = Self.readTopApps()
        lowPowerMode = Self.readLowPowerMode()
    }

    // MARK: RAM optimizer

    /// Flushes inactive and cached memory with `purge`, then reports how much became free.
    func optimize() {
        guard !cleaning, fans.ensureHelper() else { return }
        cleaning = true
        cleanResult = nil
        let before = Memory.read()?.free ?? 0
        let helper = FanModel.helper
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: helper)
            p.arguments = ["purge"]
            try? p.run()
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            await MainActor.run {
                let freed = max((Memory.read()?.free ?? 0) - before, 0)   // purge moves cache into free pages
                self.cleanResult = ok
                    ? String(format: "Freed %.1f GB of cached memory", freed / 1_073_741_824)
                    : "Couldn't clean memory."
                self.cleaning = false
                self.fans.refresh()
                self.refresh()
            }
        }
    }

    func quit(_ app: AppMemory) {
        app.app?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// Sums resident memory per .app bundle so helper processes (e.g. browser tabs) count toward their app.
    static func readTopApps(limit: Int = 6) -> [AppMemory] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        var totals: [String: Double] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let kb = Double(trimmed[..<space]) else { continue }
            let path = String(trimmed[trimmed.index(after: space)...])
            guard let r = path.range(of: ".app/") else { continue }
            totals[String(path[..<r.lowerBound]) + ".app", default: 0] += kb * 1024
        }

        let running = NSWorkspace.shared.runningApplications
        let me = Bundle.main.bundlePath
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { path, bytes in
            AppMemory(id: path,
                      name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                      bytes: bytes,
                      icon: NSWorkspace.shared.icon(forFile: path),
                      app: path == me ? nil : running.first { $0.bundleURL?.path == path })
        }
    }

    // MARK: Performance

    static func readLowPowerMode() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").contains { $0.contains("lowpowermode") && $0.hasSuffix("1") }
    }

    @discardableResult
    func setLowPowerMode(_ on: Bool) -> Bool {
        let ok = fans.runPrivileged(["lowpower", on ? "1" : "0"], failure: "Couldn't change Low Power Mode.")
        lowPowerMode = Self.readLowPowerMode()
        return ok
    }

    /// Turbo = Low Power Mode off + Pro fan curve + no idle sleep.
    /// Turning it off restores the fan mode, Low Power Mode and keep-awake state from before.
    func setTurbo(_ on: Bool) {
        let d = UserDefaults.standard
        if on {
            let prevMode = fans.mode, prevLowPower = lowPowerMode, prevAwake = keepAwake
            if prevLowPower && !setLowPowerMode(false) { return }
            guard fans.apply(.pro) else {
                if prevLowPower { setLowPowerMode(true) }
                return
            }
            d.set(prevMode.rawValue, forKey: "modeBeforeTurbo")
            d.set(prevLowPower, forKey: "lowPowerBeforeTurbo")
            d.set(prevAwake, forKey: "awakeBeforeTurbo")
            keepAwake = true
        } else {
            let prev = Mode(rawValue: d.string(forKey: "modeBeforeTurbo") ?? "") ?? .normal
            fans.apply(prev)
            if d.bool(forKey: "lowPowerBeforeTurbo") { setLowPowerMode(true) }
            keepAwake = d.bool(forKey: "awakeBeforeTurbo")
        }
        turbo = on
        d.set(on, forKey: "turbo")
    }

    private func updateSleepAssertion() {
        if keepAwake, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "FanPilot keep awake" as CFString, &sleepAssertion)
        } else if !keepAwake, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
