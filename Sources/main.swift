// WattBar：在選單列即時顯示 MacBook 功耗的小工具
// 功能對照 PowerTop（github.com/kDolphin/PowerTop，MIT 授權），讀取的系統欄位參考自該專案。
// 資料來源：IOKit 的 AppleSmartBattery / AppleSmartBatteryBank / AppleSmartBatteryCell。
//
// 注意：這份程式刻意不用 @State、@Observable 等「巨集」，只用 property wrapper，
// 這樣只裝命令列工具（沒有完整 Xcode）也能編譯。

import SwiftUI
import AppKit
import IOKit
import ServiceManagement

// MARK: - IOKit 工具

private func properties(of service: io_service_t) -> [String: Any]? {
    var ref: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = ref?.takeRetainedValue() as? [String: Any] else { return nil }
    return dict
}

private func allServices(_ className: String) -> [[String: Any]] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
        return []
    }
    defer { IOObjectRelease(iterator) }
    var result: [[String: Any]] = []
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        if let p = properties(of: service) { result.append(p) }
        IOObjectRelease(service)
    }
    return result
}

// 有號數有時會被存成很大的無號整數，int64Value 會自動轉回負數
private func int(_ d: [String: Any]?, _ key: String) -> Int? {
    guard let n = d?[key] as? NSNumber else { return nil }
    return Int(n.int64Value)
}

private func bool(_ d: [String: Any]?, _ key: String) -> Bool? {
    (d?[key] as? NSNumber)?.boolValue
}

private func str(_ d: [String: Any]?, _ key: String) -> String? {
    d?[key] as? String
}

private func dict(_ d: [String: Any]?, _ key: String) -> [String: Any]? {
    d?[key] as? [String: Any]
}

private func intArray(_ d: [String: Any]?, _ key: String) -> [Int]? {
    (d?[key] as? [NSNumber])?.map { Int($0.int64Value) }
}

// MARK: - 電芯資料

struct CellCurrent: Identifiable {
    let bank: Int
    let cell: Int
    let mA: Int
    var id: String { "\(bank)-\(cell)" }
}

struct CellTelemetry {
    var series: Int
    var parallel: Int
    var parallelKnown: Bool
    var perCellArrays: Bool
    var voltagesMV: [Int]
    var qmaxMAH: [Int]
    var currents: [CellCurrent]
}

private func readCells(packBatteryData: [String: Any]?) -> CellTelemetry? {
    // Apple Silicon：每一組串聯是一個 bank 節點
    let banks = allServices("AppleSmartBatteryBank").compactMap { p -> (id: Int, v: Int, q: Int)? in
        let bd = dict(p, "BatteryData")
        guard let v = int(bd, "CellVoltage"), let q = int(bd, "Qmax") else { return nil }
        return (int(p, "BankID") ?? 0, v, q)
    }.sorted { $0.id < $1.id }

    if !banks.isEmpty {
        var currents: [CellCurrent] = []
        var slots: [Int: Int] = [:]
        for p in allServices("AppleSmartBatteryCell") {
            guard let b = int(p, "BankID"), let c = int(p, "CellID") else { continue }
            slots[b, default: 0] += 1
            if let mA = int(dict(p, "CellData"), "CellCurrent") {
                currents.append(CellCurrent(bank: b, cell: c, mA: mA))
            }
        }
        currents.sort { $0.bank == $1.bank ? $0.cell < $1.cell : $0.bank < $1.bank }
        let parallel = slots.values.max() ?? 1
        return CellTelemetry(series: banks.count, parallel: parallel, parallelKnown: !slots.isEmpty,
                             perCellArrays: false,
                             voltagesMV: banks.map(\.v), qmaxMAH: banks.map(\.q), currents: currents)
    }

    // 舊機型：整包電池直接給每顆電芯的陣列
    if let v = intArray(packBatteryData, "CellVoltage"), let q = intArray(packBatteryData, "Qmax"),
       !v.isEmpty, v.count == q.count {
        return CellTelemetry(series: v.count, parallel: 1, parallelKnown: false, perCellArrays: true,
                             voltagesMV: v, qmaxMAH: q, currents: [])
    }
    return nil
}

// MARK: - 製造日期
// 新款 Apple Silicon 電池把日期存成 6 個倒序的 ASCII 數字 YYMMDD，YY 是從 1992 年起算

private func decodeManufactureDate(_ encoded: Int) -> String? {
    guard encoded > 0 else { return nil }
    let raw = UInt64(encoded)
    guard raw <= 0xFFFF_FFFF_FFFF else { return nil }
    func digit(_ shift: UInt64) -> Int? {
        let b = UInt8((raw >> shift) & 0xFF)
        return (48...57).contains(b) ? Int(b) - 48 : nil
    }
    guard let y1 = digit(0), let y2 = digit(8), let m1 = digit(16),
          let m2 = digit(24), let d1 = digit(32), let d2 = digit(40) else { return nil }
    let year = 1992 + y1 * 10 + y2, month = m1 * 10 + m2, day = d1 * 10 + d2
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    let cal = Calendar(identifier: .gregorian)
    guard let date = cal.date(from: comps), date <= Date() else { return nil }
    let check = cal.dateComponents([.year, .month, .day], from: date)
    guard check.year == year, check.month == month, check.day == day else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
}

