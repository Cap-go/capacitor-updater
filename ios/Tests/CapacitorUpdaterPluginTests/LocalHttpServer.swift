import Foundation

/// A minimal HTTP/1.1 server on the loopback interface (IPv4 and IPv6, so `localhost` works
/// whichever address it resolves to). One thread per connection; one request per connection.
final class LocalHttpServer {
    struct Request {
        let path: String
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    final class Connection {
        let socket: Int32

        init(socket: Int32) {
            self.socket = socket
        }

        @discardableResult
        func send(_ text: String) -> Bool {
            write(Data(text.utf8))
        }

        func respond(_ head: String, body: Data = Data()) {
            _ = write(Data(head.utf8) + body)
        }

        func write(_ data: Data) -> Bool {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else {
                    return true
                }
                var offset = 0
                while offset < bytes.count {
                    let sent = Darwin.send(socket, base + offset, bytes.count - offset, 0)
                    if sent <= 0 {
                        return false
                    }
                    offset += sent
                }
                return true
            }
        }
    }

    private let listener: Int32
    let port: UInt16
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var running = true

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(handler: @escaping (Request, Connection) -> Void) throws {
        let listener = socket(AF_INET6, SOCK_STREAM, 0)
        self.listener = listener
        var off: Int32 = 0
        var enabled: Int32 = 1
        setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(listener, 64) == 0 else {
            close(listener)
            throw NSError(domain: "LocalHttpServer", code: Int(errno))
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(listener, $0, &length)
            }
        }
        port = UInt16(bigEndian: address.sin6_port)
        let thread = Thread { [weak self] in
            self?.acceptLoop(handler)
        }
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func acceptLoop(_ handler: @escaping (Request, Connection) -> Void) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                return
            }
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            Thread { [weak self] in
                defer { close(client) }
                guard let request = Self.readRequest(client) else {
                    return
                }
                self?.lock.lock()
                self?.recorded.append(request)
                self?.lock.unlock()
                handler(request, Connection(socket: client))
            }.start()
        }
    }

    private static func readRequest(_ socket: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var found = buffer.range(of: separator)
        while found == nil {
            let count = recv(socket, &chunk, chunk.count, 0)
            guard count > 0 else {
                return nil
            }
            buffer.append(chunk, count: count)
            found = buffer.range(of: separator)
        }
        guard let headEnd = found, let head = String(bytes: buffer[..<headEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        let path = lines.removeFirst().split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(buffer[headEnd.upperBound...])
        let length = Int(headers["content-length"] ?? "") ?? 0
        while body.count < length {
            let count = recv(socket, &chunk, chunk.count, 0)
            guard count > 0 else {
                break
            }
            body.append(chunk, count: count)
        }
        return Request(path: path, headers: headers, body: body)
    }
}
