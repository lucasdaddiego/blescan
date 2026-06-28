// blescan — pure, framework-free core (BLE advertisement model, vendor / service /
// beacon fingerprinting, proximity model, colour, text layout). Deliberately free of
// CoreBluetooth so it compiles and unit-tests standalone with plain `swiftc` (see
// Tests/CoreTests.swift / `make test`). main.swift holds CoreBluetooth, the TUI, and
// the entrypoint.
//
// The data we model is exactly what a BLE advertisement carries — and, importantly,
// what macOS will *let a third party see*. Unlike a LAN scanner there is NO hardware
// MAC: macOS privacy-randomises BLE addresses and never exposes them, handing back a
// host-stable CBPeripheral.identifier UUID instead. So "vendor" can't come from an OUI
// table the way lanscan does it — it comes from the advertisement itself: the 2-byte
// company identifier inside manufacturer data, and the advertised service UUIDs.

import Foundation

// MARK: - Model

/// One service-data entry: a service UUID and the bytes advertised under it.
struct ServiceDatum {
    var uuid: String     // normalised (short "FEAA" form when derived from the BT base UUID)
    var bytes: [UInt8]
}

/// A live device row, built from a CBPeripheral + its advertisementData dict. Holds the
/// raw advertised fields; all fingerprinting is derived (computed) from them so the same
/// values that render in the table also hex-dump verbatim in the detail pane.
struct Device {
    var id: String                    // CBPeripheral.identifier UUID (host-stable, NOT a MAC)
    var name: String?                 // advertised local name (or the peripheral's GAP name)
    var rssi: Int                     // dBm; 127 is CoreBluetooth's "unavailable" sentinel
    var txPower: Int?                 // GAP TX Power Level (dBm), if advertised
    var connectable: Bool?            // CBAdvertisementDataIsConnectable, if present
    var manufacturerData: [UInt8]     // raw, including the leading 2-byte company id
    var serviceUUIDs: [String]        // normalised service UUIDs
    var serviceData: [ServiceDatum]
    var solicitedUUIDs: [String]
    var overflowUUIDs: [String]
    var firstSeen: Double             // epoch seconds
    var lastSeen: Double              // epoch seconds

    // --- derived fingerprint (pure functions of the fields above) ---

    /// Little-endian 2-byte company identifier from manufacturer data, if present.
    var companyId: UInt16? { companyIdentifier(manufacturerData) }

    /// Human vendor label: a curated SIG company name, else the raw `0xXXXX` id, else "—".
    var vendor: String { vendorLabel(companyId) }

    /// Parsed iBeacon (Apple manufacturer-data layout `4C 00 02 15 …`), if this is one.
    var iBeacon: IBeacon? { parseIBeacon(manufacturerData) }

    /// Parsed Eddystone frame from the 0xFEAA service-data entry, if present.
    var eddystone: Eddystone? {
        guard let d = serviceData.first(where: { normalizeUUID($0.uuid) == "FEAA" }) else { return nil }
        return parseEddystone(d.bytes)
    }

    /// Apple "Continuity" advertisement segment types present (iBeacon, AirPods, Find My …).
    var continuityTypes: [UInt8] { appleSegmentTypes(manufacturerData) }

    /// Service UUIDs in their normalised short form, as a set for quick membership tests.
    var serviceShortSet: Set<String> {
        Set((serviceUUIDs + serviceData.map { $0.uuid } + solicitedUUIDs + overflowUUIDs).map(normalizeUUID))
    }

    /// Best-guess device category from services + manufacturer signature.
    var typeLabel: String {
        inferDeviceType(serviceShortUUIDs: serviceShortSet, companyId: companyId,
                        iBeacon: iBeacon != nil, eddystone: eddystone != nil,
                        continuityTypes: Set(continuityTypes), name: name)
    }

