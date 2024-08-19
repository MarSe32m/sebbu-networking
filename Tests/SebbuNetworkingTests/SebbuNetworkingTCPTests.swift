import XCTest
import SebbuNetworking

final class SebbuNetworkingTCPTests: XCTestCase {
    func testTCPEchoServerClient() throws {
        //throw XCTSkip("TODO: This seems to hang on release build tests")
        let loop = EventLoop()
        let port = Int.random(in: 2500...50000)
        let bindIP = IPv4Address.create(host: "127.0.0.1", port: port)!
        let bindAddress = IPAddress.v4(bindIP)
        let remoteIP = IPv4Address.create(host: "127.0.0.1", port: port)!
        let remoteAddress = IPAddress.v4(remoteIP)

        var clients: [TCPClientChannel] = []
        let server = TCPServerChannel(loop: loop)
        try server.bind(address: bindAddress)
        XCTAssertEqual(server.state, .bound)
        try server.listen()
        XCTAssertEqual(server.state, .listening)

        let client: TCPClientChannel = TCPClientChannel(loop: loop)
        try client.connect(remoteAddress: remoteAddress)

        for _ in 0..<10 where client.state != .connected {
            loop.run(.nowait)
            Thread.sleep(1000)
        }
        XCTAssertEqual(client.state, .connected)

        var iteration = 0
        let targetBytesToReceiveAndSend = 1024 * 1024
        var bytesReceived = 0
        var bytesSent = 0
        while bytesReceived < targetBytesToReceiveAndSend && iteration < 2 * 1024 {
            iteration += 1
            loop.run(.nowait)
            while let client = server.receive() { clients.append(client) }

            for client in clients {
                while let bytes = client.receive() {
                    try client.send(bytes)
                }
            }
            while let bytes = client.receive() {
                bytesReceived += bytes.count
            }
            if bytesSent < targetBytesToReceiveAndSend {
                let data: [UInt8] = (0..<1024 * 2).map { _ in .random(in: .min ... .max)}
                try client.send(data)
                bytesSent += data.count
            }
            Thread.sleep(1)
        }
        XCTAssertEqual(bytesReceived, targetBytesToReceiveAndSend)
        server.close()
        client.close()
        loop.run(.nowait)
    }

    func testAsyncTCPEchoServerClient() async throws {
        #if os(Windows)
        throw XCTSkip("Skipped until https://github.com/swiftlang/swift/issues/75942 is fixed")
        #endif
        let loop = EventLoop()
        let _ = Thread { while true { loop.run() } }
        let port = Int.random(in: 2500...50000)
        let bindIP = IPv4Address.create(host: "127.0.0.1", port: port)!
        let bindAddress = IPAddress.v4(bindIP)
        let remoteIP = IPv4Address.create(host: "127.0.0.1", port: port)!
        let remoteAddress = IPAddress.v4(remoteIP)

        let server = await AsyncTCPServerChannel(loop: loop)
        try await server.bind(address: bindAddress)
        try await server.listen()
        Task.detached {
            await withThrowingTaskGroup(of: Void.self) { group in 
                for await client in server {
                    group.addTask {
                        for await data in client {
                            try await client.send(data)
                        }
                    }
                }
            }
        }
        
        let client = await AsyncTCPClientChannel(loop: loop)
        try await client.connect(remoteAddress: remoteAddress)
        let targetBytes = 1024 * 1024
        Task.detached {
            var bytesSent = 0
            for nextBytesSent in stride(from: 0, through: targetBytes, by: 256) {
                let diff = nextBytesSent - bytesSent
                bytesSent = nextBytesSent
                if diff == 0 { continue }
                let data: [UInt8] = (0..<diff).map {_ in .random(in: .min ... .max) }     
                try await client.send(data)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        async let _ = { 
            try await Task.sleep(nanoseconds: 30_000_000_000)
            XCTFail("Timed out")
        }()
        var bytesReceived = 0
        for await data in client {
            bytesReceived += data.count
            if bytesReceived >= targetBytes { break }
        }
        XCTAssertEqual(bytesReceived, targetBytes)
        client.close()
        server.close()
        try await Task.sleep(for: .milliseconds(150))
    }

    func testTCPClose() throws {
        let loop = EventLoop()
        let server = TCPServerChannel(loop: loop)
        let client = TCPClientChannel(loop: loop)
        let address = IPAddress(host: "127.0.0.1", port: 19000)!
        try server.bind(address: address)
        try server.listen()
        try client.connect(remoteAddress: address)
        for _ in 0..<100 {
            loop.run(.nowait)
        }
        for _ in 0..<100 {
            server.close()
            client.close()
        }
        for _ in 0..<100 {
            loop.run(.nowait)
        }
    }

    func testAsyncTCPClose() async throws {
        #if os(Windows)
        throw XCTSkip("Skipped until https://github.com/swiftlang/swift/issues/75942 is fixed")
        #endif
        let loop = EventLoop()
        _ = Thread { while true { loop.run() } }
        let server = await AsyncTCPServerChannel(loop: loop)
        let client = await AsyncTCPClientChannel(loop: loop)
        let address = IPAddress(host: "127.0.0.1", port: 19000)!
        try await server.bind(address: address)
        try await server.listen()
        try await client.connect(remoteAddress: address)
        for _ in 0..<100 {
            server.close()
            client.close()
        }
    }
}
