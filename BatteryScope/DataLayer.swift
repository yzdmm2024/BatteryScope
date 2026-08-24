import Foundation
import UIKit
import SQLite3
import Darwin

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
                    guard let namePtr = sqlite3_column_name(stmt, i) else { continue }
                    let name = String(cString: namePtr)
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

// MARK: - 设备档案（机型 / 电池容量 / 系统版本）

struct DeviceProfile {
    let modelName: String
    let modelIdentifier: String
    let batteryCapacityMAh: Double
    let systemVersion: String

    static var current: DeviceProfile {
        let identifier = machineModel()
        let version = UIDevice.current.systemVersion
        let (name, cap) = lookup(identifier)
        return DeviceProfile(modelName: name,
                             modelIdentifier: identifier,
                             batteryCapacityMAh: cap,
                             systemVersion: version)
    }

    /// 把百分比掉电换算为「估算 mAh」（基于设计容量）。
    func mAh(fromPct pct: Double) -> Double {
        max(0, batteryCapacityMAh * pct / 100.0)
    }

    private static func machineModel() -> String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    /// 已知机型 →（显示名, 设计容量 mAh）。重点覆盖 iPhone 12 Pro，其余给合理默认。
    private static func lookup(_ id: String) -> (String, Double) {
        let map: [String: (String, Double)] = [
            "iPhone13,3": ("iPhone 12 Pro", 2815),
            "iPhone13,2": ("iPhone 12", 2815),
            "iPhone13,4": ("iPhone 12 Pro Max", 3687),
            "iPhone13,1": ("iPhone 12 mini", 2227),
            "iPhone14,2": ("iPhone 13 Pro", 3095),
            "iPhone14,3": ("iPhone 13 Pro Max", 4352),
            "iPhone14,4": ("iPhone 13 mini", 2406),
            "iPhone14,5": ("iPhone 13", 3227),
            "iPhone15,2": ("iPhone 14 Pro", 3200),
            "iPhone15,3": ("iPhone 14 Pro Max", 4323)
        ]
        if let v = map[id] { return v }
        return (id, 3000)
    }
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
    @Published var jailbreakStatus: String = "检测中…"
    @Published var deviceProfile: DeviceProfile = DeviceProfile.current

    /// 系统电池数据库候选路径（iOS 16 真实路径优先）。
    private let dbCandidates = [
        "/private/var/mobile/Library/BatteryLife/BatteryLife.sqlite",        // iOS 13+ 设置→电池同源（CoreData: ZLBatteryAppEnergy）
        "/private/var/mobile/Library/BatteryLife/CurrentPowerlog.PLSQL",    // Powerlog 底层（PLAccountingOperator_* / PLBatteryAgent_*）
        "/private/var/mobile/Library/BatteryLife/Powerlog/CurrentPowerlog.PLSQL",
        "/private/var/mobile/Library/BatteryLife/Powerlog/Powerlog.sqlite",
        "/private/var/mobile/Library/AggregateDictionary/ADDataStore.sqlitedb"
    ]

    /// 已知表名（优先精确匹配，再退化为子串扫描）。
    private let knownDeviceTables = [
        "PLBatteryAgent_EventBackward_BatteryUI",   // 电量百分比，每 20s（Powerlog）
        "PLBatteryAgent_EventBackward_Battery",     // Rawlevel/mAh，每 20s（Powerlog）
        "BatteryLevel", "Battery"
    ]
    private let knownAppTables = [
        "ZLBatteryAppEnergy",                              // iOS 16 BatteryLife.sqlite 核心表
        "PLAccountingOperator_Aggregate_RootNodeEnergy",   // Powerlog 每 App 每硬件能耗（每小时）
        "PLBLMAccountingService_Aggregate_BLMAppEnergyBreakdown",
        "PLAppTimeService_Aggregate_AppRunTime",
        "AppEnergy"
    ]

    /// CoreData（Z 前缀）列优先匹配，用于精确解析 ZLBatteryAppEnergy。
    private let zAppNameCols = ["ZAPPNAME", "ZBUNDLEIDENTIFIER", "ZNAME"]
    private let zEnergyCols  = ["ZENERGY", "ZBATTERYENERGY", "ZPOWER", "ZENERGYCONSUMPTION"]
    private let zTimeCols    = ["ZTIMESTAMP", "ZDATE", "ZCREATIONDATE", "ZDAY", "ZTIME"]
    private let zBgCols      = ["ZBACKGROUND", "ZBACKGROUNDDURATION", "ZBACKGROUNDENERGY", "ZBACKGROUNDTIME"]
    private let zFgCols      = ["ZFOREGROUND", "ZFOREGROUNDDURATION", "ZFOREGROUNDENERGY", "ZFOREGROUNDTIME"]