    /// Calibrated RSSI at 1 m for ranging, when the advertisement provides a reference:
    /// iBeacon carries a 1 m measured-power byte directly; Eddystone carries a 0 m TX
    /// power, which the spec says to offset by ~41 dB to estimate the 1 m value. The bare
    /// GAP TX Power Level is the radiated power, not a 1 m reference, so it is NOT used
    /// here (we fall back to RSSI thresholds instead — see `proximity`).
    var calibratedRSSIAt1m: Int? {
        if let b = iBeacon { return b.measuredPower }
        if let e = eddystone, let tx = e.txPower { return tx - 41 }
        return nil
    }

    /// Proximity bucket (immediate / near / far / unknown) from RSSI + any 1 m reference.
    var proximityBucket: Proximity { proximity(rssi: rssi, calibratedRSSIAt1m: calibratedRSSIAt1m) }

    /// Seconds since this device was last heard from, given a reference "now".
    func age(now: Double) -> Double { max(0, now - lastSeen) }

    /// Name for display — the advertised name, or a dim placeholder when unnamed.
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return "(unnamed)"
    }

    var isNamed: Bool { name?.isEmpty == false }
    var hasValidRSSI: Bool { rssi < 0 && rssi > -127 }
}

// MARK: - Manufacturer data

/// Little-endian company identifier (first two bytes) of a manufacturer-data blob.
func companyIdentifier(_ raw: [UInt8]) -> UInt16? {
    guard raw.count >= 2 else { return nil }
    return UInt16(raw[0]) | (UInt16(raw[1]) << 8)
}

/// Manufacturer-specific payload — the bytes after the 2-byte company id.
func manufacturerPayload(_ raw: [UInt8]) -> [UInt8] {
    raw.count > 2 ? Array(raw[2...]) : []
}

/// Vendor label for a company id: the curated SIG name, else the raw hex id, else "—"
/// for no manufacturer data at all. Unknown ids are shown honestly as `0xXXXX` rather
/// than guessed — there is no OUI fallback on macOS (see the file header).
func vendorLabel(_ id: UInt16?) -> String {
    guard let id = id else { return "—" }
    return companyName(id) ?? String(format: "0x%04X", id)
}

// MARK: - iBeacon

/// A decoded iBeacon: proximity UUID + major/minor + the 1 m measured power (dBm).
struct IBeacon: Equatable {
    var uuid: String
    var major: UInt16
    var minor: UInt16
    var measuredPower: Int
}

/// Parse Apple's iBeacon layout out of manufacturer data (company 0x004C, type 0x02,
/// length 0x15, then 16-byte UUID, big-endian major, big-endian minor, 1-byte power).
func parseIBeacon(_ raw: [UInt8]) -> IBeacon? {
    guard raw.count >= 25,
          raw[0] == 0x4C, raw[1] == 0x00,    // Apple company id, little-endian
          raw[2] == 0x02, raw[3] == 0x15     // iBeacon type + length
    else { return nil }
    let uuid = formatUUID(Array(raw[4..<20]))
    let major = UInt16(raw[20]) << 8 | UInt16(raw[21])
    let minor = UInt16(raw[22]) << 8 | UInt16(raw[23])
    let power = Int(Int8(bitPattern: raw[24]))
    return IBeacon(uuid: uuid, major: major, minor: minor, measuredPower: power)
}

// MARK: - Apple Continuity

/// The Apple "Continuity" protocol packs several typed segments into manufacturer data
/// (TLV: type, length, value…). We walk it to surface which segments are present —
/// iBeacon, AirPods proximity pairing, Handoff, Find My, Nearby, … — which is a strong
/// device-type signal even though the payloads themselves are largely undocumented.
func appleSegmentTypes(_ raw: [UInt8]) -> [UInt8] {
    guard raw.count >= 2, raw[0] == 0x4C, raw[1] == 0x00 else { return [] }
    var types: [UInt8] = []
    var i = 2
    // Each segment is at least type+length (2 bytes); `i` advances ≥2 per iteration, so
    // a malformed length can truncate the walk but never spin it.
    while i + 1 < raw.count {
        types.append(raw[i])
        i += 2 + Int(raw[i + 1])
    }
    return types
}

