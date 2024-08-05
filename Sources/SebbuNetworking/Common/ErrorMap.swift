import SebbuCLibUV

@inline(__always)
@inlinable
internal func mapError<T: BinaryInteger>(_ error: T) -> String {
    return String(cString: uv_strerror(numericCast(error)))
}