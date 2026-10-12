import Foundation

/// 豆包流式语音识别 WebSocket 二进制帧。
/// 字段布局依据火山引擎《大模型流式语音识别 API》，文档更新时间 2026-08-06。
/// https://www.volcengine.com/docs/6561/1354869
/// 默认地址和资源 ID 是文档给出的推荐值，不是对本机账号的实测结论。
enum DoubaoDefaults {
    static let endpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    static let legacyEndpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"
    static let nostreamEndpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
    static let resourceID = "volc.seedasr.sauc.duration"
    static let resourceIDV1 = "volc.bigasr.sauc.duration"

    static let documentedEndpoints = [endpoint, legacyEndpoint, nostreamEndpoint]
    static let documentedResourceIDs = [
        "volc.seedasr.sauc.duration",
        "volc.seedasr.sauc.concurrent",
        "volc.bigasr.sauc.duration",
        "volc.bigasr.sauc.concurrent"
    ]
}

enum DoubaoMessageType: UInt8, Equatable {
    case fullClient = 0x1
    case audioOnly = 0x2
    case fullServer = 0x9
    case error = 0xF
}

struct DoubaoFrame: Equatable {
    var messageType: DoubaoMessageType
    var flags: UInt8
    var serialization: UInt8
    var compression: UInt8
    var sequence: Int32?
    var payload: Data
    var errorCode: UInt32?

    var isLast: Bool { flags & 0x02 != 0 }
    var hasSequence: Bool { flags & 0x01 != 0 }
}

enum DoubaoFrameCodec {
    static let jsonSerialization: UInt8 = 0x1
    static let rawSerialization: UInt8 = 0x0
    static let gzipCompression: UInt8 = 0x1
    static let noCompression: UInt8 = 0x0

    static func encodeFullClient(json: Data, sequence: Int32, gzip: Bool) -> Data {
        let compressed = gzip ? Gzip.compress(json) : nil
        return encode(
            messageType: .fullClient,
            flags: 0x1,
            serialization: jsonSerialization,
            compression: compressed == nil ? noCompression : gzipCompression,
            sequence: sequence,
            payload: compressed ?? json
        )
    }

    static func encodeAudio(pcm: Data, sequence: Int32, isLast: Bool, gzip: Bool) -> Data {
        let compressed = gzip ? Gzip.compress(pcm) : nil
        let payload = compressed ?? pcm
        return encode(
            messageType: .audioOnly,
            flags: isLast ? 0x3 : 0x1,
            serialization: rawSerialization,
            compression: compressed == nil ? noCompression : gzipCompression,
            sequence: isLast ? -abs(sequence) : sequence,
            payload: payload
        )
    }

    static func encodeServerResponse(json: Data, sequence: Int32, isLast: Bool, gzip: Bool) -> Data {
        let compressed = gzip ? Gzip.compress(json) : nil
        return encode(
            messageType: .fullServer,
            flags: isLast ? 0x3 : 0x1,
            serialization: jsonSerialization,
            compression: compressed == nil ? noCompression : gzipCompression,
            sequence: sequence,
            payload: compressed ?? json
        )
    }

