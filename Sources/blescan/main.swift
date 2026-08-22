// blescan — a live terminal Bluetooth Low Energy scanner & fingerprinter for macOS.
//
// Backend: CoreBluetooth (CBCentralManager). On macOS this is the ONLY way to reach
// BLE — there is no raw HCI socket as on Linux — and native Swift is the only path
// that hands back the FULL, unflattened advertisementData dict the fingerprinting
// depends on (every wrapper — Rust btleplug, Python bleak — drops or flattens advert
// detail on macOS). The manager runs on a dedicated serial queue and feeds the
// `didDiscover` delegate; we accumulate one live-updating row per peripheral.
//
// What macOS will NOT give a third party (so we don't model it): the hardware BLE MAC
// address. macOS privacy-randomises it and never exposes it; CoreBluetooth instead
// hands back a host-stable CBPeripheral.identifier UUID. So "vendor" comes from the
// advertisement itself — the manufacturer-data company id and the service UUIDs — not
// an OUI table (contrast lanscan, which keys vendor off the MAC's OUI).
//
// The pure model / fingerprinting / layout logic lives in Core.swift (framework-free,
// unit-tested at 100%). This file holds CoreBluetooth, the TUI, and the entrypoint.

import CoreBluetooth
import Darwin
import Foundation

// MARK: - Radio (CoreBluetooth)

