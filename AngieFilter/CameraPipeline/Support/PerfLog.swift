import Foundation
import QuartzCore

/// Debug-only timing lines on stdout, read with `devicectl device process launch --console`.
enum PerfLog {
    static func line(_ text: @autoclosure () -> String) {
        #if DEBUG
        print("[perf] \(text())")
        #endif
    }

    static func now() -> CFTimeInterval {
        CACurrentMediaTime()
    }

    static func ms(since start: CFTimeInterval) -> Double {
        (CACurrentMediaTime() - start) * 1000
    }
}

/// Pings the main queue four times a second and reports any reply later than 100 ms.
enum MainThreadWatch {
    private static let queue = DispatchQueue(label: "angie.perf.main-watch", qos: .utility)
    private static var timer: DispatchSourceTimer?

    static func start() {
        #if DEBUG
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 0.25)
        source.setEventHandler {
            let sent = PerfLog.now()
            DispatchQueue.main.async {
                let late = PerfLog.ms(since: sent)
                if late > 100 {
                    PerfLog.line(String(format: "main thread blocked %.0f ms", late))
                }
            }
        }
        source.resume()
        timer = source
        #endif
    }
}

/// Rolls up per-frame numbers and prints one line per window.
final class PerfWindow: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var count = 0
    private var total: [String: Double] = [:]
    private var peak: [String: Double] = [:]
    private var tallies: [String: Int] = [:]
    private var started = CACurrentMediaTime()

    init(_ name: String) {
        self.name = name
    }

    func add(_ values: [String: Double]) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        for (key, value) in values {
            total[key, default: 0] += value
            peak[key] = max(peak[key] ?? 0, value)
        }
        flushIfDue()
    }

    func tally(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        tallies[key, default: 0] += 1
    }

    private func flushIfDue() {
        let elapsed = CACurrentMediaTime() - started
        guard elapsed >= 2 else { return }
        let fps = Double(count) / elapsed
        let parts = total.keys.sorted().map { key in
            String(format: "%@ avg %.1f max %.1f", key, total[key]! / Double(max(count, 1)), peak[key] ?? 0)
        }
        let extra = tallies.keys.sorted().map { "\($0) \(tallies[$0]!)" }
        PerfLog.line(String(format: "%@ %.1f/s ", name, fps) + (parts + extra).joined(separator: ", "))
        count = 0
        total = [:]
        peak = [:]
        tallies = [:]
        started = CACurrentMediaTime()
    }
}
