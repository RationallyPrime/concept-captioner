// The imagefolder convention's metadata.jsonl: one row per image with file_name, the caption
// column and the "<caption>_response" JSON-string column (parity with HFDatasetSink).

import Foundation

public struct MetadataRow: Sendable, Equatable {
    /// Relative to the metadata.jsonl directory.
    public var fileName: String
    /// "" or absent reads as nil.
    public var caption: String?
    /// Stored as a JSON string column; an object is also accepted on read.
    public var record: ResponseRecord?
    /// Other columns, preserved.
    public var extra: JSONObject

    public init(fileName: String, caption: String? = nil, record: ResponseRecord? = nil, extra: JSONObject = [:]) {
        self.fileName = fileName
        self.caption = caption
        self.record = record
        self.extra = extra
    }
}

public enum ImageFolderMetadata {
    public static let fileName = "metadata.jsonl"
    public static let fileNameColumn = "file_name"

    /// The record column that pairs with a caption column, as HFDatasetSink names it.
    public static func recordColumn(for captionColumn: String) -> String {
        "\(captionColumn)_response"
    }

    /// One object per non-empty line. HubError.malformed for a line that is not a JSON object
    /// with a string `file_name`, or whose caption column is neither a string nor null. A record
    /// column that is not JSON or not a JSON object reads as nil, as HFDatasetSink ignores an
    /// undecodable record; any object loads (`{}` included, as `json.loads` keeps it), with a
    /// missing `sample_id` taken from `file_name`.
    public static func parse(_ data: Data, captionColumn: String = "caption") throws -> [MetadataRow] {
        let recordColumn = recordColumn(for: captionColumn)
        var rows: [MetadataRow] = []
        var lineNumber = 0
        for rawLine in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = trimmed(rawLine)
            guard !line.isEmpty else { continue }
            let json: JSONValue
            do {
                json = try JSONValue(parsing: Data(line))
            } catch {
                throw HubError.malformed("\(fileName) line \(lineNumber) is not JSON: \(error.localizedDescription)")
            }
            guard var object = json.objectValue else {
                throw HubError.malformed("\(fileName) line \(lineNumber) is not a JSON object")
            }
            guard let name = object[fileNameColumn]?.stringValue else {
                throw HubError.malformed("\(fileName) line \(lineNumber) has no string \(fileNameColumn)")
            }
            let caption: String? = switch object[captionColumn] {
            case .none, .some(.null): nil
            case let .some(.string(text)): text.isEmpty ? nil : text
            default: throw HubError.malformed("\(fileName) line \(lineNumber): '\(captionColumn)' must be a string")
            }
            let record = parseRecord(object[recordColumn], fileName: name)
            object.removeValue(forKey: fileNameColumn)
            object.removeValue(forKey: captionColumn)
            object.removeValue(forKey: recordColumn)
            rows.append(MetadataRow(fileName: name, caption: caption, record: record, extra: object))
        }
        return rows
    }

    /// {"file_name", ...extra, "<caption>", "<caption>_response"} per line, `json.dumps` style,
    /// each line newline-terminated. Missing captions and records are written as "".
    public static func serialize(_ rows: [MetadataRow], captionColumn: String = "caption") -> Data {
        let recordColumn = recordColumn(for: captionColumn)
        var text = ""
        for row in rows {
            var object: JSONObject = [fileNameColumn: .string(row.fileName)]
            for pair in row.extra.pairs
                where pair.key != fileNameColumn && pair.key != captionColumn && pair.key != recordColumn {
                object[pair.key] = pair.value
            }
            object[captionColumn] = .string(row.caption ?? "")
            object[recordColumn] = .string(row.record.map { $0.jsonValue.pythonDumps() } ?? "")
            text += JSONValue.object(object).pythonDumps() + "\n"
        }
        return Data(text.utf8)
    }

    /// A JSON string holding a record (the written form), or an object (accepted on read).
    private static func parseRecord(_ value: JSONValue?, fileName: String) -> ResponseRecord? {
        switch value {
        case let .some(.string(text)):
            guard let json = try? JSONValue(parsing: text) else { return nil }
            return try? ResponseRecord(json: json, sampleID: fileName)
        case let .some(.object(object)):
            return try? ResponseRecord(json: .object(object), sampleID: fileName)
        default:
            return nil
        }
    }

    /// The line without surrounding ASCII whitespace (a CR from CRLF files included).
    private static func trimmed(_ line: Data) -> Data {
        let blank: Set<UInt8> = [0x20, 0x09, 0x0D]
        var start = line.startIndex
        var end = line.endIndex
        while start < end, blank.contains(line[start]) {
            start = line.index(after: start)
        }
        while end > start, blank.contains(line[line.index(before: end)]) {
            end = line.index(before: end)
        }
        return line[start ..< end]
    }
}