private func readManufactureDate(_ props: [String: Any]) -> String? {
    func parse(_ p: [String: Any]?) -> String? {
        guard let v = int(p, "ManufactureDate") ?? int(dict(p, "BatteryData"), "ManufactureDate") else { return nil }
        return decodeManufactureDate(v)
    }
    return parse(props) ?? parse(allServices("AppleSmartBatteryPack").first)
}

// MARK: - 充電上限（macOS 設定、AlDente、最佳化充電）

enum LimitSource {
    case none, macOS, optimized, alDente

    var label: String? {
        switch self {
        case .none: return nil
        case .macOS: return "macOS 設定"
        case .optimized: return "最佳化電池充電"
        case .alDente: return "AlDente"
        }
    }
}

private func prefNumber(_ domain: String, _ key: String) -> Int? {
    if let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber {
        return Int(v.doubleValue.rounded())
    }
    let path = NSHomeDirectory() + "/Library/Preferences/\(domain).plist"
    if let d = NSDictionary(contentsOfFile: path) as? [String: Any], let v = d[key] as? NSNumber {
        return Int(v.doubleValue.rounded())
    }
    return nil
}

private func validLimit(_ v: Int?) -> Int? {
    guard let v, (1..<100).contains(v) else { return nil }
    return v
}

private func resolveChargeLimit(dailyMaxSoc: Int?, notChargingReason: Int?) -> (Int, LimitSource) {
    var found: [(Int, LimitSource)] = []

    let mac = "com.apple.batteryui.charging.mac"
    for key in ["com.apple.batteryui.charging.mac.limit", "com.apple.batteryui.charging.mac.prior.limit", "limit"] {
        if let v = validLimit(prefNumber(mac, key)) { found.append((v, .macOS)); break }
    }

    let pro = "com.apphousekitchen.aldente-pro"
    let proUsesNative = (prefNumber(pro, "useTahoeNativeLimit") ?? 0) != 0
    if !proUsesNative, let v = validLimit(prefNumber(pro, "chargeVal")) {
        found.append((v, .alDente))
    } else if let v = validLimit(prefNumber("com.davidwernhart.AlDente", "chargeVal")) {
        found.append((v, .alDente))
    }

    if let strictest = found.min(by: { $0.0 < $1.0 }) { return strictest }

    // 最佳化充電暫停中，才採用 DailyMaxSoc
    if let r = notChargingReason, r & 0x0100_0000 != 0, let v = validLimit(dailyMaxSoc) {
        return (v, .optimized)
    }
    return (100, .none)
}

private func notChargingText(_ reason: Int?) -> String? {
    guard let r = reason, r != 0 else { return nil }
    if r & 0x0100_0000 != 0 { return "最佳化電池充電" }
    if r & 0x02 != 0 { return "溫度過高" }
    if r & 0x01 != 0 { return "電池已充飽" }
    if r & 0x04 != 0 { return "電池異常" }
    if r & 0x80 != 0 { return "充電器功率不足" }
    return String(format: "代碼 %d（0x%X）", r, r)
}

// MARK: - 原始讀數

struct Snapshot {
    var hasBattery = false
    var external = false
    var isCharging = false
    var fullyCharged = false
    var percent = 0
    var soc: Int?

    var voltageMV: Int?
    var amperageMA: Int?
    var instantAmperageMA: Int?

    var cycles: Int?
    var designCycles: Int?
    var designCap: Int?
    var rawMaxCap: Int?
    var nominalCap: Int?
    var fullChargeCap: Int?
    var remainingCap: Int?
    var dailyMinSoc: Int?
    var dailyMaxSoc: Int?
    var tempC: Double?

    var adapterWatts: Int?
    var adapterName: String?
    var chargingVoltageMV: Int?
    var chargingCurrentMA: Int?
    var notChargingReason: Int?
    var vacVoltageLimitMV: Int?

    var avgTimeToEmpty: Int?
    var avgTimeToFull: Int?

    // Apple Silicon 功耗遙測
    var hasTelemetry = false
    var systemLoadW = 0.0
    var systemPowerInW = 0.0
    var telemetryBatteryW = 0.0
    var wallW: Double?
    var adapterLossW: Double?
    var systemInVoltageMV: Int?
    var systemInCurrentMA: Int?
    var avgSystemW: Double?

    var cells: CellTelemetry?

    // 生命週期
    var operatingMinutes: Int?
    var ltMaxTemp: Int?
    var ltMinTemp: Int?
    var ltAvgTemp: Int?
    var ltMaxVoltageMV: Int?
    var ltMinVoltageMV: Int?
    var ltMaxChargeMA: Int?
    var ltMaxDischargeMA: Int?
    var cellDisconnectCount: Int?

    // 裝置資訊與狀態
    var serial: String?
    var chipName: String?
    var manufactureDate: String?
    var critical: Bool?
    var permanentFailure: Int?

