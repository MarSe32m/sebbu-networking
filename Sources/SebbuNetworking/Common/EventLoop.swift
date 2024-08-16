import SebbuCLibUV

//TODO: Remove once we have Atomic<> from standard library
import Atomics

public final class EventLoop {
    @usableFromInline
    internal enum EventLoopType {
        case global
        case instance
    }

    public enum RunMode {
        /// Run the eventloop indefinitely
        case `default`
        /// Run the eventloop once. Will block if the loop has nothing to do
        case once
        /// Run the eventloop once. Doesn't wait for available work items and will return immediately if the eventloop is empty
        case nowait
    }

    @usableFromInline
    internal let _handle: UnsafeMutablePointer<uv_loop_t>

    @usableFromInline
    internal let _type: EventLoopType

    public let allocator: Allocator

    public static let `default`: EventLoop = EventLoop(_type: .global, allocator: MallocAllocator())

    @usableFromInline
    internal var _thread: uv_thread_t?

    public var inEventLoop: Bool {
        guard let _thread else { return true }
        let currentThread = uv_thread_self()
        return withUnsafePointer(to: currentThread) { currentPtr in 
            return withUnsafePointer(to: _thread) { threadPtr in 
                return uv_thread_equal(currentPtr, threadPtr) != 0
            }
        }
    }

    @usableFromInline
    internal var callbackID: ManagedAtomic<Int> = .init(0)
    
    @usableFromInline
    internal var beforeLoopTickCallbacks: [(id: Int, work: () -> Void)] = []
    
    @usableFromInline
    internal var afterLoopTickCallbacks: [(id: Int, work: () -> Void)] = []
    
    @usableFromInline
    internal let prepareContext = UnsafeMutablePointer<CallbackContext>.allocate(capacity: 1)

    @usableFromInline
    internal let prepareHandle = UnsafeMutablePointer<uv_prepare_t>.allocate(capacity: 1)
    
    @usableFromInline
    internal let checkContext = UnsafeMutablePointer<CallbackContext>.allocate(capacity: 1)
    
    @usableFromInline
    internal let checkHandle = UnsafeMutablePointer<uv_check_t>.allocate(capacity: 1)
    
    @usableFromInline
    internal let notificationCount: ManagedAtomic<Int> = .init(0)
    
    @usableFromInline
    internal let notificationHandle = UnsafeMutablePointer<uv_async_t>.allocate(capacity: 1)
    
    @usableFromInline
    internal let notificationContext = UnsafeMutablePointer<CallbackContext>.allocate(capacity: 1)
    
    //TODO: Use MPSCQueue, or atleast Mutex<> from standard library
    @usableFromInline
    internal let workQueueLock: Lock = Lock()
    
    @usableFromInline
    internal var pendingWork: [() -> Void] = []
    
    @usableFromInline
    internal var workQueue: [() -> Void] = []

    @usableFromInline
    internal let running: ManagedAtomic<Bool> = .init(false)

    public convenience init(allocator: Allocator = MallocAllocator()) {
        self.init(_type: .instance, allocator: allocator)
    }

    internal init(_type: EventLoopType, allocator: Allocator) {
        self._type = _type
        self.allocator = allocator
        switch _type {
            case .instance:
                self._handle = .allocate(capacity: 1)
                self._handle.initialize(to: uv_loop_t())
                uv_loop_init(self._handle)
            case .global:
                self._handle = uv_default_loop()
        }
        
        registerPrepareAndCheckHandles()
        registerNotification()
        registerWorkQueueDraining()
    }

    public func run(_ mode: RunMode = .default) {
        if running.exchange(true, ordering: .sequentiallyConsistent) { return }
        defer { running.store(false, ordering: .sequentiallyConsistent) }
        _thread = uv_thread_self()
        defer { _thread = nil }
        switch mode {
            case .default:
                uv_run(_handle, UV_RUN_ONCE)
                //uv_run(_handle, UV_RUN_DEFAULT)
            case .once:
                uv_run(_handle, UV_RUN_ONCE)
            case .nowait:
                uv_run(_handle, UV_RUN_NOWAIT)
        }
    }

    private func _notify() {
        uv_async_send(notificationHandle)
    }

    public func notify() {
        notificationCount.wrappingIncrement(ordering: .relaxed)
        _notify()
    }

    private func registerWorkQueueDraining() {
        let id = callbackID.wrappingIncrementThenLoad(ordering: .relaxed)
        beforeLoopTickCallbacks.append((id, { [unowned(unsafe) self] in
            //TODO: Use MPSCQueue -> ditch the lock
            self.workQueueLock.lock()
            swap(&self.pendingWork, &self.workQueue)
            self.workQueueLock.unlock()
            for work in self.workQueue {
                work()
            }
            self.workQueue.removeAll(keepingCapacity: workQueue.capacity < 2048)
        }))
    }