/// Friendly name for an Apple Continuity segment type, or nil for an unrecognised one.
func continuityName(_ type: UInt8) -> String? {
    switch type {
    case 0x02: return "iBeacon"
    case 0x05: return "AirDrop"
    case 0x07: return "AirPods / Proximity Pairing"
    case 0x08: return "Hey Siri"
    case 0x09: return "AirPlay Target"
    case 0x0A: return "AirPlay Source"
    case 0x0B: return "Magic Switch (Apple Watch)"
    case 0x0C: return "Handoff"
    case 0x0D: return "Tethering Target"
    case 0x0E: return "Tethering Source"
    case 0x0F: return "Nearby Action"
    case 0x10: return "Nearby Info"
    case 0x12: return "Find My"
    default:   return nil
    }
}

// MARK: - Eddystone

/// A decoded Eddystone frame (Google's open beacon format, carried in 0xFEAA service data).
enum Eddystone: Equatable {
    case uid(txPower: Int, namespace: String, instance: String)
    case url(txPower: Int, url: String)
    case tlm(battery: Int, temperature: Double, advCount: UInt32, uptimeDeciseconds: UInt32)
    case eid(txPower: Int, eid: String)

    /// Calibrated TX power at 0 m (UID/URL/EID frames); TLM carries no ranging reference.
    var txPower: Int? {
        switch self {
        case .uid(let t, _, _), .url(let t, _), .eid(let t, _): return t
        case .tlm: return nil
        }
    }

    /// One-line description for the table / detail pane.
    var summary: String {
        switch self {
        case .uid(_, let ns, let inst): return "Eddystone-UID \(ns)/\(inst)"
        case .url(_, let url):          return "Eddystone-URL \(url)"
        case .tlm(let batt, let temp, let cnt, let up):
            return String(format: "Eddystone-TLM %dmV %.1f°C cnt=%u up=%.0fs",
                          batt, temp, cnt, Double(up) / 10.0)
        case .eid(_, let eid):          return "Eddystone-EID \(eid)"
        }
    }
}

/// Parse one Eddystone frame from a 0xFEAA service-data blob (frame type in byte 0).
func parseEddystone(_ d: [UInt8]) -> Eddystone? {
    guard let frame = d.first else { return nil }
    switch frame {
    case 0x00:   // UID: frame, txPower, 10-byte namespace, 6-byte instance, (2 RFU)
        guard d.count >= 18 else { return nil }
        return .uid(txPower: Int(Int8(bitPattern: d[1])),
                    namespace: hexString(Array(d[2..<12])),
                    instance: hexString(Array(d[12..<18])))
    case 0x10:   // URL: frame, txPower, scheme prefix, encoded URL
        guard d.count >= 3 else { return nil }
        return .url(txPower: Int(Int8(bitPattern: d[1])),
                    url: decodeEddystoneURL(scheme: d[2], Array(d[3...])))
    case 0x20:   // TLM: frame, version, battery(2), temp(2 8.8), advCount(4), uptime(4)
        guard d.count >= 14 else { return nil }
        let battery = Int(UInt16(d[2]) << 8 | UInt16(d[3]))
        let tempRaw = Int16(bitPattern: UInt16(d[4]) << 8 | UInt16(d[5]))
        let count = UInt32(d[6]) << 24 | UInt32(d[7]) << 16 | UInt32(d[8]) << 8 | UInt32(d[9])
        let uptime = UInt32(d[10]) << 24 | UInt32(d[11]) << 16 | UInt32(d[12]) << 8 | UInt32(d[13])
        return .tlm(battery: battery, temperature: Double(tempRaw) / 256.0,
                    advCount: count, uptimeDeciseconds: uptime)
    case 0x30:   // EID: frame, txPower, 8-byte ephemeral id
        guard d.count >= 10 else { return nil }
        return .eid(txPower: Int(Int8(bitPattern: d[1])), eid: hexString(Array(d[2..<10])))
    default:
        return nil
    }
}