/// Owns the CBCentralManager and turns each discovery into a Core `Device`. Delegate
/// callbacks arrive on a private serial queue, so the handlers below run OFF the main
/// thread; they hand finished Devices to the App via `onDiscover`, which locks.
final class Radio: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private let queue = DispatchQueue(label: "com.lucasdaddiego.blescan.ble")

    /// Called on the BLE queue for every advertisement (allow-duplicates is on).
    var onDiscover: ((Device) -> Void)?
    /// Called on the BLE queue whenever the adapter state changes.
    var onState: ((CBManagerState) -> Void)?

    func start() {
        // ShowPowerAlert surfaces the system "Bluetooth is off" alert if appropriate.
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func stop() {
        // CBCentralManager is meant to be driven from its own queue; hop onto it (this is
        // only ever called from the main thread at shutdown, so sync can't deadlock).
        queue.sync {
            if central?.isScanning == true { central.stopScan() }
        }
    }

    /// Current Bluetooth authorization (TCC). Uses the live manager once it exists, else
    /// the type-level value (valid before the manager is created — e.g. in --diag).
    var authorization: CBManagerAuthorization {
        central?.authorization ?? CBCentralManager.authorization
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onState?(central.state)
        if central.state == .poweredOn {
            // allowDuplicates is ESSENTIAL: without it CoreBluetooth coalesces a device to
            // a single didDiscover and the live RSSI never updates. With it we get one
            // callback per received advertisement — exactly what a live signal view needs.
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscover?(buildDevice(peripheral, advertisementData, RSSI))
    }
}

/// Convert a CoreBluetooth discovery into our framework-free `Device`. This is the only
/// place advertisementData keys are touched; everything downstream is pure Core.
private func buildDevice(_ p: CBPeripheral, _ adv: [String: Any], _ rssi: NSNumber) -> Device {
    let localName = adv[CBAdvertisementDataLocalNameKey] as? String
    let mfg = (adv[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) } ?? []
    let services = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
        .map { normalizeUUID($0.uuidString) } ?? []
    // A dictionary, so CoreBluetooth hands the entries back in hash order — sort them, or
    // the detail pane / JSON list them in a different order from one advert to the next.
    let serviceData = (adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
        .map { ServiceDatum(uuid: normalizeUUID($0.key.uuidString), bytes: [UInt8]($0.value)) }
        .sorted { $0.uuid < $1.uuid } ?? []
    let solicited = (adv[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID])?
        .map { normalizeUUID($0.uuidString) } ?? []
    let overflow = (adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID])?
        .map { normalizeUUID($0.uuidString) } ?? []
    return Device(
        id: p.identifier.uuidString,
        name: localName ?? p.name,
        rssi: rssi.intValue,
        txPower: (adv[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
        connectable: (adv[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
        manufacturerData: mfg,
        serviceUUIDs: services,
        serviceData: serviceData,
        solicitedUUIDs: solicited,
        overflowUUIDs: overflow,
        firstSeen: 0, lastSeen: 0)   // stamped by App.ingest
}

func stateLabel(_ s: CBManagerState) -> String {
    switch s {
    case .poweredOn:   return "poweredOn"
    case .poweredOff:  return "poweredOff"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    case .resetting:   return "resetting"
    case .unknown:     return "unknown"
    @unknown default:  return "unknown"
    }
}

func authLabel(_ a: CBManagerAuthorization) -> String {
    switch a {
    case .allowedAlways:  return "authorized"
    case .denied:         return "denied"
    case .restricted:     return "restricted"
    case .notDetermined:  return "not-determined"
    @unknown default:     return "unknown"
    }
}

// MARK: - Clock

/// Monotonic seconds for ageing — only deltas are used, and systemUptime can't jump
/// backward/forward on an NTP step or manual clock change the way wall time can. (The
/// "last HH:mm:ss" header still uses wall-clock `Date()`, since that one is a real time.)
func now() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Terminal capabilities

enum Term {
    static let truecolor: Bool = {
        let ct = ProcessInfo.processInfo.environment["COLORTERM"]
        return ct == "truecolor" || ct == "24bit"
    }()
}

// MARK: - ANSI

enum Ansi {
    static var enabled = true
    static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func fg256(_ s: String, _ c: Int) -> String { wrap(s, "38;5;\(c)") }
    static func bg256(_ s: String, _ c: Int) -> String { wrap(s, "48;5;\(c)") }

    /// Apply a 256-colour background that survives a string already peppered with `ESC[0m`
    /// resets (each cell colours itself and resets). A plain bg256 wrap would be cancelled
    /// by the first interior reset, leaving only the first cell highlighted — so re-assert
    /// the background after every reset. Used for the selected-row highlight.
    static func bg256Persistent(_ s: String, _ c: Int) -> String {
        guard enabled else { return s }
        let set = "\u{1B}[48;5;\(c)m"
        return set + s.replacingOccurrences(of: "\u{1B}[0m", with: "\u{1B}[0m" + set) + "\u{1B}[0m"
    }
    static func fgRGB(_ s: String, _ c: RGB) -> String { wrap(s, "38;2;\(c.r);\(c.g);\(c.b)") }

    /// Colour a string by BLE signal strength — a 24-bit gradient on truecolor terminals,
    /// the 256-palette bucket otherwise.
    static func signalColored(_ s: String, _ rssi: Int) -> String {
        Term.truecolor ? fgRGB(s, signalRGB(rssi)) : fg256(s, signalColorCode(rssi))
    }

    /// A signal bar: filled eighth-block cells over a dotted track, coloured by RSSI.
    static func signalBar(_ rssi: Int, width: Int = 10) -> String {
        let fill = subCellBar(signalFraction(rssi), width: width)
        let track = String(repeating: "·", count: max(0, width - displayWidth(fill)))
        return signalColored(fill + track, rssi)
    }
}

/// Named 256-colour palette for UI chrome.
private enum Pal {
    static let badgeFg = 231, badgeBg = 25   // "blescan" badge
    static let label = 244                   // dim field labels
    static let value = 252                   // field values
    static let text = 250                    // neutral text (table header)
    static let accent = 47                   // authorized / connectable
    static let warn = 208                    // permission / power warnings
    static let error = 196                   // errors
    static let scanning = 226                // scanning spinner
    static let selectBg = 236                // selected-row background
    static let beacon = 39                   // beacon / detail headings
}

private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

/// Proximity → colour (immediate green → far red, unknown dim).
private func proximityColored(_ p: Proximity) -> String {
    switch p {
    case .immediate: return Ansi.fg256(p.label, 46)
    case .near:      return Ansi.fg256(p.label, 226)
    case .far:       return Ansi.fg256(p.label, 208)
    case .unknown:   return Ansi.dim(p.label)
    }
}

/// Clip a possibly-ANSI-coloured string to `cols` visible cells, copying escape
/// sequences verbatim and re-appending a reset if truncated. When `padToWidth` is given
/// and the (untruncated) content is shorter, pad with spaces to that many visible cells —
/// used to stretch the selected-row highlight to the full row width.
private func clipAnsi(_ s: String, _ cols: Int, padToWidth: Int? = nil) -> String {
    if cols <= 0 { return "" }
    var out = "", width = 0, truncated = false
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "\u{1B}" {
            out.append(c)
            var j = s.index(after: i)
            while j < s.endIndex {
                let e = s[j]; out.append(e); j = s.index(after: j)
                if e.isLetter { break }
            }
            i = j
            continue
        }
        let cw = charDisplayWidth(c)
        if width + cw > cols { truncated = true; break }
        out.append(c); width += cw
        i = s.index(after: i)
    }
    if truncated && Ansi.enabled { out += "\u{1B}[0m" }
    if let p = padToWidth, !truncated {
        let target = min(p, cols)
        if width < target { out += String(repeating: " ", count: target - width) }
    }
    return out
}

// MARK: - Rendering helpers

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct Layout { var rows: Int; var cols: Int }

func termSize() -> Layout {
    var w = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_row > 0 {
        return Layout(rows: Int(w.ws_row), cols: Int(w.ws_col))
    }
    return Layout(rows: 24, cols: 100)
}

/// Table column widths (Name flexes; Trend appears only when the window is wide enough).
/// Shared by renderTable and tableSortRegions so the layout and the click hit-test agree.
private func tableColWidths(_ cols: Int) -> (name: Int, vendor: Int, type: Int, dbm: Int, bar: Int,
                                             prox: Int, conn: Int, age: Int, rate: Int, trend: Int) {
    // Type is sized to the longest label ("Keyboard / mouse (HID)", 22) so no category is
    // ever cut mid-word; Vendor is not — company names run long and Name needs the room.
    let vendor = 16, type = 22, dbm = 5, bar = 10, prox = 9, conn = 4, age = 4, rate = 5
    let fixed = vendor + type + dbm + bar + prox + conn + age + rate
    let minName = 14
    // Trend (historyLen wide) appears only once it fits alongside a minimum-width Name and
    // the one-space separators (9 boundaries with Trend on). Turning it on any earlier just
    // overflows the row — the table is clipped to `cols`, so we'd lose other columns.
    let trend = cols >= minName + fixed + App.historyLen + 9 ? App.historyLen : 0
    let separators = trend > 0 ? 9 : 8
    let name = max(minName, min(30, cols - fixed - trend - separators))
    return (name, vendor, type, dbm, bar, prox, conn, age, rate, trend)
}

/// Narrowest row the table can draw without clipping: a minimum-width Name plus the fixed
/// columns and separators. Below this the row is clipped to the terminal, never wrapped.
let tableMinCols = 14 + 75 + 8

/// x-ranges (1-based screen columns) of each header cell paired with the sort key a
/// click selects. Order mirrors renderTable's columns.
func tableSortRegions(_ cols: Int) -> [(range: ClosedRange<Int>, key: SortKey)] {
    let w = tableColWidths(cols)
    var order: [(Int, SortKey)] = [
        (w.name, .name), (w.vendor, .vendor), (w.type, .type), (w.dbm, .rssi),
        (w.bar, .rssi), (w.prox, .rssi), (w.conn, .rssi), (w.age, .age), (w.rate, .rate),
    ]
    if w.trend > 0 { order.append((w.trend, .rssi)) }
    var regions: [(range: ClosedRange<Int>, key: SortKey)] = []
    var x = 1
    for (width, key) in order {
        regions.append((x...(x + width - 1), key))
        x += width + 1
    }
    return regions
}

private func connCell(_ c: Bool?) -> String {
    switch c {
    case .some(true):  return Ansi.fg256("yes", Pal.accent)
    case .some(false): return Ansi.dim("no")
    case nil:          return Ansi.dim("?")
    }
}

/// Render the device table for the rows handed in — the caller passes just the viewport,
/// not every visible device, so a room of 200 devices costs 30 rendered rows, not 200.
/// Returns the lines, header first. `selectedID` highlights its row.
private func renderTable(_ devices: [Device], cols: Int, now t: Double,
                         history: [String: [Int]], selectedID: String?) -> [String] {
    let w = tableColWidths(cols)
    var out: [String] = []

    var header = [
        padTo("Name", w.name), padTo("Vendor", w.vendor), padTo("Type", w.type),
        padLeft("dBm", w.dbm), padTo("Signal", w.bar), padTo("Prox", w.prox),
        padTo("Conn", w.conn), padLeft("Age", w.age), padLeft("Adv/s", w.rate),
    ]
    if w.trend > 0 { header.append(padTo("Trend", w.trend)) }
    // Clip to the terminal width: the columns have a `tableMinCols` floor, so on a narrow
    // terminal the row would otherwise overrun and wrap, tearing the whole frame.
    out.append(clipAnsi(Ansi.bold(Ansi.fg256(header.joined(separator: " "), Pal.text)), cols))

    for d in devices {
        let stale = d.age(now: t) > 10
        let nameRaw = sanitizeName(d.displayName)
        let nameCell = padTo(nameRaw, w.name)
        let name = d.isNamed
            ? (stale ? Ansi.dim(nameCell) : Ansi.fg256(nameCell, Pal.value))
            : Ansi.dim(nameCell)
        let vendor = Ansi.fg256(padTo(sanitizeName(d.vendor), w.vendor), stale ? Pal.label : Pal.value)
        let type = Ansi.fg256(padTo(d.typeLabel, w.type), Pal.label)
        let dbmStr = d.hasValidRSSI ? "\(d.rssi)" : "—"
        let dbm = d.hasValidRSSI ? Ansi.signalColored(padLeft(dbmStr, w.dbm), d.rssi) : Ansi.dim(padLeft(dbmStr, w.dbm))
        // signalBar emits exactly (bar-1) cells + trailing space = bar visible cells.
        let bar = d.hasValidRSSI ? Ansi.signalBar(d.rssi, width: w.bar - 1) + " " : padTo("", w.bar)
        let prox = padTo(proximityColored(d.proximityBucket), w.prox, visibleWidth: displayWidth(d.proximityBucket.label))
        let conn = padTo(connCell(d.connectable), w.conn, visibleWidth: connVisibleWidth(d.connectable))
        let age = padLeft(formatAge(d.age(now: t)), w.age)
        let rateStr = formatRate(d.advertsPerSecond)
        let rate = d.advertsPerSecond > 0 ? padLeft(rateStr, w.rate) : Ansi.dim(padLeft(rateStr, w.rate))
        var cells = [name, vendor, type, dbm, bar, prox, conn, age, rate]
        if w.trend > 0 {
            // Fall back to the current reading only when it's a real RSSI — never seed the
            // trend with the 127 "unavailable" sentinel (it would render as a full spike).
            let samples = history[d.id] ?? (d.hasValidRSSI ? [d.rssi] : [])
            let spark = sparkline(samples)
            let padded = String(repeating: " ", count: max(0, w.trend - displayWidth(spark))) + spark
            cells.append(d.hasValidRSSI ? Ansi.signalColored(padded, d.rssi) : Ansi.dim(padded))
        }
        var row = cells.joined(separator: " ")
        if d.id == selectedID {
            // Pad to the full width so the highlight spans the row, and re-assert the bg
            // after each cell's reset (a plain bg wrap dies at the first interior ESC[0m).
            row = Ansi.bg256Persistent(clipAnsi(row, cols, padToWidth: cols), Pal.selectBg)
        } else {
            row = clipAnsi(row, cols)
        }
        out.append(row)
    }
    return out
}

/// padTo for a string that already carries ANSI escapes: pad by the KNOWN visible width
/// rather than letting padTo miscount escape bytes.
private func padTo(_ s: String, _ n: Int, visibleWidth vw: Int) -> String {
    vw < n ? s + String(repeating: " ", count: n - vw) : s
}
private func connVisibleWidth(_ c: Bool?) -> Int {
    switch c { case .some(true): return 3; case .some(false): return 2; case nil: return 1 }
}

/// The detail pane for the selected device: identity, signal, fingerprint, and a hex
/// dump of the raw manufacturer + service-data bytes (the advertisement, verbatim).
private func renderDetail(_ d: Device, cols: Int, now t: Double) -> [String] {
    func head(_ s: String) -> String { Ansi.bold(Ansi.fg256(s, Pal.beacon)) }
    func field(_ k: String, _ v: String) -> String { Ansi.fg256(padTo(k, 12), Pal.label) + v }
    var out: [String] = []
    out.append(head("▎ \(sanitizeName(d.displayName))"))

    out.append(field("identifier", Ansi.fg256(d.id, Pal.value) + Ansi.dim("  (host-stable UUID, not a MAC)")))

    var sig = d.hasValidRSSI ? Ansi.signalColored("\(d.rssi) dBm", d.rssi) : Ansi.dim("— dBm")
    sig += "  " + proximityColored(d.proximityBucket)
    if let ref = d.calibratedRSSIAt1m, d.hasValidRSSI {
        let m = estimateDistanceMeters(rssi: d.rssi, calibratedRSSIAt1m: ref)
        if m >= 0 { sig += Ansi.dim(String(format: "  ~%.1f m", m)) }
    }
    sig += Ansi.fg256("   conn ", Pal.label) + connCell(d.connectable)
    if let tx = d.txPower { sig += Ansi.fg256("   tx ", Pal.label) + "\(tx) dBm" }
    sig += Ansi.fg256("   seen ", Pal.label) + formatAge(d.age(now: t)) + " ago"
        + Ansi.dim("  (first \(formatAge(d.seenFor(now: t))) ago)")
    sig += Ansi.fg256("   adv/s ", Pal.label) + formatRate(d.advertsPerSecond)
    out.append(field("signal", sig))

    out.append(field("vendor", "\(sanitizeName(d.vendor))   " + Ansi.dim("type ") + d.typeLabel))

    let services = d.advertisedServices.map(friendlyService)
    if !services.isEmpty { out.append(field("services", services.joined(separator: ", "))) }
    if !d.solicitedUUIDs.isEmpty {
        out.append(field("solicited", d.solicitedUUIDs.map(friendlyService).joined(separator: ", ")))
    }
    if !d.overflowUUIDs.isEmpty {
        out.append(field("overflow", d.overflowUUIDs.map(friendlyService).joined(separator: ", ")))
    }

    if let b = d.iBeacon {
        out.append(field("iBeacon", "UUID \(b.uuid)  major \(b.major)  minor \(b.minor)  power \(b.measuredPower) dBm"))
    }
    if let e = d.eddystone { out.append(field("eddystone", e.summary)) }
    let cont = d.continuityTypes.compactMap(continuityName)
    if !cont.isEmpty { out.append(field("continuity", cont.joined(separator: ", "))) }

    if !d.manufacturerData.isEmpty {
        out.append(field("manufacturer", Ansi.dim("\(d.manufacturerData.count) bytes")))
        for line in hexDump(d.manufacturerData) { out.append("  " + Ansi.dim(line)) }
    }
    for sd in d.serviceData where !sd.bytes.isEmpty {
        out.append(field("svc-data", Ansi.fg256(friendlyService(sd.uuid), Pal.value) + Ansi.dim("  \(sd.bytes.count) bytes")))
        for line in hexDump(sd.bytes) { out.append("  " + Ansi.dim(line)) }
    }
    return out.map { clipAnsi($0, cols) }
}

// MARK: - App

final class App {
    let radio = Radio()
    let lock = NSLock()

    // --- shared with the BLE queue (guard with `lock`) ---
    private var devices: [String: Device] = [:]
    private var history: [String: [Int]] = [:]
    private var lastHist: [String: Double] = [:]
    private var rates: [String: AdvertRate] = [:]
    var generation = 0
    var radioState: CBManagerState = .unknown

    static let historyLen = 24

    // --- UI state (main-thread-confined) ---
    var sortKey: SortKey = .rssi
    var ascending = false
    var filter = ""
    var filterEditing = false
    var connectableOnly = false
    var namedOnly = false
    var selectedID: String?
    var scroll = 0
    var quit = false
    var helpShown = false
    var spinnerTick = 0

    // --- render cache (main-thread-confined): the last painted frame, one entry per screen
    // row, so draw() can rewrite only the rows that changed ---
    var lastLines: [String] = []
    var lastCols = 0
    var lastRows = 0
    var lastTitle = ""

    // --- mouse hit-test, refreshed each draw ---
    var headerScreenRow = -1
    var sortRegions: [(range: ClosedRange<Int>, key: SortKey)] = []
    var rowScreenStart = -1       // 1-based screen row of the first data row
    var rowIDs: [String] = []     // device id per rendered data row
    func sortColumnAt(_ col: Int) -> SortKey? { sortRegions.first { $0.range.contains(col) }?.key }

    /// Merge one discovery into the live table (called on the BLE queue).
    func ingest(_ d: Device, at t: Double) {
        lock.lock(); defer { lock.unlock() }
        if devices[d.id] != nil {
            devices[d.id]!.absorb(d, at: t)   // in place: no copy of the row per advert
        } else {
            var nd = d; nd.firstSeen = t; nd.lastSeen = t
            devices[d.id] = nd
        }
        rates[d.id, default: AdvertRate()].record(at: t)
        // Throttle the sparkline history to ~1 Hz per device so the trace spans seconds,
        // not the sub-second burst rate allow-duplicates delivers. Skip the 127 "RSSI
        // unavailable" sentinel so it never shows up as a full-height spike in the trend.
        if d.hasValidRSSI, t - (lastHist[d.id] ?? 0) >= 1.0 {
            var h = history[d.id, default: []]
            h.append(d.rssi)
            if h.count > App.historyLen { h.removeFirst(h.count - App.historyLen) }
            history[d.id] = h
            lastHist[d.id] = t
        }
        generation += 1
    }

    /// Drop devices unheard-from for `drop` seconds. Returns true if anything changed.
    @discardableResult
    func prune(at t: Double, drop: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let dead = devices.filter { t - $0.value.lastSeen > drop }.map { $0.key }
        guard !dead.isEmpty else { return false }
        for id in dead { devices[id] = nil; history[id] = nil; lastHist[id] = nil; rates[id] = nil }
        generation += 1
        return true
    }

    func setState(_ s: CBManagerState) { lock.lock(); radioState = s; generation += 1; lock.unlock() }
    func markDirty() { lock.lock(); generation += 1; lock.unlock() }
    func readGeneration() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
    func snapshotState() -> CBManagerState { lock.lock(); defer { lock.unlock() }; return radioState }
    /// Every device, each stamped with its advert rate as of `t` (the rate decays between
    /// packets, so it is evaluated at read time rather than stored at ingest).
    func snapshotDevices(at t: Double) -> [Device] {
        lock.lock(); defer { lock.unlock() }
        return devices.values.map { var d = $0; d.advertsPerSecond = rates[d.id]?.perSecond(at: t) ?? 0; return d }
    }
    /// Sparkline history for just the given ids — the rows about to be painted — instead of
    /// copying every device's ring buffer under the lock each frame.
    func history(for ids: [String]) -> [String: [Int]] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: [Int]] = [:]
        for id in ids { if let h = history[id] { out[id] = h } }
        return out
    }

    /// Filtered + sorted devices for display.
    func visible(_ all: [Device]) -> [Device] {
        var f = all
        if connectableOnly { f = f.filter { $0.connectable == true } }
        if namedOnly { f = f.filter { $0.isNamed } }
        if !filter.isEmpty {
            let q = filter.lowercased()
            f = f.filter {
                $0.displayName.lowercased().contains(q) || $0.vendor.lowercased().contains(q)
                    || $0.typeLabel.lowercased().contains(q)
            }
        }
        return sortDevices(f, by: sortKey, ascending: ascending)
    }

    func wireRadio() {
        radio.onState = { [weak self] s in self?.setState(s) }
        radio.onDiscover = { [weak self] d in self?.ingest(d, at: now()) }
    }
}

// MARK: - Terminal raw mode

private var savedTermios = termios()
private var rawActive: sig_atomic_t = 0

// The leave sequence, plus the same bytes in a plain C buffer: mouse reporting off · show
// cursor · leave the alt screen · restore the window title. prepareSignalSafeLeave() fills
// the buffer so the signal handler never has to build it (see leaveRawFromSignal).
private let leaveSequence = "\u{1B}[?1006l\u{1B}[?1000l\u{1B}[?25h\u{1B}[?1049l\u{1B}[23;2t"
private var leaveBytes: UnsafeMutablePointer<UInt8>?
private var leaveByteCount = 0

/// Write a string straight to the fd, looping over partial writes and retrying on EINTR.
/// Used for every byte we emit in raw mode (enter/leave sequences AND each frame), so the
/// TUI never mixes buffered stdio with raw writes — a full frame can be several KB and a
/// single write() may not take it all.
private func writeRaw(_ s: String) {
    let bytes = Array(s.utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress!.advanced(by: off), bytes.count - off) }
        if n < 0 { if errno == EINTR { continue }; break }   // unrecoverable error → give up
        if n == 0 { break }
        off += n
    }
}

