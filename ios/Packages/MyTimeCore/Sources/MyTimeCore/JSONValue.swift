import Foundation

/// Web 版（TypeScript）と同じ JSON をそのまま扱うための値。
///
/// - 保存は「受け取った JSON をそのまま」持つ。iOS 版がまだ知らない項目も消さずに残す（Web 版との往復で情報を失わない）。
/// - `canonical` は Web 版 `canonicalJson()` と同じ文字列を作る（キーを UTF-16 順に並べ、undefined は出さない）。
///   移行ファイルのチェックサム（SHA-256）をこの文字列で計算するため、1文字でも違えば検証に失敗する。
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: 取り出し

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var intValue: Int64? { if case .number(let n) = self, n.rounded() == n, abs(n) < 9.0e15 { return Int64(n) }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// `a` のキーを `b` で上書きした結果（オブジェクト同士だけ。iOS が知らない項目を残したまま、知っている項目を更新する）
    public func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var a) = self, case .object(let b) = other else { return other }
        for (k, v) in b { a[k] = v }
        return .object(a)
    }

    // MARK: 文字列化

    /// Web 版 `canonicalJson()` と同じ文字列
    public var canonical: String {
        var out = ""
        Self.write(self, into: &out)
        return out
    }

    private static func write(_ v: JSONValue, into out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += formatNumber(n)
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (i, x) in a.enumerated() {
                if i > 0 { out += "," }
                write(x, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            // JavaScript の Array.prototype.sort() と同じく UTF-16 のコード単位で並べる
            let keys = o.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (i, k) in keys.enumerated() {
                if i > 0 { out += "," }
                writeString(k, into: &out)
                out += ":"
                write(o[k]!, into: &out)
            }
            out += "}"
        }
    }

    /// JavaScript の `JSON.stringify(number)` と同じ表記（整数は小数点なし、指数は `1e-7` `1e+21` 形式）
    public static func formatNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == 0 { return "0" }
        if n.rounded() == n, abs(n) < 1e21 {
            return String(format: "%.0f", n)
        }
        var s = "\(n)"
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mant = String(s[s.startIndex..<e])
            var exp = String(s[s.index(after: e)...])
            var sign = "+"
            if exp.hasPrefix("-") { sign = "-"; exp.removeFirst() } else if exp.hasPrefix("+") { exp.removeFirst() }
            while exp.hasPrefix("0") && exp.count > 1 { exp.removeFirst() }
            var m = mant
            if m.hasSuffix(".0") { m.removeLast(2) }
            s = "\(m)e\(sign)\(exp)"
        }
        return s
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    public var data: Data { Data(canonical.utf8) }

    // MARK: 読み取り（依存のない小さな JSON パーサー。Foundation の実装差で数値・真偽値の扱いが変わらないように）

    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.bytes.count else { throw JSONError.trailing(p.i) }
        return v
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        guard let s = String(data: data, encoding: .utf8) else { throw JSONError.encoding }
        return try parse(s)
    }
}

public enum JSONError: Error, Equatable, CustomStringConvertible {
    case unexpected(Int)
    case trailing(Int)
    case encoding
    case number(Int)
    public var description: String {
        switch self {
        case .unexpected(let i): return "JSON の形式が正しくありません（\(i)文字目）"
        case .trailing(let i): return "JSON の後ろに余分な文字があります（\(i)文字目）"
        case .encoding: return "UTF-8 として読めません"
        case .number(let i): return "数値が正しくありません（\(i)文字目）"
        }
    }
}

private struct Parser {
    let bytes: [UInt8]
    var i = 0

    mutating func skipWS() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func value() throws -> JSONValue {
        guard i < bytes.count else { throw JSONError.unexpected(i) }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    mutating func literal(_ s: String) throws {
        let b = Array(s.utf8)
        guard i + b.count <= bytes.count, Array(bytes[i..<(i + b.count)]) == b else { throw JSONError.unexpected(i) }
        i += b.count
    }

    mutating func object() throws -> JSONValue {
        i += 1
        var o: [String: JSONValue] = [:]
        skipWS()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
        while true {
            skipWS()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw JSONError.unexpected(i) }
            let k = try string()
            skipWS()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw JSONError.unexpected(i) }
            i += 1
            skipWS()
            o[k] = try value()
            skipWS()
            guard i < bytes.count else { throw JSONError.unexpected(i) }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            throw JSONError.unexpected(i)
        }
    }

    mutating func array() throws -> JSONValue {
        i += 1
        var a: [JSONValue] = []
        skipWS()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
        while true {
            skipWS()
            a.append(try value())
            skipWS()
            guard i < bytes.count else { throw JSONError.unexpected(i) }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            throw JSONError.unexpected(i)
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else { throw JSONError.unexpected(i) }
        i += 4
        return v
    }

    mutating func string() throws -> String {
        i += 1
        var buf: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: buf, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { throw JSONError.unexpected(i) }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw JSONError.unexpected(i - 1)
                }
                continue
            }
            buf.append(c)
            i += 1
        }
        throw JSONError.unexpected(i)
    }

    mutating func number() throws -> Double {
        let start = i
        while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
        guard i > start, let d = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { throw JSONError.number(start) }
        return d
    }
}

// MARK: - Codable との橋渡し

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    /// Codable の値を JSONValue に（日付は使わず、時刻はすべて epoch ミリ秒の数値）
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try parse(data)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