/// Expand an Eddystone-URL: a 1-byte scheme prefix + bytes where 0x00–0x0D are URL
/// shorthands (`.com/`, `.org`, …) and the rest are literal ASCII.
func decodeEddystoneURL(scheme: UInt8, _ body: [UInt8]) -> String {
    let prefixes = ["http://www.", "https://www.", "http://", "https://"]
    let expansions = [".com/", ".org/", ".edu/", ".net/", ".info/", ".biz/", ".gov/",
                      ".com", ".org", ".edu", ".net", ".info", ".biz", ".gov"]
    var s = scheme < UInt8(prefixes.count) ? prefixes[Int(scheme)] : ""
    for b in body {
        if b < UInt8(expansions.count) {
            s += expansions[Int(b)]
        } else if b >= 0x20 && b < 0x7F {
            s.append(Character(UnicodeScalar(b)))
        } else {
            s += String(format: "%%%02X", b)   // non-printable → percent-escape, kept inert
        }
    }
    return s
}

// MARK: - Device-type inference

/// Best-guess device category, most-specific signal first. Beacons and trackers are
/// recognised by their manufacturer/service signature; everything else falls back to the
/// primary GATT service it advertises, then to a generic label.
func inferDeviceType(serviceShortUUIDs: Set<String>, companyId: UInt16?, iBeacon: Bool,
                     eddystone: Bool, continuityTypes: Set<UInt8>, name: String?) -> String {
    func has(_ u: String) -> Bool { serviceShortUUIDs.contains(u) }

    if iBeacon { return "iBeacon" }
    if eddystone { return "Eddystone beacon" }
    if has("FEED") || has("FEEC") { return "Tile tracker" }
    if has("FD6F") { return "Exposure Notification" }
    if has("FE2C") { return "Google Fast Pair" }

    // Apple Continuity signatures (only meaningful for Apple manufacturer data).
    if continuityTypes.contains(0x12) || has("FD44") || has("FD43") { return "Find My / AirTag" }
    if continuityTypes.contains(0x07) { return "AirPods / Apple audio" }
    if companyId == 0x004C && !continuityTypes.isEmpty { return "Apple device" }

    // GATT primary-service signatures.
    if has("1812") { return "Keyboard / mouse (HID)" }
    if has("180D") { return "Heart-rate monitor" }
    if has("1818") || has("1816") || has("1814") || has("1826") { return "Fitness sensor" }
    if has("1808") || has("1809") || has("1810") || has("1822") || has("181D") { return "Health monitor" }
    if has("181A") { return "Environmental sensor" }
    if has("1827") || has("1828") { return "BLE mesh node" }
    if has("FE95") { return "Xiaomi device" }
    if has(nordicUARTService) { return "Nordic UART device" }

    if companyId != nil { return "BLE device" }
    return name?.isEmpty == false ? "BLE device" : "—"
}

// MARK: - Proximity / distance

enum Proximity: Equatable {
    case immediate, near, far, unknown
    var label: String {
        switch self {
        case .immediate: return "immediate"
        case .near:      return "near"
        case .far:       return "far"
        case .unknown:   return "—"
        }
    }
}

/// Path-loss distance estimate (metres) from RSSI and a 1 m-calibrated reference RSSI,
/// using the well-known iBeacon ranging curve. Only as good as the calibration and the
/// environment — surfaced as a rough estimate, never a precise measurement.
func estimateDistanceMeters(rssi: Int, calibratedRSSIAt1m ref: Int) -> Double {
    if rssi == 0 || ref == 0 { return -1 }
    let ratio = Double(rssi) / Double(ref)
    if ratio < 1.0 { return pow(ratio, 10.0) }
    return 0.89976 * pow(ratio, 7.7095) + 0.111
}

/// Proximity bucket. With a 1 m reference we bucket the estimated distance; without one
/// (the common case — most adverts carry no calibrated reference) we bucket RSSI directly.
func proximity(rssi: Int, calibratedRSSIAt1m ref: Int?) -> Proximity {
    guard rssi < 0, rssi > -127 else { return .unknown }   // 0 / 127 == unavailable
    if let ref = ref {
        let d = estimateDistanceMeters(rssi: rssi, calibratedRSSIAt1m: ref)
        if d < 0 { return .unknown }
        if d < 0.5 { return .immediate }
        if d < 4.0 { return .near }
        return .far
    }
    if rssi >= -55 { return .immediate }
    if rssi >= -75 { return .near }
    return .far
}