/// Snapshot the leave sequence into a plain C buffer. MUST run before the signal handlers
/// are installed — building it inside a handler is the very thing leaveRawFromSignal exists
/// to avoid. Allocated once and owned for the life of the process.
private func prepareSignalSafeLeave() {
    guard leaveBytes == nil else { return }
    let bytes = Array(leaveSequence.utf8)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
    buf.update(from: bytes, count: bytes.count)
    leaveBytes = buf
    leaveByteCount = bytes.count
}

private func enterRaw() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    rawActive = 1
    var raw = savedTermios
    raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
    raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
    raw.c_oflag &= ~(UInt(OPOST))
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1   // 0.1s read timeout → ~10 fps idle loop
        }
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    // alt screen + hide cursor · save window title · enable SGR mouse reporting.
    writeRaw("\u{1B}[?1049h\u{1B}[?25l\u{1B}[22;2t\u{1B}[?1000h\u{1B}[?1006h")
}

private func leaveRaw() {
    guard rawActive != 0 else { return }
    rawActive = 0
    writeRaw(leaveSequence)
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
}

/// leaveRaw for a SIGNAL HANDLER: the same restore, but async-signal-safe. It touches only
/// write(2) and tcsetattr(2) over the buffer prepareSignalSafeLeave() built up front — never
/// the String path, because writeRaw's `Array(s.utf8)` mallocs and draw() keeps the
/// interrupted thread inside malloc thousands of times a second. A handler that re-enters
/// libmalloc's lock never returns, `_exit(0)` is never reached, and the user is left with a
/// wedged terminal (alt screen up, ECHO/ICANON/ISIG off, mouse reporting on) that needs a
/// `kill -9` from another window and a `reset`. Ctrl-C does NOT arrive here (ISIG is cleared,
/// so 0x03 comes through as a byte) — `kill`, a teardown script or a logout does.
private func leaveRawFromSignal() {
    guard rawActive != 0 else { return }
    rawActive = 0
    if let p = leaveBytes {
        var off = 0
        while off < leaveByteCount {
            let n = write(STDOUT_FILENO, p + off, leaveByteCount - off)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            off += n
        }
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
}

struct MouseEvent { let button: Int; let col: Int; let row: Int; let press: Bool }
enum Input { case key(Character), mouse(MouseEvent), up, down, none }

/// One byte of lookahead: readInput peeks past an ESC to tell a lone Escape from a CSI/SS3
/// sequence, and when the next byte turns out to be an ordinary key (Esc then `q`, typed
/// fast) it goes here so the key is delivered on the next read instead of being swallowed.
private var pushedBack: UInt8?

private func readByte() -> UInt8? {
    if let b = pushedBack { pushedBack = nil; return b }
    var b: UInt8 = 0
    return read(STDIN_FILENO, &b, 1) == 1 ? b : nil
}

private func readInput() -> Input {
    guard let b = readByte() else { return .none }
    if b != 0x1B {
        return b < 0x80 ? .key(Character(UnicodeScalar(b))) : .none
    }
    guard let b1 = readByte() else { return .key("\u{1B}") }   // lone Esc
    // CSI (ESC [ …) or SS3 (ESC O …): arrows arrive as the latter in application-cursor
    // mode (tmux and some terminals), with the same final byte.
    guard b1 == 0x5B /* [ */ || b1 == 0x4F /* O */ else { pushedBack = b1; return .key("\u{1B}") }
    var body = [UInt8]()
    for _ in 0..<32 {
        guard let c = readByte() else { break }
        body.append(c)
        if (0x40...0x7E).contains(c) { break }
    }
    // SGR mouse: "ESC [ < b ; x ; y" then 'M'/'m'.
    if let first = body.first, first == 0x3C, let final = body.last, final == 0x4D || final == 0x6D {
        let nums = String(decoding: body.dropFirst().dropLast(), as: UTF8.self)
            .split(separator: ";").compactMap { Int($0) }
        if nums.count == 3 {
            return .mouse(MouseEvent(button: nums[0], col: nums[1], row: nums[2], press: final == 0x4D))
        }
        return .none
    }
    // Arrow keys: ESC [ A/B → dedicated nav events (NOT synthesized j/k chars, which would
    // otherwise be typed into the filter while it's being edited).
    if let final = body.last {
        switch final {
        case 0x41: return .up     // up
        case 0x42: return .down   // down
        default: break
        }
    }
    return .none
}

// MARK: - Interactive loop

func runInteractive(app: App) {
    prepareSignalSafeLeave()   // before the handlers: they must never build it themselves
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in leaveRawFromSignal(); _exit(0) }
    }
    atexit { leaveRaw() }
    enterRaw()

    app.wireRadio()
    app.radio.start()

    var lastGen = -1, lastCols = 0, lastRows = 0, lastPrune = now(), lastSpin = now()

    while !app.quit {
        let t = now()
        if t - lastPrune >= 1.0 { app.prune(at: t, drop: 60); lastPrune = t }

        let sz = termSize()
        let gen = app.readGeneration()
        let scanning = app.snapshotState() == .poweredOn
        // The spinner / clock / ages tick at 5 Hz while scanning; the table itself repaints
        // whenever the generation advances (new advert, key, prune) or the window resizes.
        var animate = false
        if scanning, t - lastSpin >= 0.2 { app.spinnerTick &+= 1; lastSpin = t; animate = true }
        if gen != lastGen || sz.cols != lastCols || sz.rows != lastRows || animate {
            draw(app)
            lastGen = gen; lastCols = sz.cols; lastRows = sz.rows
        }
        switch readInput() {
        case .key(let k):   handleKey(k, app: app)
        case .mouse(let m): handleMouse(m, app: app)
        case .up:           moveSelection(app, -1); app.markDirty()   // works even mid-filter
        case .down:         moveSelection(app, 1); app.markDirty()
        case .none:         break
        }
    }
    app.radio.stop()
    leaveRaw()
}

