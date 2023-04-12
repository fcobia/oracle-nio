import struct NIOCore.ByteBuffer

extension ByteBuffer {
    mutating func skipUB1() {
        self.moveReaderIndex(forwardByBytes: 1)
    }

    mutating func readUB1() -> UInt8? {
        readInteger(as: UInt8.self)
    }

    mutating func skipUB2() {
        guard let length = readUBLength() else { return }
        guard length <= 2 else { fatalError() }
        self.moveReaderIndex(forwardByBytes: Int(length))
    }

    mutating func readUB2() -> UInt16? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt16.init(_:))
        case 2:
            return self.readInteger(as: UInt16.self)
        default:
            fatalError()
        }
    }

    mutating func readUB4() -> UInt32? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt32.init(_:))
        case 2:
            return self.readInteger(as: UInt16.self).map(UInt32.init(_:))
        case 4:
            return self.readInteger(as: UInt32.self)
        default:
            fatalError()
        }
    }

    mutating func skipUB4() {
        guard let length = readUBLength() else { return }
        guard length <= 4 else { fatalError() }
        self.moveReaderIndex(forwardByBytes: Int(length))
    }

    mutating func readUB8() -> UInt64? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt64.init)
        case 2:
            return self.readInteger(as: UInt16.self).map(UInt64.init)
        case 4:
            return self.readInteger(as: UInt32.self).map(UInt64.init)
        case 8:
            return self.readInteger(as: UInt64.self)
        default:
            fatalError()
        }
    }

    mutating func readUBLength() -> UInt8? {
        guard let first = self.readBytes(length: 1)?.first else { return nil }
        let length: UInt8
        if first & 0x80 != 0 {
            length = first & 0x7f
        } else {
            length = first
        }
        return length
    }

    mutating func writeUB4(_ integer: UInt32) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt32(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        case (UInt32(UInt8.max) + 1)...UInt32(UInt16.max):
            self.writeInteger(UInt8(2))
            self.writeInteger(UInt16(integer))
        default:
            self.writeInteger(UInt8(4))
            self.writeInteger(integer)
        }
    }

    mutating func writeUB8(_ integer: UInt64) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt64(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            self.writeInteger(UInt8(2))
            self.writeInteger(UInt16(integer))
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            self.writeInteger(UInt8(4))
            self.writeInteger(UInt32(integer))
        default:
            self.writeInteger(UInt8(8))
            self.writeInteger(integer)
        }
    }
}

extension ByteBuffer {
    /// Skip a number of bytes that may or may not be chunked in the buffer.
    /// The first byte gives the length. If the length is
    /// TNS_LONG_LENGTH_INDICATOR, however, chunks are read and discarded.
    mutating func skipRawBytesChunked() {
        guard let length = readUB1() else { return }
        if length != Constants.TNS_LONG_LENGTH_INDICATOR {
            moveReaderIndex(forwardByBytes: Int(length))
        } else {
            while true {
                guard let tmp = self.readUB4() else { break }
                if tmp == 0 { break }
                moveReaderIndex(forwardByBytes: Int(tmp))
            }
        }
    }
}
