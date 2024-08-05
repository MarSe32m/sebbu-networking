import XCTest
import SebbuNetworking

final class SebbuNetworkingTCPTests: XCTestCase {
    func testTCPEchoServerClient() throws {
        throw XCTSkip("TODO: Implement")
        let loop = EventLoop.default
        let bindIP = IPv4Address.create(host: "0.0.0.0", port: 25566)!
        let bindAddress = IPAddress.v4(bindIP)
        let remoteIP = IPv4Address.create(host: "127.0.0.1", port: 25566)!
        let remoteAddress = IPAddress.v4(remoteIP)

        var clients: [TCPClientChannel] = []
        let server = TCPServerChannel(loop: loop)
        try! server.bind(address: bindAddress)
        print(server.state)
        try! server.listen()
        print(server.state)

        var client: TCPClientChannel? = TCPClientChannel(loop: loop)
        try! client!.connect(remoteAddress: remoteAddress)
        print(client!.state)
        
        while let _client = client {
            loop.run(.nowait)
            while let client = server.receive() {
                clients.append(client)
            }
            clients.removeAll { 
                if $0.state == .closed {
                    print("A client closed")
                    return true
                }
                return false
            }
            for client in clients {
                while let bytes = client.receive() {
                    try! client.send(bytes)
                }
            }
            switch _client.state {
                case .connected:
                    while let bytes = _client.receive() {
                        print("Received data from server:", bytes)
                    }
                    let data = (0..<5).map {_ in UInt8.random(in: 0...1)}
                    if data == [0, 0, 0, 0, 0] {
                        _client.close()
                    } else {
                        try! _client.send(data)
                    }
                case .disconnected: break
                case .closed: client = nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func testAsyncTCPEchoServerClient() async throws {
        throw XCTSkip("TODO: Implement")
        let loop = EventLoop.default
        Thread.detachNewThread { while true { loop.run() } }
        let bindIP = IPv4Address.create(host: "0.0.0.0", port: 25566)!
        let bindAddress = IPAddress.v4(bindIP)
        let remoteIP = IPv4Address.create(host: "127.0.0.1", port: 25566)!
        let remoteAddress = IPAddress.v4(remoteIP)

        let server = await AsyncTCPServerChannel(loop: loop)
        try await server.bind(address: bindAddress)
        try await server.listen()
        Task.detached {
            try await withThrowingDiscardingTaskGroup { group in 
                for await client in server {
                    group.addTask {
                        for await data in client {
                            try await client.send(data)
                        }
                        print("Client finished")
                    }
                }
            }
        }
        
        while true {
            let client = await AsyncTCPClientChannel(loop: loop)
            try await client.connect(remoteAddress: remoteAddress)
            Task.detached {
                for await data in client {
                    print("Received data from server:", data)
                }
                print("Done receiving")
            }
            print("Connected")
            while let line = readLine() {
                if line == "quit" { 
                    client.close()
                    break
                }
                let bytes = [UInt8](line.utf8)
                try await client.send(bytes)
            }
        }
    }
}