private func moveSelection(_ app: App, _ delta: Int) {
    let vis = app.visible(app.snapshotDevices(at: now()))
    guard !vis.isEmpty else { app.selectedID = nil; return }
    let idx = vis.firstIndex { $0.id == app.selectedID } ?? 0
    let next = max(0, min(vis.count - 1, idx + delta))
    app.selectedID = vis[next].id
}

func handleKey(_ k: Character, app: App) {
    if k == "\u{03}" || k == "\u{04}" { app.quit = true; return }   // Ctrl-C / Ctrl-D, anywhere
    if app.helpShown {
        // Any key dismisses the overlay; `q` still quits rather than needing a second press.
        app.helpShown = false
        app.markDirty()
        if k != "q" { return }
    }
    if app.filterEditing {
        switch k {
        case "\r", "\n": app.filterEditing = false
        case "\u{1B}":   app.filterEditing = false; app.filter = ""   // Esc cancels
        case "\u{7F}", "\u{08}": if !app.filter.isEmpty { app.filter.removeLast() }
        case "\u{15}":   app.filter = ""                              // Ctrl-U clears
        default: if k >= " " && k != "\u{7F}" { app.filter.append(k) }
        }
        app.markDirty()
        return
    }
    switch k {
    case "q": app.quit = true
    case "j": moveSelection(app, 1)
    case "k": moveSelection(app, -1)
    case "p": setSort(app, .rssi)
    case "n": setSort(app, .name)
    case "v": setSort(app, .vendor)
    case "t": setSort(app, .type)
    case "g": setSort(app, .age)
    case "r": setSort(app, .rate)
    case "?": app.helpShown = true
    case "c": app.connectableOnly.toggle()
    case "u": app.namedOnly.toggle()
    case "/": app.filterEditing = true
    case "\u{1B}": app.filter = ""                          // Esc clears an active filter
    default: break
    }
    app.markDirty()
}

