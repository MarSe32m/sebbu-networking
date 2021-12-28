//
//  SebbuNetworkingBasicNetworkingTests.swift
//
//
//  Created by Sebastian Toivonen on 28.12.2021.
//

#if canImport(NIO)
import XCTest
import Foundation
import NIO
import NIOHTTP1
import SebbuNetworking


private let testingData = (0..<128).map { _ in UInt8.random(in: .min ... .max) }

final class SebbuNetworkingBasicNetworkingTests: XCTestCase {
    
    func testUDPClientServer() throws {
        class ServerDelegate: UDPServerProtocol {
            unowned var udpServer: UDPServer!
            
            func received(data: [UInt8], address: SocketAddress) {
                XCTAssertEqual(testingData, data)
                udpServer.send(data: data, address: address)
            }
        }
        
        class ClientDelegate: UDPClientProtocol {
            var successfulReceives = 0
            func received(data: [UInt8], address: SocketAddress) {
                XCTAssertEqual(testingData, data)
                successfulReceives += 1
            }
        }
        
        let serverDelegate = ServerDelegate()
        let server = UDPServer()
        server.delegate = serverDelegate
        serverDelegate.udpServer = server
        server.recvBufferSize = 1024 * 1024
        server.sendBufferSize = 1024 * 1024
        try server.startIPv4(port: 25567)
        try server.startIPv6(port: 25568)
        
        let clientDelegate = ClientDelegate()
        let client = UDPClient()
        client.delegate = clientDelegate
        try client.start()
        
        while clientDelegate.successfulReceives < 10000 {
            client.send(data: testingData, address: try .init(ipAddress: "127.0.0.1", port: 25567))
            client.send(data: testingData, address: try .init(ipAddress: "::1", port: 25568))
            Thread.sleep(forTimeInterval: 0.001)
        }
        try server.shutdown()
        try client.shutdown()
    }
    #if canImport(TestDisabled)
    func testTCPClientServer() async throws {
        class ServerHandler: TCPServerProtocol {
            var clients = [TCPClient]()
            var handlers = [ServerClientHandler]()
            func connected(_ client: TCPClient) {
                clients.append(client)
                let handler = ServerClientHandler()
                handlers.append(handler)
                client.delegate = handler
                client.eventLoopGroup.next().scheduleTask(deadline: NIODeadline.now() + .milliseconds(1)) {
                    for _ in 0..<10_000 {
                        client.send([1,1,1,1,1])
                    }
                }
            }
        }
        
        class ServerClientHandler: TCPClientProtocol {
            var totalReceivedData = [UInt8]()
            let expectedData: [UInt8] = (0..<10_000).flatMap {_ in [2,2,2,2,2]}
            var isConnected = false
            
            func connected() {
                XCTAssertFalse(isConnected)
                isConnected = true
                totalReceivedData.reserveCapacity(10_000 * 5)
            }
    
            func disconnected() {
                XCTAssertTrue(isConnected)
                isConnected = false
                print("Server Client: Disconnected from server!")
                XCTAssertEqual(totalReceivedData.count, expectedData.count)
                XCTAssertEqual(totalReceivedData, expectedData)
            }
            
            func received(_ data: [UInt8]) {
                totalReceivedData += data
            }
        }
        
        class ClientHandler: TCPClientProtocol {
            var totalReceivedData = [UInt8]()
            let expectedData: [UInt8] = (0..<10_000).flatMap {_ in [1,1,1,1,1]}
            var isConnected = false
            func connected() {
                XCTAssertFalse(isConnected)
                isConnected = true
                totalReceivedData.reserveCapacity(10000 * 5)
            }
            
            func disconnected() {
                XCTAssertTrue(isConnected)
                isConnected = false
                
                print("Client: Disconnected from server!")
                XCTAssertEqual(totalReceivedData.count, expectedData.count)
                XCTAssertEqual(totalReceivedData, expectedData)
            }
            
            func received(_ data: [UInt8]) {
                totalReceivedData += data
            }
        }
        
        let serverDelegate = ServerHandler()
        
        let serveripv4 = TCPServer()
        serveripv4.delegate = serverDelegate
        try await serveripv4.startIPv4(port: 25565)
        
        let serveripv6 = TCPServer()
        serveripv6.delegate = serverDelegate
        try await serveripv6.startIPv6(port: 25570)
        
        let clientDelegatev4 = ClientHandler()
        let clientv4 = TCPClient()
        clientv4.delegate = clientDelegatev4
        try await clientv4.connect(host: "127.0.0.1", port: 25565)
        
        
        //let clientDelegatev6 = ClientHandler()
        //let clientv6 = TCPClient()
        //clientv6.delegate = clientDelegatev6
        //try await clientv6.connect(host: "::1", port: 25570)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        for _ in 0..<10_000 {
            clientv4.send([2,2,2,2,2])
            //clientv6.send([2,2,2,2,2])
        }
        
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try await clientv4.disconnect()
        //try await clientv6.disconnect()
        try await serveripv4.shutdown()
        try await serveripv6.shutdown()
    }
    #endif //TestDisabled
    
    func testWebSocketClientServer() async throws {
        class ServerDelegate: WebSocketServerProtocol {
            var connections = [WebSocket]()
            var closedConnections: Bool {
                connections.count == 0
            }
            func onConnection(requestHead: HTTPRequestHead, webSocket: WebSocket, channel: Channel) {
                connections.append(webSocket)
                webSocket.onText { ws, text in
                    XCTAssertEqual(text, "Well hello!")
                    ws.close().whenComplete { result in
                        switch result {
                        case .success(_):
                            print("Closed client connection successfully")
                        case .failure(let error):
                            print("Error closing client connection", error)
                        }
                    }
                    ws.onText { _, _ in }
                    self.connections.removeAll(where: { $0 === webSocket })
                    
                }
                webSocket.send("Hello")
            }
        }
        
        let serverDelegate = ServerDelegate()
        let webSocketServer = try WebSocketServer(numberOfThreads: 1)
        webSocketServer.delegate = serverDelegate
        try await webSocketServer.startIPv4(port: 25566)
        try await webSocketServer.startIPv6(port: 25567)
        
        let webSocketClient = WebSocketClient(eventLoopGroupProvider: .createNew)
        
        let webSocketv4 = try await webSocketClient.connect(scheme: "ws", host: "127.0.0.1", port: 25566)
        webSocketv4.onText { ws, text in
            XCTAssertEqual(text, "Hello")
            ws.send("Well hello!")
        }
        
        let webSocketv6 = try await webSocketClient.connect(scheme: "ws", host: "::1", port: 25567)
        webSocketv6.onText { ws, text in
            XCTAssertEqual(text, "Hello")
            ws.send("Well hello!")
        }
        
        Thread.sleep(forTimeInterval: 5)
        if !webSocketv4.isClosed {
            try webSocketv4.close().wait()
        }
        
        if !webSocketv6.isClosed {
            try webSocketv6.close().wait()
        }
        XCTAssertTrue(webSocketv4.isClosed)
        XCTAssertTrue(webSocketv6.isClosed)
        XCTAssertTrue(serverDelegate.closedConnections)
        try webSocketClient.syncShutdown()
        try await webSocketServer.shutdown()
    }
}
#endif
