import Foundation

public struct GGUFModelMetadata: Equatable, Sendable {
    public let name: String?
    public let sizeLabel: String?

    public init(name: String?, sizeLabel: String?) {
        self.name = name
        self.sizeLabel = sizeLabel
    }

    public static func read(
        from url: URL,
        fileManager: FileManager = .default
    ) -> GGUFModelMetadata? {
        guard
            fileManager.fileExists(atPath: url.path),
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }
        defer { try? handle.close() }

        var reader = Reader(handle: handle)
        guard
            reader.readBytes(count: 4) == Data("GGUF".utf8),
            let version: UInt32 = reader.readInteger(),
            (2...3).contains(version),
            let _: UInt64 = reader.readInteger(),
            let metadataCount: UInt64 = reader.readInteger()
        else {
            return nil
        }

        var name: String?
        var sizeLabel: String?
        for _ in 0..<metadataCount {
            guard
                let key = reader.readString(),
                let valueType: UInt32 = reader.readInteger()
            else {
                return nil
            }

            if valueType == ValueType.string.rawValue,
               key == "general.name" || key == "general.size_label" {
                guard let value = reader.readString() else { return nil }
                if key == "general.name" {
                    name = value
                } else {
                    sizeLabel = value
                }
                if name != nil, sizeLabel != nil {
                    return GGUFModelMetadata(
                        name: name,
                        sizeLabel: sizeLabel
                    )
                }
            } else if !reader.skipValue(type: valueType) {
                return nil
            }
        }

        guard name != nil || sizeLabel != nil else { return nil }
        return GGUFModelMetadata(name: name, sizeLabel: sizeLabel)
    }
}

private extension GGUFModelMetadata {
    enum ValueType: UInt32 {
        case uint8 = 0
        case int8 = 1
        case uint16 = 2
        case int16 = 3
        case uint32 = 4
        case int32 = 5
        case float32 = 6
        case bool = 7
        case string = 8
        case array = 9
        case uint64 = 10
        case int64 = 11
        case float64 = 12
    }

    struct Reader {
        let handle: FileHandle

        mutating func readBytes(count: Int) -> Data? {
            guard count >= 0 else { return nil }
            return try? handle.read(upToCount: count).flatMap {
                $0.count == count ? $0 : nil
            }
        }

        mutating func readInteger<T: FixedWidthInteger>() -> T? {
            guard let data = readBytes(count: MemoryLayout<T>.size) else {
                return nil
            }
            return data.withUnsafeBytes {
                $0.loadUnaligned(as: T.self).littleEndian
            }
        }

        mutating func readString() -> String? {
            guard
                let length: UInt64 = readInteger(),
                length <= UInt64(Int.max),
                let data = readBytes(count: Int(length))
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        mutating func skipValue(type rawType: UInt32) -> Bool {
            guard let type = ValueType(rawValue: rawType) else {
                return false
            }
            switch type {
            case .uint8, .int8, .bool:
                return skip(byteCount: 1)
            case .uint16, .int16:
                return skip(byteCount: 2)
            case .uint32, .int32, .float32:
                return skip(byteCount: 4)
            case .uint64, .int64, .float64:
                return skip(byteCount: 8)
            case .string:
                return readString() != nil
            case .array:
                guard
                    let elementType: UInt32 = readInteger(),
                    let count: UInt64 = readInteger()
                else {
                    return false
                }
                for _ in 0..<count {
                    guard skipValue(type: elementType) else { return false }
                }
                return true
            }
        }

        private mutating func skip(byteCount: UInt64) -> Bool {
            guard
                let offset = try? handle.offset(),
                offset <= UInt64.max - byteCount
            else {
                return false
            }
            do {
                try handle.seek(toOffset: offset + byteCount)
                return true
            } catch {
                return false
            }
        }
    }
}
