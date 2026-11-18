import QuartzCore
import UIKit

/// Watches every frame the screen draws and writes it to the debug log (Settings > About > Share log):
///  - a frame that took longer than 40 ms, with the last thing that happened (a lyric line, a page, a button)
///  - a frames-a-second summary every 4 s while it is below 55
///  - memory use every 30 s
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var slow = 0
    private var worst: Double = 0
    private var windowStart: CFTimeInterval = 0
    private var memAt: CFTimeInterval = 0
    private(set) var lastEvent = "start"
    private var lastEventAt = Date()

    /// Names what is happening now, so a slow frame can be matched to it: `FrameMonitor.event("lyrics", "line 12")`.
    static func event(_ tag: String, _ msg: String = "") {
        DispatchQueue.main.async {
            shared.lastEvent = msg.isEmpty ? tag : "\(tag) \(msg)"
            shared.lastEventAt = Date()
        }
        DebugLog.log(tag, msg)
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = l.timestamp
        if last > 0 {
            let dt = (t - last) * 1000
            frames += 1
            // the screen may refresh at 120 Hz: only a frame much longer than the refresh interval counts
            let interval = (l.targetTimestamp - l.timestamp) * 1000
            if dt > max(40, interval * 3) {
                slow += 1
                worst = max(worst, dt)
                let ago = Int(Date().timeIntervalSince(lastEventAt) * 1000)
                DebugLog.log("frame", "frame took \(Int(dt)) ms (after: \(lastEvent), \(ago) ms ago)")
            }
        }
        last = t
        if windowStart == 0 { windowStart = t }
        if t - windowStart >= 4 {
            let fps = Double(frames) / (t - windowStart)
            if fps < 55 { DebugLog.log("fps", String(format: "%.0f fps over the last 4 s, %d slow frames, worst %.0f ms (last: %@)", fps, slow, worst, lastEvent)) }
            frames = 0; slow = 0; worst = 0; windowStart = t
        }
        if t - memAt >= 30 {
            memAt = t
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
            if kr == KERN_SUCCESS { DebugLog.log("mem", "\(info.resident_size / 1_048_576) MB in use") }
        }
    }
}
