// Ordered JSON model with Python-compatible serialization. The prompt embeds
// `json.dumps(job.sample_view(mapping), ensure_ascii=False)` and the sidecar record is
// `json.dumps(record, ensure_ascii=False, indent=1)`; JSONEncoder can reproduce neither.

import Foundation
import Yams

// MARK: - OrderedDictionary

/// A small insertion-ordered dictionary. Equality is order-insensitive (like a Python dict).
public struct OrderedDictionary<Key: Hashable, Value>: ExpressibleByDictionaryLiteral, Sequence {
    public typealias Element = (key: Key, value: Value)

    private var storage: [Element] = []
    private var index: [Key: Int] = [:]

    public init() {}

    public init(_ pairs: [(Key, Value)]) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public init(dictionaryLiteral elements: (Key, Value)...) {
        self.init(elements)
    }

    public var keys: [Key] {
        storage.map(\.key)
    }

    public var values: [Value] {
        storage.map(\.value)
    }

    public var count: Int {
        storage.count
    }

    public var isEmpty: Bool {
        storage.isEmpty
    }

    public subscript(key: Key) -> Value? {
        get {
            guard let position = index[key] else { return nil }
            return storage[position].value
        }
        set {
            if let newValue {
                if let position = index[key] {
                    storage[position].value = newValue
                } else {
                    index[key] = storage.count
                    storage.append((key: key, value: newValue))
                }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    public mutating func removeValue(forKey key: Key) {
        guard let position = index[key] else { return }
        storage.remove(at: position)
        index[key] = nil
        for later in position ..< storage.count {
            index[storage[later].key] = later
        }
    }

    public func makeIterator() -> IndexingIterator<[Element]> {
        storage.makeIterator()
    }
}

extension OrderedDictionary: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, value) in lhs {
            guard let other = rhs[key], other == value else { return false }
        }
        return true
    }
}

extension OrderedDictionary: Sendable where Key: Sendable, Value: Sendable {}

// MARK: - JSONObject

/// Insertion-ordered string-keyed JSON object. Equality is order-insensitive.
public struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private var storage: OrderedDictionary<String, JSONValue>

    public init() {
        storage = [:]
    }

    public init(_ pairs: [(String, JSONValue)]) {
        storage = OrderedDictionary(pairs)
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }

    /// Keys in insertion order.
    public var keys: [String] {
        storage.keys
    }

    public var pairs: [(key: String, value: JSONValue)] {
        Array(storage)
    }

    public var count: Int {
        storage.count
    }

    public var isEmpty: Bool {
        storage.isEmpty
    }

    /// Setting a new key appends; setting an existing key replaces in place; nil removes.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    public mutating func removeValue(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}

// MARK: - JSONValue

public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

public extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .double(value): value
        case let .int(value): Double(value)
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: JSONObject? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Parse JSON text, preserving object key order. ConfigurationError on invalid input.
    init(parsing data: Data) throws {
        var parser = JSONParser(data)
        self = try parser.parseDocument()
    }

    init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    /// Python `json.dumps(value, ensure_ascii=False[, indent=n])` byte for byte.
    func pythonDumps(indent: Int? = nil) -> String {
        var out = ""
        JSONValue.write(self, to: &out, indent: indent, level: 0)
        return out
    }

    func pythonDumpsData(indent: Int? = nil) -> Data {
        Data(pythonDumps(indent: indent).utf8)
    }

    /// Bridge to a Codable type through JSONDecoder (object order is irrelevant there).
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: pythonDumpsData())
    }

    /// Bridge from an Encodable value through JSONEncoder.
    init(encoding value: some Encodable) throws {
        try self.init(parsing: JSONEncoder().encode(value))
    }

    /// Bridge from a Yams node (job file, SKILL.md frontmatter). Mapping keys must be strings.
    init(yamlNode node: Yams.Node) throws {
        switch node {
        case let .scalar(scalar):
            self = JSONValue.fromYAMLScalar(scalar, resolved: Tag.Name(rawValue: node.tag.rawValue))
        case let .sequence(sequence):
            self = try .array(sequence.map { try JSONValue(yamlNode: $0) })
        case let .mapping(mapping):
            var object = JSONObject()
            for (keyNode, valueNode) in mapping {
                guard case let .scalar(keyScalar) = keyNode, keyNode.tag == Tag(.str) else {
                    throw ConfigurationError("mapping keys must be strings, got '\(keyNode.string ?? "?")'")
                }
                object[keyScalar.string] = try JSONValue(yamlNode: valueNode)
            }
            self = .object(object)
        case .alias:
            throw ConfigurationError("YAML aliases are not supported")
        }
    }

    /// Bridge to a Yams node, preserving key order. Strings that would read back as another
    /// type (`true`, `123`, `null`, ``) are quoted, as PyYAML does.
    func yamlNode() -> Yams.Node {
        switch self {
        case .null: Node("null", Tag(.null))
        case let .bool(value): Node(value ? "true" : "false", Tag(.bool))
        case let .int(value): Node(String(value), Tag(.int))
        case let .double(value): Node(JSONValue.yamlFloat(value), Tag(.float))
        case let .string(value): JSONValue.yamlString(value)
        case let .array(items): Node(items.map { $0.yamlNode() }, Tag(.seq))
        case let .object(object):
            Node(object.pairs.map { (JSONValue.yamlString($0.key), $0.value.yamlNode()) }, Tag(.map))
        }
    }
}

