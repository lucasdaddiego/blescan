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

    private(set) var state: CBManagerState = .unknown

    func start() {
        // ShowPowerAlert surfaces the system "Bluetooth is off" alert if appropriate.
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func stop() {
        if central?.isScanning == true { central.stopScan() }
    }

    /// Current Bluetooth authorization (TCC). Uses the live manager once it exists, else
    /// the type-level value (valid before the manager is created — e.g. in --diag).
    var authorization: CBManagerAuthorization {
        central?.authorization ?? CBCentralManager.authorization
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
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
    let serviceData = (adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
        .map { ServiceDatum(uuid: normalizeUUID($0.key.uuidString), bytes: [UInt8]($0.value)) } ?? []
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
        firstSeen: 0, lastSeen: 0)   // timestamps stamped by App.ingest
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

/// Monotonic-ish seconds for ageing (wall clock is fine here — only deltas are used).
func now() -> Double { Date().timeIntervalSince1970 }

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
    static func reverse(_ s: String) -> String { wrap(s, "7") }
    static func fg256(_ s: String, _ c: Int) -> String { wrap(s, "38;5;\(c)") }
    static func bg256(_ s: String, _ c: Int) -> String { wrap(s, "48;5;\(c)") }
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
/// sequences verbatim and re-appending a reset if truncated.
private func clipAnsi(_ s: String, _ cols: Int) -> String {
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
private func tableColWidths(_ cols: Int) -> (name: Int, vendor: Int, type: Int, dbm: Int,
                                             bar: Int, prox: Int, conn: Int, age: Int, trend: Int) {
    let vendor = 16, type = 18, dbm = 5, bar = 10, prox = 9, conn = 4, age = 4
    let trend = cols >= 104 ? App.historyLen : 0
    let nCols = trend > 0 ? 9 : 8
    let fixed = vendor + type + dbm + bar + prox + conn + age + trend + (nCols - 1)
    let name = max(14, min(30, cols - fixed))
    return (name, vendor, type, dbm, bar, prox, conn, age, trend)
}

/// x-ranges (1-based screen columns) of each header cell paired with the sort key a
/// click selects. Order mirrors renderTable's columns.
func tableSortRegions(_ cols: Int) -> [(range: ClosedRange<Int>, key: SortKey)] {
    let w = tableColWidths(cols)
    var order: [(Int, SortKey)] = [
        (w.name, .name), (w.vendor, .vendor), (w.type, .type), (w.dbm, .rssi),
        (w.bar, .rssi), (w.prox, .rssi), (w.conn, .rssi), (w.age, .age),
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

/// Render the device table. Returns the lines (header first) plus the device id rendered
/// on each data line (for click-to-select). `selectedID` highlights its row.
private func renderTable(_ devices: [Device], cols: Int, now t: Double,
                         history: [String: [Int]], selectedID: String?) -> (lines: [String], ids: [String]) {
    let w = tableColWidths(cols)
    var out: [String] = []
    var ids: [String] = []

    var header = [
        padTo("Name", w.name), padTo("Vendor", w.vendor), padTo("Type", w.type),
        padLeft("dBm", w.dbm), padTo("Signal", w.bar), padTo("Prox", w.prox),
        padTo("Conn", w.conn), padLeft("Age", w.age),
    ]
    if w.trend > 0 { header.append(padTo("Trend", w.trend)) }
    out.append(Ansi.bold(Ansi.fg256(header.joined(separator: " "), Pal.text)))

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
        var cells = [name, vendor, type, dbm, bar, prox, conn, age]
        if w.trend > 0 {
            let samples = history[d.id] ?? [d.rssi]
            let spark = sparkline(samples)
            let padded = String(repeating: " ", count: max(0, w.trend - displayWidth(spark))) + spark
            cells.append(d.hasValidRSSI ? Ansi.signalColored(padded, d.rssi) : Ansi.dim(padded))
        }
        var row = cells.joined(separator: " ")
        if d.id == selectedID { row = Ansi.bg256(clipAnsi(row, cols), Pal.selectBg) }
        out.append(row)
        ids.append(d.id)
    }
    return (out, ids)
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
    out.append(field("signal", sig))

    out.append(field("vendor", "\(sanitizeName(d.vendor))   " + Ansi.dim("type ") + d.typeLabel))

    let services = (d.serviceUUIDs + d.serviceData.map { $0.uuid }).map(friendlyService)
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
    var spinnerTick = 0

    // --- render cache (main-thread-confined) ---
    var lastFrame = ""
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
        if var e = devices[d.id] {
            if let n = d.name { e.name = n }                  // keep the last name we heard
            e.rssi = d.rssi
            if let tx = d.txPower { e.txPower = tx }
            if let c = d.connectable { e.connectable = c }
            if !d.manufacturerData.isEmpty { e.manufacturerData = d.manufacturerData }
            if !d.serviceUUIDs.isEmpty { e.serviceUUIDs = d.serviceUUIDs }
            if !d.serviceData.isEmpty { e.serviceData = d.serviceData }
            if !d.solicitedUUIDs.isEmpty { e.solicitedUUIDs = d.solicitedUUIDs }
            if !d.overflowUUIDs.isEmpty { e.overflowUUIDs = d.overflowUUIDs }
            e.lastSeen = t
            devices[d.id] = e
        } else {
            var nd = d; nd.firstSeen = t; nd.lastSeen = t
            devices[d.id] = nd
        }
        // Throttle the sparkline history to ~1 Hz per device so the trace spans seconds,
        // not the sub-second burst rate allow-duplicates delivers.
        if t - (lastHist[d.id] ?? 0) >= 1.0 {
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
        for id in dead { devices[id] = nil; history[id] = nil; lastHist[id] = nil }
        generation += 1
        return true
    }

    func setState(_ s: CBManagerState) { lock.lock(); radioState = s; generation += 1; lock.unlock() }
    func markDirty() { lock.lock(); generation += 1; lock.unlock() }
    func readGeneration() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
    func snapshotState() -> CBManagerState { lock.lock(); defer { lock.unlock() }; return radioState }
    func snapshotDevices() -> [Device] { lock.lock(); defer { lock.unlock() }; return Array(devices.values) }
    func deviceCount() -> Int { lock.lock(); defer { lock.unlock() }; return devices.count }
    func historyCopy() -> [String: [Int]] { lock.lock(); defer { lock.unlock() }; return history }

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

private func writeRaw(_ s: String) {
    var bytes = Array(s.utf8)
    _ = write(STDOUT_FILENO, &bytes, bytes.count)
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
    writeRaw("\u{1B}[?1006l\u{1B}[?1000l\u{1B}[?25h\u{1B}[?1049l\u{1B}[23;2t")
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
}

struct MouseEvent { let button: Int; let col: Int; let row: Int; let press: Bool }
enum Input { case key(Character), mouse(MouseEvent), none }

private func readByte() -> UInt8? {
    var b: UInt8 = 0
    return read(STDIN_FILENO, &b, 1) == 1 ? b : nil
}

private func readInput() -> Input {
    guard let b = readByte() else { return .none }
    if b != 0x1B {
        return b < 0x80 ? .key(Character(UnicodeScalar(b))) : .none
    }
    guard let b1 = readByte() else { return .key("\u{1B}") }   // lone Esc
    guard b1 == 0x5B /* [ */ else { _ = readByte(); return .none }
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
    // Arrow keys: ESC [ A/B/C/D → map to navigation chars.
    if let final = body.last {
        switch final {
        case 0x41: return .key("k")   // up
        case 0x42: return .key("j")   // down
        default: break
        }
    }
    return .none
}

// MARK: - Interactive loop

func runInteractive(app: App) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in leaveRaw(); _exit(0) }
    }
    atexit { leaveRaw() }
    enterRaw()

    app.wireRadio()
    app.radio.start()

    var lastGen = -1, lastCols = 0, lastRows = 0, lastPrune = now()

    while !app.quit {
        let t = now()
        if t - lastPrune >= 1.0 { app.prune(at: t, drop: 60); lastPrune = t }

        let sz = termSize()
        let gen = app.readGeneration()
        let scanning = app.snapshotState() == .poweredOn
        if scanning { app.spinnerTick &+= 1 }
        if gen != lastGen || sz.cols != lastCols || sz.rows != lastRows || scanning {
            draw(app)
            lastGen = gen; lastCols = sz.cols; lastRows = sz.rows
        }
        switch readInput() {
        case .key(let k):   handleKey(k, app: app)
        case .mouse(let m): handleMouse(m, app: app)
        case .none:         break
        }
    }
    app.radio.stop()
    leaveRaw()
}

private func moveSelection(_ app: App, _ delta: Int) {
    let vis = app.visible(app.snapshotDevices())
    guard !vis.isEmpty else { app.selectedID = nil; return }
    let idx = vis.firstIndex { $0.id == app.selectedID } ?? 0
    let next = max(0, min(vis.count - 1, idx + delta))
    app.selectedID = vis[next].id
}

func handleKey(_ k: Character, app: App) {
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
    case "q", "\u{04}", "\u{03}": app.quit = true          // q / Ctrl-D / Ctrl-C
    case "j": moveSelection(app, 1)
    case "k": moveSelection(app, -1)
    case "p": setSort(app, .rssi)
    case "n": setSort(app, .name)
    case "v": setSort(app, .vendor)
    case "t": setSort(app, .type)
    case "g": setSort(app, .age)
    case "c": app.connectableOnly.toggle()
    case "u": app.namedOnly.toggle()
    case "/": app.filterEditing = true
    case "\u{1B}": app.filter = ""                          // Esc clears an active filter
    default: break
    }
    app.markDirty()
}

func handleMouse(_ m: MouseEvent, app: App) {
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
    let all = app.snapshotDevices()
    let visible = app.visible(all)
    let state = app.snapshotState()

    if Ansi.enabled {
        let title = "blescan — \(all.count) BLE devices"
        if title != app.lastTitle { app.lastTitle = title; print("\u{1B}]2;\(title)\u{07}", terminator: "") }
    }

    // Resolve the selection (default to the first visible device).
    if app.selectedID == nil || !visible.contains(where: { $0.id == app.selectedID }) {
        app.selectedID = visible.first?.id
    }

    var lines: [String] = []

    // Header.
    let spinner = spinnerFrames[app.spinnerTick % spinnerFrames.count]
    let scanTag = state == .poweredOn ? Ansi.fg256(" \(spinner) scanning…", Pal.scanning) : ""
    let auth = authLabel(app.radio.authorization)
    let head1 = Ansi.bg256(Ansi.bold(Ansi.fg256("  blescan  ", Pal.badgeFg)), Pal.badgeBg)
        + " " + Ansi.fg256("adapter ", Pal.label)
        + Ansi.fg256(stateLabel(state), state == .poweredOn ? Pal.accent : Pal.warn)
        + Ansi.fg256("  permission ", Pal.label)
        + Ansi.fg256(auth, auth == "authorized" ? Pal.accent : Pal.warn)
        + scanTag
    lines.append(clipAnsi(head1, layout.cols))

    let head2 = Ansi.fg256("devices ", Pal.label) + Ansi.bold("\(all.count)")
        + Ansi.fg256("  shown ", Pal.label) + "\(visible.count)"
        + Ansi.fg256("  sort ", Pal.label) + app.sortKey.label + (app.ascending ? "↑" : "↓")
        + Ansi.fg256("  conn-only ", Pal.label) + (app.connectableOnly ? "on" : "off")
        + Ansi.fg256("  named-only ", Pal.label) + (app.namedOnly ? "on" : "off")
        + Ansi.fg256("  last ", Pal.label) + timeFormatter.string(from: Date())
    lines.append(clipAnsi(head2, layout.cols))
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 140))))

    // Permission / power guidance.
    if state == .unauthorized || auth == "denied" || auth == "restricted" {
        lines.append(clipAnsi(Ansi.fg256("⚠ Bluetooth permission not granted for blescan.", Pal.warn), layout.cols))
        lines.append(clipAnsi(Ansi.dim("  Enable 'blescan' in System Settings → Privacy & Security → Bluetooth, then rerun."), layout.cols))
    } else if state == .poweredOff {
        lines.append(clipAnsi(Ansi.fg256("⚠ Bluetooth is powered off — turn it on to scan.", Pal.warn), layout.cols))
    } else if state == .unsupported {
        lines.append(clipAnsi(Ansi.fg256("⚠ This Mac reports no Bluetooth LE support.", Pal.error), layout.cols))
    } else if all.isEmpty {
        lines.append(clipAnsi(Ansi.dim("Listening for advertisements…"), layout.cols))
    }

    // Filter edit / active filter line.
    if app.filterEditing {
        lines.append(clipAnsi(Ansi.fg256("filter: ", Pal.label) + app.filter + Ansi.fg256("▏", Pal.accent)
            + Ansi.dim("   (type to filter name/vendor/type · Enter to apply · Esc to clear)"), layout.cols))
    } else if !app.filter.isEmpty {
        lines.append(clipAnsi(Ansi.fg256("filter: ", Pal.label) + app.filter + Ansi.dim("   (Esc to clear)"), layout.cols))
    }

    // Body layout: detail pane takes a bounded share of the screen, table gets the rest.
    let footer = footerLines()
    let detail = app.selectedID.flatMap { id in visible.first { $0.id == id } }
        .map { renderDetail($0, cols: layout.cols, now: t) } ?? []
    let detailShown = Array(detail.prefix(min(detail.count, max(6, layout.rows / 3))))
    let chrome = lines.count + footer.count + (detailShown.isEmpty ? 0 : detailShown.count + 1) + 1
    let tableBudget = max(3, layout.rows - chrome)

    let (tableLines, ids) = renderTable(visible, cols: layout.cols, now: t,
                                        history: app.historyCopy(), selectedID: app.selectedID)
    let headerRow = tableLines.first
    let dataRows = Array(tableLines.dropFirst())
    let viewport = max(1, tableBudget - 1)   // minus the header row

    // Scroll so the selected row stays visible.
    let selIdx = app.selectedID.flatMap { sid in ids.firstIndex(of: sid) } ?? 0
    if selIdx < app.scroll { app.scroll = selIdx }
    if selIdx >= app.scroll + viewport { app.scroll = selIdx - viewport + 1 }
    let maxScroll = max(0, dataRows.count - viewport)
    app.scroll = min(max(0, app.scroll), maxScroll)

    if let h = headerRow {
        app.headerScreenRow = lines.count + 1
        app.sortRegions = tableSortRegions(layout.cols)
        lines.append(h)
        app.rowScreenStart = lines.count + 1
    }
    let shownData = Array(dataRows.dropFirst(app.scroll).prefix(viewport))
    app.rowIDs = Array(ids.dropFirst(app.scroll).prefix(viewport))
    lines.append(contentsOf: shownData)

    // Pad so the bottom chrome sits flush at the bottom.
    let used = lines.count + (detailShown.isEmpty ? 0 : detailShown.count + 1) + 1 + footer.count
    if used < layout.rows { lines.append(contentsOf: Array(repeating: "", count: layout.rows - used)) }
    if !detailShown.isEmpty {
        lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 140))))
        lines.append(contentsOf: detailShown)
    }
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 140))))
    lines.append(contentsOf: footer.map { clipAnsi($0, layout.cols) })

    // Paint with synchronized output + frame diffing.
    let painted = Array(lines.prefix(layout.rows))
    let sizeChanged = (layout.cols != app.lastCols || layout.rows != app.lastRows)
    var screen = sizeChanged ? "\u{1B}[2J\u{1B}[H" : "\u{1B}[H"
    screen += painted.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n")
    screen += "\u{1B}[J"
    if screen == app.lastFrame && !sizeChanged { return }
    app.lastFrame = screen
    app.lastCols = layout.cols
    app.lastRows = layout.rows
    print("\u{1B}[?2026h" + screen + "\u{1B}[?2026l", terminator: "")
    fflush(stdout)
}

