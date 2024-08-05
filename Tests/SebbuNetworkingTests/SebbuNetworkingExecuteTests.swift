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
}