// MARK: - Python-compatible serialization

extension JSONValue {
    private static func write(_ value: JSONValue, to out: inout String, indent: Int?, level: Int) {
        switch value {
        case .null: out += "null"
        case let .bool(flag): out += flag ? "true" : "false"
        case let .int(number): out += String(number)
        case let .double(number): out += pythonFloatRepr(number)
        case let .string(text): writeString(text, to: &out)
        case let .array(items):
            guard !items.isEmpty else { return out += "[]" }
            out += "["
            for (position, item) in items.enumerated() {
                out += position == 0 ? opening(indent, level) : separator(indent, level)
                write(item, to: &out, indent: indent, level: level + 1)
            }
            out += closing(indent, level) + "]"
        case let .object(object):
            guard !object.isEmpty else { return out += "{}" }
            out += "{"
            for (position, pair) in object.pairs.enumerated() {
                out += position == 0 ? opening(indent, level) : separator(indent, level)
                writeString(pair.key, to: &out)
                out += ": "
                write(pair.value, to: &out, indent: indent, level: level + 1)
            }
            out += closing(indent, level) + "}"
        }
    }

    private static func opening(_ indent: Int?, _ level: Int) -> String {
        guard let indent else { return "" }
        return "\n" + String(repeating: " ", count: indent * (level + 1))
    }

    private static func separator(_ indent: Int?, _ level: Int) -> String {
        guard indent != nil else { return ", " }
        return "," + opening(indent, level)
    }

    private static func closing(_ indent: Int?, _ level: Int) -> String {
        guard let indent else { return "" }
        return "\n" + String(repeating: " ", count: indent * level)
    }

    /// `json.dumps` with `ensure_ascii=False`: only `"`, `\` and controls below 0x20 are escaped.
    private static func writeString(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// Python `repr(float)`: shortest round-trip digits, fixed notation when the decimal exponent
    /// is in -4 ... 16, exponent notation (`1e+16`, `1e-05`) otherwise, `.0` on integral values.
    static func pythonFloatRepr(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        var text = value.description
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        let parts = text.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var digits = Array(mantissa[0] + (mantissa.count > 1 ? mantissa[1] : ""))
        var decimalPoint = mantissa[0].count + exponent
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            decimalPoint -= 1
        }
        while digits.count > 1, digits.last == "0" {
            digits.removeLast()
        }
        if digits == ["0"] { decimalPoint = 1 }
        let sign = negative ? "-" : ""
        if decimalPoint <= -4 || decimalPoint > 16 {
            let power = decimalPoint - 1
            let magnitude = String(abs(power))
            let fraction = digits.count > 1 ? "." + String(digits.dropFirst()) : ""
            return sign + String(digits[0]) + fraction + "e" + (power < 0 ? "-" : "+")
                + (magnitude.count < 2 ? "0" : "") + magnitude
        }
        if decimalPoint <= 0 {
            return sign + "0." + String(repeating: "0", count: -decimalPoint) + String(digits)
        }
        if decimalPoint >= digits.count {
            return sign + String(digits) + String(repeating: "0", count: decimalPoint - digits.count) + ".0"
        }
        return sign + String(digits[..<decimalPoint]) + "." + String(digits[decimalPoint...])
    }
}

// MARK: - Yams scalars

extension JSONValue {
    private static func fromYAMLScalar(_ scalar: Node.Scalar, resolved: Tag.Name) -> JSONValue {
        let node = Node.scalar(scalar)
        switch resolved {
        case .null: return node.null != nil ? .null : .string(scalar.string)
        case .bool: if let flag = node.bool { return .bool(flag) }
        case .int:
            if let number = node.int { return .int(number) }
            if let number = node.float { return .double(number) }
        case .float: if let number = node.float { return .double(number) }
        default: break
        }
        return .string(scalar.string)
    }

    private static func yamlString(_ text: String) -> Node {
        let plain = Node(text)
        return plain.tag == Tag(.str) ? plain : Node(text, Tag(.str), .singleQuoted)
    }

