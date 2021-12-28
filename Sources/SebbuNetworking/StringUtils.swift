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
#endif

//TODO: Implement this to work on Windows aswell
#if !os(Windows)
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
#else
//TODO: Remove
public extension String {
    func isIPv4() -> Bool {
        let items = self.components(separatedBy: ".")
        
        if items.count != 4 { return false }
        
        for item in items {
            var tmp = 0
            if item.count > 3 || item.count < 1 {
                return false
            }
            
            for char in item {
                if char < "0" || char > "9" {
                    return false
                }
                
                tmp = tmp * 10 + Int(String(char))!
            }
            
            if tmp < 0 || tmp > 255 {
                return false
            }
            
            if (tmp > 0 && item.first == "0") || (tmp == 0 && item.count > 1) {
                return false
            }
        }
        
        return true
    }

    func isIPv6() -> Bool {
        let items = self.components(separatedBy: ":")
        if items.count != 8 {
            return false
        }
        
        for item in items {
            if item.count > 4 || item.count < 1 {
                return false;
            }
            
            for char in item.lowercased() {
                if((char < "0" || char > "9") && (char < "a" || char > "f")){
                    return false
                }
            }
        }
        return true
    }

    func isIpAddress() -> Bool { return self.isIPv6() || self.isIPv4() }
}
#endif
