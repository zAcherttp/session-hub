import Foundation

/// Reads Claude Desktop session metadata and CLI transcripts from disk. Read-only.
///
/// Parsed results are cached by file modification date and size, so a rescan only
/// re-reads files that changed. Transcripts are read in bounded pieces from the head and
/// the tail, never whole, which keeps memory flat even for multi-megabyte files.
final class Scanner: @unchecked Sendable {
    struct Result {
        var columns: [Column]
        var sessions: [Session]
        var activeAccount: String?
        /// Sessions skipped because they don't belong to this Mac.
        var hiddenNonLocal: Int
        /// Transcript ids owned by Desktop sessions (not shown in the CLI column).
        var desktopCliIds: Set<String>
        /// Data shape observed so far (accumulated across scans; only new or changed files add to it).
        var shape: ShapeProfile
    }

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private struct DesktopEntry {
        let stamp: Stamp
        let session: Session?
        let cliIds: [String]
    }

    private struct TranscriptEntry {
        let stamp: Stamp
        let session: Session?
    }

    private struct EndingEntry {
        let stamp: Stamp
        let ending: Ending
    }

    private let lock = NSLock()
    private var desktopCache: [String: DesktopEntry] = [:]
    private var transcriptCache: [String: TranscriptEntry] = [:]
    private var endingCache: [String: EndingEntry] = [:]
    /// Grows as files are parsed; presence ratios stay meaningful because counts grow together.
    private var shape = ShapeProfile()

    // MARK: Scan

    func scan() -> Result {
        var columns: [Column] = []
        var sessions: [Session] = []
        var desktopCliIds = Set<String>()
        var hidden = 0
        var seenDesktop = Set<String>()

        // The Stash is read like an account folder; its sessions belong to no Desktop login.
        let stash = Column(kind: .stash)
        columns.append(stash)
        for (url, stamp) in Self.files(in: Paths.stash, where: { $0.hasPrefix("local_") && $0.hasSuffix(".json") }) {
            seenDesktop.insert(url.path)
            let entry = cachedDesktop(url: url, stamp: stamp, columnId: stash.id)
            desktopCliIds.formUnion(entry.cliIds)
            if let s = entry.session { sessions.append(s) }
        }

        for account in Self.children(of: Paths.desktopSessions).sorted() where Self.isUUID(account) {
            let accountDir = Paths.desktopSessions.appendingPathComponent(account)
            for org in Self.children(of: accountDir).sorted() where Self.isUUID(org) {
                let column = Column(kind: .desktop(account: account, org: org))
                columns.append(column)
                let dir = accountDir.appendingPathComponent(org)
                for (url, stamp) in Self.files(in: dir, where: { $0.hasPrefix("local_") && $0.hasSuffix(".json") }) {
                    seenDesktop.insert(url.path)
                    let entry = cachedDesktop(url: url, stamp: stamp, columnId: column.id)
                    desktopCliIds.formUnion(entry.cliIds)
                    guard let s = entry.session else { continue }
                    guard Self.isLocal(cwd: s.cwd, originCwd: s.originCwd) else { hidden += 1; continue }
                    sessions.append(s)
                }
            }
        }

        columns.append(Column(kind: .cli))
        let cli = scanCLI(excluding: desktopCliIds)
        let localCli = cli.filter { Self.isLocal(cwd: $0.cwd, originCwd: $0.originCwd) }
        hidden += cli.count - localCli.count
        sessions.append(contentsOf: localCli)

        lock.lock()
        desktopCache = desktopCache.filter { seenDesktop.contains($0.key) }
        lock.unlock()

        sessions = classify(sessions)

        let active = Self.readJSON(Paths.desktopConfig)?["lastKnownAccountUuid"] as? String
        lock.lock()
        shape.layout = ShapeProfile.observeLayout()
        shape.claudeDesktopVersion = ShapeProfile.installedDesktopVersion
        shape.claudeCodeVersion = shape.latestCodeVersion
        shape.generatedAt = Date()
        let shapeNow = shape
        lock.unlock()
        // Hand freed scan buffers back to the system instead of letting malloc keep them dirty.
        malloc_zone_pressure_relief(nil, 0)
        return Result(columns: columns, sessions: sessions, activeAccount: active,
                      hiddenNonLocal: hidden, desktopCliIds: desktopCliIds, shape: shapeNow)
    }