    /// PyYAML `represent_float`: `repr` lowercased, `.0` inserted before a bare exponent.
    private static func yamlFloat(_ value: Double) -> String {
        if value.isNaN { return ".nan" }
        if value.isInfinite { return value < 0 ? "-.inf" : ".inf" }
        let text = pythonFloatRepr(value)
        guard !text.contains("."), text.contains("e") else { return text }
        return text.replacingOccurrences(of: "e", with: ".0e")
    }
}

// MARK: - Parser

/// A small recursive-descent JSON parser over UTF-8 bytes that keeps object key order. Accepts
/// what Python's `json.loads` accepts by default, `NaN` and `Infinity` included.
private struct JSONParser {
    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard position == bytes.count else { throw error("extra data") }
        return value
    }

    private func error(_ problem: String) -> ConfigurationError {
        ConfigurationError("invalid JSON: \(problem) at byte \(position)")
    }

    private mutating func skipWhitespace() {
        while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) {
            position += 1
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard position < bytes.count else { throw error("unexpected end of input") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return try .string(parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "N"): try expect("NaN"); return .double(.nan)
        case UInt8(ascii: "I"): try expect("Infinity"); return .double(.infinity)
        case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character")
        }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes.count - position >= expected.count,
              Array(bytes[position ..< position + expected.count]) == expected
        else { throw error("expected '\(literal)'") }
        position += expected.count
    }

    private mutating func parseObject() throws -> JSONValue {
        position += 1
        var object = JSONObject()
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                throw error("expected a string key")
            }
            let key = try parseString()
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("expected ':'") }
            position += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard position < bytes.count else { throw error("unterminated object") }
            if bytes[position] == UInt8(ascii: ",") {
                position += 1
                continue
            }
            guard bytes[position] == UInt8(ascii: "}") else { throw error("expected ',' or '}'") }
            position += 1
            return .object(object)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        position += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            try items.append(parseValue())
            skipWhitespace()
            guard position < bytes.count else { throw error("unterminated array") }
            if bytes[position] == UInt8(ascii: ",") {
                position += 1
                continue
            }
            guard bytes[position] == UInt8(ascii: "]") else { throw error("expected ',' or ']'") }
            position += 1
            return .array(items)
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = position
        if bytes[position] == UInt8(ascii: "-") {
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "I") {
                try expect("Infinity")
                return .double(-.infinity)
            }
        }
        var integral = true
        if position < bytes.count, bytes[position] == UInt8(ascii: "0") {
            position += 1 // a leading zero is the whole integer part: "01" is extra data, as in Python
        } else {
            guard scanDigits() else { throw error("expected a digit") }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            integral = false
            position += 1
            guard scanDigits() else { throw error("expected a digit after '.'") }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            integral = false
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard scanDigits() else { throw error("expected an exponent") }
        }
        guard let text = String(bytes: bytes[start ..< position], encoding: .utf8) else {
            throw error("malformed number")
        }
        if integral, let number = Int(text) { return .int(number) }
        guard let number = Double(text) else { throw error("malformed number") }
        return .double(number)
    }

    private mutating func scanDigits() -> Bool {
        let start = position
        while position < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[position]) {
            position += 1
        }
        return position > start
    }

    private mutating func parseString() throws -> String {
        position += 1
        var buffer: [UInt8] = []
        while true {
            guard position < bytes.count else { throw error("unterminated string") }
            let byte = bytes[position]
            position += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let text = String(bytes: buffer, encoding: .utf8) else { throw error("invalid UTF-8 in string") }
                return text
            case UInt8(ascii: "\\"):
                try parseEscape(into: &buffer)
            case 0 ..< 0x20:
                throw error("control character in string")
            default:
                buffer.append(byte)
            }
        }
    }

    private mutating func parseEscape(into buffer: inout [UInt8]) throws {
        guard position < bytes.count else { throw error("unterminated escape") }
        let byte = bytes[position]
        position += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(byte)
        case UInt8(ascii: "b"): buffer.append(0x08)
        case UInt8(ascii: "f"): buffer.append(0x0C)
        case UInt8(ascii: "n"): buffer.append(0x0A)
        case UInt8(ascii: "r"): buffer.append(0x0D)
        case UInt8(ascii: "t"): buffer.append(0x09)
        case UInt8(ascii: "u"):
            var code = try parseHex4()
            if (0xD800 ... 0xDBFF).contains(code), position + 1 < bytes.count,
               bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") {
                let saved = position
                position += 2
                let low = try parseHex4()
                if (0xDC00 ... 0xDFFF).contains(low) {
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                } else {
                    position = saved
                }
            }
            let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
            buffer.append(contentsOf: Array(String(scalar).utf8))
        default:
            throw error("invalid escape")
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard bytes.count - position >= 4,
              let hex = String(bytes: bytes[position ..< position + 4], encoding: .utf8),
              let code = UInt32(hex, radix: 16)
        else { throw error("invalid \\u escape") }
        position += 4
        return code
    }
}
