//
//  SebbuNetworkingAsyncUDPTests.swift
//  
//
//  Created by Sebastian Toivonen on 21.7.2022.
//

#if canImport(NIO)
import XCTest
import NIO
import SebbuNetworking
import Atomics

final class SebbuKitAsyncUDPTests: XCTestCase {
    private var eventLoopGroup: MultiThreadedEventLoopGroup! = nil
    
    override func setUp() {
        super.setUp()
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
        try await eventLoopGroup.shutdownGracefully()
    }

    func testAsyncUDPEchoClientServer() async throws {
        let server = try await AsyncUDPServer.create(host: "0", port: 25565, configuration: .init(), on: eventLoopGroup)
        let client = try await AsyncUDPClient.create(host: "0", port: 0, configuration: .init(), on: eventLoopGroup)
        
        XCTAssertNotNil(server.localAddress)
        XCTAssertNotNil(client.localAddress)
        XCTAssertNil(server.remoteAddress)
        XCTAssertNil(client.remoteAddress)
        
        var sendBuffer = ByteBuffer()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 25565)
        var envelope = AddressedEnvelope(remoteAddress: address, data: sendBuffer)
        for i in 0..<10 {
            sendBuffer.clear()
            sendBuffer.writeInteger(i)
            envelope.data = sendBuffer
            client.send(envelope)
        }
        
        for try await datagram in server.prefix(10) {
            guard let integer: Int = datagram.data.getInteger(at: 0) else {
                XCTFail("Failed to read an integer out of the datagram")
                return
            }
            XCTAssertTrue((0..<10).contains(integer))
            server.send(datagram)
        }
        
        for i in 0..<10 {
            guard let datagram = try? await client.receive(timeout: 10_000_000_000) else {
                XCTFail("Failed to receive datagram")
                return
            }
            guard let integer: Int = datagram.data.getInteger(at: 0) else {
                XCTFail("Failed to read an integer out of the echoed datagram")
                return
            }
            XCTAssertEqual(i, integer)
        }
        
