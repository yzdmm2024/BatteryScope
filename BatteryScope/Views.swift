import SwiftUI

// MARK: - 颜色工具

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if h.count == 6 {
            let r = Double(Int(String(h.prefix(2)), radix: 16) ?? 0) / 255
            let g = Double(Int(String(h.dropFirst(2).prefix(2)), radix: 16) ?? 0) / 255
            let b = Double(Int(String(h.dropFirst(4).prefix(2)), radix: 16) ?? 0) / 255
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
            return
        }
        self.init(.sRGB, red: 0.9, green: 0.9, blue: 0.95, opacity: 1)
    }
}

// MARK: - 按压缩放交互

struct PressableScale: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 玻璃卡片（无描边、大圆角、微弱外阴影、背景模糊）

struct GlassCard<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = 24

    init(cornerRadius: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.30))
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 6)
    }
}

// MARK: - 根视图

struct ContentView: View {
    @EnvironmentObject var provider: BatteryDataProvider

    var body: some View {
        ZStack {
            backgroundGradient
            ScrollView {
                VStack(spacing: 18) {
                    HeaderCard()
                    ForEach(provider.hours) { hour in
                        HourCard(bucket: hour)
                    }
                    StatusCard()
                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 18)
            }
        }
        .ignoresSafeArea()
    }

    var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(hex: "#E9EEFA"), Color(hex: "#F5ECF6"), Color(hex: "#E8F4F0")],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - 顶部汇总卡片

struct HeaderCard: View {
    @EnvironmentObject var provider: BatteryDataProvider

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今日电量透视")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundColor(Color(hex: "#2B2F3A"))
                        Text("过去 24 小时 · \(provider.source.rawValue)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "#7A8090"))
                    }
                    Spacer()
                    BatteryRing(pct: provider.currentBatteryPct)
                }

                HStack(spacing: 14) {
                    Metric(label: "总掉电", value: String(format: "%.1f%%", provider.totalDrainPct))
                    Metric(label: "记录时段", value: "24h")
                    Metric(label: "活跃 App", value: "\(provider.topApps.count)")
                }

                if let bg = provider.biggestBackground {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color(hex: "#F0A04B"))
                        Text("后台耗电大户：\(bg.appName)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(hex: "#C0632A"))
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: "#FBE7D2").opacity(0.7)))
                }

                if !provider.topApps.isEmpty {
                    Text("耗电排行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#7A8090"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(provider.topApps.prefix(5).enumerated()), id: \.element.id) { i, app in
                                TopAppChip(rank: i + 1, app: app)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "#2B2F3A"))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "#8A90A0"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.35)))
    }
}

struct BatteryRing: View {
    let pct: Double
    var body: some View {
        let v = pct >= 0 ? pct : 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.5), lineWidth: 9)
            Circle().trim(from: 0, to: CGFloat(min(max(v, 0), 100) / 100))
                .stroke(
                    AngularGradient(colors: [Color(hex: "#7FD1AE"), Color(hex: "#6FA8FF")],
                                   center: .center),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(pct >= 0 ? "\(Int(v))%" : "—")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "#2B2F3A"))
        }
        .frame(width: 62, height: 62)
    }
}

struct TopAppChip: View {
    let rank: Int
    let app: AppEnergyEntry
    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(hex: "#6FA8FF").opacity(0.85)))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#2B2F3A"))
                Text(String(format: "%.0f", app.energyMAh))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#8A90A0"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.4)))
    }
}

// MARK: - 每小时卡片

struct HourCard: View {
    let bucket: HourBucket

    private var maxDrain: Double {
        bucket.minutes.map { $0.drainPct }.max() ?? 1
    }
    private var maxApp: Double {
        (bucket.apps.map { $0.energyMAh }.max() ?? 1)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(String(format: "%02d:00", bucket.hour))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(Color(hex: "#2B2F3A"))
                    Spacer()
                    Text(String(format: "掉电 %.2f%%", bucket.totalDrainPct))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(hex: "#7A8090"))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.4)))
                }

                // 60 分钟掉电热力条
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 3) {
                    ForEach(bucket.minutes) { m in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(minuteColor(m.drainPct))
                            .frame(height: 12)
                    }
                }
                HStack {
                    Text("每分钟掉电（亮度越高掉得越快）")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#9AA0B0"))
                    Spacer()
                }

                // 该小时各 App 耗电
                if bucket.apps.isEmpty {
                    Text("无 App 级数据（系统未记录该小时明细）")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#AAB0BE"))
                } else {
                    VStack(spacing: 9) {
                        ForEach(bucket.apps.sorted { $0.energyMAh > $1.energyMAh }) { app in
                            AppRow(app: app, maxEnergy: maxApp)
                        }
                    }
                }
            }
        }
    }

    func minuteColor(_ drain: Double) -> Color {
        if drain <= 0.0001 { return Color(hex: "#DDE3EE").opacity(0.55) }
        let t = min(drain / max(maxDrain, 0.05), 1)
        // 低 → 柔蓝，高 → 暖橙
        return Color(hex: "#FF9F6B").opacity(0.25 + 0.7 * t)
    }
}

struct AppRow: View {
    let app: AppEnergyEntry
    let maxEnergy: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(app.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "#2B2F3A"))
                    .lineLimit(1)
                if app.backgroundPct >= 0 && app.isBackgroundHeavy {
                    Text("后台")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: "#F0A04B")))
                } else if app.backgroundPct >= 0 {
                    Text(app.backgroundPct > 0.3 ? "含后台" : "前台")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#7A8090"))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.5)))
                }
                Spacer()
                Text(String(format: "%.0f", app.energyMAh))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "#2B2F3A"))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.35))
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(app.isBackgroundHeavy ? Color(hex: "#F0A04B") : Color(hex: "#6FA8FF"))
                        .frame(width: geo.size.width * CGFloat(min(app.energyMAh / max(maxEnergy, 1), 1)))
                }
                .frame(height: 9)
            }
            .frame(height: 9)
        }
    }
}

// MARK: - 状态 / 探测卡片

struct StatusCard: View {
    @EnvironmentObject var provider: BatteryDataProvider

    var body: some View {
        GlassCard(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(provider.statusMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(hex: "#5A6070"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                Button {
                    provider.refresh()
                    provider.recordSelfSample()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("重新读取")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(
                        LinearGradient(colors: [Color(hex: "#6FA8FF"), Color(hex: "#7FD1AE")],
                                       startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(PressableScale())

                DisclosureGroup("数据库探测明细（如读不到数据请截图发我）") {
                    ScrollView {
                        Text(provider.probeReport.isEmpty ? "（无）" : provider.probeReport)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "#8A90A0"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "#7A8090"))
            }
        }
    }
}
