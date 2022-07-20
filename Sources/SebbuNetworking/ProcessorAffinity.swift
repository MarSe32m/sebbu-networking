//
//  ProcessorAffinity.swift
//  
//
//  Created by Sebastian Toivonen on 20.7.2022.
//

import CSebbuNetworking
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public struct CpuBit: Equatable {
    public let position: Int32
}

public enum ProcessorAffinityError: Error {
    case errorCode(Int32)
    case platformNotSupported
}

public func getProcessorAffinity() throws -> [CpuBit] {
    #if os(Linux)
    var cpuSet: cpu_set_t = cpu_set_t()
    let currentThread = pthread_self()
    cpu_zero(&cpuSet)
    let status = pthread_getaffinity_np(currentThread, MemoryLayout.stride(ofValue: cpuSet), &cpuSet)
    if status != 0 {
        throw ProcessorAffinityError.errorCode(status)
    }
    return withUnsafeBytes(of: &cpuSet.__bits) { bytes in
        var cpuBits: [CpuBit] = []
        var position = 0
        for byte in bytes {
            for i in 0..<8 {
                if byte >> i & 1 == 1 {
                    cpuBits.append(CpuBit(position: Int32(position)))
                }
                position += 1
            }
        }
        return cpuBits
    }
    #elseif os(Windows)
    #warning("TODO: Windows implementation")
    throw ProcessorAffinityError.platformNotSupported
    #else
    throw ProcessorAffinityError.platformNotSupported
    #endif
}

@discardableResult
public func setProcessorAffinity(_ cpuBits: [CpuBit]) throws -> [CpuBit] {
    #if os(Linux)
    var cpuSet: cpu_set_t = cpu_set_t()
    let currentThread = pthread_self()
    cpu_zero(&cpuSet)
    for cpuBit in cpuBits {
        cpu_set(cpuBit.position, &cpuSet)
    }
    let status = pthread_setaffinity_np(currentThread, MemoryLayout.stride(ofValue: cpuSet), &cpuSet)
    if status != 0 {
        throw ProcessorAffinityError.errorCode(status)
    }
    return try getProcessorAffinity()
    #elseif os(Windows)
    #warning("TODO: Windows implementation")
    throw ProcessorAffinityError.platformNotSupported
    #else
    throw ProcessorAffinityError.platformNotSupported
    #endif
}
