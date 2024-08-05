//
//  FileDescpriptorLimit.swift
//  
//
//  Created by Sebastian Toivonen on 5.12.2021.
//

#if os(macOS)
import Darwin
#elseif os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#endif

#if os(macOS) || os(Linux)
public enum RLimitError: Error {
    case setError(Int)
    case getError(Int)
}

public func setFileDescriptorSoftLimit(_ count: Int) throws {
    var limit = rlimit()
    #if os(macOS)
    let rlimit_nofile = RLIMIT_NOFILE
    #elseif os(Linux)
    let rlimit_nofile = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
    #endif
    let getRLimitResult = getrlimit(rlimit_nofile, &limit)
    if getRLimitResult != 0 {
        throw RLimitError.getError(Int(getRLimitResult))
    }
    limit.rlim_cur = rlim_t(count)
    let setRLimitResult = setrlimit(rlimit_nofile, &limit)
    if setRLimitResult != 0 {
        throw RLimitError.setError(Int(setRLimitResult))
    }
}

public func setFileDescriptorHardLimit(_ count: Int) throws {
    var limit = rlimit()
    #if os(macOS)
    let rlimit_nofile = RLIMIT_NOFILE
    #elseif os(Linux)
    let rlimit_nofile = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
    #endif
    let getRLimitResult = getrlimit(rlimit_nofile, &limit)
    if getRLimitResult != 0 {
        throw RLimitError.getError(Int(getRLimitResult))
    }
    limit.rlim_max = rlim_t(count)
    let setRLimitResult = setrlimit(rlimit_nofile, &limit)
    if setRLimitResult != 0 {
        throw RLimitError.setError(Int(setRLimitResult))
    }
}

public func getFileDescriptorSoftLimit() throws -> Int {
    var limit = rlimit()
    #if os(macOS)
    let rlimit_nofile = RLIMIT_NOFILE
    #elseif os(Linux)
    let rlimit_nofile = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
    #endif
    let getRLimitResult = getrlimit(rlimit_nofile, &limit)
    if getRLimitResult != 0 {
        throw RLimitError.getError(Int(getRLimitResult))
    }
    return Int(limit.rlim_cur)
}

public func getFileDescriptorHardLimit() throws -> Int {
    var limit = rlimit()
    #if os(macOS)
    let rlimit_nofile = RLIMIT_NOFILE
    #elseif os(Linux)
    let rlimit_nofile = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
    #endif
    let getRLimitResult = getrlimit(rlimit_nofile, &limit)
    if getRLimitResult != 0 {
        throw RLimitError.getError(Int(getRLimitResult))
    }
    return Int(limit.rlim_max)
}
#else 
public func setFileDescriptorSoftLimit(_ count: Int) throws {}

public func setFileDescriptorHardLimit(_ count: Int) throws {}

public func getFileDescriptorSoftLimit() throws -> Int { 0 }

public func getFileDescriptorHardLimit() throws -> Int { 0 }
#endif