        try await client.close()
        try await server.close()
        do {
            let _ = try await client.receive()
        } catch let error {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == ChannelError.alreadyClosed)
        }
        do {
            let _ = try await server.receive()
        } catch let error {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == ChannelError.alreadyClosed)
        }
    }
    
    func testAsyncUDPMultipleClientsServerEcho() async throws {
        let server = try await AsyncUDPClient.create(host: "0", port: 25566, configuration: .init(), on: eventLoopGroup)
        XCTAssertNotNil(server.localAddress)
        XCTAssertNil(server.remoteAddress)
        var clients = [AsyncUDPClient]()
        for _ in 0..<50 {
            let client = try await AsyncUDPClient.create(host: "0", port: 0, configuration: .init(), on: eventLoopGroup)
            XCTAssertNotNil(client.localAddress)
            XCTAssertNil(client.remoteAddress)
            clients.append(client)
        }
        for client in clients {
            Task.detached {
                let address = try SocketAddress(ipAddress: "127.0.0.1", port: 25566)
                for i in 0..<10 {
                    var data = ByteBuffer()
                    data.writeInteger(i)
                    client.send(AddressedEnvelope(remoteAddress: address, data: data))
                }
                for i in 0..<10 {
                    guard let datagram = try? await client.receive(timeout: 1_000_000_000) else {
                        XCTFail("Failed to receive datagram")
                        return
                    }
                    guard let integer: Int = datagram.data.getInteger(at: 0) else {
                        XCTFail("Failed to read an integer out of the echoed datagram")
                        return
                    }
                    XCTAssertEqual(i, integer)
                }
                try await client.close()
                do {
                    let _ = try await client.receive()
                } catch let error {
                    XCTAssertTrue(error is ChannelError)
                    XCTAssertTrue(error as! ChannelError == ChannelError.alreadyClosed)
                }
            }
        }
        for _ in 0..<50 * 10 {
            let datagram = try await server.receive(timeout: 10_000_000)
            try await server.sendBlocking(datagram)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await server.close()
    }
    
    func testAsyncUDPClientServerErrors() async throws {
        let client = try await AsyncUDPClient.create(host: "0", port: 0, configuration: .init(), on: eventLoopGroup)
        let server = try await AsyncUDPServer.create(host: "0", port: 25567, configuration: .init(), on: eventLoopGroup)
        
        var serverTask = Task.detached {
            let _ = try await server.receive()
        }
        
        var clientTask = Task.detached {
            let _ = try await client.receive()
        }
        
        try await Task.sleep(nanoseconds: 100_000_000)
        serverTask.cancel()
        clientTask.cancel()
        
        // Task cancellation error
        var serverDidThrow = false
        do {
            let _ = try await serverTask.value
        } catch {
            XCTAssertTrue(error is CancellationError)
            serverDidThrow = true
        }
        XCTAssertTrue(serverDidThrow)
        
        var clientDidThrow = false
        do {
            let _ = try await clientTask.value
        } catch {
            XCTAssert(error is CancellationError)
            clientDidThrow = true
        }
        XCTAssertTrue(clientDidThrow)
        
        // Timeout error
        serverDidThrow = false
        do {
            let _ = try await server.receive(timeout: 1_000_000_000)
        } catch {
            XCTAssertTrue(error is ReceiveTimeoutError)
            serverDidThrow = true
        }
        XCTAssertTrue(serverDidThrow)
        
        clientDidThrow = false
        do {
            let _ = try await client.receive(timeout: 1_000_000_000)
        } catch {
            XCTAssertTrue(error is ReceiveTimeoutError)
            clientDidThrow = true
        }
        XCTAssertTrue(clientDidThrow)
        
        // Closed error
        serverTask = Task.detached {
            let _ = try await server.receive()
        }
        
        clientTask = Task.detached {
            let _ = try await client.receive()
        }
        
        try await server.close()
        try await client.close()
        
        serverDidThrow = false
        do {
            let _ = try await serverTask.value
        } catch {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
            serverDidThrow = true
        }
        XCTAssertTrue(serverDidThrow)
        
        clientDidThrow = false
        do {
            let _ = try await clientTask.value
        } catch {
            XCTAssert(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
            clientDidThrow = true
        }
        XCTAssertTrue(clientDidThrow)
    }
    
    func testAsyncUDPClientServerPingPong() async throws {
        let server = try await AsyncUDPServer.create(host: "0", port: 25568, configuration: .init(), on: eventLoopGroup)
        let client = try await AsyncUDPClient.create(host: "0", port: 0, configuration: .init(), on: eventLoopGroup)
        
        let currentSequence = ManagedAtomic<Int>(0)
        let maxSequence = 1000
        enum Sender: UInt64, AtomicValue {
            case server
            case client
        }
        let currentSender = ManagedAtomic<Sender>(.client)
        let serverTask = Task.detached {
            for try await var datagram in server {
                guard let integer: Int = datagram.data.readInteger(as: Int.self) else {
                    XCTFail("Failed to read integer on server!")
                    return
                }
                currentSender.store(.server, ordering: .sequentiallyConsistent)
                datagram.data.clear(minimumCapacity: 8)
                datagram.data.writeInteger(integer)
                while currentSender.load(ordering: .relaxed) == .server
                        && currentSequence.load(ordering: .relaxed) < maxSequence {
                    server.send(datagram)
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                if currentSequence.load(ordering: .relaxed) >= maxSequence { break }
            }
            try await server.close()
        }
        let clientTask = Task.detached {
            let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 25568)
            var buffer = ByteBuffer()
            buffer.writeInteger(0, as: Int.self)
            while currentSender.load(ordering: .relaxed) == .client {
                client.send(AddressedEnvelope<ByteBuffer>(remoteAddress: serverAddress, data: buffer))
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            for try await var datagram in client {
                guard let integer: Int = datagram.data.readInteger(as: Int.self) else {
                    XCTFail("Failed to read integer on client!")
                    return
                }
                currentSender.store(.client, ordering: .sequentiallyConsistent)
                datagram.data.clear(minimumCapacity: 8)
                datagram.data.writeInteger(integer + 1)
                currentSequence.wrappingIncrement(ordering: .relaxed)
                while currentSender.load(ordering: .relaxed) == .client
                        && currentSequence.load(ordering: .relaxed) < maxSequence {
                    client.send(datagram)
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                if currentSequence.load(ordering: .relaxed) >= maxSequence { break }
            }
            try await client.close()
        }
        try await clientTask.value
        try await serverTask.value
    }
    
    func testAsyncUDPClientServerMemoryLeaks() async throws {
        weak var weakServer: AsyncUDPServer?
        weak var weakClient: AsyncUDPClient?
        
        var server: AsyncUDPServer? = try await AsyncUDPServer.create(host: "0", port: 0, configuration: .init(), on: eventLoopGroup)
        var client: AsyncUDPClient? = try await AsyncUDPClient.create(host: "0", port: 0, configuration: .init(), on: eventLoopGroup)
        
        weakServer = server
        weakClient = client
        
        try await server!.close()
        try await client!.close()
        
        server = nil
        client = nil
        
        XCTAssertNil(weakServer)
        XCTAssertNil(weakClient)
    }
}
#endif

