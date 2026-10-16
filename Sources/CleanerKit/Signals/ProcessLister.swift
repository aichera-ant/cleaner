import Darwin
import Foundation

/// Çalışan süreç.
public struct RunningProcess: Sendable, Equatable {
    public var pid: Int32
    /// Çalıştırılabilir dosyanın adı (ör. `Docker`, `Claude`, `Simulator`).
    public var name: String
    /// Çalıştırılabilir dosyanın tam yolu (okunabildiyse).
    public var path: String?

    public init(pid: Int32, name: String, path: String?) {
        self.pid = pid
        self.name = name
        self.path = path
    }
}

/// Çalışan süreç ve uygulama listesi.
public protocol ProcessListing: Sendable {
    func runningProcesses() -> [RunningProcess]
}

extension ProcessListing {
    /// Ad tam eşleşir (büyük/küçük harf duyarlı) ya da süreç `<ad>.app` paketinin içinden çalışır.
    /// Örn. "Claude" masaüstü uygulamasıyla eşleşir, `claude` CLI ile eşleşmez.
    public func isRunning(_ name: String) -> Bool {
        let appMarker = "/\(name).app/Contents/"
        return runningProcesses().contains { p in
            p.name == name || (p.path?.contains(appMarker) ?? false)
        }
    }
}

/// libproc ile gerçek uygulama.
public struct LiveProcessLister: ProcessListing {
    public init() {}

    public func runningProcesses() -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        var result: [RunningProcess] = []
        result.reserveCapacity(Int(n))
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            if len > 0 {
                let path = Self.string(pathBuf)
                result.append(RunningProcess(pid: pid, name: (path as NSString).lastPathComponent, path: path))
            } else {
                var nameBuf = [CChar](repeating: 0, count: 256)
                if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
                    result.append(RunningProcess(pid: pid, name: Self.string(nameBuf), path: nil))
                }
            }
        }
        return result
    }

    private static func string(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
