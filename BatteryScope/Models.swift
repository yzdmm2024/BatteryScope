import Foundation

/// 单个 App 在某个小时内的耗电记录。
struct AppEnergyEntry: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let bundleId: String?
    var energyMAh: Double        // 相对能耗（mAh 估算或系统原始值）
    var foregroundPct: Double    // 该 App 能耗中「前台」占比 0..1
    var backgroundPct: Double    // 该 App 能耗中「后台」占比 0..1

    var isBackgroundHeavy: Bool { backgroundPct >= 0.5 && energyMAh > 0 }
}

/// 某一分钟的设备掉电格子。
struct MinuteCell: Identifiable {
    let minute: Int             // 0..59
    var drainPct: Double        // 这一分钟整机电量下降百分比（>=0）
    var id: Int { minute }
}

/// 一小时的聚合桶：包含 60 个分钟格子 + 该小时各 App 的能耗。
struct HourBucket: Identifiable {
    let id: Int                 // = hour
    let hour: Int               // 0..23
    var deviceStartPct: Double?
    var deviceEndPct: Double?
    var minutes: [MinuteCell]
    var apps: [AppEnergyEntry]

    init(hour: Int) {
        self.hour = hour
        self.id = hour
        self.minutes = (0..<60).map { MinuteCell(minute: $0, drainPct: 0) }
        self.apps = []
    }

    /// 该小时总掉电百分比：优先用设备起止电量差，否则用分钟格子累加。
    var totalDrainPct: Double {
        if let s = deviceStartPct, let e = deviceEndPct {
            return max(0, s - e)
        }
        return minutes.reduce(0) { $0 + $1.drainPct }
    }

    /// 该小时内耗电最大的 App。
    var topApp: AppEnergyEntry? {
        apps.max(by: { $0.energyMAh < $1.energyMAh })
    }
}
