import XCTest
import SebbuNetworking

final class SebbuNetworkingUDPTests: XCTestCase {
    func testAsyncUDPEchoServerClient() async throws {
        throw XCTSkip("TODO: Implement")
        let loop = EventLoop(allocator: FixedSizeAllocator(allocationSize: 250))
        let _ = Thread { while true { loop.run() } }
        let bindAddress = IPAddress.v4(.create(host: "0.0.0.0", port: 25565)!)

        let server = await AsyncUDPChannel(loop: loop)
        try await server.bind(address: bindAddress, flags: [.reuseaddr], sendBufferSize: 4 * 1024 * 1024, recvBufferSize: 4 * 1024 * 1024)

        Task.detached {
            for await packet in server {
                try await server.send(packet.data, to: packet.address)
            }
        }

        let connectAddress = IPAddress.v4(.create(host: "127.0.0.1", port: 25565)!)
        let client = await AsyncUDPConnectedChannel(loop: loop)

        try await client.connect(remoteAddress: connectAddress, sendBufferSize: 256 * 1024, recvBufferSize: 256 * 1024)

        let receiveTask = Task.detached {
            var bytesReceived = 0
            for await packet in client {
                bytesReceived += packet.data.count
            }
            return bytesReceived
        }
        var bytesSent = 0

        while true {
            let data = (0..<5).map {_ in UInt8.random(in: .min ... .max)}
            try await client.send(data)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testUDPEchoServerClient() throws {
        throw XCTSkip("TODO: Implement")
        let loop = EventLoop(allocator: FixedSizeAllocator(allocationSize: 250))
        //let _ = loop.registerAfterTickCallback {
        //    print("After tick")
        //}
        //let _ = loop.registerBeforeTickCallback {
        //    print("Before tick")
        //}
        for i in 0..<10 {
            loop.execute {
                print(i)
            }
        }
        for _ in 0..<10 {
            loop.run(.once)
        }
        let bindAddress = IPAddress.v4(.create(host: "0.0.0.0", port: 25565)!)
        let serverChannel = UDPChannel(loop: loop)
        try! serverChannel.bind(address: bindAddress, flags: [.reuseaddr], sendBufferSize: 4 * 1024 * 1024, recvBufferSize: 4 * 1024 * 1024)

        let connectAddress = IPAddress.v4(.create(host: "127.0.0.1", port: 25565)!)
        let clientChannel = UDPConnectedChannel(loop: loop)
        try! clientChannel.connect(remoteAddress: connectAddress, sendBufferSize: 256 * 1024, recvBufferSize: 256 * 1024)

        // Basic usage for UDP Channels
        while true {
            // Run the loop
            loop.run(.nowait)
            // Process server received packets
            while let packet = serverChannel.receive() {
                try? serverChannel.send(packet.data, to: packet.address)
            }
            // Process client received packets
            while let packet  = clientChannel.receive() {
                print("Received data from server:", packet)
            }
            // Do your computation, update game tick etc.
            let data = (0..<5).map {_ in UInt8.random(in: .min ... .max)}
            try? clientChannel.send(data)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
