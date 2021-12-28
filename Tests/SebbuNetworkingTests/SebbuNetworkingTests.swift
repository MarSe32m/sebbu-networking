import XCTest
import SebbuNetworking

final class SebbuNetworkingTests: XCTestCase {
    func testNetworkUtils() {
        let ipAddress = NetworkUtils.publicIP
        XCTAssert(ipAddress != nil, "IP Address was nil")
        XCTAssert(ipAddress!.isIpAddress())
    }
}
