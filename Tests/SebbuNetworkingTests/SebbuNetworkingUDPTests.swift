import XCTest
import SebbuNetworking

final class SebbuNetworkingUDPTests: XCTestCase {
    private actor ByteCounter {
        var byteCount = 0

        func increment(by: Int) {
            byteCount += by
        }
    }

    func testAsyncUDPEchoServerClient() async throws {
        let loop = EventLoop(allocator: FixedSizeAllocator(allocationSize: 250))
        let _ = Thread { while true { loop.run() } }
        let port = Int.random(in: 2500...50000)
        let bindAddress = IPAddress.v4(.create(host: "127.0.0.1", port: port)!)

        let server = await AsyncUDPChannel(loop: loop)
        try await server.bind(address: bindAddress, flags: [.reuseaddr])

        Task.detached {
            for await packet in server {
                try await server.send(packet.data, to: packet.address)
            }
        }

        let connectAddress = IPAddress.v4(.create(host: "127.0.0.1", port: port)!)
        let client = await AsyncUDPConnectedChannel(loop: loop)
        let counter = ByteCounter()
        try await client.connect(remoteAddress: connectAddress)

        Task.detached {
            for await packet in client {
                await counter.increment(by: packet.data.count)
            }
        }
        let start = ContinuousClock.now
        let targetBytes = 1024 * 1024
        while await counter.byteCount < targetBytes && start.duration(to: .now) < .seconds(60) {
            let data = (0..<128).map {_ in UInt8.random(in: .min ... .max)}
            try await client.send(data)
        }
        let bytesReceived = await counter.byteCount
        XCTAssertGreaterThanOrEqual(bytesReceived, targetBytes)
        //server.close()
        //client.close()
    }

    func testUDPEchoServerClient() throws {
        let loop = EventLoop(allocator: FixedSizeAllocator(allocationSize: 250))
        let port = Int.random(in: 2500...50000)
        let bindAddress = IPAddress.v4(.create(host: "127.0.0.1", port: port)!)
        let serverChannel = UDPChannel(loop: loop)
        try! serverChannel.bind(address: bindAddress, flags: [.reuseaddr])
        
        let connectAddress = IPAddress.v4(.create(host: "127.0.0.1", port: port)!)
        let clientChannel = UDPConnectedChannel(loop: loop)
        try! clientChannel.connect(remoteAddress: connectAddress, sendBufferSize: 256 * 1024, recvBufferSize: 256 * 1024)

        let targetBytes = 1024 * 1024
        var bytesReceived = 0
        let start = ContinuousClock.now
        while bytesReceived < targetBytes && start.duration(to: .now) < .seconds(60) {
            loop.run(.nowait)
            while let packet = serverChannel.receive() {
                try serverChannel.send(packet.data, to: packet.address)
            }

            while let packet = clientChannel.receive() {
                bytesReceived += packet.data.count
            }
            let data = (0..<128).map { _ in UInt8.random(in: .min ... .max) }
            try clientChannel.send(data)
        }
        XCTAssertGreaterThanOrEqual(bytesReceived, targetBytes)
        //serverChannel.close()
        //clientChannel.close()
        loop.run(.nowait)
    }
}