    /// 跨数据源的全局 App 能耗聚合（用于无法按小时分桶时兜底）。
    private var globalAppEnergy: [String: (energy: Double, fg: Double, bg: Double)] = [:]

    // MARK: 越狱检测（Relaxin / RootHide 等无根越狱）

    var isJailbroken: Bool {
        let rootHideMarkers = ["/var/jb", "/.jbroot", "/private/var/jb"]
        for m in rootHideMarkers where FileManager.default.fileExists(atPath: m) { return true }
        let pkgManagers = [
            "/var/jb/Applications/Sileo.app",
            "/var/jb/Applications/Zebra.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app"
        ]
        for a in pkgManagers where FileManager.default.fileExists(atPath: a) { return true }
        return false
    }

    var jailbreakKind: String {
        if FileManager.default.fileExists(atPath: "/var/jb") ||
           FileManager.default.fileExists(atPath: "/.jbroot") ||
           FileManager.default.fileExists(atPath: "/private/var/jb") {
            return "RootHide / Relaxin"
        }
        if FileManager.default.fileExists(atPath: "/Applications/Sileo.app") ||
           FileManager.default.fileExists(atPath: "/var/jb/Applications/Sileo.app") {
            return "Sileo 环境"
        }
        return "未知 / 无"
    }

    // MARK: 主刷新

    func refresh() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        currentBatteryPct = Double(UIDevice.current.batteryLevel) * 100
        deviceProfile = DeviceProfile.current

        let jb = isJailbroken
        jailbreakStatus = jb
            ? "已越狱（\(jailbreakKind)）· 可读取系统电池库"
            : "未检测到越狱 · 重启后未重新越狱将降级为设备级采样"

        var buckets = (0..<24).map { HourBucket(hour: $0) }
        var foundSystem = false
        var report = ""
        globalAppEnergy.removeAll()

        for path in dbCandidates {
            guard let db = SQLiteDB(path: path) else { continue }
            let tables = db.tables()
            report += "▸ \(path)\n   表(\(tables.count)): \(tables.joined(separator: ", "))\n"
            if tables.isEmpty { continue }
            foundSystem = true

            // 1) iOS 16 设置→电池同源：ZLBatteryAppEnergy（含 App + 能耗 + 前后台）
            if tables.contains("ZLBatteryAppEnergy") {
                report += "   ✓ 命中 ZLBatteryAppEnergy 列: \(db.columns(of: "ZLBatteryAppEnergy").joined(separator: ", "))\n"
                loadAppEnergyZ(db: db, into: &buckets)
            }
            // 2) Powerlog 底层：每 App 每小时能耗（两步：Nodes → RootNodeEnergy）
            if tables.contains("PLAccountingOperator_Aggregate_RootNodeEnergy") {
                report += "   ✓ 命中 PLAccountingOperator_Aggregate_RootNodeEnergy\n"
                loadAppEnergyPowerlog(db: db, into: &buckets)
            }
            // 3) 设备级每分钟掉电（真实整机曲线）
            if let t = pickTable(tables, preferred: knownDeviceTables, contains: ["battery", "level"]) {
                report += "   选用设备表: \(t) 列: \(db.columns(of: t).joined(separator: ", "))\n"
                loadDeviceTimeline(db: db, table: t, into: &buckets)
            }
            // 4) 其余已知 App 表兜底（非专用表）
            for t in knownAppTables where tables.contains(t)
                && t != "ZLBatteryAppEnergy"
                && t != "PLAccountingOperator_Aggregate_RootNodeEnergy" {
                report += "   兜底 App 表: \(t)\n"
                loadAppEnergy(db: db, table: t, into: &buckets)
            }
        }

        dedupeApps(in: &buckets)
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

    // MARK: 列选择：先精确匹配 Z 前缀，再退化到包含匹配

    private func chooseCol(_ cols: [String], zPrefixed: [String], contains: [String]) -> String? {
        for p in zPrefixed where cols.contains(where: { $0.uppercased() == p.uppercased() }) {
            return cols.first(where: { $0.uppercased() == p.uppercased() })
        }
        for c in cols {
            let base = c.hasPrefix("Z") ? String(c.dropFirst()) : c
            if contains.contains(where: { base.localizedCaseInsensitiveContains($0) || c.localizedCaseInsensitiveContains($0) }) {
                return c
            }
        }
        return nil
    }