// MARK: - Sorting

enum SortKey {
    case rssi, name, vendor, type, age
    var label: String {
        switch self {
        case .rssi:   return "RSSI"
        case .name:   return "Name"
        case .vendor: return "Vendor"
        case .type:   return "Type"
        case .age:    return "Age"
        }
    }
}

/// RSSI used for ordering: the unavailable sentinel (0 / 127) sorts to the bottom.
private func effectiveRSSI(_ d: Device) -> Int { d.hasValidRSSI ? d.rssi : -9999 }

/// Strict ordering of two devices for `key`'s default direction. Every key falls back to
/// RSSI then the stable identifier so the order is total (extracted from `sortDevices` so
/// each branch is unit-testable). Named devices sort before unnamed in name order.
func deviceBefore(_ a: Device, _ b: Device, by key: SortKey) -> Bool {
    switch key {
    case .rssi:
        return effectiveRSSI(a) != effectiveRSSI(b) ? effectiveRSSI(a) > effectiveRSSI(b) : a.id < b.id
    case .name:
        if a.isNamed != b.isNamed { return a.isNamed }   // named first
        let an = a.displayName.lowercased(), bn = b.displayName.lowercased()
        return an != bn ? an < bn : effectiveRSSI(a) > effectiveRSSI(b)
    case .vendor:
        return a.vendor != b.vendor ? a.vendor < b.vendor : effectiveRSSI(a) > effectiveRSSI(b)
    case .type:
        return a.typeLabel != b.typeLabel ? a.typeLabel < b.typeLabel : effectiveRSSI(a) > effectiveRSSI(b)
    case .age:
        return a.lastSeen != b.lastSeen ? a.lastSeen > b.lastSeen : effectiveRSSI(a) > effectiveRSSI(b)
    }
}

func sortDevices(_ devices: [Device], by key: SortKey, ascending: Bool) -> [Device] {
    let sorted = devices.sorted { deviceBefore($0, $1, by: key) }
    return ascending ? sorted.reversed() : sorted
}

// MARK: - UUID helpers

private let btBaseSuffix = "-0000-1000-8000-00805F9B34FB"

/// Nordic UART Service — a 128-bit vendor UUID (not on the Bluetooth base), so it keeps
/// its full form through normalizeUUID. Referenced by both the name table and type guess.
let nordicUARTService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"

/// Normalise a UUID to its short SIG form: a 128-bit UUID built on the Bluetooth base
/// (`0000XXXX-0000-1000-8000-00805F9B34FB`) collapses to the 4-hex `XXXX`; everything
/// else is returned uppercased unchanged. Makes lookups work whether CoreBluetooth hands
/// us the short or the long form.
func normalizeUUID(_ s: String) -> String {
    let u = s.uppercased()
    if u.count == 4 { return u }
    if u.count == 36, u.hasSuffix(btBaseSuffix), u.hasPrefix("0000") {
        return String(u.dropFirst(4).prefix(4))
    }
    return u
}

/// Friendly service name for a UUID, e.g. "Heart Rate", or nil if unknown.
func serviceName(_ uuid: String) -> String? { gattServiceNames[normalizeUUID(uuid)] }

/// "Heart Rate (0x180D)" for known services; the raw (normalised) UUID otherwise.
func friendlyService(_ uuid: String) -> String {
    let short = normalizeUUID(uuid)
    if let name = gattServiceNames[short] {
        return short.count == 4 ? "\(name) (0x\(short))" : "\(name) (\(short))"
    }
    return short.count == 4 ? "0x\(short)" : short
}

