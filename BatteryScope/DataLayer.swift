import Foundation
import SQLite3

// MARK: - 极简 SQLite 读取器（使用系统 libsqlite3）

final class SQLiteDB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if sqlite3_open(path, &db) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    func tables() -> [String] {
        var out: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    func columns(of table: String) -> [String] {
        var out: [String] = []
        let sql = "PRAGMA table_info('\(table)');"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { out.append(String(cString: c)) }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    func query(_ sql: String) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                let count = sqlite3_column_count(stmt)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT:   row[name] = Double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT:
                        if let c = sqlite3_column_text(stmt, i) { row[name] = String(cString: c) }
                    default: break
                    }
                }
                rows.append(row)
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }
}

// MARK: - 数据源类型

enum DataSource: String {
    case system = "系统真实数据"
    case fallback = "设备级采样（降级）"
    case mixed = "混合"
}

// MARK: - 电池数据提供器

final class BatteryDataProvider: ObservableObject {
    @Published var hours: [HourBucket] = []
    @Published var source: DataSource = .fallback
    @Published var statusMessage: String = "正在读取…"
    @Published var probeReport: String = ""
    @Published var topApps: [AppEnergyEntry] = []
    @Published var biggestBackground: AppEnergyEntry? = nil
    @Published var totalDrainPct: Double = 0
    @Published var currentBatteryPct: Double = -1

    /// 系统电池数据库候选路径（与「设置→电池」同源）。
    private let dbCandidates = [
        "/private/var/mobile/Library/BatteryLife/BatteryLife.sqlite",
        "/private/var/mobile/Library/BatteryLife/BatteryLife.db",
        "/private/var/mobile/Library/BatteryLife/Powerlog/Powerlog.sqlite",
        "/private/var/mobile/Library/AggregateDictionary/ADDataStore.sqlitedb"
    ]

    // 已知表名（优先精确匹配，再退化为子串扫描）
    private let knownDeviceTables = [
        "PLBatteryAgent_EventBackward_BatteryUI",
        "PLBatteryAgent_EventBackward_Battery",
        "BatteryLevel", "Battery"
    ]
    private let knownAppTables = [
        "PLBLMAccountingService_Aggregate_BLMAppEnergyBreakdown",
        "PLAccountingOperator_Aggregate_RootNodeEnergy",
        "PLAppTimeService_Aggregate_AppRunTime",
        "AppEnergy", "ZLBatteryAppEnergy"
    ]

    func refresh() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        currentBatteryPct = Double(UIDevice.current.batteryLevel) * 100

        var buckets = (0..<24).map { HourBucket(hour: $0) }
        var foundSystem = false
        var report = ""

        for path in dbCandidates {
            guard let db = SQLiteDB(path: path) else { continue }
            let tables = db.tables()
            report += "▸ \(path)\n   表: \(tables.joined(separator: ", "))\n"
            if tables.isEmpty { continue }
            foundSystem = true

            // 1) 设备级每分钟掉电（真实）
            if let t = pickTable(tables, preferred: knownDeviceTables, contains: ["battery", "level"]) {
                report += "   选用设备表: \(t)\n"
                loadDeviceTimeline(db: db, table: t, into: &buckets)
            }
            // 2) 每 App 每小时耗电（真实）
            if let t = pickTable(tables, preferred: knownAppTables, contains: ["energy", "app"]) {
                report += "   选用 App 表: \(t)\n"
                loadAppEnergy(db: db, table: t, into: &buckets)
            }
        }

        if !foundSystem {
            source = .fallback
            report += "未找到可读的系统电池数据库。\n"
            applySelfSamples(into: &buckets)
        } else {
            source = .system
        }