func handleMouse(_ m: MouseEvent, app: App) {
    if app.helpShown {
        if m.press { app.helpShown = false; app.markDirty() }   // a click dismisses the overlay
        return
    }
    if m.button & 64 != 0 {                                 // wheel
        moveSelection(app, m.button & 1 == 0 ? -1 : 1)
        app.markDirty()
        return
    }
    let leftPress = m.press && m.button & 0b11 == 0 && m.button & 32 == 0
    guard leftPress else { return }
    if m.row == app.headerScreenRow, let key = app.sortColumnAt(m.col) {
        setSort(app, key)
    } else if app.rowScreenStart >= 0 {
        let idx = m.row - app.rowScreenStart
        if idx >= 0 && idx < app.rowIDs.count { app.selectedID = app.rowIDs[idx] }
    }
    app.markDirty()
}

func setSort(_ app: App, _ key: SortKey) {
    if app.sortKey == key { app.ascending.toggle() } else { app.sortKey = key; app.ascending = false }
}

func draw(_ app: App) {
    let layout = termSize()
    let t = now()
    let all = app.snapshotDevices(at: t)
    let visible = app.visible(all)
    let state = app.snapshotState()
    let authorization = app.radio.authorization

    if Ansi.enabled {
        let title = "blescan — \(all.count) BLE devices"
        if title != app.lastTitle { app.lastTitle = title; writeRaw("\u{1B}]2;\(title)\u{07}") }
    }

    // Resolve the selection (default to the first visible device).
    if app.selectedID == nil || !visible.contains(where: { $0.id == app.selectedID }) {
        app.selectedID = visible.first?.id
    }

    var lines: [String] = []
    let rule = Ansi.dim(String(repeating: "─", count: layout.cols))

    // Header. (spinnerTick uses &+= and could in theory wrap negative; index via the bit
    // pattern as UInt so the modulo is always in range — Swift's % keeps a negative sign.)
    let spinner = spinnerFrames[Int(UInt(bitPattern: app.spinnerTick) % UInt(spinnerFrames.count))]
    let scanTag = state == .poweredOn ? Ansi.fg256(" \(spinner) scanning…", Pal.scanning) : ""
    let head1 = Ansi.bg256(Ansi.bold(Ansi.fg256("  blescan  ", Pal.badgeFg)), Pal.badgeBg)
        + " " + Ansi.fg256("adapter ", Pal.label)
        + Ansi.fg256(stateLabel(state), state == .poweredOn ? Pal.accent : Pal.warn)
        + Ansi.fg256("  permission ", Pal.label)
        + Ansi.fg256(authLabel(authorization), authorization == .allowedAlways ? Pal.accent : Pal.warn)
        + scanTag
    lines.append(clipAnsi(head1, layout.cols))

    let head2 = Ansi.fg256("devices ", Pal.label) + Ansi.bold("\(all.count)")
        + Ansi.fg256("  shown ", Pal.label) + "\(visible.count)"
        + Ansi.fg256("  sort ", Pal.label) + app.sortKey.label + (app.ascending ? "↑" : "↓")
        + Ansi.fg256("  conn-only ", Pal.label) + (app.connectableOnly ? "on" : "off")
        + Ansi.fg256("  named-only ", Pal.label) + (app.namedOnly ? "on" : "off")
        + Ansi.fg256("  last ", Pal.label) + timeFormatter.string(from: Date())
    lines.append(clipAnsi(head2, layout.cols))
    lines.append(rule)

    // Permission / power guidance.
    if state == .unauthorized || authorization == .denied || authorization == .restricted {
        lines.append(clipAnsi(Ansi.fg256("⚠ Bluetooth permission not granted for blescan.", Pal.warn), layout.cols))
        lines.append(clipAnsi(Ansi.dim("  Enable 'blescan' in System Settings → Privacy & Security → Bluetooth, then rerun."), layout.cols))
    } else if state == .poweredOff {
        lines.append(clipAnsi(Ansi.fg256("⚠ Bluetooth is powered off — turn it on to scan.", Pal.warn), layout.cols))
    } else if state == .unsupported {
        lines.append(clipAnsi(Ansi.fg256("⚠ This Mac reports no Bluetooth LE support.", Pal.error), layout.cols))
    } else if all.isEmpty {
        lines.append(clipAnsi(Ansi.dim("Listening for advertisements…"), layout.cols))
    } else if visible.isEmpty {
        lines.append(clipAnsi(Ansi.dim("\(all.count) device\(all.count == 1 ? "" : "s") heard, but none match the current filter / toggles."), layout.cols))
    }

    if layout.cols < tableMinCols {
        lines.append(clipAnsi(Ansi.fg256("↔ \(layout.cols) columns — the table needs \(tableMinCols); rows are clipped until the window is wider.", Pal.warn), layout.cols))
    }

    // Filter edit / active filter line.
    if app.filterEditing {
        lines.append(clipAnsi(Ansi.fg256("filter: ", Pal.label) + app.filter + Ansi.fg256("▏", Pal.accent)
            + Ansi.dim("   (type to filter name/vendor/type · Enter to apply · Esc to clear)"), layout.cols))
    } else if !app.filter.isEmpty {
        lines.append(clipAnsi(Ansi.fg256("filter: ", Pal.label) + app.filter + Ansi.dim("   (Esc to clear)"), layout.cols))
    }

    let footer = footerLines(layout.cols)

    if app.helpShown {
        // The overlay replaces the table AND the detail pane; nothing is clickable.
        app.headerScreenRow = -1; app.rowScreenStart = -1; app.rowIDs = []; app.sortRegions = []
        let body = helpLines().map { clipAnsi($0, layout.cols) }
        let budget = max(1, layout.rows - lines.count - footer.count - 1)
        lines.append(contentsOf: body.prefix(budget))
        let used = lines.count + 1 + footer.count
        if used < layout.rows { lines.append(contentsOf: Array(repeating: "", count: layout.rows - used)) }
        lines.append(rule)
        lines.append(contentsOf: footer.map { clipAnsi($0, layout.cols) })
        paint(app, lines, layout)
        return
    }

    // Body layout: detail pane takes a bounded share of the screen, table gets the rest.
    let detail = app.selectedID.flatMap { id in visible.first { $0.id == id } }
        .map { renderDetail($0, cols: layout.cols, now: t) } ?? []
    let detailShown = Array(detail.prefix(min(detail.count, max(6, layout.rows / 3))))
    let chrome = lines.count + footer.count + (detailShown.isEmpty ? 0 : detailShown.count + 1) + 1
    let tableBudget = max(3, layout.rows - chrome)
    let viewport = max(1, tableBudget - 1)   // minus the header row

    // Scroll so the selected row stays visible, then render ONLY the rows in the viewport.
    let selIdx = visible.firstIndex { $0.id == app.selectedID } ?? 0
    if selIdx < app.scroll { app.scroll = selIdx }
    if selIdx >= app.scroll + viewport { app.scroll = selIdx - viewport + 1 }
    let maxScroll = max(0, visible.count - viewport)
    app.scroll = min(max(0, app.scroll), maxScroll)

    let window = Array(visible.dropFirst(app.scroll).prefix(viewport))
    let ids = window.map { $0.id }
    let tableLines = renderTable(window, cols: layout.cols, now: t,
                                 history: app.history(for: ids), selectedID: app.selectedID)

    app.headerScreenRow = lines.count + 1
    app.sortRegions = tableSortRegions(layout.cols)
    lines.append(tableLines[0])
    app.rowScreenStart = lines.count + 1
    app.rowIDs = ids
    lines.append(contentsOf: tableLines.dropFirst())

    // Pad so the bottom chrome sits flush at the bottom.
    let used = lines.count + (detailShown.isEmpty ? 0 : detailShown.count + 1) + 1 + footer.count
    if used < layout.rows { lines.append(contentsOf: Array(repeating: "", count: layout.rows - used)) }
    if !detailShown.isEmpty {
        lines.append(rule)
        lines.append(contentsOf: detailShown)
    }
    lines.append(rule)
    lines.append(contentsOf: footer.map { clipAnsi($0, layout.cols) })
    paint(app, lines, layout)
}