/// Lowercase, unseparated hex of a byte run (for namespaces, EIDs, instance ids).
func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// Format 16 bytes as a canonical 8-4-4-4-12 UUID string (uppercase).
func formatUUID(_ b: [UInt8]) -> String {
    let h = b.map { String(format: "%02X", $0) }.joined()
    guard h.count == 32 else { return h }
    let c = Array(h)
    func seg(_ lo: Int, _ hi: Int) -> String { String(c[lo..<hi]) }
    return "\(seg(0,8))-\(seg(8,12))-\(seg(12,16))-\(seg(16,20))-\(seg(20,32))"
}

// MARK: - Hex dump

/// Classic `offset  hex bytes  |ascii|` dump, `width` bytes per row (default 16, split
/// into two groups for readability). Empty input → no rows.
func hexDump(_ bytes: [UInt8], width: Int = 16) -> [String] {
    guard !bytes.isEmpty, width > 0 else { return [] }
    var rows: [String] = []
    var offset = 0
    while offset < bytes.count {
        let slice = Array(bytes[offset..<min(offset + width, bytes.count)])
        var hex = ""
        for i in 0..<width {
            if i == width / 2 { hex += " " }                 // gap between the two halves
            hex += i < slice.count ? String(format: "%02x ", slice[i]) : "   "
        }
        let ascii = slice.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." }
        rows.append(String(format: "%04x  %@ |%@|", offset, hex.trimmingCharacters(in: .whitespaces), String(ascii)))
        offset += width
    }
    return rows
}

// MARK: - Signal colour (BLE-tuned) — 256-palette + truecolor gradient

/// BLE RSSI → 256-colour palette index. BLE runs weaker than Wi-Fi, so the buckets sit
/// lower than a Wi-Fi scanner's. The truecolor gradient (bleSignalRGB) mirrors these stops.
func signalColorCode(_ rssi: Int) -> Int {
    switch rssi {
    case let r where r >= -55: return 46    // bright green — right next to you
    case let r where r >= -67: return 82    // green
    case let r where r >= -77: return 226   // yellow
    case let r where r >= -87: return 208   // orange
    default: return 196                      // red — faint / far
    }
}

typealias RGB = (r: Int, g: Int, b: Int)

/// Linear interpolation across an ascending list of (position, colour) stops. Clamps
/// below the first / above the last stop.
func lerpRGB(_ x: Double, _ stops: [(at: Double, rgb: RGB)]) -> RGB {
    guard let first = stops.first else { return (255, 255, 255) }
    if x <= first.at { return first.rgb }
    for i in 1..<stops.count {
        let lo = stops[i - 1], hi = stops[i]
        if x <= hi.at {
            let t = (x - lo.at) / (hi.at - lo.at)   // lo.at < x ≤ hi.at here ⇒ denominator > 0
            return (Int((Double(lo.rgb.r) + t * Double(hi.rgb.r - lo.rgb.r)).rounded()),
                    Int((Double(lo.rgb.g) + t * Double(hi.rgb.g - lo.rgb.g)).rounded()),
                    Int((Double(lo.rgb.b) + t * Double(hi.rgb.b - lo.rgb.b)).rounded()))
        }
    }
    return stops.last!.rgb
}

/// BLE RSSI → smooth 24-bit colour: red (faint) → amber → green (close). Stops mirror
/// signalColorCode's buckets so the two paths agree.
func signalRGB(_ rssi: Int) -> RGB {
    lerpRGB(Double(rssi), [
        (-90, (220,  60,  55)),   // red
        (-80, (235, 140,  45)),   // orange
        (-70, (228, 210,  70)),   // yellow
        (-60, (120, 205,  80)),   // green
        (-50, ( 60, 220,  95)),   // bright green
    ])
}

/// RSSI → [0,1] bar fill, mapping the -100…-40 dBm window BLE typically spans.
func signalFraction(_ rssi: Int) -> Double {
    max(0.0, min(1.0, Double(rssi + 100) / 60.0))
}

// MARK: - Sub-cell bars (Unicode eighth-blocks) & sparklines

private let eighthBlocks = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