    // MARK: 设备级每分钟掉电

    private func loadDeviceTimeline(db: SQLiteDB, table: String, into buckets: inout [HourBucket]) {
        let cols = db.columns(of: table)
        let timeCol = chooseCol(cols, zPrefixed: ["TIMESTAMP", "TIME", "ZTIMESTAMP", "ZDATE"],
                                contains: ["timestamp", "time"])
                  ?? cols.first
        let levelCol = chooseCol(cols, zPrefixed: ["UI", "LEVEL", "RAWLEVEL", "PERCENTAGE"],
                                contains: ["ui", "level", "percent"])
                  ?? cols.first(where: { $0.localizedCaseInsensitiveContains("level") })
                  ?? cols.first
        guard let timeCol, let levelCol else { return }

        let rows = db.query("SELECT \"\(timeCol)\" AS t, \"\(levelCol)\" AS l FROM \"\(table)\" ORDER BY t ASC;")
        let now = Date().timeIntervalSince1970
        var last: (time: TimeInterval, level: Double)? = nil

        for r in rows {
            let tVal = valueAsDouble(r["t"])
            let lVal = valueAsDouble(r["l"])
            guard tVal > 0, lVal >= 0 else { continue }
            guard tVal > now - 86400 && tVal <= now + 60 else { continue }
            let level = normalizeLevel(lVal)
            if let prev = last {
                let dt = tVal - prev.time
                let dl = prev.level - level
                if dt > 0, dt < 3600, dl > 0 {
                    assignDrain(into: &buckets, at: tVal, drain: dl / (dt / 60))
                }
            }
            last = (tVal, level)
        }
    }

    private func normalizeLevel(_ v: Double) -> Double {
        if v >= 0, v <= 1.0001 { return v * 100 }
        if v > 1000 { return v }   // mAh 原始值（仅看趋势差）
        return v
    }

    private func assignDrain(into buckets: inout [HourBucket], at time: TimeInterval, drain: Double) {
        let d = Date(timeIntervalSince1970: time)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
        guard let h = comps.hour, let m = comps.minute, h >= 0, h < 24, m >= 0, m < 60 else { return }
        buckets[h].minutes[m].drainPct += min(max(drain, 0), 5)
    }

    // MARK: 每 App 每小时耗电 —— iOS 16 BatteryLife.sqlite (ZLBatteryAppEnergy)