    static func encodeServerError(code: UInt32, message: String) -> Data {
        let payload = Data(message.utf8)
        var data = Data(header(messageType: .error, flags: 0x0, serialization: jsonSerialization, compression: noCompression))
        data.append(uint32(code))
        data.append(uint32(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) throws -> DoubaoFrame {
        guard data.count >= 4 else { throw DoubaoCodecError.truncated }
        let headerSize = Int(data[0] & 0x0F) * 4
        guard headerSize >= 4, data.count >= headerSize else { throw DoubaoCodecError.truncated }
        guard let messageType = DoubaoMessageType(rawValue: data[1] >> 4) else {
            throw DoubaoCodecError.unknownMessageType
        }
        let flags = data[1] & 0x0F
        let serialization = data[2] >> 4
        let compression = data[2] & 0x0F
        var offset = headerSize
        var sequence: Int32?
        if flags & 0x01 != 0 {
            sequence = try readInt32(data, offset: &offset)
        }

        if messageType == .error {
            let code = try readUInt32(data, offset: &offset)
            let size = try readUInt32(data, offset: &offset)
            let payload = try readPayload(data, offset: &offset, size: size, compression: compression)
            return DoubaoFrame(
                messageType: messageType,
                flags: flags,
                serialization: serialization,
                compression: compression,
                sequence: sequence,
                payload: payload,
                errorCode: code
            )
        }

        let size = try readUInt32(data, offset: &offset)
        let payload = try readPayload(data, offset: &offset, size: size, compression: compression)
        return DoubaoFrame(
            messageType: messageType,
            flags: flags,
            serialization: serialization,
            compression: compression,
            sequence: sequence,
            payload: payload,
            errorCode: nil
        )
    }

    private static func encode(
        messageType: DoubaoMessageType,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        sequence: Int32?,
        payload: Data
    ) -> Data {
        var data = Data(header(
            messageType: messageType,
            flags: flags,
            serialization: serialization,
            compression: compression
        ))
        if let sequence {
            data.append(int32(sequence))
        }
        data.append(uint32(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    private static func header(
        messageType: DoubaoMessageType,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8
    ) -> [UInt8] {
        [
            0x11,
            (messageType.rawValue << 4) | (flags & 0x0F),
            (serialization << 4) | (compression & 0x0F),
            0x00
        ]
    }

    private static func readPayload(
        _ data: Data,
        offset: inout Int,
        size: UInt32,
        compression: UInt8
    ) throws -> Data {
        let count = Int(size)
        guard offset + count <= data.count else { throw DoubaoCodecError.truncated }
        let raw = data.subdata(in: offset..<(offset + count))
        offset += count
        if compression == gzipCompression {
            guard let inflated = Gzip.decompress(raw) else { throw DoubaoCodecError.badGzip }
            return inflated
        }
        return raw
    }

    private static func readInt32(_ data: Data, offset: inout Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32(data, offset: &offset))
    }

    private static func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw DoubaoCodecError.truncated }
        let value = data.subdata(in: offset..<(offset + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func int32(_ value: Int32) -> Data {
        uint32(UInt32(bitPattern: value))
    }
}

enum DoubaoCodecError: Error, Equatable {
    case truncated
    case unknownMessageType
    case badGzip
}

enum ASRError: Error, Equatable {
    case missingCredential
    case badEndpoint
    case connectionFailed
    /// HTTP 升级没有变成 101。`httpStatus == nil` 表示系统没有带回状态码。
    case handshakeRejected(httpStatus: Int?)
    case server(code: UInt32)
    case finalTimeout
    case cancelled
    case notConnected

    var message: String {
        switch self {
        case .missingCredential:
            return "还没有填写语音识别凭证。"
        case .badEndpoint:
            return "语音识别地址不正确。"
        case .connectionFailed:
            return "连接语音识别服务失败。"
        case let .handshakeRejected(httpStatus):
            return Self.handshakeMessage(httpStatus: httpStatus)
        case let .server(code):
            return Self.serverMessage(code)
        case .finalTimeout:
            return "等待识别结果超时。"
        case .cancelled:
            return "已取消。"
        case .notConnected:
            return "语音识别连接没有建立。"
        }
    }

    /// 把 URLSession 的传输错误收成可展示的识别错误。已经是 `ASRError` 时原样返回。
    static func classifyTransport(_ error: Error, http: HTTPURLResponse?) -> ASRError {
        if let asr = error as? ASRError { return asr }
        if error is CancellationError { return .cancelled }
        let status = http?.statusCode
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .badServerResponse:
                return .handshakeRejected(httpStatus: status == 101 ? nil : status)
            default:
                break
            }
        }
        if let status, status != 101 {
            return .handshakeRejected(httpStatus: status)
        }
        return .connectionFailed
    }

    static func handshakeMessage(httpStatus: Int?) -> String {
        switch httpStatus {
        case 401:
            return "语音识别凭证被拒绝。新版控制台填写 API Key；旧版控制台填写 App ID 和 Access Token。"
        case 403:
            return "当前资源 ID 没有开通。模型 2.0 小时版使用 volc.seedasr.sauc.duration，模型 1.0 小时版使用 volc.bigasr.sauc.duration。"
        case let status?:
            return "语音识别服务没有接受这次连接（HTTP \(status)）。请核对地址、资源 ID 和密钥。"
        default:
            return "语音识别服务没有接受这次连接。请核对密钥，并确认资源 ID 与已开通的模型一致。"
        }
    }

    static func serverMessage(_ code: UInt32) -> String {
        switch code {
        case 45000001: return "请求参数无效（\(code)）。"
        case 45000002: return "没有识别到语音（\(code)）。"
        case 45000081: return "语音数据包超时（\(code)）。"
        case 45000151: return "音频格式不正确（\(code)）。"
        case 55000031: return "语音服务繁忙（\(code)）。"
        default: return "语音识别失败（\(code)）。"
        }
    }
}

enum DoubaoRequestBuilder {
    struct Payload: Encodable {
        struct User: Encodable {
            var uid: String
        }
        struct Audio: Encodable {
            var format = "pcm"
            var codec = "raw"
            var rate = 16000
            var bits = 16
            var channel = 1
        }
        struct Request: Encodable {
            var model_name = "bigmodel"
            var enable_itn = true
            var enable_punc = true
            var enable_ddc = false
            var show_utterances = true
            var result_type = "full"
        }
        var user: User
        var audio = Audio()
        var request = Request()
    }

    static func json(uid: String) -> Data {
        let payload = Payload(user: Payload.User(uid: uid))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }
}

enum ASRAuthMode: String, Codable, Equatable, Sendable {
    case apiKey
    case legacy
}

struct DoubaoConfig: Equatable, Sendable {
    var endpoint: String
    var resourceID: String
    var authMode: ASRAuthMode
    var apiKey: String
    var appKey: String
    var accessKey: String
    var connectID: String

    func urlRequest() throws -> URLRequest {
        guard let url = URL(string: endpoint), let scheme = url.scheme, scheme == "wss" || scheme == "https" else {
            throw ASRError.badEndpoint
        }
        guard !resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASRError.missingCredential
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = SessionLimits.connectTimeoutSeconds
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        switch authMode {
        case .apiKey:
            guard !apiKey.isEmpty else { throw ASRError.missingCredential }
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        case .legacy:
            guard !appKey.isEmpty, !accessKey.isEmpty else { throw ASRError.missingCredential }
            request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        }
        return request
    }
}