    // MARK: Status

    /// Reads how each session's conversation ends (cached by transcript stamp) and assigns its status.
    private func classify(_ sessions: [Session]) -> [Session] {
        let fm = FileManager.default
        let now = Date()
        var out = sessions
        var stamps = [Stamp?](repeating: nil, count: sessions.count)
        var endings = [Ending](repeating: .unknown, count: sessions.count)
        var todo: [Int] = []
        lock.lock()
        for (i, s) in sessions.enumerated() {
            guard let a = try? fm.attributesOfItem(atPath: s.transcriptURL.path),
                  let m = a[.modificationDate] as? Date, let size = a[.size] as? Int else { continue }
            let stamp = Stamp(modified: m, size: size)
            stamps[i] = stamp
            if let hit = endingCache[s.transcriptURL.path], hit.stamp == stamp { endings[i] = hit.ending } else { todo.append(i) }
        }
        lock.unlock()

        let outLock = NSLock()
        let stripes = min(4, max(1, todo.count))
        DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.tailLimit, alignment: 16)
            defer { buffer.deallocate() }
            var observed = ShapeProfile()
            for j in stride(from: stripe, to: todo.count, by: stripes) {
                let i = todo[j]
                let e = autoreleasepool { Self.readEnding(sessions[i].transcriptURL, buffer: buffer, shape: &observed) }
                outLock.lock(); endings[i] = e; outLock.unlock()
            }
            lock.lock(); shape.merge(observed); lock.unlock()
        }

        lock.lock()
        for i in todo { if let st = stamps[i] { endingCache[sessions[i].transcriptURL.path] = EndingEntry(stamp: st, ending: endings[i]) } }
        let live = Set(sessions.map(\.transcriptURL.path))
        endingCache = endingCache.filter { live.contains($0.key) }
        lock.unlock()

        for i in out.indices {
            let age = stamps[i].map { now.timeIntervalSince($0.modified) }
            (out[i].status, out[i].statusReason) = SessionStatus.classify(out[i], ending: endings[i], transcriptAge: age)
        }
        return out
    }

    /// Finds the last user/assistant message in the transcript's tail and classifies it.
    static func readEnding(_ url: URL, buffer: UnsafeMutableRawBufferPointer, shape: inout ShapeProfile) -> Ending {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }
        let size = Int(lseek(fd, 0, SEEK_END))
        var window = 64 * 1024
        while true {
            let start = max(0, size - window)
            let n = pread(fd, buffer.baseAddress, min(size - start, buffer.count), off_t(start))
            guard n > 0 else { return .unknown }
            let tail = Data(bytesNoCopy: buffer.baseAddress!, count: n, deallocator: .none)
            if let msg = lastMessage(in: tail, dropFirstLine: start > 0) {
                shape.observeTranscriptLine(msg)
                return ending(of: msg)
            }
            if start == 0 || window >= tailLimit { return .unknown }
            window = min(window * 4, tailLimit)
        }
    }

    private static func lastMessage(in data: Data, dropFirstLine: Bool) -> [String: Any]? {
        let user = Data(#""type":"user""#.utf8), assistant = Data(#""type":"assistant""#.utf8)
        var end = data.endIndex
        let floor = dropFirstLine ? (data.firstIndex(of: 0x0A).map { $0 + 1 } ?? data.endIndex) : data.startIndex
        while end > floor {
            let start = data[floor..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? floor
            let line = data[start..<end]
            end = start > floor ? start - 1 : floor
            // Cheap byte check before parsing: most tail lines are attachments or bookkeeping.
            guard !line.isEmpty, line.range(of: user) != nil || line.range(of: assistant) != nil,
                  let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let t = o["type"] as? String, t == "user" || t == "assistant",
                  o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true else { continue }
            return o
        }
        return nil
    }

    static func ending(of o: [String: Any]) -> Ending {
        let message = o["message"] as? [String: Any]
        let parts = message?["content"] as? [[String: Any]] ?? []
        let kinds = Set(parts.compactMap { $0["type"] as? String })
        let text = (message?["content"] as? String)
            ?? parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if o["type"] as? String == "assistant" {
            if kinds.contains("tool_use") { return .toolPending }
            return trimmed.hasSuffix("?") ? .question : .answered
        }
        if kinds.contains("tool_result") { return .toolResultNoReply }
        if trimmed.contains("[Request interrupted by user") { return .userInterrupted }
        return .unanswered
    }

    private func cachedDesktop(url: URL, stamp: Stamp, columnId: String) -> DesktopEntry {
        lock.lock()
        if let hit = desktopCache[url.path], hit.stamp == stamp { lock.unlock(); return hit }
        lock.unlock()
        var observed = ShapeProfile()
        let entry = Self.parseDesktop(url: url, columnId: columnId, stamp: stamp, shape: &observed)
        lock.lock()
        shape.merge(observed)
        desktopCache[url.path] = entry
        lock.unlock()
        return entry
    }

    private func scanCLI(excluding desktopIds: Set<String>) -> [Session] {
        var files: [(URL, Stamp)] = []
        for p in Self.children(of: Paths.cliProjects) {
            let dir = Paths.cliProjects.appendingPathComponent(p)
            for (url, stamp) in Self.files(in: dir, where: { $0.hasSuffix(".jsonl") })
            where !desktopIds.contains(url.deletingPathExtension().lastPathComponent) {
                files.append((url, stamp))
            }
        }

        var out = [Session?](repeating: nil, count: files.count)
        var fresh: [(String, TranscriptEntry)] = []
        let outLock = NSLock()
        // A few parallel readers are plenty for disk-bound work and keep peak buffer memory low.
        let stripes = min(4, max(1, files.count))
        DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
          // One read buffer per reader, reused for every file: no per-read heap churn.
          let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.tailLimit, alignment: 16)
          defer { buffer.deallocate() }
          var observed = ShapeProfile()
          defer { lock.lock(); shape.merge(observed); lock.unlock() }
          for i in stride(from: stripe, to: files.count, by: stripes) {
            let (url, stamp) = files[i]
            lock.lock()
            let hit = transcriptCache[url.path]
            lock.unlock()
            if let hit, hit.stamp == stamp {
                outLock.lock(); out[i] = hit.session; outLock.unlock()
                continue
            }
            // Drain Foundation temporaries per file so parallel reads don't pile up.
            let session = autoreleasepool { Self.parseTranscript(url, modified: stamp.modified, buffer: buffer, shape: &observed) }
            outLock.lock()
            out[i] = session
            fresh.append((url.path, TranscriptEntry(stamp: stamp, session: session)))
            outLock.unlock()
          }
        }

        lock.lock()
        let live = Set(files.map(\.0.path))
        transcriptCache = transcriptCache.filter { live.contains($0.key) }
        for (k, v) in fresh { transcriptCache[k] = v }
        lock.unlock()
        return out.compactMap { $0 }
    }

    // MARK: Desktop

    private static func parseDesktop(url: URL, columnId: String, stamp: Stamp, shape: inout ShapeProfile) -> DesktopEntry {
        guard let j = readJSON(url) else { return DesktopEntry(stamp: stamp, session: nil, cliIds: []) }
        shape.observeDesktopSession(j)
        guard
              let id = j["sessionId"] as? String,
              let cli = j["cliSessionId"] as? String,
              let cwd = j["cwd"] as? String else {
            return DesktopEntry(stamp: stamp, session: nil, cliIds: [])
        }
        let ms = (j["lastActivityAt"] as? Double) ?? (j["createdAt"] as? Double) ?? 0
        let summary = j["postTurnSummary"] as? [String: Any]
        let title = (j["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
        let branch = j["branch"] as? String
        let prStates = ((j["prs"] as? [[String: Any]]) ?? []).compactMap { $0["state"] as? String }
        var session = Session(
            sessionId: id,
            source: .desktop(fileURL: url),
            columnId: columnId,
            cliSessionId: cli,
            title: title,
            cwd: cwd,
            originCwd: (j["originCwd"] as? String) ?? cwd,
            branch: branch,
            worktreeName: j["worktreeName"] as? String,
            lastActivity: Date(timeIntervalSince1970: ms / 1000),
            isArchived: (j["isArchived"] as? Bool) ?? false,
            isStarred: (j["isStarred"] as? Bool) ?? false,
            model: j["model"] as? String,
            statusLine: summary?["status_detail"] as? String,
            prCount: (j["prs"] as? [Any])?.count ?? 0,
            cwdExists: FileManager.default.fileExists(atPath: cwd),
            searchKey: searchKey(title, cwd, branch)
        )
        session.summaryCategory = summary?["status_category"] as? String
        // A summary describes the latest turn only if it summarizes the last assistant message.
        session.summaryIsCurrent = summary != nil
            && (summary?["summarizes_uuid"] as? String) == (j["lastAssistantUuid"] as? String)
        session.openPRs = prStates.filter { $0 == "OPEN" }.count
        session.finishedPRs = prStates.filter { $0 == "MERGED" || $0 == "CLOSED" }.count
        return DesktopEntry(stamp: stamp, session: session, cliIds: [cli] + ((j["priorCliSessionIds"] as? [String]) ?? []))
    }

    // MARK: CLI transcripts

    private static let headLimit = 128 * 1024
    private static let tailLimit = 512 * 1024

    static func parseTranscript(_ url: URL, modified: Date,
                                buffer: UnsafeMutableRawBufferPointer? = nil, shape: inout ShapeProfile) -> Session? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let owned = buffer == nil ? UnsafeMutableRawBufferPointer.allocate(byteCount: tailLimit, alignment: 16) : nil
        defer { owned?.deallocate() }
        let buf = buffer ?? owned!
        let size = Int(lseek(fd, 0, SEEK_END))

        /// Reads `count` bytes at `offset` into the shared buffer and wraps them without copying.
        func read(at offset: Int, count: Int) -> Data {
            let n = pread(fd, buf.baseAddress, min(count, buf.count), off_t(offset))
            guard n > 0 else { return Data() }
            return Data(bytesNoCopy: buf.baseAddress!, count: n, deallocator: .none)
        }

        // Head: one bounded read, parsed line by line only until cwd, entrypoint and the first prompt are known.
        var cwd: String?, entrypoint: String?, branch: String?, firstPrompt: String?
        let head = read(at: 0, count: min(size, headLimit))
        var lineStart = head.startIndex
        while lineStart < head.endIndex, let nl = head[lineStart...].firstIndex(of: 0x0A) {
            let line = head[lineStart..<nl]
            lineStart = nl + 1
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            shape.observeTranscriptLine(o)
            if cwd == nil, let c = o["cwd"] as? String { cwd = c }
            if entrypoint == nil, let e = o["entrypoint"] as? String {
                entrypoint = e
                // Desktop-originated transcripts are listed via Desktop metadata; stop early.
                if e == "claude-desktop" { return nil }
            }
            if branch == nil, let b = o["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
            if firstPrompt == nil, o["type"] as? String == "user", o["isMeta"] as? Bool != true,
               let text = messageText(o["message"]), !text.hasPrefix("<") {
                firstPrompt = text
            }
            if cwd != nil, entrypoint != nil, firstPrompt != nil { break }
        }
        guard var cwd, let firstPrompt else { return nil }

        // Tail: search backwards for the latest title/model/folder/branch, widening only if needed.
        // A /branch fork starts with the parent's copied lines, so its own folder and branch are the latest ones.
        var title: String?, model: String?, lastCwd: String?, lastBranch: String?
        var window = 64 * 1024
        while true {
            let start = max(0, size - window)
            let tail = read(at: start, count: size - start)
            if title == nil, let t = lastTitle(in: tail) {
                shape.observeTranscriptLine(t)
                title = (t["customTitle"] as? String) ?? (t["aiTitle"] as? String)
            }
            model = model ?? lastMatch(#""model":""#, prefix: "claude-", in: tail)
            lastCwd = lastCwd ?? lastMatch(#""cwd":""#, prefix: nil, in: tail)
            lastBranch = lastBranch ?? lastMatch(#""gitBranch":""#, prefix: nil, in: tail)
            if (title != nil && model != nil) || start == 0 || window >= tailLimit { break }
            window = min(window * 4, tailLimit)
        }
        if let c = lastCwd, c != cwd { cwd = c; branch = nil }
        if let b = lastBranch { branch = b.isEmpty || b == "HEAD" ? nil : b }

        let origin = cwd.range(of: "/.claude/worktrees/").map { String(cwd[..<$0.lowerBound]) } ?? cwd
        let wt = cwd.range(of: "/.claude/worktrees/").map { String(cwd[$0.upperBound...]).components(separatedBy: "/").first ?? "" }
        let id = url.deletingPathExtension().lastPathComponent
        let finalTitle = title ?? String(firstPrompt.replacingOccurrences(of: "\n", with: " ").prefix(90))
        return Session(
            sessionId: id,
            source: .cli,
            columnId: "cli",
            cliSessionId: id,
            title: finalTitle,
            cwd: cwd,
            originCwd: origin,
            branch: branch,
            worktreeName: wt,
            lastActivity: modified,
            isArchived: false,
            isStarred: false,
            model: model,
            statusLine: nil,
            prCount: 0,
            cwdExists: FileManager.default.fileExists(atPath: cwd),
            searchKey: searchKey(finalTitle, cwd, branch)
        )
    }

    /// The most recent custom or AI title line in `data`.
    private static func lastTitle(in data: Data) -> [String: Any]? {
        let custom = data.range(of: Data(#""type":"custom-title""#.utf8), options: .backwards)
        let ai = data.range(of: Data(#""type":"ai-title""#.utf8), options: .backwards)
        guard let hit = [custom, ai].compactMap({ $0 }).max(by: { $0.lowerBound < $1.lowerBound }),
              let o = try? JSONSerialization.jsonObject(with: line(around: hit, in: data)) as? [String: Any] else { return nil }
        return o
    }

    /// The string value after the last occurrence of `key` (e.g. `"model":"`), optionally requiring a prefix.
    private static func lastMatch(_ key: String, prefix: String?, in data: Data) -> String? {
        var searchEnd = data.endIndex
        let keyData = Data(key.utf8)
        while let r = data.range(of: keyData, options: .backwards, in: data.startIndex..<searchEnd) {
            if let close = data[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) {
                let value = String(decoding: data[r.upperBound..<close], as: UTF8.self)
                if prefix.map(value.hasPrefix) ?? true { return value }
            }
            searchEnd = r.lowerBound
        }
        return nil
    }

    private static func line(around r: Range<Data.Index>, in data: Data) -> Data {
        let start = data[..<r.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
        let end = data[r.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
        return data[start..<end]
    }

    // MARK: Helpers

    /// A session counts as local when its working folder is in this Mac user's home or exists on this disk.
    /// Anything else (another user's or another machine's paths) is never shown, so it can't be edited.
    static func isLocal(cwd: String, originCwd: String) -> Bool {
        let home = Paths.home.path
        let fm = FileManager.default
        return cwd == home || cwd.hasPrefix(home + "/") || originCwd.hasPrefix(home + "/")
            || fm.fileExists(atPath: cwd) || fm.fileExists(atPath: originCwd)
    }

    static func searchKey(_ title: String, _ cwd: String, _ branch: String?) -> String {
        [title, cwd, branch ?? ""].joined(separator: "\n").lowercased()
    }

    static func messageText(_ message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = m["content"] as? [[String: Any]] {
            for p in parts where p["type"] as? String == "text" {
                if let t = p["text"] as? String { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return nil
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    private static func children(of dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// Files in `dir` matching `name`, with modification date and size fetched in the same directory read.
    private static func files(in dir: URL, where name: (String) -> Bool) -> [(URL, Stamp)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard name(url.lastPathComponent), let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Stamp(modified: v.contentModificationDate ?? .distantPast, size: v.fileSize ?? 0))
        }
    }
}