    var chargeLimit = 100
    var limitSource = LimitSource.none

    var healthPercent: Int? {
        guard let design = designCap, design > 0,
              let cur = rawMaxCap ?? fullChargeCap ?? nominalCap, cur > 0 else { return nil }
        return min(100, cur * 100 / design)
    }

    // 不分正負號的電池功率，方向交給狀態判斷
    var batteryMagnitudeW: Double {
        if hasTelemetry, abs(telemetryBatteryW) > 0.05 { return abs(telemetryBatteryW) }
        guard let v = voltageMV, let a = amperageMA else { return 0 }
        return abs(Double(v) * Double(a) / 1_000_000)
    }
}

enum Reader {
    static func read() -> Snapshot {
        var s = Snapshot()
        guard let p = allServices("AppleSmartBattery").first else { return s }
        let bd = dict(p, "BatteryData")
        let bank = allServices("AppleSmartBatteryBank").compactMap { dict($0, "BatteryData") }.first

        func packOrBD(_ k: String) -> Int? { int(p, k) ?? int(bd, k) }

        s.hasBattery = bool(p, "BatteryInstalled") ?? true
        s.external = bool(p, "ExternalConnected") ?? false
        s.isCharging = bool(p, "IsCharging") ?? false
        s.fullyCharged = bool(p, "FullyCharged") ?? false
        if let cur = int(p, "CurrentCapacity"), let mx = int(p, "MaxCapacity"), mx > 0 {
            s.percent = cur * 100 / mx
        }
        s.soc = int(bd, "StateOfCharge") ?? int(p, "StateOfCharge") ?? int(bank, "StateOfCharge")

        s.voltageMV = int(p, "Voltage")
        s.amperageMA = int(p, "Amperage")
        s.instantAmperageMA = int(p, "InstantAmperage")

        s.cycles = int(p, "CycleCount")
        s.designCycles = int(p, "DesignCycleCount9C") ?? int(p, "DesignCycleCount70")
        s.designCap = packOrBD("DesignCapacity")
        s.rawMaxCap = packOrBD("AppleRawMaxCapacity") ?? int(bank, "AppleRawMaxCapacity")
        s.nominalCap = packOrBD("NominalChargeCapacity")
        s.fullChargeCap = int(bd, "FullChargeCapacity") ?? int(p, "FullChargeCapacity")
        s.remainingCap = int(bd, "RemainingCapacity") ?? int(p, "RemainingCapacity")
        s.dailyMinSoc = int(bd, "DailyMinSoc") ?? int(p, "DailyMinSoc") ?? int(bank, "DailyMinSoc")
        s.dailyMaxSoc = int(bd, "DailyMaxSoc") ?? int(p, "DailyMaxSoc") ?? int(bank, "DailyMaxSoc")
        if let t = packOrBD("Temperature") ?? int(bank, "Temperature") { s.tempC = Double(t) / 100 }

        let adapter = dict(p, "AdapterDetails")
        if let w = int(adapter, "Watts"), w > 0 { s.adapterWatts = w }
        s.adapterName = str(adapter, "Description") ?? str(adapter, "Name")

        let charger = dict(p, "ChargerData")
        s.chargingVoltageMV = int(charger, "ChargingVoltage")
        s.chargingCurrentMA = int(charger, "ChargingCurrent")
        s.notChargingReason = int(charger, "NotChargingReason")
        s.vacVoltageLimitMV = int(charger, "VacVoltageLimit")

        s.avgTimeToEmpty = valid(int(bd, "AvgTimeToEmpty") ?? int(p, "AvgTimeToEmpty"))
        s.avgTimeToFull = valid(int(bd, "AvgTimeToFull") ?? int(p, "AvgTimeToFull"))

        if let t = dict(p, "PowerTelemetryData") {
            s.hasTelemetry = true
            s.systemLoadW = Double(int(t, "SystemLoad") ?? 0) / 1000
            s.systemPowerInW = s.external ? Double(int(t, "SystemPowerIn") ?? 0) / 1000 : 0
            s.telemetryBatteryW = Double(int(t, "BatteryPower") ?? 0) / 1000
            s.wallW = int(t, "WallEnergyEstimate").map { Double($0) / 1000 }
            s.adapterLossW = int(t, "AdapterEfficiencyLoss").map { Double($0) / 1000 }
            s.systemInVoltageMV = int(t, "SystemVoltageIn")
            s.systemInCurrentMA = int(t, "SystemCurrentIn")
            if let acc = int(t, "AccumulatedSystemLoad"), let n = int(t, "SystemLoadAccumulatorCount"), n > 0 {
                s.avgSystemW = Double(acc) / Double(n) / 1000
            }
        }

        s.cells = readCells(packBatteryData: bd)

        let life = dict(bd, "LifetimeData")
        s.operatingMinutes = int(life, "TotalOperatingTime")
        s.ltMaxTemp = int(life, "MaximumTemperature")
        s.ltMinTemp = int(life, "MinimumTemperature")
        s.ltAvgTemp = int(life, "AverageTemperature")
        s.ltMaxVoltageMV = int(life, "MaximumPackVoltage")
        s.ltMinVoltageMV = int(life, "MinimumPackVoltage")
        s.ltMaxChargeMA = int(life, "MaximumChargeCurrent")
        s.ltMaxDischargeMA = int(life, "MaximumDischargeCurrent")
        s.cellDisconnectCount = int(p, "BatteryCellDisconnectCount")

        s.serial = str(p, "Serial")
        s.chipName = str(p, "DeviceName")
        s.manufactureDate = readManufactureDate(p)
        s.critical = bool(p, "AtCriticalLevel")
        s.permanentFailure = int(p, "PermanentFailureStatus")

        (s.chargeLimit, s.limitSource) = resolveChargeLimit(dailyMaxSoc: s.dailyMaxSoc,
                                                           notChargingReason: s.notChargingReason)
        return s
    }

