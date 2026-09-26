import Foundation

/// Reads Claude Desktop session metadata and CLI transcripts from disk. Read-only.
enum Scanner {
    struct Result {
        var columns: [Column]
        var sessions: [Session]
        var activeAccount: String?
        /// Sessions skipped because they don't belong to this Mac.
        var hiddenNonLocal: Int
    }

    /// A session counts as local when its working folder is in this Mac user's home or exists on this disk.
    /// Anything else (another user's or another machine's paths) is never shown, so it can't be edited.
    static func isLocal(cwd: String, originCwd: String) -> Bool {
        let home = Paths.home.path
        let fm = FileManager.default
        return cwd == home || cwd.hasPrefix(home + "/") || originCwd.hasPrefix(home + "/")
            || fm.fileExists(atPath: cwd) || fm.fileExists(atPath: originCwd)
    }

    static func scan() -> Result {
        let fm = FileManager.default
        var columns: [Column] = []
        var sessions: [Session] = []
        var desktopCliIds = Set<String>()
        var hidden = 0

        let accounts = (try? fm.contentsOfDirectory(atPath: Paths.desktopSessions.path)) ?? []
        for account in accounts.sorted() where isUUID(account) {
            let accountDir = Paths.desktopSessions.appendingPathComponent(account)
            let orgs = (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? []
            for org in orgs.sorted() where isUUID(org) {
                let column = Column(kind: .desktop(account: account, org: org))
                columns.append(column)
                let dir = accountDir.appendingPathComponent(org)
                let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                for file in files where file.hasPrefix("local_") && file.hasSuffix(".json") {
                    let url = dir.appendingPathComponent(file)
                    guard let s = parseDesktop(url: url, columnId: column.id) else { continue }
                    desktopCliIds.insert(s.cliSessionId)
                    guard isLocal(cwd: s.cwd, originCwd: s.originCwd) else { hidden += 1; continue }
                    if let json = readJSON(url), let prior = json["priorCliSessionIds"] as? [String] {
                        desktopCliIds.formUnion(prior)
                    }
                    sessions.append(s)
                }
            }
        }

        columns.append(Column(kind: .cli))
        let cli = scanCLI(excluding: desktopCliIds)
        let localCli = cli.filter { isLocal(cwd: $0.cwd, originCwd: $0.originCwd) }
        hidden += cli.count - localCli.count
        sessions.append(contentsOf: localCli)

        let active = readJSON(Paths.desktopConfig)?["lastKnownAccountUuid"] as? String
        return Result(columns: columns, sessions: sessions, activeAccount: active, hiddenNonLocal: hidden)
    }

    // MARK: Desktop

    static func parseDesktop(url: URL, columnId: String) -> Session? {
        guard let j = readJSON(url),
              let id = j["sessionId"] as? String,
              let cli = j["cliSessionId"] as? String,
              let cwd = j["cwd"] as? String else { return nil }
        let ms = (j["lastActivityAt"] as? Double) ?? (j["createdAt"] as? Double) ?? 0
        let summary = j["postTurnSummary"] as? [String: Any]
        return Session(
            sessionId: id,
            source: .desktop(fileURL: url),
            columnId: columnId,
            cliSessionId: cli,
            title: (j["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session",
            cwd: cwd,
            originCwd: (j["originCwd"] as? String) ?? cwd,
            branch: j["branch"] as? String,
            worktreeName: j["worktreeName"] as? String,
            lastActivity: Date(timeIntervalSince1970: ms / 1000),
            isArchived: (j["isArchived"] as? Bool) ?? false,
            isStarred: (j["isStarred"] as? Bool) ?? false,
            model: j["model"] as? String,
            statusLine: summary?["status_detail"] as? String,
            prCount: (j["prs"] as? [Any])?.count ?? 0
        )
    }

    // MARK: CLI

    static func scanCLI(excluding desktopIds: Set<String>) -> [Session] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(atPath: Paths.cliProjects.path)) ?? []
        var out: [Session] = []
        let lock = NSLock()
        var files: [URL] = []
        for p in projects {
            let dir = Paths.cliProjects.appendingPathComponent(p)
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".jsonl") {
                let id = String(f.dropLast(6))
                if !desktopIds.contains(id) { files.append(dir.appendingPathComponent(f)) }
            }
        }
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            if let s = parseTranscript(files[i]) {
                lock.lock(); out.append(s); lock.unlock()
            }
        }
        return out
    }

    static func parseTranscript(_ url: URL) -> Session? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = String(decoding: (try? handle.read(upToCount: 96 * 1024)) ?? Data(), as: UTF8.self)

        var cwd: String?, entrypoint: String?, branch: String?, firstPrompt: String?
        for line in head.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil, let c = o["cwd"] as? String { cwd = c }
            if entrypoint == nil, let e = o["entrypoint"] as? String { entrypoint = e }
            if branch == nil, let b = o["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
            if firstPrompt == nil, o["type"] as? String == "user", o["isMeta"] as? Bool != true,
               let text = messageText(o["message"]), !text.hasPrefix("<") {
                firstPrompt = text
            }
            if cwd != nil, entrypoint != nil, firstPrompt != nil { break }
        }
        // Desktop-originated transcripts belong to Desktop metadata; orphans stay hidden.
        guard let cwd, entrypoint != "claude-desktop", firstPrompt != nil else { return nil }

        var title: String?, model: String?
        let tailSize: UInt64 = 384 * 1024
        let tailStart = size > tailSize ? size - tailSize : 0
        try? handle.seek(toOffset: tailStart)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            if title == nil, line.contains("\"type\":\"custom-title\"") || line.contains("\"type\":\"ai-title\""),
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                title = (o["customTitle"] as? String) ?? (o["aiTitle"] as? String)
            }
            if model == nil, line.contains("\"type\":\"assistant\""), let r = line.range(of: #""model":"(claude-[^"]+)""#, options: .regularExpression) {
                model = String(line[r].dropFirst(9).dropLast())
            }
            if branch == nil, line.contains("\"gitBranch\":\"") ,
               let r = line.range(of: #""gitBranch":"[^"]+""#, options: .regularExpression) {
                let b = String(line[r].dropFirst(13).dropLast())
                if b != "HEAD" { branch = b }
            }
            if title != nil, model != nil { break }
        }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let origin = cwd.range(of: "/.claude/worktrees/").map { String(cwd[..<$0.lowerBound]) } ?? cwd
        let wt = cwd.range(of: "/.claude/worktrees/").map { String(cwd[$0.upperBound...]).components(separatedBy: "/").first ?? "" }
        let fallback = firstPrompt!.replacingOccurrences(of: "\n", with: " ")
        return Session(
            sessionId: String(url.deletingPathExtension().lastPathComponent),
            source: .cli,
            columnId: "cli",
            cliSessionId: String(url.deletingPathExtension().lastPathComponent),
            title: title ?? String(fallback.prefix(90)),
            cwd: cwd,
            originCwd: origin,
            branch: branch,
            worktreeName: wt,
            lastActivity: mtime,
            isArchived: false,
            isStarred: false,
            model: model,
            statusLine: nil,
            prCount: 0
        )
    }

    // MARK: Helpers

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
}
