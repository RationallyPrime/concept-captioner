import Foundation

/// A display-only projection of the Caption string while its JSON object is still arriving.
/// It never supplies an output to validation or a sink.
enum PartialCaption {
    static func text(from json: String) -> String {
        let bytes = Array(json.utf8)
        var depth = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x7B || byte == 0x5B { depth += 1 }
            if byte == 0x7D || byte == 0x5D { depth -= 1 }
            if byte == 0x22 {
                let start = index
                index = stringEnd(bytes, from: index + 1)
                guard index < bytes.count else { return "" }
                if depth == 1,
                   (try? JSONDecoder().decode(String.self, from: Data(bytes[start ... index]))) == "caption" {
                    var value = index + 1
                    while value < bytes.count, whitespace(bytes[value]) {
                        value += 1
                    }
                    guard value < bytes.count, bytes[value] == 0x3A else { return "" }
                    value += 1
                    while value < bytes.count, whitespace(bytes[value]) {
                        value += 1
                    }
                    guard value < bytes.count, bytes[value] == 0x22 else { return "" }
                    let end = stringEnd(bytes, from: value + 1)
                    if end < bytes.count {
                        return (try? JSONDecoder().decode(String.self, from: Data(bytes[value ... end]))) ?? ""
                    }
                    // A chunk can end inside an escape, UTF-8 scalar or surrogate pair. Keep only
                    // the decodable prefix until the remainder arrives in the next real delta.
                    var prefix = Array(bytes[value...])
                    for _ in 0 ... 12 {
                        if let text = try? JSONDecoder().decode(String.self, from: Data(prefix + [0x22])) {
                            return text
                        }
                        guard prefix.count > 1 else { break }
                        prefix.removeLast()
                    }
                    return ""
                }
            }
            index += 1
        }
        return ""
    }

    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x22 { return index }
            if bytes[index] == 0x5C { index += 1 }
            index += 1
        }
        return bytes.count
    }

    private static func whitespace(_ byte: UInt8) -> Bool {
        [0x09, 0x0A, 0x0D, 0x20].contains(byte)
    }
}
