import XCTest
import SebbuNetworking

final class SebbuNetworkingGetAddrInfoTests: XCTestCase {
    func testGetAddrInfo() async {
        let loop = EventLoop()
        var address =  IPAddress.createResolvingBlocking(host: "github.com", port: 8080)
        XCTAssertNotNil(address)
        
        var done = false
        IPAddress.createResolving(loop: loop, host: "apple.com", port: 8080) { address in 
            XCTAssertNotNil(address)
            done = true
        } 
        while !done { loop.run(.nowait) }
        let loopTask = Task.detached {
            while true {
                try Task.checkCancellation()
                loop.run(.nowait)
                await Task.yield()
            }
        }
        address = await IPAddress.createResolving(loop: loop, host: "google.com", port: 8080)
        XCTAssertNotNil(address)
        loopTask.cancel()
    }
}