/// Put a frame on screen, rewriting only the rows that differ from the last frame. A full
/// repaint (clear + every row) happens only when the terminal was resized. Between
/// adverts, a tick costs the two header rows (spinner, clock) and whichever Age cells
/// rolled over — a few hundred bytes, not the whole screen. Wrapped in synchronized output
/// (DEC 2026) so the terminal shows the new rows all at once.
private func paint(_ app: App, _ lines: [String], _ layout: Layout) {
    let painted = Array(lines.prefix(layout.rows))
    let sizeChanged = layout.cols != app.lastCols || layout.rows != app.lastRows
    var screen = ""
    if sizeChanged || painted.count != app.lastLines.count {
        screen = "\u{1B}[2J\u{1B}[H" + painted.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n")
    } else {
        for (i, line) in painted.enumerated() where line != app.lastLines[i] {
            screen += "\u{1B}[\(i + 1);1H" + line + "\u{1B}[K"
        }
        if screen.isEmpty { return }
    }
    app.lastLines = painted
    app.lastCols = layout.cols
    app.lastRows = layout.rows
    writeRaw("\u{1B}[?2026h" + screen + "\u{1B}[?2026l")
}

/// The `?` overlay: every key and mouse action, plus what each column means.
func helpLines() -> [String] {
    func k(_ key: String, _ what: String) -> String { "  " + Ansi.fg256(padTo(key, 22), Pal.accent) + what }
    func c(_ col: String, _ what: String) -> String { "  " + Ansi.fg256(padTo(col, 8), Pal.value) + what }
    return [
        Ansi.bold(Ansi.fg256("▎ keys", Pal.beacon)),
        k("q · Ctrl-C · Ctrl-D", "quit"),
        k("j / k · ↑ / ↓ · wheel", "move the selection (the detail pane follows it)"),
        k("p n v t g r", "sort by power (RSSI) · name · vendor · type · age · advert rate — press again to reverse"),
        k("c", "connectable-only toggle"),
        k("u", "named-only toggle"),
        k("/", "filter by name / vendor / type  (Enter applies · Esc clears)"),
        k("?", "this help  (any key closes it)"),
        k("mouse", "click a column header to sort · click a row to select it"),
        "",
        Ansi.bold(Ansi.fg256("▎ columns", Pal.beacon)),
        c("Vendor", "from the SIG company id in manufacturer data; 0xXXXX = id not in the curated table; — = no manufacturer data"),
        c("Type", "best guess from beacon / Continuity / service signatures"),
        c("dBm", "last RSSI; — when the radio reports it unavailable"),
        c("Signal", "the same value as a bar over the −100…−40 dBm window"),
        c("Prox", "immediate / near / far — from the beacon's 1 m reference when it has one, else RSSI thresholds"),
        c("Conn", "advertises as connectable: yes / no / ? (not stated)"),
        c("Age", "since the last packet; rows dim after 10 s and drop after 60 s"),
        c("Adv/s", "packets per second over the last 5 s — beacons and trackers are steady, phones burst"),
        c("Trend", "RSSI sparkline, one sample per second (wide terminals only)"),
    ]
}

