import Foundation

enum Gzip {
    static func compress(_ data: Data) -> Data? {
        transcode(data, compress: true)
    }

    static func decompress(_ data: Data) -> Data? {
        transcode(data, compress: false)
    }

    private static func transcode(_ data: Data, compress: Bool) -> Data? {
        var stream = z_stream()
        let windowBits = MAX_WBITS + 16
        let initCode: Int32
        if compress {
            initCode = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                windowBits,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        } else {
            initCode = inflateInit2_(
                &stream,
                windowBits,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }
        guard initCode == Z_OK else { return nil }
        defer {
            if compress {
                deflateEnd(&stream)
            } else {
                inflateEnd(&stream)
            }
        }

        let source = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(compress ? source.count + 64 : max(source.count * 2, 64))
        var sourceOffset = 0
        var status = Z_OK

        repeat {
            let chunkCapacity = 16_384
            var chunk = [UInt8](repeating: 0, count: chunkCapacity)
            let produced: Int
            let code: Int32
            (code, produced) = chunk.withUnsafeMutableBufferPointer { outBuffer in
                source.withUnsafeBufferPointer { inBuffer in
                    if source.count == sourceOffset || inBuffer.baseAddress == nil {
                        stream.next_in = nil
                        stream.avail_in = 0
                    } else {
                        stream.next_in = UnsafeMutablePointer(mutating: inBuffer.baseAddress!).advanced(by: sourceOffset)
                        stream.avail_in = uInt(source.count - sourceOffset)
                    }
                    stream.next_out = outBuffer.baseAddress
                    stream.avail_out = uInt(chunkCapacity)
                    let result = compress
                        ? deflate(&stream, Z_FINISH)
                        : inflate(&stream, Z_NO_FLUSH)
                    let wrote = chunkCapacity - Int(stream.avail_out)
                    let consumedNow = (source.count - sourceOffset) - Int(stream.avail_in)
                    sourceOffset += consumedNow
                    return (result, wrote)
                }
            }
            status = code
            if produced > 0 {
                output.append(contentsOf: chunk.prefix(produced))
            }
            if status == Z_STREAM_END {
                break
            }
            if status != Z_OK {
                return nil
            }
        } while output.count < 8_000_000

        guard status == Z_STREAM_END else { return nil }
        return Data(output)
    }
}
