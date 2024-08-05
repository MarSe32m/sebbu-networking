//
//  WebSocketClient.swift
//  
//
//  Created by Sebastian Toivonen on 17.6.2021.
//

#if canImport(NIO_)
import NIO
@_exported import WebSocketKit
import NIOWebSocket

public extension WebSocketClient {
    func connect(scheme: String = "ws", host: String, port: Int, path: String = "/", headers: HTTPHeaders = [:]) async throws -> WebSocket {
        return try await withUnsafeThrowingContinuation { continuation in
            connect(scheme: scheme, host: host, port: port, path: path, headers: headers) { ws in
                continuation.resume(returning: ws)
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }
}

public extension WebSocket {
    static func connect(to url: String, headers: HTTPHeaders = [:], configuration: WebSocketClient.Configuration = .init(), on group: EventLoopGroup) async throws -> WebSocket {
        try await withUnsafeThrowingContinuation { continuation in
            connect(to: url, headers: headers, configuration: configuration, on: group) { websocket in
                continuation.resume(returning: websocket)
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }
    
    static func connect(scheme: String = "ws", host: String, port: Int, path: String = "/", query: String?, headers: HTTPHeaders = [:], configuration: WebSocketClient.Configuration = .init(), on group: EventLoopGroup) async throws -> WebSocket {
        try await withUnsafeThrowingContinuation { continuation in
            connect(scheme: scheme, host: host, port: port, path: path, query: query, headers: headers, configuration: configuration, on: group) { websocket in
                continuation.resume(returning: websocket)
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
