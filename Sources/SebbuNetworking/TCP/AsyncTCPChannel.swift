
public final class AsyncTCPClientChannel: @unchecked Sendable {
    public var eventLoop: EventLoop {
        _channel.eventLoop
    }

    @usableFromInline
    internal let _channel: TCPClientChannel

    @usableFromInline
    internal let _stream: AsyncStream<[UInt8]>

    @usableFromInline
    internal let _streamWriter: AsyncStream<[UInt8]>.Continuation

    public init(channel: TCPClientChannel) {
        self._channel = channel
        (_stream, _streamWriter) = AsyncStream<[UInt8]>.makeStream()
        channel.asyncOnReceive {[unowned(unsafe) self] data in 
            self._streamWriter.yield(data)
        }
        _channel.onClose { [weak self] in
            self?._streamWriter.finish()
        }
    }

    public convenience init(loop: EventLoop) async {
        let channel = await withUnsafeContinuation { continuation in 
            loop.execute {
                let _channel = TCPClientChannel(loop: loop)
                continuation.resume(returning: _channel)
            }
        }
        self.init(channel: channel)
    }

    public func connect(remoteAddress: IPAddress, nodelay: Bool = true, keepAlive: Int = 60, sendBufferSize: Int? = nil, recvBufferSize: Int? = nil) async throws {
        try await withUnsafeThrowingContinuation { continuation in 
            eventLoop.execute {
                self._channel.asyncOnConnect { result in 
                    continuation.resume(with: result)
                    self._channel.asyncOnConnect(nil)
                }
                do {
                    try self._channel.connect(remoteAddress: remoteAddress, nodelay: nodelay, keepAlive: keepAlive, sendBufferSize: sendBufferSize, recvBufferSize: sendBufferSize)
                } catch {
                    self._channel.asyncOnConnect(nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @inline(__always)
    public func send(_ data: [UInt8]) async throws {
        try await withUnsafeThrowingContinuation { cont in
            eventLoop.execute {
                do {
                    try self._channel.send(data)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        
    }

    public func close() {
        eventLoop.execute {
            self._channel.close()
        }
        _streamWriter.finish()
    }
}

extension AsyncTCPClientChannel: AsyncSequence {
    public typealias Element = [UInt8]

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        internal var wrappedIterator: AsyncStream<[UInt8]>.AsyncIterator

        public mutating func next() async -> AsyncTCPClientChannel.Element? {
            await wrappedIterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(wrappedIterator: _stream.makeAsyncIterator())
    }
}

public final class AsyncTCPServerChannel: @unchecked Sendable {
    public var eventLoop: EventLoop {
        _channel.eventLoop
    }

    @usableFromInline
    internal let _channel: TCPServerChannel

    @usableFromInline
    internal let _stream: AsyncStream<AsyncTCPClientChannel>

    @usableFromInline
    internal let _streamWriter: AsyncStream<AsyncTCPClientChannel>.Continuation

    public init(channel: TCPServerChannel) {
        self._channel = channel
        (_stream, _streamWriter) = AsyncStream<AsyncTCPClientChannel>.makeStream()
        channel.asyncOnConnection { [unowned(unsafe) self] client in
            let client = AsyncTCPClientChannel(channel: client)
            self._streamWriter.yield(client)
        }
        _channel.onClose { [weak self] in
            self?._streamWriter.finish()
        }
    }

    public convenience init(loop: EventLoop) async {
        let channel = await withUnsafeContinuation { continuation in 
            loop.execute {
                let _channel = TCPServerChannel(loop: loop)
                continuation.resume(returning: _channel)
            }
        }
        self.init(channel: channel)
    }

    public func bind(address: IPAddress, flags: TCPChannelFlags = []) async throws {
        try await withUnsafeThrowingContinuation { cont in 
            eventLoop.execute {
                do {
                    try self._channel.bind(address: address, flags: flags)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func listen(backlog: Int = 256) async throws {
        try await withUnsafeThrowingContinuation { cont in 
            eventLoop.execute {
                do {
                    try self._channel.listen(backlog: backlog)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func close() {
        eventLoop.execute {
            self._channel.close()
        }
        _streamWriter.finish()
    }
}

extension AsyncTCPServerChannel: AsyncSequence {
    public typealias Element = AsyncTCPClientChannel

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        internal var wrappedIterator: AsyncStream<AsyncTCPClientChannel>.AsyncIterator

        public mutating func next() async -> AsyncTCPServerChannel.Element? {
            await wrappedIterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(wrappedIterator: _stream.makeAsyncIterator())
    }
}