    // 65535 代表系統還在計算
    private static func valid(_ m: Int?) -> Int? {
        guard let m, m > 0, m < 65535 else { return nil }
        return m
    }
}

// MARK: - 電力狀態

enum Phase {
    case battery, connecting, acOnly, acCharging, acSupplement

    var title: String {
        switch self {
        case .battery: return "電池放電中"
        case .connecting: return "充電器連接中"
        case .acOnly: return "充電器供電"
        case .acCharging: return "充電器供電並充電"
        case .acSupplement: return "充電器 + 電池補電"
        }
    }

    var detail: String {
        switch self {
        case .battery: return "目前完全由電池供電"
        case .connecting: return "剛接上充電器，數據穩定中"
        case .acOnly: return "充電器供電，電池沒有進出"
        case .acCharging: return "充電器供電，同時幫電池充電"
        case .acSupplement: return "負載超過充電器能力，電池正在一起供電"
        }
    }
}

struct PowerState {
    var phase = Phase.battery
    var systemW = 0.0
    var adapterW = 0.0     // 充電器實際輸出
    var batteryW = 0.0     // 電池充電或放電的量（正數）
    var minutes: Int?
    var timeLabel = "預估可用"
    var timeNote: String?
    var atLimit = false

    var isCharging: Bool { phase == .acCharging }
    var isDraining: Bool { phase == .battery || phase == .acSupplement }

    var headerW: Double {
        (phase == .acOnly || phase == .acCharging) ? adapterW : systemW
    }

    var menuW: Double { isCharging ? adapterW : systemW }
}

private func duration(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    return h > 0 ? "\(h) 小時 \(m) 分" : "\(m) 分"
}

// 指數移動平均，2 秒一筆，大約平滑最近一分鐘
private struct Smoother {
    var value: Double?
    let alpha = 0.065
    mutating func add(_ x: Double) -> Double {
        let v = value.map { $0 + alpha * (x - $0) } ?? x
        value = v
        return v
    }
}

final class PowerModel: ObservableObject {
    static let shared = PowerModel()

    @Published private(set) var snap = Snapshot()
    @Published private(set) var state = PowerState()
    @Published private(set) var updatedAt = Date()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?
    private var lastExternal: Bool?
    private var connectingUntil: Date?
    private var drainSmoother = Smoother()
    private var chargeSmoother = Smoother()

