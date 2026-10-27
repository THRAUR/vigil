import Foundation

/// A JSON tree that keeps object key order and number spelling, so editing
/// ~/.claude/settings.json produces a minimal diff instead of a reshuffled file.
public indirect enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// Replaces the value in place, or appends the key at the end. No-op on non-objects.
    public mutating func set(_ key: String, _ value: JSONValue) {
        guard case .object(var members) = self else { return }
        if let i = members.firstIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            members.append(JSONMember(key: key, value: value))
        }
        self = .object(members)
    }

    public mutating func remove(_ key: String) {
        guard case .object(var members) = self else { return }
        members.removeAll { $0.key == key }
        self = .object(members)
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue
    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public var offset: Int
    public var message: String
    public var description: String { "invalid JSON at byte \(offset): \(message)" }
}

public struct JSONParser {
    private let bytes: [UInt8]
    private var i = 0

    public static func parse(_ text: String) throws -> JSONValue {
        var p = JSONParser(bytes: Array(text.utf8))
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw p.error("trailing characters") }
        return v
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func error(_ message: String) -> JSONParseError { JSONParseError(offset: i, message: message) }

    private mutating func skipSpace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        for b in literal.utf8 {
            guard i < bytes.count, bytes[i] == b else { throw error("expected \(literal)") }
            i += 1
        }
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw error("nested too deeply") }
        guard i < bytes.count else { throw error("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [JSONMember] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected key") }
                let key = try string()
                skipSpace()
                try expect(":")
                skipSpace()
                members.append(JSONMember(key: key, value: try value(depth: depth + 1)))
                skipSpace()
                guard i < bytes.count else { throw error("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw error("expected , or }")
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JSONValue] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard i < bytes.count else { throw error("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw error("expected , or ]")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try expect("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null"); return .null
        default:
            return .number(try number())
        }
    }

    private mutating func number() throws -> String {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        func digits() -> Int {
            let s = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            return i - s
        }
        guard digits() > 0 else { throw error("bad number") }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw error("bad fraction") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw error("bad exponent") }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count,
              let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw error("bad \\u escape")
        }
        i += 4
        return v
    }

    private mutating func string() throws -> String {
        i += 1 // opening quote
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let b = bytes[i]
            i += 1
            switch b {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard i < bytes.count else { throw error("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), i + 6 <= bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("bad surrogate pair") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw error("bad code point") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default:
                    throw error("bad escape")
                }
            default:
                guard b >= 0x20 else { throw error("control character in string") }
                out.append(b)
            }
        }
    }
}

/// Prints like JavaScript's `JSON.stringify(value, null, 2)`, which is how Claude Code writes settings.
public enum JSONPrinter {
    public static func render(_ value: JSONValue, indentWidth: Int = 2) -> String {
        var out = ""
        write(value, level: 0, indentWidth: indentWidth, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, level: Int, indentWidth: Int, into out: inout String) {
        let pad = String(repeating: " ", count: (level + 1) * indentWidth)
        let closePad = String(repeating: " ", count: level * indentWidth)
        switch value {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (n, m) in members.enumerated() {
                out += pad + quote(m.key) + ": "
                write(m.value, level: level + 1, indentWidth: indentWidth, into: &out)
                out += n == members.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (n, item) in items.enumerated() {
                out += pad
                write(item, level: level + 1, indentWidth: indentWidth, into: &out)
                out += n == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .string(let s): out += quote(s)
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
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
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}
