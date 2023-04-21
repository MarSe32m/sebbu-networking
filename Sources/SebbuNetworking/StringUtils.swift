//
//  StringUtils.swift
//  
//
//  Created by Sebastian Toivonen on 27.12.2021.
//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public extension String {
    var isIpAddress: Bool {
        #if os(Windows)
        var v4: IN_ADDR = IN_ADDR()
        var v6: IN6_ADDR = IN6_ADDR()
        return self.withCString(encodedAs: UTF16.self) {
            return InetPtonW(AF_INET, $0, &v4) == 1 ||
                   InetPtonW(AF_INET6, $0, &v6) == 1
        }
        #else
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            return inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                   inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
        #endif   
    }
}
