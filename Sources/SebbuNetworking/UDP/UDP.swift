import SebbuCLibUV

public struct UDPChannelFlags: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Disables dual stack mode
    public static let ipv6Only = UDPChannelFlags(rawValue: numericCast(UV_UDP_IPV6ONLY.rawValue))

    public static let partial = UDPChannelFlags(rawValue: numericCast(UV_UDP_PARTIAL.rawValue))
    public static let reuseaddr = UDPChannelFlags(rawValue: numericCast(UV_UDP_REUSEADDR.rawValue))
    public static let mmsgChunk = UDPChannelFlags(rawValue: numericCast(UV_UDP_MMSG_CHUNK.rawValue))
    public static let mmsgFree = UDPChannelFlags(rawValue: numericCast(UV_UDP_MMSG_FREE.rawValue))
    public static let linuxRecvErr = UDPChannelFlags(rawValue: numericCast(UV_UDP_LINUX_RECVERR.rawValue))
    public static let reuseport = UDPChannelFlags(rawValue: numericCast(UV_UDP_REUSEPORT.rawValue))
    public static let recvmmsg = UDPChannelFlags(rawValue: numericCast(UV_UDP_RECVMMSG.rawValue))
}

public enum UDPChannelError: Error {
    case channelAlreadyBound(reason: String, errorNumber: Int)
    case channelAlreadyConnected(reason: String, errorNumber: Int)
    case failedToInitializeHandle(reason: String, errorNumber: Int)
    case failedToBind(reason: String, errorNumber: Int)
    case failedToConnect(reason: String, errorNumber: Int)
    case failedToStartReceiving(reason: String, errorNumber: Int)
    case failedToSend(reason: String, errorNumber: Int)
}

public struct UDPChannelPacket {
    public let address: IPAddress
    public let data: [UInt8]

    public init(address: IPAddress, data: [UInt8]) {
        self.address = address
        self.data = data
    }
}