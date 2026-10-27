import Darwin
import Foundation
import VigilCore

/// Newline-delimited JSON over a Unix socket in ~/Library/Application Support/Vigil (mode 0600,
/// and peers must have our uid).
enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func configure(_ fd: Int32, timeout: Double) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func readLine(_ fd: Int32, limit: Int = 1 << 16) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < limit {
            let n = read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0A { return data }
                data.append(byte)
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return data.isEmpty ? nil : data
            }
        }
        return nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 { if errno == EINTR { continue } else { return false } }
                left -= n
                p = p.advanced(by: n)
            }
            return true
        }
    }
}

final class SocketServer {
    private let path: String
    private let handler: (Request) -> Response
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "vigil.socket", attributes: .concurrent)

    /// `handler` runs on the main queue.
    init(path: String, handler: @escaping (Request) -> Response) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        guard var addr = UnixSocket.address(path) else { throw POSIXError(.ENAMETOOLONG) }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 32) == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        UnixSocket.configure(fd, timeout: 5)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        guard let line = UnixSocket.readLine(fd) else { return }
        let response: Response
        if let request = try? Wire.decoder().decode(Request.self, from: line) {
            response = DispatchQueue.main.sync { handler(request) }
        } else {
            response = .failure("malformed request")
        }
        var data = (try? Wire.encoder().encode(response)) ?? Data(#"{"ok":false}"#.utf8)
        data.append(0x0A)
        _ = UnixSocket.writeAll(fd, data)
    }
}

enum SocketClient {
    enum Failure: Error, CustomStringConvertible {
        case notRunning
        case io(String)
        var description: String {
            switch self {
            case .notRunning: return "the Vigil app isn't running"
            case .io(let s): return s
            }
        }
    }

    static func send(_ request: Request, timeout: Double = 5) throws -> Response {
        guard var addr = UnixSocket.address(Paths.socket.path) else { throw Failure.io("socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        UnixSocket.configure(fd, timeout: timeout)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw Failure.notRunning }
            throw Failure.io("connect: \(String(cString: strerror(errno)))")
        }
        var data = try Wire.encoder().encode(request)
        data.append(0x0A)
        guard UnixSocket.writeAll(fd, data) else { throw Failure.io("write failed") }
        guard let line = UnixSocket.readLine(fd) else { throw Failure.io("no reply from the app (timed out?)") }
        do {
            return try Wire.decoder().decode(Response.self, from: line)
        } catch {
            throw Failure.io("bad reply from the app: \(error)")
        }
    }
}
