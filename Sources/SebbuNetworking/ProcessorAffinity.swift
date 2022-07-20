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
    public let position: Int
}

public enum ProcessorAffinityError: Error {
    case errorCode(Int32)
    #if !(os(Linux) || os(Windows))
    case platformNotSupported
    #endif
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
                    cpuBits.append(CpuBit(position: numericCast(position)))
                }
                position += 1
            }
        }
        return cpuBits
    }
    #elseif os(Windows)
    let currentThread = WinSDK.GetCurrentThread()
    var groupAffinity = _GROUP_AFFINITY()
    if !WinSDK.GetThreadGroupAffinity(currentThread, &groupAffinity) {
        let error = WinSDK.GetLastError()
        throw ProcessorAffinityError.errorCode(numericCast(error))
    }
    var mask = groupAffinity.Mask
    return withUnsafeBytes(of: &mask) { bytes in
        var cpuBits: [CpuBit] = []
        var position = 0
        for byte in bytes {
            for i in 0..<8 {
                if byte >> i & 1 == 1 {
                    cpuBits.append(CpuBit(position: numericCast(position)))
                }
                position += 1
            }
        }
        return cpuBits
    }
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
        cpu_set(numericCast(cpuBit.position), &cpuSet)
    }
    let status = pthread_setaffinity_np(currentThread, MemoryLayout.stride(ofValue: cpuSet), &cpuSet)
    if status != 0 {
        throw ProcessorAffinityError.errorCode(status)
    }
    return try getProcessorAffinity()
    #elseif os(Windows)
    let currentThread = WinSDK.GetCurrentThread()
    var mask: DWORD_PTR = 0
    for cpuBit in cpuBits {
        mask |= 1 << cpuBit.position
    }
    if WinSDK.SetThreadAffinityMask(currentThread, mask) == 0 {
        let error = WinSDK.GetLastError()
        throw ProcessorAffinityError.errorCode(numericCast(error))
    }
    return try getProcessorAffinity()
    #else
    throw ProcessorAffinityError.platformNotSupported
    #endif
}
