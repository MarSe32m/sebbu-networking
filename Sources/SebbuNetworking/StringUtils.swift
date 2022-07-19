//
//  StringUtils.swift
//  
//
//  Created by Sebastian Toivonen on 27.12.2021.
//

#if os(macOS) || os(iOS)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public extension String {
    func isIpAddress() -> Bool {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            return inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                   inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
    }
}