        self.hours = buckets
        self.probeReport = report
        computeSummary()
        buildStatus()
    }

    // MARK: 设备级每分钟掉电

    private func loadDeviceTimeline(db: SQLiteDB, table: String, into buckets: inout [HourBucket]) {
        let cols = db.columns(of: table)
        let timeCol = cols.first(where: { $0.localizedCaseInsensitiveContains("timestamp") || $0.localizedCaseInsensitiveContains("time") })
                  ?? cols.first
        // 优先百分比列，其次电流/电量列
        let levelCol = cols.first(where: { $0.localizedCaseInsensitiveContains("ui") && $0.localizedCaseInsensitiveContains("level") })
                  ?? cols.first(where: { $0.localizedCaseInsensitiveContains("level") })
                  ?? cols.first(where: { $0.localizedCaseInsensitiveContains("percent") })
        guard let timeCol, let levelCol else { return }

        let rows = db.query("SELECT \"\(timeCol)\" AS t, \"\(levelCol)\" AS l FROM \"\(table)\" ORDER BY t ASC;")
        let now = Date().timeIntervalSince1970
        var last: (time: TimeInterval, level: Double)? = nil

        for r in rows {
            let tVal = (r["t"] as? Int).map({ Double($0) }) ?? (r["t"] as? Double) ?? 0
            let lVal = (r["l"] as? Double) ?? Double(r["l"] as? Int ?? 0)
            guard tVal > 0, lVal >= 0 else { continue }
            // 仅取最近 24 小时
            guard tVal > now - 86400 && tVal <= now + 60 else { continue }
            let level = normalizeLevel(lVal)
            if let prev = last {
                let dt = tVal - prev.time
                let dl = prev.level - level           // 掉电为正
                if dt > 0, dt < 3600, dl > 0 {
                    let perMin = dl / (dt / 60)
                    assignDrain(into: &buckets, at: tVal, drain: perMin)
                }
            }
            last = (tVal, level)
        }
    }

    /// 不同表电量单位不同（0..1 / 0..100 / mAh），统一归一到 0..100 百分比附近用于看趋势。
    private func normalizeLevel(_ v: Double) -> Double {
        if v >= 0, v <= 1.0001 { return v * 100 }
        if v > 1000 { return v }            // mAh 原始值（仅看趋势差）
        return v
    }

    private func assignDrain(into buckets: inout [HourBucket], at time: TimeInterval, drain: Double) {
        let d = Date(timeIntervalSince1970: time)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
        guard let h = comps.hour, let m = comps.minute, h >= 0, h < 24, m >= 0, m < 60 else { return }
        let clamped = min(max(drain, 0), 5)   // 单分钟掉电封顶 5%，过滤异常
        buckets[h].minutes[m].drainPct += clamped
    }

    // MARK: 每 App 每小时耗电

    private func loadAppEnergy(db: SQLiteDB, table: String, into buckets: inout [HourBucket]) {
        let cols = db.columns(of: table)
        let timeCol = cols.first(where: { $0.localizedCaseInsensitiveContains("timestamp") || $0.localizedCaseInsensitiveContains("time") }) ?? cols.first
        let nameCol = cols.first(where: { $0.localizedCaseInsensitiveContains("appname") || $0.localizedCaseInsensitiveContains("name") })
        let energyCol = cols.first(where: { $0.localizedCaseInsensitiveContains("energy") })
        let bgCol = cols.first(where: { $0.localizedCaseInsensitiveContains("background") })
        let fgCol = cols.first(where: { $0.localizedCaseInsensitiveContains("foreground") })
        guard let timeCol, let nameCol, let energyCol else { return }

        let sel = "SELECT \"\(timeCol)\" AS t, \"\(nameCol)\" AS n, \"\(energyCol)\" AS e"
            + (bgCol.map { ", \"\($0)\" AS b" } ?? "")
            + (fgCol.map { ", \"\($0)\" AS f" } ?? "")
            + " FROM \"\(table)\" ORDER BY t ASC;"
        let rows = db.query(sel)
        let now = Date().timeIntervalSince1970

        for r in rows {
            let tVal = (r["t"] as? Int).map({ Double($0) }) ?? (r["t"] as? Double) ?? 0
            guard let name = r["n"] as? String else { continue }
            let eVal = (r["e"] as? Double) ?? Double(r["e"] as? Int ?? 0)
            guard eVal > 0 else { continue }
            guard tVal > now - 86400, tVal <= now + 60 else { continue }
            let comps = Calendar.current.dateComponents([.hour], from: Date(timeIntervalSince1970: tVal))
            guard let h = comps.hour, h >= 0, h < 24 else { continue }
            let bg = (r["b"] as? Double) ?? (r["b"] as? Int).map(Double.init)
            let fg = (r["f"] as? Double) ?? (r["f"] as? Int).map(Double.init)
            var fgPct = -1.0, bgPct = -1.0
            if let bg, let fg, (bg + fg) > 0 {
                bgPct = bg / (bg + fg); fgPct = fg / (bg + fg)
            }
            var entry = AppEnergyEntry(appName: prettyAppName(name),
                                       bundleId: nil,
                                       energyMAh: eVal,
                                       foregroundPct: fgPct,
                                       backgroundPct: bgPct)
            // 合并同一小时同一 App
            if let idx = buckets[h].apps.firstIndex(where: { $0.appName == entry.appName }) {
                buckets[h].apps[idx].energyMAh += eVal
            } else {
                buckets[h].apps.append(entry)
            }
        }
    }

    private func prettyAppName(_ raw: String) -> String {
        // 系统进程常以 com.apple.xxx 形式出现，做简单可读化
        if raw.hasPrefix("com.apple.") { return String(raw.dropFirst("com.apple.".count)) }
        return raw
    }

    // MARK: 降级：App 自身采样

    private let sampleFile = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("battery_samples.json")

    func recordSelfSample() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let pct = Double(UIDevice.current.batteryLevel) * 100
        let now = Date().timeIntervalSince1970
        var samples = loadSelfSamples()
        samples.append(["t": now, "l": pct])
        // 仅保留最近 24h
        let cutoff = now - 86400
        samples = samples.filter { ($0["t"] as? Double ?? 0) > cutoff }
        try? JSONSerialization.data(withJSONObject: samples).write(to: sampleFile)
    }

    private func loadSelfSamples() -> [[String: Double]] {
        guard let data = try? Data(contentsOf: sampleFile),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return [] }
        return arr
    }

    private func applySelfSamples(into buckets: inout [HourBucket]) {
        let samples = loadSelfSamples().sorted { ($0["t"] ?? 0) < ($1["t"] ?? 0) }
        var last: (Double, Double)? = nil
        for s in samples {
            guard let t = s["t"], let l = s["l"] else { continue }
            if let prev = last {
                let dt = t - prev.0
                let dl = prev.1 - l
                if dt > 0, dt < 3600, dl > 0 {
                    assignDrain(into: &buckets, at: t, drain: dl / (dt / 60))
                }
            }
            last = (t, l)
        }
    }

    // MARK: 汇总

    private func computeSummary() {
        var allApps: [String: AppEnergyEntry] = [:]
        var total = 0.0
        for b in hours {
            total += b.totalDrainPct
            for a in b.apps {
                if var e = allApps[a.appName] {
                    e.energyMAh += a.energyMAh
                    allApps[a.appName] = e
                } else {
                    allApps[a.appName] = a
                }
            }
        }
        totalDrainPct = total
        topApps = allApps.values.sorted { $0.energyMAh > $1.energyMAh }.prefix(5).map { $0 }
        biggestBackground = allApps.values
            .filter { $0.backgroundPct > 0 && $0.foregroundPct >= 0 }
            .max(by: { ($0.backgroundPct * $0.energyMAh) < ($1.backgroundPct * $1.energyMAh) })
    }

    private func buildStatus() {
        if source == .fallback {
            statusMessage = "⚠️ 未读取到系统按 App 统计。可能原因：\n• TrollStore 未正确赋予「无沙盒」权限；\n• 你的设备未生成该数据库（iOS 16 路径可能不同）。\n已降级为设备级电量曲线。可在 GitHub 提 issue 把下方探测结果发我，我据此适配你的机型。"
        } else {
            statusMessage = "✅ 已读取系统电池数据库（与「设置→电池」同源）。\n注：iOS 仅按「每小时」聚合每个 App 的耗电，分钟级为整机真实掉电曲线。"
        }
    }

    // 工具：选表
    private func pickTable(_ tables: [String], preferred: [String], contains: [String]) -> String? {
        if let exact = tables.first(where: { preferred.contains($0) }) { return exact }
        return tables.first(where: { t in contains.contains(where: { t.localizedCaseInsensitiveContains($0) }) })
    }
}
