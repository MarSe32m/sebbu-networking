import XCTest
import SebbuNetworking

final class SebbuNetworkingTests: XCTestCase {
    func testNetworkUtils() {
        let ipAddress = NetworkUtils.publicIP
        XCTAssert(ipAddress != nil, "IP Address was nil")
        XCTAssert(ipAddress!.isIpAddress)
    }
    
    func testIpAddressRecognition() {
        XCTAssertTrue("1.2.3.4".isIpAddress)
        XCTAssertTrue("0.0.0.0".isIpAddress)
        XCTAssertTrue("255.255.255.255".isIpAddress)
        XCTAssertTrue("::".isIpAddress)
        XCTAssertTrue("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff".isIpAddress())
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
    
    #if !os(Windows)
    func disabled_testIPv4Supported() {
        XCTAssertTrue(NetworkUtils.supportsIPv4)
    }
    
    func disabled_testIPv6Supported() {
        XCTAssertTrue(NetworkUtils.supportsIPv6)
    }
    #endif
}
