//
//  NetworkUtils.swift
//  
//
//  Created by Sebastian Toivonen on 9.2.2020.
//  Copyright © 2021 Sebastian Toivonen. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct NetworkUtils {
    private struct IpifyJson: Codable {
        let ip: String
    }

    private struct HTTPBinJson: Codable {
        let origin: String
    }
    
    private static let ipAddressProviders = ["https://api64.ipify.org/?format=json", 
                                             "https://api.ipify.org/?format=json",
                                             "http://myexternalip.com/json"]
    
    public static let publicIP: String? = {
        for address in ipAddressProviders {
            guard let url = URL(string: address) else {
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                let ipAddress = try JSONDecoder().decode(IpifyJson.self, from: data).ip
                if ipAddress.isIpAddress() {
                    return ipAddress
                }
            } catch let error {
                print("Error retreiving IP address from: \(address)")
                print(error)
            }
        }
        
        if let url = URL(string: "http://checkip.amazonaws.com/") {
            do {
                let ipAddress = try String(contentsOf: url)
                if ipAddress.isIpAddress() {
                    return ipAddress
                }
            } catch let error {
                print("Error retreiving IP address from: \(url)")
                print(error)
            }
        }
        
        if let url = URL(string: "http://httbin.org/ip") {
            do {
                let data = try Data(contentsOf: url)
                let ipAddress = try JSONDecoder().decode(HTTPBinJson.self, from: data).origin
                if ipAddress.isIpAddress() {
                    return ipAddress
                }
            } catch let error {
                print("Error retrieving IP address from: \(url)")
                print(error)
            }
        }
        return nil
    }()
}