func footerLines() -> [String] {
    let keys = "[q]uit  [j/k]select  [p]ower [n]ame [v]endor [t]ype a[g]e sort  [c]onn-only [u]named-only  [/]filter  ·  mouse: wheel selects, click a header to sort, click a row to inspect"
    return [Ansi.dim(keys)]
}

// MARK: - Non-interactive collection (--once / --json / --diag)

/// Start the radio and block `window` seconds while the BLE queue accumulates devices,
/// then return the snapshot. A short initial grace lets the adapter reach poweredOn.
private func collect(app: App, window: TimeInterval) -> [Device] {
    app.wireRadio()
    app.radio.start()
    let deadline = Date().addingTimeInterval(window)
    while Date() < deadline {
        app.prune(at: now(), drop: 120)
        Thread.sleep(forTimeInterval: 0.1)
    }
    app.radio.stop()
    return app.snapshotDevices()
}

func runOnce(app: App, window: TimeInterval, json: Bool) {
    let devices = sortDevices(collect(app: app, window: window), by: app.sortKey, ascending: app.ascending)
    if json {
        struct Out: Encodable {
            let id: String; let name: String?; let rssi: Int; let txPower: Int?
            let connectable: Bool?; let vendor: String; let type: String
            let proximity: String; let services: [String]
            let manufacturerHex: String?
        }
        let arr = devices.map { d -> Out in
            Out(id: d.id, name: d.name, rssi: d.rssi, txPower: d.txPower, connectable: d.connectable,
                vendor: d.vendor, type: d.typeLabel, proximity: d.proximityBucket.label,
                services: (d.serviceUUIDs + d.serviceData.map { $0.uuid }).map(friendlyService),
                manufacturerHex: d.manufacturerData.isEmpty ? nil : hexString(d.manufacturerData))
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(arr), let s = String(data: data, encoding: .utf8) { print(s) } else { print("[]") }
        return
    }
    print(Ansi.bold("blescan — \(devices.count) BLE devices  (adapter \(stateLabel(app.snapshotState())), permission \(authLabel(app.radio.authorization)))"))
    if devices.isEmpty {
        print(Ansi.dim("No advertisements heard. Is Bluetooth on and the permission granted? Try `blescan --diag`."))
        return
    }
    print("")
    let t = now()
    let (lines, _) = renderTable(devices, cols: termSize().cols, now: t, history: [:], selectedID: nil)
    for line in lines { print(line) }
}

func runDiag(app: App) {
    let devices = collect(app: app, window: 3.0)
    let named = devices.filter { $0.isNamed }.count
    print("blescan diagnostics")
    print("  adapter state      : \(stateLabel(app.snapshotState()))")
    print("  permission         : \(authLabel(app.radio.authorization))")
    print("  devices found      : \(devices.count)")
    print("  named devices      : \(named)/\(devices.count)")
    print("  truecolor terminal : \(Term.truecolor)")
    if app.snapshotState() == .unauthorized || authLabel(app.radio.authorization) == "denied" {
        print("")
        print("  ⚠ Bluetooth permission isn't granted for blescan.")
        print("    System Settings → Privacy & Security → Bluetooth → enable 'blescan'.")
    } else if app.snapshotState() == .poweredOff {
        print("")
        print("  ⚠ Bluetooth is powered off — turn it on to scan.")
    }
}

// MARK: - Entry

func printHelp() {
    print("""
    blescan — live Bluetooth Low Energy scanner & fingerprinter (macOS, CoreBluetooth)

    USAGE:
      blescan            interactive TUI (default)
      blescan --once     scan ~6s, print the device table, then exit
      blescan --json     scan ~6s, emit the devices as JSON on stdout
      blescan --diag     print adapter / permission diagnostics
      blescan --help     show this help  (also -h)

    Colour is automatic: on in a terminal, off when piped/redirected (or set NO_COLOR).

    TUI KEYS:
      q / Ctrl-C / Ctrl-D quit · j/k (or ↑/↓) select · p/n/v/t/g sort (again to reverse)
      c connectable-only · u named-only · / filter (Enter apply, Esc clear)
      mouse: wheel selects · click a header to sort · click a row to inspect
    """)
}

func main() {
    let args = CommandLine.arguments
    if args.contains("--help") || args.contains("-h") { printHelp(); return }

    let known: Set<String> = ["--once", "--json", "--diag"]
    for a in args.dropFirst() where !known.contains(a) {
        FileHandle.standardError.write(Data("error: unknown option '\(a)' (see --help)\n".utf8))
        exit(2)
    }

    Ansi.enabled = ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(STDOUT_FILENO) != 0

    let app = App()
    if args.contains("--diag") { runDiag(app: app); return }
    if args.contains("--json") { runOnce(app: app, window: 6.0, json: true); return }
    if args.contains("--once") { runOnce(app: app, window: 6.0, json: false); return }

    // The interactive TUI needs a real terminal to draw to and read keys from. When
    // piped/redirected there's nowhere to render — point the user at the headless modes.
    if isatty(STDOUT_FILENO) == 0 {
        FileHandle.standardError.write(Data("blescan: the interactive TUI needs a terminal — use --once or --json when piping.\n".utf8))
        exit(1)
    }
    runInteractive(app: app)
}

main()
