//
//  SebbuNetworkingAsyncNetworkingTests.swift
//
//
//  Created by Sebastian Toivonen on 28.12.2021.
//
#if canImport(NIO)
import XCTest
import NIO
import SebbuNetworking

private let testData = (0..<1024 * 128).map { _ in UInt8.random(in: .min ... .max) }
private let testCount = 150

final class SebbuKitAsyncNetworkingTests: XCTestCase {
    func testAsyncTCPClientServerConnection() async throws {
        let listener = AsyncTCPListener(numberOfThreads: System.coreCount)
        try await listener.startIPv4(port: 8888)
        var clientTasks = [Task<Int, Error>]()

        var totalSum = 0

        for i in 0..<testCount {
            clientTasks.append(Task {
                let client = AsyncTCPClient()
                try await client.connect(host: "localhost", port: 8888)
                for _ in 0..<testCount {
                    client.send(testData)
                    guard let data = await client.receive() else {
                        XCTFail("Failed to receive pong message")
                        fatalError("Failed...")
                    }
                    XCTAssert(data.count != 0)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await client.disconnect()
                return i
            })
            totalSum += i
        }

        for _ in 0..<testCount {
            guard let client = await listener.listen() else {
                XCTFail("Failed to listen for all clients...")
                fatalError("Failed...")
            }
            Task {
                var totalDataReceived = 0
                while let data = await client.receive(count: testData.count) {
                    client.send([1,2,3,4,5,6])
                    totalDataReceived += data.count
                }
                XCTAssert(totalDataReceived == testCount * testData.count)
            }
        }

        for task in clientTasks {
            totalSum -= try await task.value
        }
        try await listener.shutdown()
        XCTAssert(totalSum == 0)
        let lastClient = await listener.listen()
        XCTAssert(lastClient == nil)
    }
    
    func testAsyncTCPClientServerConnectionChunkedReads() async throws {
        let listener = AsyncTCPListener(numberOfThreads: System.coreCount)
        try await listener.startIPv4(port: 8889)
        var clientTasks = [Task<Int, Error>]()

        var totalSum = 0

        for i in 0..<testCount {
            clientTasks.append(Task {
                let client = AsyncTCPClient()
                try await client.connect(host: "localhost", port: 8889)
                for _ in 0..<testCount {
                    client.send(testData)
                }
                
                for _ in 0..<testCount {
                    guard let data = await client.receive(count: testData.count) else {
                        XCTFail("Failed to receive pong message")
                        fatalError("Failed...")
                    }
                    XCTAssert(data == testData)
                }
                
                try await client.disconnect()
                return i
            })
            totalSum += i
        }

        for _ in 0..<testCount {
            guard let client = await listener.listen() else {
                XCTFail("Failed to listen for all clients...")
                fatalError("Failed...")
            }
            Task {
                for _ in 0..<testCount {
                    guard let data = await client.receive(count: testData.count) else {
                        XCTFail("Failed to receive ping message")
                        return
                    }
                    client.send(data)
                }
            }
        }

        for task in clientTasks {
            totalSum -= try await task.value
        }
        try await listener.shutdown()
        XCTAssert(totalSum == 0)
        let lastClient = await listener.listen()
        XCTAssert(lastClient == nil)
    }
    
    func testConnection() async throws {
        let listener = AsyncTCPListener(numberOfThreads: 1)
        try await listener.startIPv4(port: 8890)
        let client1 = AsyncTCPClient()
        Task {
            try await client1.connect(host: "localhost", port: 8890)
        }
        guard let client2 = await listener.listen() else {
            XCTFail("Failed to listen for a connection...")
            return
        }
        client1.send([1,2,3,4,5,6])
        var recvData = await client2.receive(count: 6)!
        XCTAssert(recvData.count == 6)
        Task {
            for _ in 0..<1024 * 1024 {
                client2.send([UInt8](repeating: 0, count: 1024))
            }
        }
        for _ in 0..<1024 {
            recvData = await client1.receive(count: 1024 * 1024)!
            XCTAssert(recvData.count == 1024 * 1024)
        }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        try await client1.disconnect()
        try await client2.disconnect()
        try await listener.shutdown()
        let lastClient = await listener.listen()
        XCTAssert(lastClient == nil)
    }
}
#endif
