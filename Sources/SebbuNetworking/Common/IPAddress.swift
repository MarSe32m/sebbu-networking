import SebbuCLibUV

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
import ucrt
#elseif canImport(Darwin)
import Darwin
#endif

public final class IPv4Address {
    @usableFromInline
    internal var address: sockaddr_in

    internal init(address: sockaddr_in) {
        self.address = address
    }

    public static func create(host: String, port: Int) -> IPv4Address? {
        var address = sockaddr_in()
        let result = host.withCString { hostPtr in
            uv_ip4_addr(hostPtr, numericCast(port), &address)
        }
        return result == 0 ? IPv4Address(address: address) : nil
    }

    public static func create(_ address: sockaddr) -> IPv4Address? {
        if address.sa_family != AF_INET { return nil }
        return withUnsafePointer(to: address) { addrPtr in 
            addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addrInPtr in 
                IPv4Address(address: addrInPtr.pointee)
            }
        }
    }
}

public final class IPv6Address {
    @usableFromInline
    internal var address: sockaddr_in6

    internal init(address: sockaddr_in6) {
        self.address = address
    }

    public static func create(host: String, port: Int) -> IPv6Address? {
        var address = sockaddr_in6()
        let result = host.withCString { hostPtr in
            uv_ip6_addr(hostPtr, numericCast(port), &address)
        }
        return result == 0 ? IPv6Address(address: address) : nil
    }

    public static func create(_ address: sockaddr) -> IPv6Address? {
        if address.sa_family != AF_INET6 { return nil }
        return withUnsafePointer(to: address) { addrPtr in 
            addrPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addrInPtr in 
                IPv6Address(address: addrInPtr.pointee)
            }
        }
    }
}

public enum IPAddress: CustomStringConvertible {
    case v4(IPv4Address)
    case v6(IPv6Address)

    public init?(_ address: sockaddr) {
        if let ip = IPv4Address.create(address) {
            self = .v4(ip)
        } else if let ip = IPv6Address.create(address) {
            self = .v6(ip)
        } else {
            return nil
        }
    }

    public init?(host: String, port: Int) {
        if let ip = IPv4Address.create(host: host, port: port) {
            self = .v4(ip)
        } else if let ip = IPv6Address.create(host: host, port: port) {
            self = .v6(ip)
        } else {
            return nil
        }
    }

    public var description: String {
        let ip = withSocketHandle { sockAddrPtr in
            return String(unsafeUninitializedCapacity: 46) { buffer in 
                buffer.initialize(repeating: 0)
                let result = buffer.withMemoryRebound(to: CChar.self) { buffer in 
                    uv_ip_name(sockAddrPtr, buffer.baseAddress, 46)
                }
                assert(result == 0, "Failed to create ip address with error: \(mapError(result))")
                return 46
            }
        }
        let port = switch self {
            case .v4(let ipv4):
                ipv4.address.sin_port.bigEndian
            case .v6(let ipv6):
                ipv6.address.sin6_port.bigEndian
        }
        return "\(ip):\(port)"
    }

    public static func createResolvingBlocking(host: String, port: Int) -> IPAddress? {
        let loop = EventLoop()
        let req = UnsafeMutablePointer<uv_getaddrinfo_t>.allocate(capacity: 1)
        req.initialize(to: .init())
        defer { 
            req.deinitialize(count: 1)
            req.deallocate()
        }
        let result = uv_getaddrinfo(loop._handle, req, nil, host, String(port), nil)
        if result != 0 {
            print("Failed to retrieve addrinfo")
            return nil
        }
        let info = req.pointee.addrinfo
        defer { 
            if info != nil {
                uv_freeaddrinfo(info)
            }
        }
        if let info = info, let addrPointer = info.pointee.ai_addr {
            let addressBytes = UnsafeRawPointer(addrPointer)
            switch info.pointee.ai_family {
                case AF_INET:
                    return .v4(.init(address: addressBytes.load(as: sockaddr_in.self)))
                case AF_INET6:
                    return .v6(.init(address: addressBytes.load(as: sockaddr_in6.self)))
                default:
                    return nil
            }
        }
        return nil
    }