    private init() {
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetSmoothing()
            self?.refresh()
        }
    }

    func refresh() {
        let s = Reader.read()
        if let last = lastExternal, last != s.external {
            resetSmoothing()
            connectingUntil = s.external ? Date().addingTimeInterval(3) : nil
        }
        lastExternal = s.external
        snap = s
        state = compute(s)
        updatedAt = Date()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("WattBar: 設定開機啟動失敗 \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func resetSmoothing() {
        drainSmoother = Smoother()
        chargeSmoother = Smoother()
    }

    private func compute(_ s: Snapshot) -> PowerState {
        var st = PowerState()
        let mag = s.batteryMagnitudeW
        let threshold = 0.3

        if !s.external {
            st.phase = .battery
            st.batteryW = mag
            st.systemW = s.systemLoadW > 0 ? s.systemLoadW : mag
        } else if let until = connectingUntil, Date() < until, s.systemPowerInW < threshold {
            st.phase = .connecting
            st.systemW = s.systemLoadW
        } else if s.hasTelemetry {
            let input = s.systemPowerInW, load = s.systemLoadW
            if input > load + threshold, !s.fullyCharged, (s.isCharging || mag > threshold) {
                st.phase = .acCharging
                st.batteryW = mag > threshold ? mag : input - load
            } else if load > input + threshold, mag > threshold {
                // 只有電池真的有電流流出才算補電，避免數據延遲造成誤判
                st.phase = .acSupplement
                st.batteryW = mag
            } else {
                st.phase = .acOnly
            }
            st.systemW = load > 0 ? load : max(0, input - (st.isCharging ? st.batteryW : 0))
            st.adapterW = input > 0 ? input : st.systemW + (st.isCharging ? st.batteryW : 0)
        } else {
            // 沒有遙測（Intel 機型）：只能從電池電流推算
            if s.isCharging, mag > threshold {
                st.phase = .acCharging
                st.batteryW = mag
            } else {
                st.phase = .acOnly
            }
        }

        if st.systemW == 0, let v = s.systemInVoltageMV, let a = s.systemInCurrentMA, v > 0, a > 0 {
            st.systemW = Double(v) * Double(a) / 1_000_000
        }

        estimateTime(s, &st)
        return st
    }

    private func estimateTime(_ s: Snapshot, _ st: inout PowerState) {
        let soc = s.soc ?? s.percent
        guard let mv = s.voltageMV, mv > 0 else { return }
        let volts = Double(mv) / 1000
        let full = s.fullChargeCap ?? s.rawMaxCap ?? s.nominalCap

        if st.isCharging {
            let limit = s.chargeLimit
            st.timeLabel = limit < 100 ? "充到 \(limit)% 還要" : "充飽還要"
            let rate = chargeSmoother.add(st.batteryW)
            if soc >= limit, st.batteryW < 1 {
                st.atLimit = true
                return
            }
            var computed: Int?
            if let full, full > 0, soc < limit {
                let target = full * limit / 100
                let deltaMAH = s.remainingCap.map { target - $0 } ?? full * (limit - soc) / 100
                if deltaMAH > 0 {
                    let wh = Double(deltaMAH) * volts / 1000
                    let tapered = taper(rate, soc: soc, target: limit)
                    if tapered >= 0.2 { computed = cap(Int(wh / tapered * 60)) }
                }
            }
            if limit < 100 {
                var scaled: Int?
                if let avg = s.avgTimeToFull, soc < limit, soc < 100 {
                    scaled = cap(avg * (limit - soc) / (100 - soc))
                }
                st.minutes = computed ?? scaled ?? s.avgTimeToFull
                if computed != nil || scaled != nil, let src = s.limitSource.label {
                    st.timeNote = "依充電上限 \(limit)%（\(src)）估算"
                }
            } else {
                st.minutes = s.avgTimeToFull ?? computed
                if s.avgTimeToFull == nil, computed != nil {
                    st.timeNote = "系統沒有提供，依剩餘電量和平均功率估算"
                }
            }
        } else if st.isDraining {
            st.timeLabel = "預估可用"
            let rate = drainSmoother.add(st.batteryW > 0 ? st.batteryW : st.systemW)
            if let avg = s.avgTimeToEmpty {
                st.minutes = avg
            } else if rate >= 0.2 {
                var wh: Double?
                if let r = s.remainingCap, r > 0 {
                    wh = Double(r) * volts / 1000
                } else if let full, full > 0, soc > 0 {
                    wh = Double(full) * Double(soc) / 100 * volts / 1000
                }
                if let wh {
                    st.minutes = cap(Int(wh / rate * 60))
                    st.timeNote = "系統沒有提供，依剩餘電量和平均功率估算"
                }
            }
        }
    }

    // 接近充電目標時充電會變慢（定電壓階段），估算時把速率打折
    private func taper(_ rate: Double, soc: Int, target: Int) -> Double {
        let t = min(max(target, 1), 100)
        let start = max(65, t - 15)
        guard soc > start, t > start else { return rate }
        let k = max(0.25, 1 - Double(soc - start) / Double(t - start) * 0.75)
        return rate * k
    }

    private func cap(_ m: Int) -> Int { min(max(0, m), 99 * 60 + 59) }
}

// MARK: - 格式

private func watts(_ w: Double) -> String { String(format: "%.1f W", w) }
private func mAh(_ v: Int?) -> String { v.map { "\($0) mAh" } ?? "—" }
private func volts(_ mv: Int) -> String { String(format: "%.2f V", Double(mv) / 1000) }

private func batterySymbol(_ percent: Int, charging: Bool) -> String {
    if charging { return "battery.100.bolt" }
    switch percent {
    case 88...: return "battery.100"
    case 63..<88: return "battery.75"
    case 38..<63: return "battery.50"
    case 13..<38: return "battery.25"
    default: return "battery.0"
    }
}

private func levelColor(_ p: Int) -> Color { p <= 20 ? .red : (p <= 50 ? .orange : .green) }
private func healthColor(_ h: Int?) -> Color {
    guard let h else { return .secondary }
    return h >= 80 ? .green : (h >= 60 ? .orange : .red)
}

private func cycleText(_ s: Snapshot) -> String {
    guard let c = s.cycles else { return "—" }
    if let d = s.designCycles { return "\(c) / \(d)（設計壽命）" }
    return "\(c)"
}

// MARK: - 共用元件

struct Meter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(tint).frame(width: g.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct Row: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }
}

struct MeterRow: View {
    let label: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Meter(fraction: fraction, tint: tint)
            Text(value).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 12))
    }
}

// MARK: - 流向圖

struct Node: View {
    let icon: String
    let title: String
    let value: String
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 20)).frame(height: 24)
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .frame(width: 76)
        .opacity(active ? 1 : 0.4)
    }
}

struct Arrow: View {
    let active: Bool
    let right: Bool
    let color: Color

