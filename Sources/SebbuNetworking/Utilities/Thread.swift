import SebbuCLibUV

//TODO: Consider moving this a sebbu-concurrency or sebbu-ts-ds
public final class Thread {
    @usableFromInline
    internal let tid: UnsafeMutablePointer<uv_thread_t?> = .allocate(capacity: 1)

    public let procedure: () -> Void

    public init(_ body: @escaping () -> Void) {
        self.procedure = body
        let _body = UnsafeMutablePointer<() -> Void>.allocate(capacity: 1)
        _body.initialize {
            self.procedure()
        }
        let err = uv_thread_create(tid, { arg in
            guard let body = arg?.assumingMemoryBound(to: (() -> Void).self) else { fatalError("unreachable") }
            body.pointee()
            body.deinitialize(count: 1)
            body.deallocate()
        }, .init(_body))
        precondition(err == 0)
    }

    public func setPriority(_ priority: Priority) {
        let err = uv_thread_setpriority(tid, numericCast(priority.uvPriority))
        debugOnly {
            print("Failed to set thread priority with error:", mapError(err))
        }
    }

    public func join() {
        uv_thread_join(tid)
    }

    public static func sleep(_ milliseconds: Int) {
        precondition(milliseconds >= 0)
        uv_sleep(numericCast(milliseconds))
    }

    deinit {
        tid.deallocate()
    }
}

extension Thread: Equatable {
    public static func ==(lhs: Thread, rhs: Thread) -> Bool {
        uv_thread_equal(lhs.tid, rhs.tid) != 0
    }
}

public extension Thread {
    enum Priority {
        case highest
        case aboveNormal
        case normal
        case belowNormal
        case lowest

        init(_ uvPriority: Int32) {
            switch uvPriority {
                case numericCast(UV_THREAD_PRIORITY_HIGHEST):
                    self = .highest
                case numericCast(UV_THREAD_PRIORITY_ABOVE_NORMAL):
                    self = .aboveNormal
                case numericCast(UV_THREAD_PRIORITY_NORMAL):
                    self = .normal
                case numericCast(UV_THREAD_PRIORITY_BELOW_NORMAL):
                    self = .belowNormal
                case numericCast(UV_THREAD_PRIORITY_LOWEST):
                    self = .lowest
                default:
                    fatalError("unreacahble")
            }
        }

        internal var uvPriority: Int {
            switch self {
                case .highest:      return numericCast(UV_THREAD_PRIORITY_HIGHEST)
                case .aboveNormal:  return numericCast(UV_THREAD_PRIORITY_ABOVE_NORMAL)
                case .normal:       return numericCast(UV_THREAD_PRIORITY_NORMAL)
                case .belowNormal:  return numericCast(UV_THREAD_PRIORITY_BELOW_NORMAL)
                case .lowest:       return numericCast(UV_THREAD_PRIORITY_LOWEST)
            }
        }
    }
}