    public static func createResolving(loop: EventLoop, host: String, port: Int, callback: @escaping (IPAddress?) -> Void) {
        loop.execute {
            let req = UnsafeMutablePointer<uv_getaddrinfo_t>.allocate(capacity: 1)
            req.initialize(to: .init())
            let reqContext = UnsafeMutablePointer<(IPAddress?) -> Void>.allocate(capacity: 1)
            reqContext.initialize(to: callback)
            req.pointee.data = .init(reqContext)
            let result = uv_getaddrinfo(loop._handle, req, { req, status, addrInfo in
                guard let callbackPtr = req?.pointee.data.assumingMemoryBound(to: ((IPAddress?) -> Void).self) else { fatalError("unreachable") }
                defer {
                    callbackPtr.deinitialize(count: 1)
                    callbackPtr.deallocate()
                    req!.deallocate()
                }
                guard status == 0 else { 
                    callbackPtr.pointee(nil)
                    return
                }
                let info = addrInfo!
                defer { uv_freeaddrinfo(info) }
                if let addrPointer = info.pointee.ai_addr {
                    let addressBytes = UnsafeRawPointer(addrPointer)
                    switch info.pointee.ai_family {
                        case AF_INET:
                            callbackPtr.pointee(.v4(.init(address: addressBytes.load(as: sockaddr_in.self))))
                        case AF_INET6:
                            callbackPtr.pointee(.v6(.init(address: addressBytes.load(as: sockaddr_in6.self))))
                        default:
                            callbackPtr.pointee(nil)
                    }
                    return
                }
                callbackPtr.pointee(nil)
            }, host, String(port), nil)
            if result != 0 {
                debugOnly {
                    print("Failed to retrieve addrinfo")
                }
                callback(nil)
                return
            }
        }
    }

    public static func createResolving(loop: EventLoop, host: String, port: Int) async -> IPAddress?  {
        await withUnsafeContinuation { continuation in
            createResolving(loop: loop, host: host, port: port) { address in 
                continuation.resume(returning: address)
            }
        }
    }

    @inlinable
    internal func withSocketHandle<T>(_ body: (UnsafePointer<sockaddr>) throws -> T) rethrows -> T {
        switch self {
            case .v4(let ipv4):
                try withUnsafePointer(to: &ipv4.address) { ptr in 
                    try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                        try body(sockAddrPtr)
                    }
                }
            case .v6(let ipv6):
                try withUnsafePointer(to: &ipv6.address) { ptr in 
                    try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in 
                        try body(sockAddrPtr)
                    }
                }
        }
    }
}

extension IPAddress: Equatable {
    public static func ==(lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
            case (.v4(let addr1), .v4(let addr2)):
                #if os(Windows)
                return addr1.address.sin_family == addr2.address.sin_family
                    && addr1.address.sin_port == addr2.address.sin_port
                    && addr1.address.sin_addr.S_un.S_addr == addr1.address.sin_addr.S_un.S_addr
                #else
                return addr1.address.sin_family == addr2.address.sin_family
                    && addr1.address.sin_port == addr2.address.sin_port
                    && addr1.address.sin_addr.s_addr == addr1.address.sin_addr.s_addr
                #endif
            case (.v6(let addr1), .v6(let addr2)):
                guard
                addr1.address.sin6_family == addr2.address.sin6_family
                    && addr1.address.sin6_port == addr2.address.sin6_port
                    && addr1.address.sin6_flowinfo == addr2.address.sin6_flowinfo
                    && addr1.address.sin6_scope_id == addr2.address.sin6_scope_id
                else {
                    return false
                }
                var s6addr1 = addr1.address.sin6_addr
                var s6addr2 = addr2.address.sin6_addr
                return memcmp(&s6addr1, &s6addr2, MemoryLayout.size(ofValue: s6addr1)) == 0
            case (.v4, _), (.v6, _):
                return false
        }
    }
}

extension IPAddress: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
            case .v4(let v4Addr):
                hasher.combine(1)
                hasher.combine(v4Addr.address.sin_family)
                hasher.combine(v4Addr.address.sin_port)
                #if os(Windows)
                hasher.combine(v4Addr.address.sin_addr.S_un.S_addr)
                #else
                hasher.combine(v4Addr.address.sin_addr.s_addr)
                #endif
            case .v6(let v6Addr):
                hasher.combine(2)
                hasher.combine(v6Addr.address.sin6_family)
                hasher.combine(v6Addr.address.sin6_port)
                hasher.combine(v6Addr.address.sin6_flowinfo)
                hasher.combine(v6Addr.address.sin6_scope_id)
                withUnsafeBytes(of: v6Addr.address.sin6_addr) {
                    hasher.combine(bytes: $0)
                }
        }
    }
}