/// A horizontal bar with sub-cell precision: `fraction` of `width` full cells, the final
/// partial cell drawn with an eighth-block glyph. Any positive fraction shows at least a
/// 1/8 sliver so faint signals stay visible. One display column per glyph.
func subCellBar(_ fraction: Double, width: Int) -> String {
    guard width > 0 else { return "" }
    let f = max(0.0, min(1.0, fraction))
    if f <= 0 { return "" }
    let eighths = max(1, Int((f * Double(width) * 8).rounded()))
    return String(repeating: "█", count: eighths / 8) + eighthBlocks[eighths % 8]
}

private let sparkGlyphs = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

/// Render RSSI samples as a sparkline over the [lo,hi] dBm scale (the -100…-40 window the
/// signal bar uses). Empty in → empty out, so callers can pad/clip by display width.
func sparkline(_ samples: [Int], lo: Int = -100, hi: Int = -40) -> String {
    guard !samples.isEmpty, hi > lo else { return "" }
    let span = Double(hi - lo), top = Double(sparkGlyphs.count - 1)
    return samples.map { v in
        let f = max(0.0, min(1.0, (Double(v) - Double(lo)) / span))
        return sparkGlyphs[Int((f * top).rounded())]
    }.joined()
}

// MARK: - Age formatting

/// Compact "time since last heard" — `now`, `3s`, `4m`, `2h`.
func formatAge(_ seconds: Double) -> String {
    if seconds < 1 { return "now" }
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    return "\(Int(seconds / 3600))h"
}

// MARK: - Display-width-aware text layout
//
// Terminal cells, not grapheme counts: CJK/emoji glyphs occupy two columns but count as
// one Character, so padding by `.count` misaligns the table. These helpers measure and
// truncate by display width instead.

/// Approximate East-Asian display width of a single Character (0/1/2 cells).
func charDisplayWidth(_ c: Character) -> Int {
    let v = c.unicodeScalars.first!.value
    if v == 0 { return 0 }
    if (0x0300...0x036F).contains(v) || (0x200B...0x200F).contains(v) || v == 0xFEFF { return 0 }
    let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x1F900...0x1F9FF, 0x20000...0x3FFFD,
    ]
    for r in wide where r.contains(v) { return 2 }
    return 1
}

func displayWidth(_ s: String) -> Int { s.reduce(0) { $0 + charDisplayWidth($1) } }

/// Truncate to at most `n` display columns without splitting a grapheme.
func truncateToWidth(_ s: String, _ n: Int) -> String {
    var w = 0, out = ""
    for ch in s {
        let cw = charDisplayWidth(ch)
        if w + cw > n { break }
        out.append(ch); w += cw
    }
    return out
}

/// Left-justify to `n` display columns (pad right, truncate if longer).
func padTo(_ s: String, _ n: Int) -> String {
    let w = displayWidth(s)
    if w <= n { return s + String(repeating: " ", count: n - w) }
    let t = truncateToWidth(s, n)
    return t + String(repeating: " ", count: max(0, n - displayWidth(t)))
}

/// Right-justify to `n` display columns (pad left, truncate if longer).
func padLeft(_ s: String, _ n: Int) -> String {
    let w = displayWidth(s)
    if w <= n { return String(repeating: " ", count: n - w) + s }
    let t = truncateToWidth(s, n)
    return String(repeating: " ", count: max(0, n - displayWidth(t))) + t
}

// MARK: - Terminal-safe name display
//
// A BLE local name is arbitrary bytes — a hostile device can name itself with ANSI escape
// sequences, carriage returns, etc. Printing such a name raw would let it move the cursor,
// recolour or clear the terminal, or corrupt the table. So every name passes through
// sanitizeName before it reaches the screen. (JSON output keeps the raw name: JSONEncoder
// escapes control bytes, so the JSON stays valid and inert until a consumer renders it.)

/// Replace C0 controls (incl. ESC, CR, LF, TAB), DEL and C1 controls with a visible
/// middle-dot placeholder, width-preserving so columns stay aligned. Printable text
/// (including CJK/emoji names) passes through untouched.
func sanitizeName(_ s: String) -> String {
    let placeholder: Unicode.Scalar = "\u{00B7}"   // ·
    var out = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        let v = scalar.value
        out.append(v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) ? placeholder : scalar)
    }
    return String(out)
}