    private func loadAppEnergyZ(db: SQLiteDB, into buckets: inout [HourBucket]) {
        let table = "ZLBatteryAppEnergy"
        let cols = db.columns(of: table)
        guard let nameCol = chooseCol(cols, zPrefixed: zAppNameCols, contains: ["appname", "name", "bundle"]),
              let energyCol = chooseCol(cols, zPrefixed: zEnergyCols, contains: ["energy", "power"]) else { return }
        let timeCol = chooseCol(cols, zPrefixed: zTimeCols, contains: ["timestamp", "time", "date", "day"])
        let bgCol = chooseCol(cols, zPrefixed: zBgCols, contains: ["background"])
        let fgCol = chooseCol(cols, zPrefixed: zFgCols, contains: ["foreground"])

        var sel = "SELECT \"\(nameCol)\" AS n, \"\(energyCol)\" AS e"
        if let t = timeCol { sel += ", \"\(t)\" AS t" }
        if let b = bgCol { sel += ", \"\(b)\" AS b" }
        if let f = fgCol { sel += ", \"\(f)\" AS f" }
        sel += " FROM \"\(table)\";"

        let rows = db.query(sel)
        let now = Date().timeIntervalSince1970

        for r in rows {
            guard let name = r["n"] as? String else { continue }
            let eVal = valueAsDouble(r["e"])
            guard eVal > 0 else { continue }
            let tVal = valueAsDouble(r["t"])
            let bg = (r["b"]).map(valueAsDouble)
            let fg = (r["f"]).map(valueAsDouble)
            var fgPct = -1.0, bgPct = -1.0
            if let bg, let fg, (bg + fg) > 0 { bgPct = bg / (bg + fg); fgPct = fg / (bg + fg) }
            let entry = AppEnergyEntry(appName: prettyAppName(name), bundleId: nil,
                                       energyMAh: eVal, foregroundPct: fgPct, backgroundPct: bgPct)

            if tVal > 1e9, tVal > now - 86400, tVal <= now + 60 {
                let h = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: tVal))
                mergeApp(into: &buckets[h].apps, entry: entry)
            } else {
                // 时间无法分桶（如 day index）：聚合到全局，UI 以「全天」展示。
                let g = globalAppEnergy[name] ?? (0, -1, -1)
                globalAppEnergy[name] = (g.energy + eVal, g.fg, g.bg)
            }
        }
    }

    // MARK: 每 App 每小时耗电 —— Powerlog (PLAccountingOperator_Aggregate_RootNodeEnergy)

    private func loadAppEnergyPowerlog(db: SQLiteDB, into buckets: inout [HourBucket]) {
        let nodeTable = "PLAccountingOperator_EventNone_Nodes"
        let eTable = "PLAccountingOperator_Aggregate_RootNodeEnergy"
        guard db.tables().contains(nodeTable), db.tables().contains(eTable) else { return }

        let ncols = db.columns(of: nodeTable)
        guard let nName = chooseCol(ncols, zPrefixed: [], contains: ["name"]),
              let nID = chooseCol(ncols, zPrefixed: [], contains: ["id"]) else { return }
        let nodes = db.query("SELECT \"\(nID)\" AS id, \"\(nName)\" AS nm FROM \"\(nodeTable)\";")
        var idToName: [Int: String] = [:]
        for r in nodes {
            let idv = Int(valueAsDouble(r["id"]))
            if let nm = r["nm"] as? String, idv >= 0 { idToName[idv] = nm }
        }

        let ecols = db.columns(of: eTable)
        guard let eTime = chooseCol(ecols, zPrefixed: [], contains: ["timestamp", "time"]),
              let eNode = chooseCol(ecols, zPrefixed: [], contains: ["nodeid", "node"]),
              let eEnergy = chooseCol(ecols, zPrefixed: [], contains: ["energy"]) else { return }
        let rows = db.query("SELECT \"\(eTime)\" AS t, \"\(eNode)\" AS nid, \"\(eEnergy)\" AS e FROM \"\(eTable)\";")
        let now = Date().timeIntervalSince1970

        for r in rows {
            let tVal = valueAsDouble(r["t"])
            guard tVal > now - 86400, tVal <= now + 60 else { continue }
            let nid = Int(valueAsDouble(r["nid"]))
            guard let name = idToName[nid] else { continue }
            let eVal = valueAsDouble(r["e"])
            guard eVal > 0 else { continue }
            let h = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: tVal))
            let entry = AppEnergyEntry(appName: prettyAppName(name), bundleId: nil,
                                       energyMAh: eVal, foregroundPct: -1, backgroundPct: -1)
            mergeApp(into: &buckets[h].apps, entry: entry)
        }
    }

    // MARK: 每 App 每小时耗电 —— 通用兜底（其他表名）

    private func loadAppEnergy(db: SQLiteDB, table: String, into buckets: inout [HourBucket]) {
        let cols = db.columns(of: table)
        let timeCol = chooseCol(cols, zPrefixed: [], contains: ["timestamp", "time"])
        let nameCol = chooseCol(cols, zPrefixed: [], contains: ["appname", "name", "bundle"])
        let energyCol = chooseCol(cols, zPrefixed: [], contains: ["energy", "power"])
        let bgCol = chooseCol(cols, zPrefixed: [], contains: ["background"])
        let fgCol = chooseCol(cols, zPrefixed: [], contains: ["foreground"])
        guard let timeCol, let nameCol, let energyCol else { return }

        let sel = "SELECT \"\(timeCol)\" AS t, \"\(nameCol)\" AS n, \"\(energyCol)\" AS e"
            + (bgCol.map { ", \"\($0)\" AS b" } ?? "")
            + (fgCol.map { ", \"\($0)\" AS f" } ?? "")
            + " FROM \"\(table)\" ORDER BY t ASC;"
        let rows = db.query(sel)
        let now = Date().timeIntervalSince1970

        for r in rows {
            guard let name = r["n"] as? String else { continue }
            let eVal = valueAsDouble(r["e"])
            guard eVal > 0 else { continue }
            let tVal = valueAsDouble(r["t"])
            guard tVal > now - 86400, tVal <= now + 60 else { continue }
            let bg = (r["b"]).map(valueAsDouble)
            let fg = (r["f"]).map(valueAsDouble)
            var fgPct = -1.0, bgPct = -1.0
            if let bg, let fg, (bg + fg) > 0 { bgPct = bg / (bg + fg); fgPct = fg / (bg + fg) }
            let entry = AppEnergyEntry(appName: prettyAppName(name), bundleId: nil,
                                       energyMAh: eVal, foregroundPct: fgPct, backgroundPct: bgPct)
            let h = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: tVal))
            mergeApp(into: &buckets[h].apps, entry: entry)
        }
    }

    /// 把某 App 的能耗合并进某小时的 apps 数组（同名累加，避免重复）。
    private func mergeApp(into apps: inout [AppEnergyEntry], entry: AppEnergyEntry) {
        if let idx = apps.firstIndex(where: { $0.appName == entry.appName }) {
            apps[idx].energyMAh += entry.energyMAh
            // 前后台占比：仅在两者都有有效值时做简单更新
            if entry.backgroundPct >= 0 && apps[idx].backgroundPct >= 0 {
                let total = apps[idx].energyMAh
                apps[idx].backgroundPct = (apps[idx].backgroundPct * (total - entry.energyMAh)
                                          + entry.backgroundPct * entry.energyMAh) / max(total, 1)
                apps[idx].foregroundPct = 1 - apps[idx].backgroundPct
            }
        } else {
            apps.append(entry)
        }
    }

    /// 每个小时桶内按 App 名称去重合并（多数据源写入时避免出现重复行）。
    private func dedupeApps(in buckets: inout [HourBucket]) {
        for i in buckets.indices {
            var seen: [String: Int] = [:]
            var merged: [AppEnergyEntry] = []
            for app in buckets[i].apps {
                if let idx = seen[app.appName] {
                    merged[idx].energyMAh += app.energyMAh
                    if app.backgroundPct >= 0 && merged[idx].backgroundPct >= 0 {
                        let total = merged[idx].energyMAh
                        merged[idx].backgroundPct = (merged[idx].backgroundPct * (total - app.energyMAh)
                                                    + app.backgroundPct * app.energyMAh) / max(total, 1)
                        merged[idx].foregroundPct = 1 - merged[idx].backgroundPct
                    }
                } else {
                    seen[app.appName] = merged.count
                    merged.append(app)
                }
            }
            buckets[i].apps = merged
        }
    }

    private func prettyAppName(_ raw: String) -> String {
        if raw.hasPrefix("com.apple.") { return String(raw.dropFirst("com.apple.".count)) }
        return raw
    }

    private func valueAsDouble(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        return 0
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
        // 合并无法分桶的全局 App 能耗
        for (name, g) in globalAppEnergy {
            let entry = AppEnergyEntry(appName: name, bundleId: nil,
                                       energyMAh: g.energy, foregroundPct: g.fg, backgroundPct: g.bg)
            if var e = allApps[name] { e.energyMAh += g.energy; allApps[name] = e }
            else { allApps[name] = entry }
        }
        totalDrainPct = total
        topApps = allApps.values.sorted { $0.energyMAh > $1.energyMAh }.prefix(5).map { $0 }
        biggestBackground = allApps.values
            .filter { $0.backgroundPct > 0 && $0.foregroundPct >= 0 }
            .max(by: { ($0.backgroundPct * $0.energyMAh) < ($1.backgroundPct * $1.energyMAh) })
    }

    private func buildStatus() {
        if source == .fallback {
            statusMessage = "⚠️ 未读取到系统按 App 统计。可能原因：\n• 越狱后未用 TrollStore 安装（或重启后未重新越狱，沙盒生效）；\n• 你的设备未生成该数据库（罕见）。\n已降级为设备级电量曲线。把下方「探测明细」截图发我，我按你机型适配表名。"
        } else if isJailbroken {
            statusMessage = "✅ 已读取系统电池数据库（与「设置→电池」同源）。\n越狱环境（\(jailbreakKind)）下权限充足，数据真实可靠。\n注：iOS 仅按「每小时」聚合每个 App 耗电，分钟级为整机真实掉电曲线。"
        } else {
            statusMessage = "✅ 已读取系统电池数据库（与「设置→电池」同源），但未检测到越狱。\n若重启后未重新越狱，下次可能读不到——届时需重新越狱或用 TrollStore 安装。"
        }
    }

    // 工具：选表
    private func pickTable(_ tables: [String], preferred: [String], contains: [String]) -> String? {
        if let exact = tables.first(where: { preferred.contains($0) }) { return exact }
        return tables.first(where: { t in contains.contains(where: { t.localizedCaseInsensitiveContains($0) }) })
    }
}
