import NIOCore

// MARK: Int64

extension Int64: OracleDecodable {
    public init<JSONDecoder: OracleJSONDecoder>(
        from buffer: inout NIOCore.ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext<JSONDecoder>
    ) throws {
        switch type {
        case .number, .binaryInteger:
            self = try OracleNumeric.parseInteger(from: &buffer)
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}