    var body: some View {
        Image(systemName: right ? "arrow.right" : "arrow.left")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(active ? color : Color.gray.opacity(0.35))
    }
}

struct FlowDiagram: View {
    let s: Snapshot
    let st: PowerState

    var body: some View {
        let batteryActive = st.isCharging || st.isDraining
        HStack(spacing: 4) {
            Node(icon: "powerplug.fill", title: "充電器",
                 value: s.external ? watts(st.adapterW) : "未接", active: s.external)
            Arrow(active: s.external && st.phase != .connecting, right: true, color: .green)
            Node(icon: "laptopcomputer", title: "系統", value: watts(st.systemW), active: true)
            // 電池在右邊：充電時往右（系統 → 電池），放電時往左（電池 → 系統）
            Arrow(active: batteryActive, right: st.isCharging, color: st.isCharging ? .green : .orange)
            Node(icon: batterySymbol(s.percent, charging: st.isCharging), title: "電池",
                 value: batteryActive ? watts(st.batteryW) : "\(s.percent)%", active: batteryActive)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 選單列面板

struct PanelView: View {
    @ObservedObject var model: PowerModel
    @AppStorage("showWatts") private var showWatts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.snap.hasBattery {
                header
                FlowDiagram(s: model.snap, st: model.state)
                Divider()
                powerRows
                Divider()
                batteryRows
            } else {
                Text("找不到內建電池，WattBar 需要在 MacBook 上使用。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            controls
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        let st = model.state
        return HStack(alignment: .firstTextBaseline) {
            Text(watts(st.headerW)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(st.phase.title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(st.phase == .acSupplement ? Color.orange : Color.primary)
                Text(st.phase.detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var powerRows: some View {
        let s = model.snap, st = model.state
        return VStack(spacing: 6) {
            Row(label: "系統功耗", value: watts(st.systemW))
            Row(label: "充電器輸出", value: s.external ? watts(st.adapterW) : "未接上")
            if st.isCharging { Row(label: "電池充電", value: watts(st.batteryW)) }
            if st.phase == .battery { Row(label: "電池放電", value: watts(st.batteryW)) }
            if st.phase == .acSupplement { Row(label: "電池補電", value: watts(st.batteryW)) }
            if s.external, let rated = s.adapterWatts {
                let load = st.adapterW / Double(rated)
                MeterRow(label: "充電器負載", value: String(format: "%.0f%%", load * 100),
                         fraction: load, tint: load > 0.9 ? .orange : .blue)
                Row(label: "充電器規格", value: "\(rated) W")
            }
        }
    }

    private var batteryRows: some View {
        let s = model.snap, st = model.state
        let level = s.soc ?? s.percent
        return VStack(spacing: 6) {
            MeterRow(label: "電量", value: "\(level)%", fraction: Double(level) / 100, tint: levelColor(level))
            if let h = s.healthPercent {
                MeterRow(label: "健康度", value: "\(h)%", fraction: Double(h) / 100, tint: healthColor(h))
            }
            if let t = s.tempC { Row(label: "溫度", value: String(format: "%.1f °C", t)) }
            Row(label: "循環次數", value: cycleText(s))
            Row(label: st.timeLabel, value: timeText)
            if let note = st.timeNote {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var timeText: String {
        let s = model.snap, st = model.state
        if s.fullyCharged { return "已充飽" }
        if st.atLimit { return "已達充電上限 \(s.chargeLimit)%" }
        if st.phase == .acOnly {
            return notChargingText(s.notChargingReason).map { "未充電（\($0)）" } ?? "未充電"
        }
        return st.minutes.map(duration) ?? "計算中"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("在選單列顯示瓦數", isOn: $showWatts)
                .toggleStyle(.switch).controlSize(.small)
            Toggle("登入時自動啟動", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch).controlSize(.small)
            HStack {
                Button("詳細資訊") { DetailWindow.shared.show() }
                Spacer()
                Button("結束 WattBar") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - 詳細資訊視窗

struct Card<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    let content: Content

    init(_ title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.color = color
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }
}

struct Subheading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DetailView: View {
    @ObservedObject var model: PowerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.snap.hasBattery {
                    powerSection
                    healthSection
                    if let cells = model.snap.cells { cellSection(cells) }
                    lifetimeSection
                    deviceSection
                } else {
                    Text("找不到內建電池，WattBar 需要在 MacBook 上使用。").foregroundStyle(.secondary)
                }
                Text("更新時間 " + model.updatedAt.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 400, idealHeight: 680)
    }

    // 目前電力
    private var powerSection: some View {
        let s = model.snap, st = model.state
        return Card("目前電力", icon: "bolt.fill", color: .green) {
            Row(label: "電力來源", value: st.phase.title)
            Row(label: "系統功耗", value: watts(st.systemW))
            if s.external { Row(label: "充電器輸出", value: watts(st.adapterW)) }
            if st.isCharging { Row(label: "電池充電功率", value: watts(st.batteryW)) }
            if st.phase == .battery { Row(label: "電池放電功率", value: watts(st.batteryW)) }
            if st.phase == .acSupplement { Row(label: "電池補電功率", value: watts(st.batteryW)) }
            if s.external, let rated = s.adapterWatts {
                Row(label: "充電器規格", value: s.adapterName.map { "\(rated) W（\($0)）" } ?? "\(rated) W")
                Row(label: "充電器負載率", value: String(format: "%.0f%%", st.adapterW / Double(rated) * 100))
            }
            if st.isCharging || st.isDraining {
                Row(label: st.timeLabel, value: st.minutes.map(duration) ?? (st.atLimit ? "已達上限" : "計算中"))
                if let note = st.timeNote { Note(note) }
            }

            if s.external {
                Subheading("充電狀態")
                Row(label: "是否充電", value: st.isCharging ? "充電中" : "未充電")
                if s.fullyCharged { Row(label: "已充飽", value: "是") }
                if let r = notChargingText(s.notChargingReason) { Row(label: "未充電原因", value: r) }
                if let v = s.chargingVoltageMV, v > 0 { Row(label: "充電電壓", value: "\(v) mV") }
                if let c = s.chargingCurrentMA { Row(label: "充電電流", value: "\(c) mA") }
                if let v = s.vacVoltageLimitMV, v > 0 { Row(label: "最高充電電壓限制", value: "\(v) mV") }
            }

            if s.hasTelemetry {
                Subheading("歷史平均與輸入")
                if let w = s.avgSystemW { Row(label: "平均系統功耗", value: watts(w)) }
                if s.external, let w = s.wallW, w > 0 { Row(label: "平均插座端功率", value: watts(w)) }
                if s.external, let w = s.adapterLossW, w > 0 { Row(label: "平均充電器損耗", value: watts(w)) }
                if s.external, let v = s.systemInVoltageMV, v > 0 { Row(label: "充電器輸出電壓", value: volts(v)) }
                if s.external, let a = s.systemInCurrentMA, a > 0 { Row(label: "充電器輸出電流", value: "\(a) mA") }
            } else {
                Row(label: "資料來源", value: "估算模式（這台機器沒有功耗遙測）")
            }
        }
    }

    // 電池健康
    private var healthSection: some View {
        let s = model.snap
        let level = s.soc ?? s.percent
        return Card("電池健康", icon: "heart.fill", color: healthColor(s.healthPercent)) {
            Subheading("總覽")
            MeterRow(label: "電量", value: "\(level)%", fraction: Double(level) / 100, tint: levelColor(level))
            if let h = s.healthPercent {
                MeterRow(label: "健康度", value: "\(h)%", fraction: Double(h) / 100, tint: healthColor(h))
            }
            if let c = s.cycles, let d = s.designCycles, d > 0 {
                MeterRow(label: "循環次數", value: "\(c)", fraction: Double(c) / Double(d),
                         tint: Double(c) / Double(d) > 0.8 ? .orange : .blue)
            }
            Row(label: "循環次數", value: cycleText(s))

            Subheading("容量")
            Row(label: "原廠設計容量", value: mAh(s.designCap))
            Row(label: "目前滿電容量", value: mAh(s.rawMaxCap ?? s.fullChargeCap))
            Row(label: "校正後滿電容量", value: mAh(s.nominalCap))
            Row(label: "剩餘電量", value: mAh(s.remainingCap))

            Subheading("充電與保養")
            Row(label: "充電上限", value: s.limitSource.label.map { "\(s.chargeLimit)%（\($0)）" } ?? "\(s.chargeLimit)%")
            if let lo = s.dailyMinSoc, let hi = s.dailyMaxSoc { Row(label: "最佳化充電區間", value: "\(lo)% – \(hi)%") }
            if let t = s.tempC { Row(label: "電池溫度", value: String(format: "%.1f °C", t)) }

            Subheading("即時讀數")
            if let v = s.voltageMV { Row(label: "電池電壓", value: volts(v)) }
            if let a = s.amperageMA { Row(label: "電池電流", value: "\(abs(a)) mA（\(directionText)）") }
            if let a = s.instantAmperageMA { Row(label: "瞬間電流", value: "\(abs(a)) mA") }

            if s.critical != nil || s.permanentFailure != nil {
                Subheading("狀態與警示")
                if let c = s.critical { Row(label: "電量嚴重不足", value: c ? "是" : "否") }
                if let f = s.permanentFailure { Row(label: "永久故障狀態", value: f == 0 ? "正常" : "異常（\(f)）") }
            }
        }
    }

    private var directionText: String {
        let st = model.state
        if st.isCharging { return "充電" }
        if st.isDraining { return "放電" }
        return "待機"
    }

    // 電芯資料
    private func cellSection(_ c: CellTelemetry) -> some View {
        let bankIDs = Array(Set(c.currents.map(\.bank))).sorted()
        return Card("電芯資料", icon: "battery.100", color: .cyan) {
            Text(topologyText(c)).font(.system(size: 12, weight: .medium))
            if let b = voltageBalance(c.voltagesMV) { Row(label: "串聯電壓平衡", value: b) }
            if let b = currentBalance(c.currents) { Row(label: "並聯電流平衡", value: b) }

            if c.perCellArrays {
                Subheading("各電芯")
                ForEach(Array(c.voltagesMV.enumerated()), id: \.offset) { item in
                    Row(label: "電芯 \(item.offset + 1)", value: "\(item.element) mV · Qmax \(c.qmaxMAH[item.offset]) mAh")
                }
            } else {
                Subheading("串聯組")
                Note("Qmax 是這一組並聯電芯估計的滿電容量。")
                ForEach(Array(c.voltagesMV.enumerated()), id: \.offset) { item in
                    Row(label: "第 \(item.offset + 1) 組", value: "\(item.element) mV · Qmax \(c.qmaxMAH[item.offset]) mAh")
                }
                if !c.currents.isEmpty {
                    Subheading("並聯電芯電流")
                    Note("每顆並聯電芯的瞬間電流，同一組內略有差異是正常的。")
                    ForEach(c.currents) { cell in
                        let group = (bankIDs.firstIndex(of: cell.bank) ?? 0) + 1
                        Row(label: "第 \(group) 組 · 電芯 \(cell.cell + 1)", value: "\(abs(cell.mA)) mA")
                    }
                }
            }
        }
    }

    private func topologyText(_ c: CellTelemetry) -> String {
        if c.perCellArrays { return "電池結構：\(c.series) 顆電芯" }
        if c.parallelKnown { return "電池結構：\(c.series)S\(c.parallel)P（共 \(c.series * c.parallel) 顆電芯）" }
        return "電池結構：\(c.series) 組串聯"
    }

    private func voltageBalance(_ v: [Int]) -> String? {
        guard v.count >= 2, let lo = v.min(), let hi = v.max() else { return nil }
        let d = hi - lo
        return "相差 \(d) mV · " + (d <= 50 ? "正常" : (d <= 100 ? "尚可" : "值得注意"))
    }

    private func currentBalance(_ cells: [CellCurrent]) -> String? {
        let spreads = Dictionary(grouping: cells, by: \.bank).values.compactMap { g -> Int? in
            let v = g.map(\.mA)
            guard v.count >= 2, let lo = v.min(), let hi = v.max() else { return nil }
            return hi - lo
        }
        guard let d = spreads.max() else { return nil }
        return "組內最大相差 \(d) mA · " + (d <= 80 ? "正常" : (d <= 150 ? "尚可" : "值得注意"))
    }

    // 生命週期統計
    private var lifetimeSection: some View {
        let s = model.snap
        return Card("生命週期統計", icon: "clock.arrow.circlepath", color: .purple) {
            Subheading("從第一次使用到現在")
            if let m = s.operatingMinutes { Row(label: "總使用時間", value: "\(m / 60) 小時") }
            if let t = s.ltMaxTemp { Row(label: "最高溫度", value: "\(t) °C") }
            if let t = s.ltMinTemp { Row(label: "最低溫度", value: "\(t) °C") }
            if let t = s.ltAvgTemp { Row(label: "平均溫度", value: "\(t) °C") }
            if let v = s.ltMaxVoltageMV { Row(label: "最高電池組電壓", value: volts(v)) }
            if let v = s.ltMinVoltageMV { Row(label: "最低電池組電壓", value: volts(v)) }
            if let a = s.ltMaxChargeMA { Row(label: "最大充電電流", value: "\(abs(a)) mA") }
            if let a = s.ltMaxDischargeMA { Row(label: "最大放電電流", value: "\(abs(a)) mA") }
            if let n = s.cellDisconnectCount { Row(label: "保護觸發次數", value: n == 0 ? "0（正常）" : "\(n)") }
            if s.operatingMinutes == nil && s.ltMaxTemp == nil && s.cellDisconnectCount == nil {
                Note("這台機器沒有提供生命週期資料。")
            }
        }
    }

    // 裝置資訊
    private var deviceSection: some View {
        let s = model.snap
        return Card("裝置資訊", icon: "info.circle", color: .secondary) {
            Row(label: "電池序號", value: s.serial ?? "—")
            Row(label: "電池管理晶片", value: s.chipName ?? "—")
            Row(label: "製造日期", value: s.manufactureDate ?? "—")
        }
    }
}

final class DetailWindow {
    static let shared = DetailWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: DetailView(model: PowerModel.shared))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "WattBar 詳細資訊"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 480, height: 680))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

@main
struct WattBarApp: App {
    @StateObject private var model = PowerModel.shared
    @AppStorage("showWatts") private var showWatts = true

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            label
        }
        .menuBarExtraStyle(.window)
    }

    // 電池在補電或功耗超過 99 W 時，前面加上警示符號
    private var label: Text {
        let st = model.state
        guard showWatts, model.snap.hasBattery else { return Text(Image(systemName: "bolt.fill")) }
        let w = min(99, max(0, Int(st.menuW.rounded())))
        let text = Text("\(w)W")
        if st.phase == .acSupplement || st.menuW > 99 {
            return Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(" ") + text
        }
        return text
    }
}