/// The one-line key hint, sized to the terminal width: the richest variant that fits
/// `cols` wins, shedding the verbose mouse help, then the brief one, then per-key detail
/// as the window narrows — so it never gets truncated mid-word the way one fixed string
/// does. The last (most compact) variant is the floor; on a terminal too narrow for even
/// that the draw-time clipAnsi trims it, but the table has already overrun its
/// `tableMinCols` floor by then. Tier widths: 189 / 141 / 116 / 103 / 71 columns.
func footerLines(_ cols: Int) -> [String] {
    let variants = [
        "[q]uit  [j/k]select  [p]ower [n]ame [v]endor [t]ype a[g]e [r]ate sort  [c]onn-only [u]named-only  [/]filter  [?]help  ·  mouse: wheel selects, click a header to sort, click a row to inspect",
        "[q]uit  [j/k]select  [p]ower [n]ame [v]endor [t]ype a[g]e [r]ate sort  [c]onn-only [u]named-only  [/]filter  [?]help  ·  mouse: wheel + click",
        "[q]uit  [j/k]select  [p]ower [n]ame [v]endor [t]ype a[g]e [r]ate sort  [c]onn-only [u]named-only  [/]filter  [?]help",
        "[q]uit  [j/k]sel  [p]ower [n]ame [v]endor [t]ype a[g]e [r]ate sort  [c]onn [u]named  [/]filter  [?]help",
        "[q]uit  [j/k]sel  [p/n/v/t/g/r]sort  [c]onn [u]named  [/]filter  [?]help",
    ]
    return [Ansi.dim(widthFittingVariant(variants, cols))]
}

// MARK: - Non-interactive collection (--once / --json / --stream / --diag)

/// Start the radio and block `window` seconds while the BLE queue accumulates devices,
/// then return the snapshot. The window also covers the adapter's ramp to poweredOn.
private func collect(app: App, window: TimeInterval) -> [Device] {
    app.wireRadio()
    app.radio.start()
    Thread.sleep(forTimeInterval: window)
    app.radio.stop()
    return app.snapshotDevices(at: now())
}

/// One device as JSON (`--json` array element / `--stream` line). Optional fields are
/// omitted when absent (synthesized Encodable uses encodeIfPresent), so the output only
/// carries what a device actually advertised. Services are raw normalised UUIDs so a
/// consumer can match on them (`select(.services | index("180D"))`); the display strings
/// live beside them in `serviceNames`.
struct DeviceJSON: Encodable {
    struct Beacon: Encodable { let uuid: String; let major: Int; let minor: Int; let measuredPower: Int }
    struct ServiceData: Encodable { let service: String; let serviceName: String; let hex: String }

    let ts: String?                  // --stream only: wall-clock time of the line
    let id: String
    let name: String?
    let rssi: Int?
    let txPower: Int?
    let connectable: Bool?
    let vendor: String
    let companyId: String?
    let type: String
    let proximity: String
    let advertsPerSecond: Double
    let firstSeenSecondsAgo: Int
    let lastSeenSecondsAgo: Int
    let services: [String]
    let serviceNames: [String]
    let solicitedServices: [String]?
    let overflowServices: [String]?
    let continuity: [String]?
    let iBeacon: Beacon?
    let eddystone: String?
    let manufacturerHex: String?
    let serviceData: [ServiceData]?

    init(_ d: Device, now t: Double, ts: String? = nil) {
        func nilIfEmpty<T>(_ a: [T]) -> [T]? { a.isEmpty ? nil : a }
        self.ts = ts
        id = d.id
        name = d.name
        rssi = d.hasValidRSSI ? d.rssi : nil          // 127 == unavailable → omit
        txPower = d.txPower
        connectable = d.connectable
        vendor = d.vendor
        companyId = d.companyId.map { String(format: "0x%04X", $0) }
        type = d.typeLabel
        proximity = d.proximityBucket.label
        advertsPerSecond = (d.advertsPerSecond * 10).rounded() / 10
        firstSeenSecondsAgo = Int(d.seenFor(now: t).rounded())
        lastSeenSecondsAgo = Int(d.age(now: t).rounded())
        services = d.advertisedServices
        serviceNames = d.advertisedServices.map(friendlyService)
        solicitedServices = nilIfEmpty(d.solicitedUUIDs)
        overflowServices = nilIfEmpty(d.overflowUUIDs)
        continuity = nilIfEmpty(d.continuityTypes.compactMap(continuityName))
        iBeacon = d.iBeacon.map { Beacon(uuid: $0.uuid, major: Int($0.major), minor: Int($0.minor), measuredPower: $0.measuredPower) }
        eddystone = d.eddystone?.summary
        manufacturerHex = d.manufacturerData.isEmpty ? nil : hexString(d.manufacturerData)
        serviceData = nilIfEmpty(d.serviceData.filter { !$0.bytes.isEmpty }
            .map { ServiceData(service: $0.uuid, serviceName: friendlyService($0.uuid), hex: hexString($0.bytes)) })
    }
}