// MARK: - Bluetooth SIG assigned numbers (curated subsets)
//
// macOS gives no OUI/MAC, so vendor identity comes from these two SIG tables: the company
// id inside manufacturer data, and the advertised service UUIDs. Both are large official
// registries; embedded here is a curated, high-confidence subset of the common entries.
// An unknown company id is shown as its raw `0xXXXX` value rather than guessed — accuracy
// over coverage — so missing here means "shown honestly as hex", not "wrong".

/// Curated SIG "Company Identifiers" → name. nil ⇒ caller shows the raw hex id.
func companyName(_ id: UInt16) -> String? { sigCompanies[id] }

private let sigCompanies: [UInt16: String] = [
    0x0000: "Ericsson Technology Licensing",
    0x0001: "Nokia Mobile Phones",
    0x0002: "Intel",
    0x0003: "IBM",
    0x0004: "Toshiba",
    0x0006: "Microsoft",
    0x0008: "Motorola",
    0x0009: "Infineon Technologies",
    0x000A: "Qualcomm (CSR)",
    0x000D: "Texas Instruments",
    0x000F: "Broadcom",
    0x0013: "Atmel",
    0x004C: "Apple",
    0x0059: "Nordic Semiconductor",
    0x0075: "Samsung Electronics",
    0x0078: "Nike",
    0x0087: "Garmin",
    0x00C4: "LG Electronics",
    0x00D7: "Qualcomm Connected Experiences",
    0x00E0: "Google",
    0x0157: "Anhui Huami (Amazfit / Zepp)",
    0x0171: "Amazon",
    0x012D: "Sony",
    0x0499: "Ruuvi Innovations",
    0x0822: "Adafruit Industries",
]

/// Curated SIG GATT service UUIDs (16-bit) + common member service UUIDs → friendly name.
/// Keyed by the normalised short form (see normalizeUUID), plus the Nordic UART 128-bit
/// service by its long form.
private let gattServiceNames: [String: String] = [
    // Standard GATT services
    "1800": "Generic Access",
    "1801": "Generic Attribute",
    "1802": "Immediate Alert",
    "1803": "Link Loss",
    "1804": "Tx Power",
    "1805": "Current Time",
    "1806": "Reference Time Update",
    "1807": "Next DST Change",
    "1808": "Glucose",
    "1809": "Health Thermometer",
    "180A": "Device Information",
    "180D": "Heart Rate",
    "180E": "Phone Alert Status",
    "180F": "Battery",
    "1810": "Blood Pressure",
    "1811": "Alert Notification",
    "1812": "Human Interface Device",
    "1813": "Scan Parameters",
    "1814": "Running Speed and Cadence",
    "1815": "Automation IO",
    "1816": "Cycling Speed and Cadence",
    "1818": "Cycling Power",
    "1819": "Location and Navigation",
    "181A": "Environmental Sensing",
    "181B": "Body Composition",
    "181C": "User Data",
    "181D": "Weight Scale",
    "181E": "Bond Management",
    "181F": "Continuous Glucose Monitoring",
    "1820": "Internet Protocol Support",
    "1821": "Indoor Positioning",
    "1822": "Pulse Oximeter",
    "1823": "HTTP Proxy",
    "1824": "Transport Discovery",
    "1825": "Object Transfer",
    "1826": "Fitness Machine",
    "1827": "Mesh Provisioning",
    "1828": "Mesh Proxy",
    "1829": "Reconnection Configuration",
    "183A": "Insulin Delivery",
    // Common member (company-assigned) service UUIDs — strong vendor/beacon signals
    "FEAA": "Google Eddystone",
    "FE2C": "Google Fast Pair",
    "FD6F": "Exposure Notification",
    "FEED": "Tile",
    "FEEC": "Tile",
    "FD44": "Apple",
    "FD43": "Apple",
    "FE95": "Xiaomi",
    "FEBE": "Bose",
    nordicUARTService: "Nordic UART (NUS)",
]
