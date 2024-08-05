//
//  SebbuNetworkingProcessorAffinityTests.swift
//  
//
//  Created by Sebastian Toivonen on 20.7.2022.
//
import XCTest
import SebbuNetworking

final class SebbuNetworkingSystemUtilsTests: XCTestCase {
    func testProcessorAffinity() throws {
        #if os(Linux) || os(Windows)
        var cpuBits = try SystemUtils.getProcessorAffinity()
        XCTAssertFalse(cpuBits.isEmpty)
        cpuBits.removeFirst()
        let newBits = try SystemUtils.setProcessorAffinity(cpuBits)
        XCTAssertEqual(newBits, cpuBits)
        #else
        throw XCTSkip("Processor affinity not supported on this platform")
        #endif
    }

    func testCoreCount() {
        XCTAssertGreaterThan(SystemUtils.availableParallelism, 0)
    }
}