private func writeStderr(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

/// `--json` exits 3 (with a line on stderr) if the radio never came up, so a caller can
/// tell an empty room from a scan that never happened. (--once prints its own hint line
/// and --diag reports the state, so the JSON modes were the only ones with no signal.)
private func failIfNeverScanned(_ app: App) {
    if let problem = headlessScanFailure(poweredOn: app.snapshotState() == .poweredOn,
                                         state: stateLabel(app.snapshotState()),
                                         authorization: authLabel(app.radio.authorization)) {
        writeStderr(problem)
        exit(3)
    }
}

func runOnce(app: App, window: TimeInterval, json: Bool) {
    let devices = sortDevices(collect(app: app, window: window), by: app.sortKey, ascending: app.ascending)
    let t = now()   // after the scan, so the ages are measured from the moment of output
    if json {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let arr = devices.map { DeviceJSON($0, now: t) }
        if let data = try? enc.encode(arr), let s = String(data: data, encoding: .utf8) { print(s) } else { print("[]") }
        failIfNeverScanned(app)
        return
    }
    print(Ansi.bold("blescan — \(devices.count) BLE devices  (adapter \(stateLabel(app.snapshotState())), permission \(authLabel(app.radio.authorization)))"))
    if devices.isEmpty {
        print(Ansi.dim("No advertisements heard. Is Bluetooth on and the permission granted? Try `blescan --diag`."))
        return
    }
    print("")
    for line in renderTable(devices, cols: termSize().cols, now: t, history: [:], selectedID: nil) { print(line) }
}

/// `--stream`: NDJSON on stdout for as long as the process runs (or `window` seconds). One
/// line per device per packet, throttled to at most one line per device per second so a
/// chatty beacon (allow-duplicates delivers every packet, tens a second) can't flood the
/// pipe; a silent device produces nothing. Each line is the `--json` object plus `ts`.
func runStream(app: App, window: TimeInterval?) {
    setvbuf(stdout, nil, _IOLBF, 0)   // a pipe is block-buffered by default: flush per line
    app.wireRadio()
    app.radio.start()
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let start = now()
    var writtenAt: [String: Double] = [:]        // id → when we last wrote it
    var writtenSeen: [String: Double] = [:]      // id → the lastSeen that line carried
    while true {
        let t = now()
        if let w = window, t - start >= w { break }
        let state = app.snapshotState()
        if state == .poweredOff || state == .unauthorized || state == .unsupported { failIfNeverScanned(app) }
        app.prune(at: t, drop: 60)
        let live = app.snapshotDevices(at: t)
        for d in live where d.lastSeen > (writtenSeen[d.id] ?? -1) && t - (writtenAt[d.id] ?? -1) >= 1 {
            let row = DeviceJSON(d, now: t, ts: iso.string(from: Date()))
            if let data = try? enc.encode(row), let s = String(data: data, encoding: .utf8) { print(s) }
            writtenAt[d.id] = t; writtenSeen[d.id] = d.lastSeen
        }
        // Forget bookkeeping for pruned devices; a long stream sees endless rotating ids.
        if writtenAt.count > live.count * 2 + 16 {
            let ids = Set(live.map { $0.id })
            writtenAt = writtenAt.filter { ids.contains($0.key) }
            writtenSeen = writtenSeen.filter { ids.contains($0.key) }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    app.radio.stop()
    failIfNeverScanned(app)
}

func runDiag(app: App, window: TimeInterval) {
    let devices = collect(app: app, window: window)
    let named = devices.filter { $0.isNamed }.count
    let state = app.snapshotState(), auth = app.radio.authorization
    print("blescan diagnostics")
    print("  version            : \(blescanVersion)")
    print("  adapter state      : \(stateLabel(state))")
    print("  permission         : \(authLabel(auth))")
    print("  devices found      : \(devices.count)")
    print("  named devices      : \(named)/\(devices.count)")
    print("  truecolor terminal : \(Term.truecolor)")
    if state == .unauthorized || auth == .denied || auth == .restricted {
        print("")
        print("  ⚠ Bluetooth permission isn't granted for blescan.")
        print("    System Settings → Privacy & Security → Bluetooth → enable 'blescan'.")
    } else if state == .poweredOff {
        print("")
        print("  ⚠ Bluetooth is powered off — turn it on to scan.")
    }
}

// MARK: - Entry

/// CFBundleShortVersionString from the Info.plist the Makefile embeds into the Mach-O
/// (`-sectcreate __TEXT __info_plist`); a plain `swift build` has no plist, hence "dev".
let blescanVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

func printHelp() {
    print("""
    blescan — live Bluetooth Low Energy scanner & fingerprinter (macOS, CoreBluetooth)

    USAGE:
      blescan            interactive TUI (default)
      blescan --once     scan, print the device table, then exit
      blescan --json     scan, emit the devices as a JSON array on stdout
      blescan --stream   emit NDJSON — one line per device per packet (≤ 1 line/device/s)
                         — until killed, or for --window seconds
      blescan --diag     print adapter / permission diagnostics
      blescan --version  print the version  (also -V)
      blescan --help     show this help  (also -h)

    OPTIONS:
      --window N         seconds to scan in the headless modes (default 6; 3 for --diag;
                         unbounded for --stream). Also --window=N.

    --json and --stream exit 3 (with a line on stderr) when the adapter never powered on,
    so an empty result from a quiet room is distinguishable from a scan that never happened.

    Colour is automatic: on in a terminal, off when piped/redirected (or set NO_COLOR).

    TUI KEYS:
      q / Ctrl-C / Ctrl-D quit · j/k (or ↑/↓) select · p/n/v/t/g/r sort (again to reverse)
      c connectable-only · u named-only · / filter (Enter apply, Esc clear) · ? help
      mouse: wheel selects · click a header to sort · click a row to inspect
    """)
}

func main() {
    let opts: Options
    switch parseArguments(Array(CommandLine.arguments.dropFirst())) {
    case .success(let o): opts = o
    case .failure(let e): writeStderr(e.message); exit(2)
    }

    Ansi.enabled = ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(STDOUT_FILENO) != 0

    let app = App()
    switch opts.mode {
    case .help:    printHelp()
    case .version: print("blescan \(blescanVersion)")
    case .diag:    runDiag(app: app, window: opts.window ?? 3.0)
    case .json:    runOnce(app: app, window: opts.window ?? 6.0, json: true)
    case .once:    runOnce(app: app, window: opts.window ?? 6.0, json: false)
    case .stream:  runStream(app: app, window: opts.window)
    case .tui:
        // The interactive TUI needs a real terminal to draw to AND to read keys from. If
        // either end is piped/redirected there's nowhere to render or no blocking key read
        // (a non-tty stdin returns EOF immediately and would spin the loop at 100% CPU) —
        // point the user at the headless modes instead.
        if isatty(STDOUT_FILENO) == 0 || isatty(STDIN_FILENO) == 0 {
            writeStderr("blescan: the interactive TUI needs a terminal on stdin and stdout — use --once, --json or --stream when piping.")
            exit(1)
        }
        if opts.window != nil {
            writeStderr("blescan: --window only applies to the headless modes (--once, --json, --stream, --diag).")
            exit(2)
        }
        runInteractive(app: app)
    }
}

main()
