// blescan core unit tests — dependency-free so they run under Command Line Tools alone
// (no XCTest/Xcode required). Build & run with `make test`, measure coverage with
// `make coverage`, or directly:
//
//   swiftc -parse-as-library Sources/blescan/Core.swift Tests/CoreTests.swift \
//       -o /tmp/blescan-tests && /tmp/blescan-tests
//
// Exit code is non-zero if any check fails. These tests are kept at 100% region
// coverage of Core.swift (enforced by `make coverage` / CI); when you add code to
// Core.swift, add a check here.

import Foundation

var checks = 0, failures = 0
func ok(_ cond: Bool, _ msg: String) {
    checks += 1
    if !cond { failures += 1; print("FAIL: \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    checks += 1
    if a != b { failures += 1; print("FAIL: \(msg) — got \(a), want \(b)") }
}

/// Build a Device with sensible defaults, overriding only what a test cares about.
func dev(id: String = "id", name: String? = "x", rssi: Int = -60, tx: Int? = nil,
         conn: Bool? = nil, mfg: [UInt8] = [], svc: [String] = [],
         svcData: [ServiceDatum] = [], solicited: [String] = [], overflow: [String] = [],
         first: Double = 0, last: Double = 0) -> Device {
    Device(id: id, name: name, rssi: rssi, txPower: tx, connectable: conn,
           manufacturerData: mfg, serviceUUIDs: svc, serviceData: svcData,
           solicitedUUIDs: solicited, overflowUUIDs: overflow, firstSeen: first, lastSeen: last)
}

/// Names of a sorted result, joined, for compact ordering assertions.
func order(_ ds: [Device]) -> String { ds.map { $0.id }.joined() }

// A valid 25-byte iBeacon manufacturer blob: Apple, type 02 15, 16-byte UUID, major,
// minor, measured power -59 (0xC5).
let ibeaconBytes: [UInt8] =
    [0x4C, 0x00, 0x02, 0x15] + Array(repeating: 0x01, count: 16) + [0x00, 0x2A, 0x00, 0x07, 0xC5]

@main enum CoreTests {
    static func main() {
        testManufacturer()
        testVendor()
        testIBeacon()
        testContinuity()
        testEddystone()
        testEddystoneURL()
        testDeviceType()
        testProximity()
        testSorting()
        testUUID()
        testHexDump()
        testSignalColor()
        testGradient()
        testBars()
        testAge()
        testLayout()
        testFittingVariant()
        testSanitize()
        testDevice()

        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Manufacturer data

    static func testManufacturer() {
        eq(companyIdentifier([0x4C, 0x00]), 0x004C, "company id little-endian")
        eq(companyIdentifier([0x75, 0x00, 0xFF]), 0x0075, "company id ignores payload")
        ok(companyIdentifier([0x4C]) == nil, "company id nil when < 2 bytes")
        eq(manufacturerPayload([0x4C, 0x00, 0xAA, 0xBB]), [0xAA, 0xBB], "payload after company id")
        eq(manufacturerPayload([0x4C, 0x00]), [], "no payload when only company id")
    }

    // MARK: Vendor labels

    static func testVendor() {
        eq(companyName(0x004C), "Apple", "Apple company name")
        eq(companyName(0x0075), "Samsung Electronics", "Samsung company name")
        eq(companyName(0x00E0), "Google", "Google company name")
        ok(companyName(0xFFFE) == nil, "unknown company id → nil")
        eq(vendorLabel(0x004C), "Apple", "vendorLabel known → name")
        eq(vendorLabel(0xABCD), "0xABCD", "vendorLabel unknown → hex")
        eq(vendorLabel(nil), "—", "vendorLabel nil → dash")
    }

    // MARK: iBeacon

    static func testIBeacon() {
        let b = parseIBeacon(ibeaconBytes)
        ok(b != nil, "valid iBeacon parses")
        eq(b?.uuid, "01010101-0101-0101-0101-010101010101", "iBeacon UUID formatted")
        eq(b?.major, 42, "iBeacon major (big-endian 0x002A)")
        eq(b?.minor, 7, "iBeacon minor (big-endian 0x0007)")
        eq(b?.measuredPower, -59, "iBeacon measured power (signed)")
        ok(parseIBeacon([0x4C, 0x00, 0x02, 0x15]) == nil, "too-short iBeacon → nil")
        ok(parseIBeacon([0x4D, 0x00, 0x02, 0x15] + Array(repeating: 0, count: 21)) == nil,
           "wrong company → nil")
        ok(parseIBeacon([0x4C, 0x00, 0x03, 0x15] + Array(repeating: 0, count: 21)) == nil,
           "wrong type byte → nil")
    }

    // MARK: Apple Continuity

    static func testContinuity() {
        // Two TLV segments: Nearby Info (0x10, len 2) then Handoff (0x0C, len 1).
        eq(appleSegmentTypes([0x4C, 0x00, 0x10, 0x02, 0xAA, 0xBB, 0x0C, 0x01, 0x00]),
           [0x10, 0x0C], "walks Apple TLV segment types")
        eq(appleSegmentTypes([0x06, 0x00, 0x10, 0x02]), [], "non-Apple manufacturer → no segments")
        eq(appleSegmentTypes([0x4C]), [], "truncated manufacturer → no segments")

        eq(continuityName(0x02), "iBeacon", "continuity 0x02")
        eq(continuityName(0x05), "AirDrop", "continuity 0x05")
        eq(continuityName(0x07), "AirPods / Proximity Pairing", "continuity 0x07")
        eq(continuityName(0x08), "Hey Siri", "continuity 0x08")
        eq(continuityName(0x09), "AirPlay Target", "continuity 0x09")
        eq(continuityName(0x0A), "AirPlay Source", "continuity 0x0A")
        eq(continuityName(0x0B), "Magic Switch (Apple Watch)", "continuity 0x0B")
        eq(continuityName(0x0C), "Handoff", "continuity 0x0C")
        eq(continuityName(0x0D), "Tethering Target", "continuity 0x0D")
        eq(continuityName(0x0E), "Tethering Source", "continuity 0x0E")
        eq(continuityName(0x0F), "Nearby Action", "continuity 0x0F")
        eq(continuityName(0x10), "Nearby Info", "continuity 0x10")
        eq(continuityName(0x12), "Find My", "continuity 0x12")
        ok(continuityName(0x99) == nil, "unknown continuity type → nil")
    }

    // MARK: Eddystone frames

    static func testEddystone() {
        ok(parseEddystone([]) == nil, "empty Eddystone → nil")

        let uid = parseEddystone([0x00, 0xEC] + Array(repeating: 0xAB, count: 10) + Array(repeating: 0xCD, count: 6))
        eq(uid, .uid(txPower: -20, namespace: "abababababababababab", instance: "cdcdcdcdcdcd"), "Eddystone-UID")
        ok(parseEddystone([0x00, 0xEC]) == nil, "short UID → nil")

        let url = parseEddystone([0x10, 0xEC, 0x00, 0x74, 0x07])
        eq(url, .url(txPower: -20, url: "http://www.t.com"), "Eddystone-URL")
        ok(parseEddystone([0x10]) == nil, "short URL → nil")

        let tlm = parseEddystone([0x20, 0x00, 0x0B, 0xB8, 0x0B, 0x00, 0x00, 0x00, 0x04, 0xD2, 0x00, 0x00, 0x27, 0x10])
        eq(tlm, .tlm(battery: 3000, temperature: 11.0, advCount: 1234, uptimeDeciseconds: 10000), "Eddystone-TLM")
        ok(parseEddystone([0x20, 0x00]) == nil, "short TLM → nil")

        let eid = parseEddystone([0x30, 0xEC] + Array(repeating: 0xEE, count: 8))
        eq(eid, .eid(txPower: -20, eid: "eeeeeeeeeeeeeeee"), "Eddystone-EID")
        ok(parseEddystone([0x30]) == nil, "short EID → nil")

        ok(parseEddystone([0x99, 0x00]) == nil, "unknown frame type → nil")

        // txPower: present for UID/URL/EID, absent for TLM.
        eq(uid?.txPower, -20, "UID exposes tx power")
        eq(url?.txPower, -20, "URL exposes tx power")
        eq(eid?.txPower, -20, "EID exposes tx power")
        ok(tlm?.txPower == nil, "TLM has no tx-power reference")

        // summaries
        ok(uid!.summary.hasPrefix("Eddystone-UID abababababababababab/cdcdcdcdcdcd"), "UID summary")
        eq(url!.summary, "Eddystone-URL http://www.t.com", "URL summary")
        ok(tlm!.summary.contains("3000mV"), "TLM summary has battery")
        ok(tlm!.summary.contains("11.0"), "TLM summary has temperature")
        ok(eid!.summary.hasPrefix("Eddystone-EID eeeeeeee"), "EID summary")
    }

    // MARK: Eddystone URL expansion

    static func testEddystoneURL() {
        // scheme prefixes
        eq(decodeEddystoneURL(scheme: 0, [0x61]), "http://www.a", "scheme 0 → http://www.")
        eq(decodeEddystoneURL(scheme: 1, [0x61]), "https://www.a", "scheme 1 → https://www.")
        eq(decodeEddystoneURL(scheme: 2, [0x61]), "http://a", "scheme 2 → http://")
        eq(decodeEddystoneURL(scheme: 3, [0x61]), "https://a", "scheme 3 → https://")
        eq(decodeEddystoneURL(scheme: 9, [0x61]), "a", "unknown scheme → no prefix")
        // body: expansion byte, printable ASCII, non-printable percent-escape
        eq(decodeEddystoneURL(scheme: 2, [0x67, 0x6F, 0x07]), "http://go.com", "expansion .com")
        eq(decodeEddystoneURL(scheme: 2, [0x1F]), "http://%1F", "non-printable → percent-escape")
    }

    // MARK: Device-type inference (drive every branch)

    static func testDeviceType() {
        func t(_ svc: Set<String> = [], company: UInt16? = nil, iBeacon: Bool = false,
               eddystone: Bool = false, cont: Set<UInt8> = [], name: String? = "x") -> String {
            inferDeviceType(serviceShortUUIDs: svc, companyId: company, iBeacon: iBeacon,
                            eddystone: eddystone, continuityTypes: cont, name: name)
        }
        eq(t(iBeacon: true), "iBeacon", "iBeacon wins")
        eq(t(eddystone: true), "Eddystone beacon", "Eddystone")
        eq(t(["FEED"]), "Tile tracker", "Tile FEED")
        eq(t(["FEEC"]), "Tile tracker", "Tile FEEC")
        eq(t(["FD6F"]), "Exposure Notification", "Exposure Notification")
        eq(t(["FE2C"]), "Google Fast Pair", "Fast Pair")
        eq(t(cont: [0x12]), "Find My / AirTag", "Find My via continuity")
        eq(t(["FD44"]), "Find My / AirTag", "Find My via FD44")
        eq(t(["FD43"]), "Find My / AirTag", "Find My via FD43")
        eq(t(cont: [0x07]), "AirPods / Apple audio", "AirPods")
        eq(t(company: 0x004C, cont: [0x10]), "Apple device", "Apple device fallback")
        eq(t(["1812"]), "Keyboard / mouse (HID)", "HID")
        eq(t(["180D"]), "Heart-rate monitor", "Heart rate")
        eq(t(["1818"]), "Fitness sensor", "Fitness 1818")
        eq(t(["1816"]), "Fitness sensor", "Fitness 1816")
        eq(t(["1814"]), "Fitness sensor", "Fitness 1814")
        eq(t(["1826"]), "Fitness sensor", "Fitness 1826")
        eq(t(["1808"]), "Health monitor", "Health 1808")
        eq(t(["1809"]), "Health monitor", "Health 1809")
        eq(t(["1810"]), "Health monitor", "Health 1810")
        eq(t(["1822"]), "Health monitor", "Health 1822")
        eq(t(["181D"]), "Health monitor", "Health 181D")
        eq(t(["181A"]), "Environmental sensor", "Environmental")
        eq(t(["1827"]), "BLE mesh node", "Mesh 1827")
        eq(t(["1828"]), "BLE mesh node", "Mesh 1828")
        eq(t(["FE95"]), "Xiaomi device", "Xiaomi")
        eq(t([nordicUARTService]), "Nordic UART device", "Nordic UART")
        eq(t(company: 0x0059), "BLE device", "known company, no service → BLE device")
        eq(t(name: "Widget"), "BLE device", "no company but named → BLE device")
        eq(t(name: nil), "—", "nothing identifiable → dash")
        eq(t(name: ""), "—", "empty name, nothing else → dash")
    }

    // MARK: Proximity / distance

    static func testProximity() {
        // distance curve
        ok(estimateDistanceMeters(rssi: 0, calibratedRSSIAt1m: -59) == -1, "rssi 0 → invalid distance")
        ok(estimateDistanceMeters(rssi: -50, calibratedRSSIAt1m: 0) == -1, "ref 0 → invalid distance")
        ok(estimateDistanceMeters(rssi: -50, calibratedRSSIAt1m: -59) < 0.5, "close ratio<1 short distance")
        ok(estimateDistanceMeters(rssi: -90, calibratedRSSIAt1m: -59) > 4, "far ratio>1 long distance")

        // proximity with a 1 m reference
        eq(proximity(rssi: -50, calibratedRSSIAt1m: -59), .immediate, "ref → immediate")
        eq(proximity(rssi: -70, calibratedRSSIAt1m: -59), .near, "ref → near")
        eq(proximity(rssi: -95, calibratedRSSIAt1m: -59), .far, "ref → far")
        eq(proximity(rssi: -50, calibratedRSSIAt1m: 0), .unknown, "ref 0 → unknown distance")
        // proximity without a reference (RSSI thresholds)
        eq(proximity(rssi: -50, calibratedRSSIAt1m: nil), .immediate, "no ref → immediate")
        eq(proximity(rssi: -70, calibratedRSSIAt1m: nil), .near, "no ref → near")
        eq(proximity(rssi: -90, calibratedRSSIAt1m: nil), .far, "no ref → far")
        eq(proximity(rssi: 127, calibratedRSSIAt1m: nil), .unknown, "sentinel rssi → unknown")

        eq(Proximity.immediate.label, "immediate", "immediate label")
        eq(Proximity.near.label, "near", "near label")
        eq(Proximity.far.label, "far", "far label")
        eq(Proximity.unknown.label, "—", "unknown label")
    }

    // MARK: Sorting

    static func testSorting() {
        // rssi: stronger first; equal rssi tie-breaks by id; sentinel rssi sorts last.
        let r = [dev(id: "a", rssi: -70), dev(id: "b", rssi: -40), dev(id: "c", rssi: -40), dev(id: "d", rssi: 127)]
        eq(order(sortDevices(r, by: .rssi, ascending: false)), "bcad", "rssi desc, tie by id, sentinel last")
        eq(sortDevices(r, by: .rssi, ascending: true).first!.id, "d", "ascending reverses")

        // name: named before unnamed; then case-insensitive; equal names tie by rssi.
        let n = [dev(id: "a", name: "Bravo", rssi: -50), dev(id: "b", name: nil, rssi: -40),
                 dev(id: "c", name: "alpha", rssi: -60), dev(id: "d", name: "alpha", rssi: -30)]
        eq(order(sortDevices(n, by: .name, ascending: false)), "dcab", "name: alpha(strong) alpha bravo unnamed")

        // vendor: label asc; equal vendor ties by rssi.
        let v = [dev(id: "a", rssi: -50, mfg: [0x4C, 0x00]), dev(id: "b", rssi: -40, mfg: [0x75, 0x00]),
                 dev(id: "c", rssi: -30, mfg: [0x4C, 0x00])]
        eq(order(sortDevices(v, by: .vendor, ascending: false)), "ca b".replacingOccurrences(of: " ", with: ""),
           "vendor Apple(<Samsung) tie by rssi")

        // type: label asc; equal type ties by rssi.
        let ty = [dev(id: "a", rssi: -50, svc: ["180D"]), dev(id: "b", rssi: -40, svc: ["1812"]),
                  dev(id: "c", rssi: -30, svc: ["180D"])]
        eq(order(sortDevices(ty, by: .type, ascending: false)), "cab", "type Heart-rate(<Keyboard) tie by rssi")

        // age: most-recently-seen first; equal lastSeen ties by rssi.
        let g = [dev(id: "a", rssi: -50, last: 10), dev(id: "b", rssi: -40, last: 30),
                 dev(id: "c", rssi: -30, last: 30)]
        eq(order(sortDevices(g, by: .age, ascending: false)), "cba", "age newest first, tie by rssi")

        // Drive deviceBefore in both directions so each ternary's true/false sides run.
        ok(deviceBefore(dev(id: "a", rssi: -40), dev(id: "b", rssi: -70), by: .rssi), "stronger sorts first")
        ok(deviceBefore(dev(id: "a", rssi: -40), dev(id: "b", rssi: -40), by: .rssi), "equal rssi → id order")
        ok(deviceBefore(dev(name: "a"), dev(name: nil), by: .name), "named before unnamed")
        ok(!deviceBefore(dev(name: nil), dev(name: "a"), by: .name), "unnamed after named")
        ok(deviceBefore(dev(id: "a", name: "z", rssi: -40), dev(id: "b", name: "z", rssi: -70), by: .name),
           "equal name → stronger rssi")
        ok(deviceBefore(dev(id: "x", rssi: -40, mfg: [0x4C, 0x00]), dev(id: "y", rssi: -70, mfg: [0x4C, 0x00]), by: .vendor),
           "equal vendor → stronger rssi")
        ok(deviceBefore(dev(rssi: -40, svc: ["180D"]), dev(rssi: -70, svc: ["180D"]), by: .type),
           "equal type → stronger rssi")
        ok(deviceBefore(dev(rssi: -40, last: 5), dev(rssi: -70, last: 5), by: .age), "equal age → stronger rssi")

        eq(SortKey.rssi.label, "RSSI", "label rssi")
        eq(SortKey.name.label, "Name", "label name")
        eq(SortKey.vendor.label, "Vendor", "label vendor")
        eq(SortKey.type.label, "Type", "label type")
        eq(SortKey.age.label, "Age", "label age")
    }

    // MARK: UUID helpers

    static func testUUID() {
        eq(normalizeUUID("180d"), "180D", "short UUID uppercased")
        eq(normalizeUUID("0000180D-0000-1000-8000-00805F9B34FB"), "180D", "base UUID → short form")
        eq(normalizeUUID("1234ABCD-0000-1000-8000-00805F9B34FB"),
           "1234ABCD-0000-1000-8000-00805F9B34FB", "32-bit-on-base keeps full form")
        eq(normalizeUUID(nordicUARTService), nordicUARTService, "non-base 128-bit unchanged")

        eq(serviceName("180D"), "Heart Rate", "serviceName known")
        ok(serviceName("1234") == nil, "serviceName unknown → nil")

        eq(friendlyService("180d"), "Heart Rate (0x180D)", "friendlyService known 16-bit")
        eq(friendlyService(nordicUARTService), "Nordic UART (NUS) (\(nordicUARTService))", "friendlyService known long")
        eq(friendlyService("1234"), "0x1234", "friendlyService unknown 16-bit")
        eq(friendlyService("12345678-1234-1234-1234-123456789ABC"),
           "12345678-1234-1234-1234-123456789ABC", "friendlyService unknown long")

        eq(hexString([0x0A, 0xFF, 0x00]), "0aff00", "hexString lowercase")
        eq(formatUUID(Array(repeating: 0xAB, count: 16)),
           "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB", "formatUUID 16 bytes")
        eq(formatUUID([0x01, 0x02, 0x03]), "010203", "formatUUID wrong length → raw hex")
    }

    // MARK: Hex dump

    static func testHexDump() {
        eq(hexDump([]), [], "empty → no rows")
        eq(hexDump([0x41], width: 0), [], "zero width → no rows")
        // short row: padded, with the half-gap, printable + non-printable ascii.
        let short = hexDump([0x41, 0x00, 0x7E])
        eq(short.count, 1, "3 bytes → 1 row")
        ok(short[0].hasPrefix("0000  41 00 7e"), "row starts with offset + hex")
        ok(short[0].hasSuffix("|A.~|"), "ascii column: printable kept, control dotted")
        // two full-ish rows exercise the offset increment.
        let long = hexDump(Array(0..<20).map { UInt8($0) })
        eq(long.count, 2, "20 bytes → 2 rows")
        ok(long[1].hasPrefix("0010"), "second row offset = 0x10")
        // The short final row keeps the hex field's full width, so the |ascii| column
        // lines up with the full row above it (regression: a trim used to break this).
        eq(long[0].firstIndex(of: "|"), long[1].firstIndex(of: "|"), "ascii column aligns across rows")
    }

    // MARK: Signal colour

    static func testSignalColor() {
        eq(signalColorCode(-50), 46, "≥-55 bright green")
        eq(signalColorCode(-60), 82, "≥-67 green")
        eq(signalColorCode(-70), 226, "≥-77 yellow")
        eq(signalColorCode(-80), 208, "≥-87 orange")
        eq(signalColorCode(-95), 196, "<-87 red")
    }

    // MARK: Truecolor gradient

    static func testGradient() {
        ok(lerpRGB(0.5, [(0.0, (0, 0, 0)), (1.0, (100, 200, 40))]) == (50, 100, 20), "lerpRGB midpoint")
        ok(lerpRGB(0.5, []) == (255, 255, 255), "lerpRGB empty → white")
        ok(lerpRGB(-1.0, [(0.0, (10, 20, 30)), (1.0, (90, 90, 90))]) == (10, 20, 30), "lerpRGB below first")
        ok(lerpRGB(2.0, [(0.0, (10, 20, 30)), (1.0, (90, 90, 90))]) == (90, 90, 90), "lerpRGB above last")

        ok(signalRGB(-30).g > signalRGB(-95).g, "strong greener than weak")
        ok(signalRGB(-95) == (220, 60, 55), "weak clamps to red")
        ok(signalRGB(-30) == (60, 220, 95), "strong clamps to bright green")

        eq(signalFraction(-40), 1.0, "fraction caps at 1 (≥-40)")
        eq(signalFraction(-100), 0.0, "fraction floors at 0 (≤-100)")
        ok(abs(signalFraction(-70) - 0.5) < 1e-9, "fraction midpoint at -70")
    }

    // MARK: Bars / sparklines

    static func testBars() {
        eq(subCellBar(0, width: 10), "", "zero fraction → empty")
        eq(subCellBar(0.5, width: 0), "", "zero width → empty")
        eq(subCellBar(1.0, width: 6), "██████", "full → width blocks")
        eq(subCellBar(0.5, width: 4), "██", "half of 4 → 2 blocks")
        eq(subCellBar(0.01, width: 10), "▏", "tiny positive → 1/8 sliver")
        ok(displayWidth(subCellBar(0.77, width: 10)) <= 10, "partial never exceeds width")

        eq(sparkline([]), "", "empty samples → empty")
        eq(sparkline([-50], lo: -40, hi: -100), "", "degenerate scale → empty")
        eq(sparkline([-100]), "▁", "floor → lowest glyph")
        eq(sparkline([-40]), "█", "ceiling → highest glyph")
        eq(displayWidth(sparkline([-50, -60, -70, -80])), 4, "one cell per sample")
    }

    // MARK: Age formatting

    static func testAge() {
        eq(formatAge(0.5), "now", "<1s → now")
        eq(formatAge(5), "5s", "seconds")
        eq(formatAge(120), "2m", "minutes")
        eq(formatAge(7200), "2h", "hours")
    }

    // MARK: Display-width-aware text layout

    static func testLayout() {
        eq(charDisplayWidth("\u{0}"), 0, "null → 0 width")
        eq(charDisplayWidth("\u{0301}"), 0, "combining acute → 0")
        eq(charDisplayWidth("\u{200B}"), 0, "zero-width space → 0")
        eq(charDisplayWidth("\u{FEFF}"), 0, "BOM → 0")
        eq(charDisplayWidth("A"), 1, "ascii → 1")
        eq(charDisplayWidth("你"), 2, "CJK → 2")
        eq(charDisplayWidth("😀"), 2, "emoji → 2")
        eq(charDisplayWidth("🇬🇧"), 2, "flag emoji (regional indicators) → 2")

        // Clusters whose *base* scalar is narrow but whose glyph is not: measuring only the
        // first scalar reported these as 1 column while the terminal paints 2, so a name
        // built from them overran the row budget and wrapped (frame tearing).
        eq(charDisplayWidth("\u{2764}"), 1, "bare U+2764 (text glyph) → 1")
        eq(charDisplayWidth("\u{2764}\u{FE0F}"), 2, "U+2764 + VS16 (emoji presentation) → 2")
        eq(charDisplayWidth("\u{2764}\u{FE0E}"), 1, "U+2764 + VS15 (text presentation) → 1")
        eq(charDisplayWidth("1\u{FE0F}\u{20E3}"), 2, "keycap sequence → 2")
        eq(charDisplayWidth("1\u{20E3}"), 2, "unqualified keycap (no VS16) → 2")
        let hearts = String(repeating: "\u{2764}\u{FE0F}", count: 13)
        eq(displayWidth(hearts), 26, "13 emoji hearts measure 26 columns, not 13")
        eq(truncateToWidth(hearts, 14).count, 7, "emoji name clipped to the column budget")
        eq(displayWidth(padTo(hearts, 27)), 27, "padded emoji name fills its cell exactly")

        eq(displayWidth("a你"), 3, "mixed display width")
        eq(padTo("ab", 4), "ab  ", "padTo pads right")
        eq(padTo("hello", 3), "hel", "padTo truncates")
        eq(displayWidth(padTo("你好", 3)), 3, "padTo truncates wide without overflow")
        eq(padLeft("ab", 4), "  ab", "padLeft pads left")
        eq(padLeft("hello", 3), "hel", "padLeft truncates")
        eq(displayWidth(padLeft("你好", 3)), 3, "padLeft truncates wide without overflow")
    }

    // MARK: Width-fitting variant selection

    static func testFittingVariant() {
        let v = ["richest", "mid", "x"]   // display widths 7 / 3 / 1, richest first
        eq(widthFittingVariant(v, 99), "richest", "widest fits → richest variant")
        eq(widthFittingVariant(v, 5), "mid", "richest too wide → next that fits")
        eq(widthFittingVariant(v, 0), "x", "none fit → narrowest as floor")
        eq(widthFittingVariant([], 5), "", "no variants → empty string")
    }

    // MARK: Terminal-safe names

    static func testSanitize() {
        eq(sanitizeName("AirPods Pro"), "AirPods Pro", "printable name unchanged")
        eq(sanitizeName(""), "", "empty stays empty")
        eq(sanitizeName("café 你好 😀"), "café 你好 😀", "Unicode printable passes through")
        eq(sanitizeName("evil\u{1B}[31mLED"), "evil·[31mLED", "ESC neutralised")
        eq(sanitizeName("a\tb\nc\rd"), "a·b·c·d", "TAB/LF/CR neutralised")
        eq(sanitizeName("x\u{7F}y"), "x·y", "DEL neutralised")
        eq(sanitizeName("x\u{85}y"), "x·y", "C1 control neutralised")
        eq(sanitizeName("x\u{061C}y"), "x·y", "Arabic letter mark neutralised")
        eq(sanitizeName("x\u{200B}y"), "x·y", "zero-width space neutralised")
        eq(sanitizeName("x\u{200E}y"), "x·y", "LRM neutralised")
        eq(sanitizeName("x\u{2028}y"), "x·y", "line separator neutralised")
        eq(sanitizeName("evil\u{202E}txet.gpj"), "evil·txet.gpj", "RTL override neutralised")
        eq(sanitizeName("x\u{2066}y"), "x·y", "bidi isolate neutralised")
        eq(sanitizeName("x\u{FEFF}y"), "x·y", "BOM neutralised")
        eq(displayWidth(sanitizeName("a\u{1B}\u{7F}b")), 4, "sanitised name keeps width")
    }

    // MARK: Device computed properties

    static func testDevice() {
        // iBeacon device: vendor Apple, type iBeacon, 1 m ref from measured power.
        let beacon = dev(rssi: -70, mfg: ibeaconBytes)
        eq(beacon.companyId, 0x004C, "device company id")
        eq(beacon.vendor, "Apple", "device vendor")
        ok(beacon.iBeacon != nil, "device exposes iBeacon")
        eq(beacon.typeLabel, "iBeacon", "device type label")
        eq(beacon.calibratedRSSIAt1m, -59, "calibrated ref from iBeacon measured power")
        eq(beacon.proximityBucket, .near, "iBeacon proximity from ref")

        // Eddystone-URL device: 1 m ref derived from 0 m tx power (− 41).
        let urlSvc = ServiceDatum(uuid: "FEAA", bytes: [0x10, 0xEC, 0x02, 0x67])
        let eddy = dev(mfg: [], svcData: [urlSvc])
        ok(eddy.eddystone != nil, "device exposes Eddystone")
        eq(eddy.typeLabel, "Eddystone beacon", "Eddystone type label")
        eq(eddy.calibratedRSSIAt1m, -20 - 41, "calibrated ref from Eddystone tx power − 41")

        // Eddystone-TLM device: a frame with no ranging reference → nil calibration.
        let tlmSvc = ServiceDatum(uuid: "FEAA", bytes: [0x20, 0x00] + Array(repeating: 0, count: 12))
        let tlm = dev(svcData: [tlmSvc])
        ok(tlm.eddystone != nil, "TLM device exposes Eddystone")
        ok(tlm.calibratedRSSIAt1m == nil, "TLM has no ranging reference")

        // Plain device: known vendor, no beacon, RSSI-threshold proximity, service set.
        let plain = dev(name: "Sensor", rssi: -50, mfg: [0x59, 0x00], svc: ["180F"], solicited: ["1811"], overflow: ["1812"])
        eq(plain.vendor, "Nordic Semiconductor", "plain device vendor")
        ok(plain.calibratedRSSIAt1m == nil, "plain device has no 1 m reference")
        eq(plain.proximityBucket, .immediate, "plain device proximity from RSSI")
        ok(plain.serviceShortSet.contains("180F") && plain.serviceShortSet.contains("1812"),
           "serviceShortSet merges all UUID sources")
        eq(plain.continuityTypes, [], "non-Apple device has no continuity segments")

        // Names + validity flags.
        eq(dev(name: "Buds").displayName, "Buds", "named displayName")
        eq(dev(name: nil).displayName, "(unnamed)", "unnamed placeholder")
        eq(dev(name: "").displayName, "(unnamed)", "empty name placeholder")
        ok(dev(name: "x").isNamed, "isNamed true when named")
        ok(!dev(name: nil).isNamed, "isNamed false when unnamed")
        ok(dev(rssi: -60).hasValidRSSI, "valid rssi")
        ok(!dev(rssi: 127).hasValidRSSI, "sentinel rssi invalid")
        eq(dev(last: 100).age(now: 105), 5, "age = now − lastSeen")
        eq(dev(last: 100).age(now: 90), 0, "age clamps at 0 for clock skew")
    }
}
