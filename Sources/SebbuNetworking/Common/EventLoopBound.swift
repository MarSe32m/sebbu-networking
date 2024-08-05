public protocol EventLoopBound {
    var eventLoop: EventLoop { get }
    func run(_ mode: EventLoop.RunMode)
}

public extension EventLoopBound {
    @inlinable
    func run(_ mode: EventLoop.RunMode) {
        eventLoop.run(mode)
    }
}