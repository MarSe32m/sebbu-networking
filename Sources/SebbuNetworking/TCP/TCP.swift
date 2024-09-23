import SebbuCLibUV

public struct TCPChannelFlags: OptionSet, Sendable {
    public typealias RawValue = UInt32

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let ipv6only = TCPChannelFlags(rawValue: numericCast(UV_TCP_IPV6ONLY.rawValue))
    public static let reuseport = TCPChannelFlags(rawValue: numericCast(UV_TCP_REUSEPORT.rawValue))
}

public enum TCPServerChannelState {
    case unbound
    case bound
    case listening
    case closed
}

public enum TCPClientChannelState {
    case disconnected
    case connected
    case closed
}

public enum TCPClientChannelError: Error {
    case failedToSetKeepalive(reason: String, errorNumber: Int)
    case failedToSetNodelay(reason: String, errorNumber: Int)
    case failedToSend(reason: String, errorNumber: Int)
    case connectionFailure(reason: String, errorNumber: Int)
}

public enum TCPServerChannelError: Error {
    case failedToBind(reason: String, errorNumber: Int)
    case failedToListen(reason: String, errorNumber: Int)
}