import XCTest
import SebbuNetworking

final class SebbuNetworkingExecuteTests: XCTestCase {
    func testEventLoopExecute() async throws {
        let loop = EventLoop()
        let _ = Thread { while true { loop.run() } }
        for i in 0..<100_000 {
            let j = await withUnsafeContinuation { (continuation: UnsafeContinuation<Int, Never>) in
                loop.execute {
                    continuation.resume(returning: i)
                }
            }
            XCTAssertEqual(i, j)
        }
    }

    func testSchedule() {
        let loop = EventLoop()
        let _ = Thread { while true { loop.run() } }
        var iteration = 0
        loop.schedule(timeout: .seconds(1), repeating: .milliseconds(16)) { shouldStop in 
            iteration += 1
            if iteration == 60 { shouldStop = true }
        }
        Thread.sleep(3000)
        XCTAssertEqual(iteration, 60)
    }
}
