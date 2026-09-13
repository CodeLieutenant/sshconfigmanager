import Foundation
import SQLite3

nonisolated struct LegacySQLiteReader {
    enum Value: Sendable {
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null

        var string: String? {
            switch self {
            case .text(let text): text
            case .integer(let number): String(number)
            case .real(let number): String(number)
            case .blob, .null: nil
            }
        }

        var int: Int? {
            switch self {
            case .integer(let number): Int(number)
            case .real(let number): Int(number)
            case .text(let text): Int(text)
            case .blob, .null: nil
            }
        }

        var double: Double? {
            switch self {
            case .real(let number): number
            case .integer(let number): Double(number)
            case .text(let text): Double(text)
            case .blob, .null: nil
            }
        }

        var bool: Bool { (int ?? 0) != 0 }

        var data: Data? {
            if case .blob(let data) = self { return data }
            return nil
        }
    }

    typealias Row = [String: Value]

    enum Failure: Error, CustomStringConvertible {
        case open(String)

        var description: String {
            switch self {
            case .open(let message): "cannot open legacy database: \(message)"
            }
        }
    }

    private let handle: OpaquePointer

    init(url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw Failure.open(message)
        }
        handle = db
    }

    func close() {
        sqlite3_close(handle)
    }

    func tableExists(_ name: String) -> Bool {
        !rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(name)'").isEmpty
    }

    func rows(_ sql: String) -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: Row = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                row[name] = value(statement, column)
            }
            result.append(row)
        }
        return result
    }

    private func value(_ statement: OpaquePointer, _ column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}
