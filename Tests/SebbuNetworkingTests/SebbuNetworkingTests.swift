import XCTest
import SebbuNetworking

final class SebbuNetworkingTests: XCTestCase {
    func testNetworkUtils() async {
        let ipAddress = await NetworkUtils.publicIP
        XCTAssert(ipAddress != nil, "IP Address was nil")
        XCTAssert(ipAddress!.isIpAddress)
    }
    
    func testIpAddressRecognition() {
        XCTAssertTrue("1.2.3.4".isIpAddress)
        XCTAssertTrue("0.0.0.0".isIpAddress)
        XCTAssertTrue("255.255.255.255".isIpAddress)
        XCTAssertTrue("::".isIpAddress)
        XCTAssertTrue("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff".isIpAddress)
        XCTAssertTrue("2001::f:1234".isIpAddress)
        
        XCTAssertFalse("".isIpAddress)
        XCTAssertFalse("foo".isIpAddress)
        XCTAssertFalse("256.256.256.256".isIpAddress)
        XCTAssertFalse("1.2.3".isIpAddress)
        XCTAssertFalse("1.2.3.4.5".isIpAddress)
        XCTAssertFalse("-1.2.3.4".isIpAddress)
        XCTAssertFalse(":".isIpAddress)
        XCTAssertFalse("2001::f::1234".isIpAddress)
        XCTAssertFalse("2001:g::".isIpAddress)
    }
}
