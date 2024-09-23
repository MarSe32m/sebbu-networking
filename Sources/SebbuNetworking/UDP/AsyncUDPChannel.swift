public final class AsyncUDPChannel: @unchecked Sendable {
    public var eventLoop: EventLoop {
        _channel.eventLoop
    }

    @usableFromInline
    internal let _channel: UDPChannel

    @usableFromInline
    internal let _stream: AsyncStream<UDPChannelPacket>

    @usableFromInline
    internal let _streamWriter: AsyncStream<UDPChannelPacket>.Continuation

    public init(channel: UDPChannel) {
        self._channel = channel
        (_stream, _streamWriter) = AsyncStream<UDPChannelPacket>.makeStream()
        channel.onReceiveForAsync { [unowned(unsafe) self] data, address in 
            self._streamWriter.yield(.init(address: address, data: data))
        }   
        _channel.onClose { [weak self] in 
            self?._streamWriter.finish()
        }
    }

    public convenience init(loop: EventLoop) async {
        let channel = await withUnsafeContinuation { continuation in 
            loop.execute {
                let _channel = UDPChannel(loop: loop)
                continuation.resume(returning: _channel)
            }
        }
        self.init(channel: channel)
    }

    public func bind(address: IPAddress, flags: UDPChannelFlags = [], sendBufferSize: Int? = nil, recvBufferSize: Int? = nil) async throws {
        try await withUnsafeThrowingContinuation { continuation in 
            eventLoop.execute {
                do {
                    try self._channel.bind(address: address, flags: flags, sendBufferSize: sendBufferSize, recvBufferSize: recvBufferSize)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @inline(__always)
    public func send(_ data: [UInt8], to: IPAddress) async throws {
        try await withUnsafeThrowingContinuation { continuation in 
            eventLoop.execute {
                do {
                    try self._channel.send(data, to: to)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
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

extension AsyncUDPChannel: AsyncSequence {
    public typealias Element = UDPChannelPacket

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        internal var wrappedIterator: AsyncStream<UDPChannelPacket>.AsyncIterator

        public mutating func next() async -> AsyncUDPChannel.Element? {
            await wrappedIterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(wrappedIterator: _stream.makeAsyncIterator())
    }
}

public final class AsyncUDPConnectedChannel: @unchecked Sendable {
    public var eventLoop: EventLoop {
        _channel.eventLoop
    }

    @usableFromInline
    internal let _channel: UDPConnectedChannel

    @usableFromInline
    internal let _stream: AsyncStream<UDPChannelPacket>

    @usableFromInline
    internal let _streamWriter: AsyncStream<UDPChannelPacket>.Continuation

    public init(channel: UDPConnectedChannel) {
        self._channel = channel
        (_stream, _streamWriter) = AsyncStream<UDPChannelPacket>.makeStream()
        _channel.onReceiveForAsync { [unowned(unsafe) self] data, address in 
            self._streamWriter.yield(.init(address: address, data: data))
        }
        _channel.onClose { [weak self] in 
            self?._streamWriter.finish()
        }
    }

    public convenience init(loop: EventLoop) async {
        let channel = await withUnsafeContinuation { continuation in 
            loop.execute {
                let _channel = UDPConnectedChannel(loop: loop)
                continuation.resume(returning: _channel)
            }
        }
        self.init(channel: channel)
    }

    public func connect(remoteAddress: IPAddress, sendBufferSize: Int? = nil, recvBufferSize: Int? = nil) async throws {
        try await withUnsafeThrowingContinuation { continuation in 
            eventLoop.execute {
                do {
                    try self._channel.connect(remoteAddress: remoteAddress, sendBufferSize: sendBufferSize, recvBufferSize: recvBufferSize)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @inline(__always)
    public func send(_ data: [UInt8]) async throws {
        try await withUnsafeThrowingContinuation { continuation in 
            eventLoop.execute {
                do {
                    try self._channel.send(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
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

extension AsyncUDPConnectedChannel: AsyncSequence {
    public typealias Element = UDPChannelPacket

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        internal var wrappedIterator: AsyncStream<UDPChannelPacket>.AsyncIterator

        public mutating func next() async -> AsyncUDPConnectedChannel.Element? {
            await wrappedIterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(wrappedIterator: _stream.makeAsyncIterator())
    }
}
