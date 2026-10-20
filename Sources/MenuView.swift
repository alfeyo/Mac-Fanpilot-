import SwiftUI
import AppKit

// MARK: - Palette

private func heatColor(_ fraction: Double) -> Color {
    switch fraction {
    case ..<0.6: .mint
    case ..<0.8: .orange
    default: .red
    }
}

private extension Mode {
    var symbol: String {
        switch self {
        case .normal: "leaf.fill"
        case .boost: "hare.fill"
        case .pro: "cpu.fill"
        case .max: "flame.fill"
        case .custom: "slider.horizontal.3"
        }
    }
    var tint: Color {
        switch self {
        case .normal: .blue
        case .boost: .teal
        case .pro: .indigo
        case .max: .orange
        case .custom: .purple
        }
    }
    var hint: String {
        switch self {
        case .normal: "Apple's default fan control. Quiet — fans stay off until the chip warms up."
        case .boost: "Fans at ~65%. Great for long exports or builds — less throttling."
        case .pro: "Fans follow CPU temperature on an aggressive curve, staying ahead of heat during sustained heavy work."
        case .max: "Full speed. Loud, but keeps the chip coolest under sustained load."
        case .custom: "Drag to choose a fixed fan speed."
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct RingGauge: View {
    let label: String
    let value: String
    let unit: String
    let fraction: Double
    let detail: String

    var body: some View {
        let color = heatColor(fraction)
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.02, min(fraction, 1)))
                    .stroke(AngularGradient(colors: [color.opacity(0.5), color], center: .center),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: fraction)
                VStack(spacing: -2) {
                    Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unit).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 62, height: 62)
            Text(label).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SpinningFan: View {
    let rpm: Double
    let color: Color
    var body: some View {
        TimelineView(.animation(paused: rpm < 1)) { ctx in
            // Visual speed only: ~1 turn/sec at 2400 RPM.
            let angle = ctx.date.timeIntervalSinceReferenceDate * rpm * 0.15
            Image(systemName: "fan.fill")
                .font(.system(size: 18))
                .foregroundStyle(rpm < 1 ? Color.secondary : color)
                .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: 30, height: 30)
        .background(Circle().fill((rpm < 1 ? Color.secondary : color).opacity(0.12)))
    }
}

private struct FanRow: View {
    let fan: Fan
    let name: String
    let tint: Color

    var body: some View {
        let fraction = fan.max > 0 ? min(fan.rpm / fan.max, 1) : 0
        HStack(spacing: 10) {
            SpinningFan(rpm: fan.rpm, color: tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(fan.rpm < 1 ? "Idle" : "\(Int(fan.rpm))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    if fan.rpm >= 1 { Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * fraction))
                            .animation(.easeOut(duration: 0.6), value: fraction)
                    }
                }
                .frame(height: 5)
            }
        }
    }
}

private struct ModeTile: View {
    let mode: Mode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.system(size: 15, weight: .semibold))
                Text(mode.rawValue).font(.system(size: 10.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(selected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [mode.tint.opacity(0.85), mode.tint], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.1 : 0.05)))
            )
            .shadow(color: selected ? mode.tint.opacity(0.35) : .clear, radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

// MARK: - Main panel

enum Tab: String, CaseIterable, Identifiable {
    case fans = "Fans", memory = "Memory", performance = "Performance"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .fans: "fan.fill"
        case .memory: "memorychip.fill"
        case .performance: "bolt.fill"
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: FanModel
    @ObservedObject var tools: ToolsModel
    @AppStorage("tab") private var tab: Tab = .fans

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let s = model.status {
                Card {
                    HStack(spacing: 0) {
                        RingGauge(label: "CPU", value: "\(Int(s.cpuAvg))", unit: "°C",
                                  fraction: s.cpuAvg / 105, detail: "peak \(Int(s.cpuMax))°")
                        RingGauge(label: "GPU", value: "\(Int(s.gpuAvg))", unit: "°C",
                                  fraction: s.gpuAvg / 105, detail: "peak \(Int(s.gpuMax))°")
                        if let m = model.memory {
                            RingGauge(label: "Memory", value: "\(Int((m.used / m.total * 100).rounded()))", unit: "%",
                                      fraction: m.used / m.total,
                                      detail: "\(gb(m.used)) of \(gb(m.total)) GB")
                        }
                    }
                }
            } else {
                Card {
                    HStack { ProgressView().controlSize(.small); Text("Reading sensors…").foregroundStyle(.secondary) }
                }
            }

            tabBar

            switch tab {
            case .fans: fansTab
            case .memory: memoryTab
            case .performance: performanceTab
            }

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.red)
            }

            footer
        }
        .padding(14)
        .frame(width: 330)
        .animation(.easeInOut(duration: 0.2), value: tab)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Label(t.rawValue, systemImage: t.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tab == t ? Color.primary.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Fans tab

    @ViewBuilder private var fansTab: some View {
        if let s = model.status {
                Card {
                    VStack(spacing: 12) {
                        if s.fans.isEmpty {
                            Text("This Mac has no fans.").foregroundStyle(.secondary)
                        }
                        ForEach(s.fans) { f in
                            FanRow(fan: f,
                                   name: s.fans.count == 2 ? (f.id == 0 ? "Left fan" : "Right fan") : "Fan \(f.id + 1)",
                                   tint: model.mode.tint)
                        }
                    }
                }
        }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Mode.allCases) { m in
                        ModeTile(mode: m, selected: model.mode == m) { model.apply(m) }
                    }
                }
                if model.mode == .custom {
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.customPercent, in: 0...100, step: 5) { editing in
                            if !editing { model.apply(.custom) }
                        }
                        .tint(Mode.custom.tint)
                        Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(model.rpm(forPercent: model.customPercent)))")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if model.mode == .pro {
                    proPanel.transition(.opacity.combined(with: .move(edge: .top)))
                }
                Text(model.mode.hint)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.mode != .normal {
                    Button { model.apply(.normal) } label: {
                        Label("Reset to normal fan settings", systemImage: "arrow.uturn.backward.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Mode.normal.tint)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.mode)

    }

    // MARK: Memory tab

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    if let m = model.memory {
                        HStack {
                            stat("Used", "\(gb(m.used)) GB")
                            stat("Free", "\(gb(m.free)) GB")
                            stat("Swap", "\(gb(m.swapUsed)) GB", warn: m.swapUsed > m.total * 0.25)
                        }
                    }
                    Button { tools.optimize() } label: {
                        HStack(spacing: 6) {
                            if tools.cleaning { ProgressView().controlSize(.small) }
                            else { Image(systemName: "sparkles") }
                            Text(tools.cleaning ? "Cleaning…" : "Free Up RAM")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [.green.opacity(0.8), .green], startPoint: .top, endPoint: .bottom)))
                    }
                    .buttonStyle(.plain)
                    .disabled(tools.cleaning)
                    if let r = tools.cleanResult {
                        Label(r, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(.green)
                    }
                }
            }

            Text("TOP MEMORY USERS")
                .font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            Card {
                VStack(spacing: 8) {
                    ForEach(tools.topApps) { a in
                        HStack(spacing: 8) {
                            Image(nsImage: a.icon).resizable().frame(width: 20, height: 20)
                            Text(a.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text("\(gb(a.bytes)) GB")
                                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(a.bytes > 2_147_483_648 ? .orange : .primary)
                            if a.app != nil {
                                Button { tools.quit(a) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Quit \(a.name)")
                            } else {
                                Color.clear.frame(width: 14, height: 1)
                            }
                        }
                    }
                }
            }
            Text("Quitting heavy apps is what really frees RAM. \"Free Up RAM\" flushes cached memory so new apps launch faster.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(warn ? .orange : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Performance tab

    private var performanceTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { tools.setTurbo(!tools.turbo) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(tools.turbo ? 0.25 : 0)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tools.turbo ? "Turbo is ON" : "Turbo")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(tools.turbo ? "Max sustained performance" : "Tap for maximum sustained performance")
                            .font(.system(size: 10.5)).opacity(0.8)
                    }
                    Spacer()
                }
                .padding(12)
                .foregroundStyle(tools.turbo ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tools.turbo
                          ? AnyShapeStyle(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.primary.opacity(0.05))))
                .shadow(color: tools.turbo ? .orange.opacity(0.4) : .clear, radius: 8, y: 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Card {
                VStack(spacing: 10) {
                    settingRow("Low Power Mode", "tortoise.fill",
                               detail: "Slows the CPU to save battery. Off = full speed.",
                               isOn: Binding(get: { tools.lowPowerMode }, set: { tools.setLowPowerMode($0) }))
                    Divider()
                    settingRow("Keep Mac awake", "cup.and.saucer.fill",
                               detail: "Prevents sleep during long renders and builds.",
                               isOn: $tools.keepAwake)
                }
            }

            Text("Apple Silicon can't be overclocked — clock speeds are locked by Apple. Turbo gets the most out of your chip by keeping Low Power Mode off, running the Pro fan curve so it never throttles, and preventing sleep.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingRow(_ title: String, _ symbol: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "fan.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 0) {
                Text("FanPilot").font(.system(size: 14, weight: .bold, design: .rounded))
                Text(Host.current().localizedName ?? "This Mac").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Text(model.mode.rawValue.uppercased())
                .font(.system(size: 9.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(model.mode.tint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(model.mode.tint.opacity(0.15)))
        }
    }

    private var proPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            proSlider(title: "Ramp up from", value: $model.proStart, range: 35...75)
            proSlider(title: "Full speed at", value: $model.proFull, range: max(model.proStart + 5, 60)...95)
            if let s = model.status {
                HStack {
                    Text("Hottest core \(Int(s.cpuMax))°C")
                    Spacer()
                    Text("Target \(Int(model.proRPM(for: s))) RPM").monospacedDigit()
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Mode.pro.tint)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Mode.pro.tint.opacity(0.08)))
    }

    private func proSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10.5)).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: 1) { editing in
                if !editing { model.apply(.pro) }
            }
            .tint(Mode.pro.tint)
            Text("\(Int(value.wrappedValue))°")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Label("Open FanPilot at login", systemImage: "power.circle")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Toggle("Open FanPilot at login",
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            footerButtons
        }
    }

    private var footerButtons: some View {
        HStack {
            if model.helperInstalled {
                Button { model.uninstallHelper() } label: {
                    Label("Uninstall helper", systemImage: "trash")
                }
                .help("Return fans to normal and remove the installed fan helper")
            }
            Spacer()
            Button {
                if model.mode != .normal { model.runPrivileged(["auto"]) }
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit and return fans to normal")
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func gb(_ bytes: Double) -> String {
        String(format: "%.1f", bytes / 1_073_741_824)
    }
}