    public func schedule(timeout: Duration, repeating: Duration? = nil, _ callback: @escaping (_ stop: inout Bool) -> Void) {
        execute {
            let timeout = UInt64(timeout / .milliseconds(1))
            let repeating = repeating != nil ? UInt64(repeating! / .milliseconds(1)) : 0
            let timer = UnsafeMutablePointer<uv_timer_t>.allocate(capacity: 1)
            uv_timer_init(self._handle, timer)
            let context = UnsafeMutablePointer<TimerContext>.allocate(capacity: 1)
            context.initialize(to: .init(repeating: repeating > 0, callback: callback))
            timer.pointee.data = .init(context)
            uv_timer_start(timer, { timer in 
                guard let context = timer?.pointee.data.assumingMemoryBound(to: TimerContext.self) else { fatalError()}
                var shouldStop = false
                context.pointee.callback(&shouldStop)
                if shouldStop || !context.pointee.repeating {
                    uv_timer_stop(timer)
                    timer?.withMemoryRebound(to: uv_handle_t.self, capacity: 1) { handle in 
                        uv_close(handle) { handle in 
                            handle?.deallocate()
                        }
                    }
                    context.deinitialize(count: 1)
                    context.deallocate()
                }
            }, timeout, repeating)
        }
    }

    public func execute(_ body: @escaping () -> Void) {
        //TODO: Use MPSCQueue
        workQueueLock.lock()
        pendingWork.append(body)
        workQueueLock.unlock()
        notify()
    }

    public func registerAfterTickCallback(_ callback: @escaping () -> Void) -> Int {
        let id = callbackID.wrappingIncrementThenLoad(ordering: .relaxed)
        execute { self.afterLoopTickCallbacks.append((id, callback)) }
        return id
    }

    public func removeAfterTickCallback(id: Int) {
        execute { self.afterLoopTickCallbacks.removeAll { $0.id == id } }
    }

    public func registerBeforeTickCallback(_ callback: @escaping () -> Void) -> Int {
        let id = callbackID.wrappingIncrementThenLoad(ordering: .relaxed)
        execute { self.beforeLoopTickCallbacks.append((id, callback)) }
        return id
    }

    public func removeBeforeTickCallback(id: Int) {
        execute { self.beforeLoopTickCallbacks.removeAll { $0.id == id } }
    }

    private func registerPrepareAndCheckHandles() {
        prepareContext.initialize(to: .init(callback: { [unowned(unsafe) self] in
            for (_, callback) in self.beforeLoopTickCallbacks {
                callback()
            }
        }))
        uv_prepare_init(_handle, prepareHandle)
        prepareHandle.pointee.data = .init(prepareContext)
        uv_prepare_start(prepareHandle) { handle in 
            guard let context = handle?.pointee.data.assumingMemoryBound(to: CallbackContext.self) else { fatalError("unreacahble") }
            context.pointee.callback()
        }
        checkContext.initialize(to: .init(callback: { [unowned(unsafe) self] in
            for (_, callback) in self.afterLoopTickCallbacks {
                callback()
            }
        }))
        uv_check_init(_handle, checkHandle)
        checkHandle.pointee.data = .init(checkContext)
        uv_check_start(checkHandle) { handle in 
            guard let context = handle?.pointee.data.assumingMemoryBound(to: CallbackContext.self) else { fatalError("unreachable") }
            context.pointee.callback()
        }
    }

    private func cleanUpPrepareAndCheckHandles() {
        prepareHandle.withMemoryRebound(to: uv_handle_t.self, capacity: 1) { handle in 
            uv_close(handle) { handle in 
                handle?.deallocate()
            }
        }
        prepareContext.deinitialize(count: 1)
        prepareContext.deallocate()
        
        checkHandle.withMemoryRebound(to: uv_handle_t.self, capacity: 1) { handle in 
            uv_close(handle) { handle in 
                handle?.deallocate()
            }
        }
        checkContext.deinitialize(count: 1)
        checkContext.deallocate()
    }

     private func registerNotification() {
        uv_async_init(_handle, notificationHandle) { handle in 
            guard let notificationContext = handle?.pointee.data.assumingMemoryBound(to: CallbackContext.self) else { fatalError("unreachable") }
            notificationContext.pointee.callback()
        }
        notificationContext.initialize(to: .init(callback: { [weak self] in
            guard let self = self else { return }
            if self.notificationCount.wrappingDecrementThenLoad(ordering: .relaxed) > 0 { self._notify() }
        }))
        notificationHandle.pointee.data = .init(notificationContext)
    }

    private func cleanUpNotificationHandle() {
        notificationHandle.withMemoryRebound(to: uv_handle_t.self, capacity: 1) { handle in 
            uv_close(handle) { handle in 
                handle?.deallocate()
            }
        }
        notificationContext.deinitialize(count: 1)
        notificationContext.deallocate()
        workQueue.removeAll()
        pendingWork.removeAll()
    }

    deinit {
        cleanUpPrepareAndCheckHandles()
        cleanUpNotificationHandle()
        run(.nowait)
        if _type == .global { return }
        uv_loop_close(_handle)
        _handle.deinitialize(count: 1)
        _handle.deallocate()
    }
}

@usableFromInline
internal struct CallbackContext {
    @usableFromInline
    internal let callback: () -> Void
}

@usableFromInline
internal struct TimerContext {
    @usableFromInline
    internal let repeating: Bool

    @usableFromInline
    internal let callback: (inout Bool) -> Void
}