import AppKit
import SQLite3

struct Sample {
    var active = false
    var last = Date.distantPast
    var turn = ""
    mutating func consume(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        if let stamp = obj["timestamp"] as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: stamp) { last = max(last, date) }
        }
        let kind = payload["type"] as? String ?? ""
        if obj["type"] as? String == "event_msg" {
            if kind == "task_started" { active = true; turn = payload["turn_id"] as? String ?? "" }
            if ["task_complete", "task_completed", "turn_aborted", "task_failed"].contains(kind) {
                let id = payload["turn_id"] as? String ?? ""
                if id.isEmpty || turn.isEmpty || id == turn { active = false }
            }
        }
        if obj["type"] as? String == "response_item", kind == "message",
           payload["role"] as? String == "assistant",
           ["final", "final_answer"].contains(payload["phase"] as? String ?? "") { active = false }
    }
}
struct Cursor { var offset: UInt64 = 0; var pending = Data(); var sample = Sample() }
class Monitor {
    let root: URL
    var cursors: [URL: Cursor] = [:]
    var readable = false
    init(root: URL) { self.root = root }
    func poll() {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { readable = false; return }
        readable = fm.isReadableFile(atPath: root.path)
        var present = Set<URL>()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, Date().timeIntervalSince(modified) < 86400 * 2 else { continue }
            present.insert(url)
            var c = cursors[url] ?? Cursor()
            let size = UInt64(values.fileSize ?? 0)
            if size < c.offset { c = Cursor() }
            guard size != c.offset else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { readable = false; continue }
            defer { try? handle.close() }
            // On first discovery, only inspect the tail; discard an incomplete leading line.
            let start = c.offset == 0 && size > 2_000_000 ? size - 2_000_000 : c.offset
            do {
                try handle.seek(toOffset: start)
                let data = try handle.readToEnd() ?? Data()
                c.offset = start + UInt64(data.count)
                var bytes = c.pending; bytes.append(data)
                if start > 0 && c.pending.isEmpty && c.sample.last == Date.distantPast,
                   let newline = bytes.firstIndex(of: 10) { bytes.removeSubrange(...newline) }
                while let newline = bytes.firstIndex(of: 10) {
                    c.sample.consume(Data(bytes[..<newline])); bytes.removeSubrange(...newline)
                }
                c.pending = bytes; cursors[url] = c
            } catch { readable = false }
        }
        cursors = cursors.filter { present.contains($0.key) }
    }
    var activeSessions: [(URL, Sample)] {
        cursors.compactMap { $0.value.sample.active ? ($0.key, $0.value.sample) : nil }
            .sorted { $0.1.last > $1.1.last }
    }
    func titles() -> [String: String] {
        // Only fetch labels, using a read-only connection. No credentials or message text.
        let files = (try? FileManager.default.contentsOfDirectory(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let databases = files.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let database = databases.first else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path, title FROM threads WHERE archived = 0", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) {
                result[String(cString: path)] = String(cString: title)
            }
        }
        return result
    }
    func status(now: Date = Date()) -> (String, NSColor, Int) {
        if !readable { return ("无法读取 Codex 会话记录", .systemOrange, 0) }
        let active = cursors.values.map(\.sample).filter { $0.active }
        let fresh = active.filter { now.timeIntervalSince($0.last) < 120 }
        if !fresh.isEmpty { return ("Codex 正在工作 · \(active.count) 个会话（近期活动 \(fresh.count) 个）", .systemGreen, active.count) }
        if !active.isEmpty { return ("任务尚未结束 · 超过 2 分钟没有新记录", .systemOrange, active.count) }
        return ("Codex 空闲 · 没有检测到进行中的任务", .systemPurple, 0)
    }
}
class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    let monitor = Monitor(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex").appendingPathComponent("sessions"))
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.activity").count > 1 { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        update(); rebuildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func menuWillOpen(_ menu: NSMenu) { monitor.poll(); rebuildMenu() }
    func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Codex · 会话活动", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: monitor.status().0, action: nil, keyEquivalent: ""))
        let active = monitor.activeSessions
        if !active.isEmpty {
            menu.addItem(.separator())
            let names = monitor.titles()
            for (url, sample) in active.prefix(15) {
                let fresh = Date().timeIntervalSince(sample.last) < 120
                let title = names[url.path].flatMap { $0.isEmpty ? nil : $0 } ?? "会话 " + String(url.deletingPathExtension().lastPathComponent.suffix(8))
                let row = NSMenuItem(title: String(title.prefix(45)), action: nil, keyEquivalent: "")
                row.image = NSImage(systemSymbolName: fresh ? "circle.fill" : "clock", accessibilityDescription: fresh ? "近期有活动" : "等待新记录")
                row.toolTip = fresh ? "近期有活动" : "超过 2 分钟无新记录，任务尚未结束"
                menu.addItem(row)
            }
            if active.count > 15 { menu.addItem(NSMenuItem(title: "另有 \(active.count - 15) 个会话…", action: nil, keyEquivalent: "")) }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "数字：未结束会话数 · 每 2 秒刷新", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "绿：近期活动　黄：等待记录　紫：空闲", action: nil, keyEquivalent: ""))
        let quitItem = NSMenuItem(title: "退出 Codex Activity", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
    }
    func update() {
        monitor.poll()
        let (title, color, count) = monitor.status()
        item.button?.title = count > 0 ? " \(count)" : ""
        item.button?.toolTip = title
        item.button?.setAccessibilityLabel(title)
        // Native code mark: crisp chevrons with a separate colored activity light.
        let icon = NSImage(size: NSSize(width: 25, height: 22), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1.65
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 7, y: 16)); path.line(to: NSPoint(x: 2, y: 11)); path.line(to: NSPoint(x: 7, y: 6))
            path.move(to: NSPoint(x: 15, y: 16)); path.line(to: NSPoint(x: 20, y: 11)); path.line(to: NSPoint(x: 15, y: 6))
            path.move(to: NSPoint(x: 12.5, y: 17)); path.line(to: NSPoint(x: 9.5, y: 5)); path.stroke()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 17, y: 1, width: 8, height: 8)).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: 2, width: 6, height: 6)).fill()
            return true
        }
        icon.isTemplate = false; item.button?.image = icon
    }
    @objc func quit() { NSApp.terminate(nil) }
}
if CommandLine.arguments.contains("--check") {
    let monitor = Monitor(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex").appendingPathComponent("sessions"))
    monitor.poll(); print(monitor.status().0); exit(monitor.readable ? 0 : 1)
}
if CommandLine.arguments.contains("--self-test") {
    var s = Sample()
    func event(_ type: String, _ id: String) -> Data { try! JSONSerialization.data(withJSONObject: ["type":"event_msg", "payload":["type":type,"turn_id":id]]) }
    s.consume(event("task_started", "a")); assert(s.active)
    s.consume(event("task_complete", "b")); assert(s.active)
    s.consume(event("task_complete", "a")); assert(!s.active)
    s.consume(event("task_started", "c")); s.consume(event("turn_aborted", "c")); assert(!s.active)
    s.consume(Data("partial".utf8)); assert(!s.active)
    let m = Monitor(root: URL(fileURLWithPath: "/nonexistent")); m.readable = true
    var c = Cursor(); c.sample.active = true; c.sample.last = Date(); m.cursors[URL(fileURLWithPath: "/fixture")] = c
    assert(m.status().1 == .systemGreen)
    assert(m.status(now: Date().addingTimeInterval(121)).1 == .systemOrange)
    var waiting = Cursor(); waiting.sample.active = true
    m.cursors[URL(fileURLWithPath: "/waiting")] = waiting
    assert(m.status().2 == 2) // A stale session is still counted as unfinished.
    assert(m.activeSessions.count == 2)
    waiting.sample.active = false
    m.cursors[URL(fileURLWithPath: "/waiting")] = waiting
    assert(m.status().2 == 1)
    print("PASS: 开始、结束、取消、轮次匹配、损坏记录与活动过期")
    exit(0)
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
