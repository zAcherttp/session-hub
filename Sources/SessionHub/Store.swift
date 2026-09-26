import AppKit
import Foundation

enum FileOp: Codable, Hashable {
    case move(from: String, to: String)
    case copy(from: String, to: String)
    case create(path: String, data: Data)
    case remove(path: String)
}

@MainActor
final class Store: ObservableObject {
    static let claudeBundleId = "com.anthropic.claudefordesktop"

    @Published var columns: [Column] = []
    @Published var sessions: [Session] = []
    @Published var activeAccount: String?
    @Published var prefs = AccountPrefs()
    @Published var pending: [String: PendingMove] = [:]
    @Published var isScanning = false
    @Published var isApplying = false
    @Published var message: String?
    @Published var lastJournal: URL?
    @Published var hiddenNonLocal = 0

    init() {
        loadPrefs()
        lastJournal = Self.latestJournal()
    }

    // MARK: Loading

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        let result = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value
        columns = result.columns
        sessions = result.sessions.sorted { $0.lastActivity > $1.lastActivity }
        activeAccount = result.activeAccount
        hiddenNonLocal = result.hiddenNonLocal
        let ids = Set(sessions.map(\.id))
        pending = pending.filter { ids.contains($0.key) }
        isScanning = false
    }

    var orderedColumns: [Column] {
        let order = prefs.columnOrder
        return columns.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            if a.kind == .cli { return false }
            if b.kind == .cli { return true }
            if a.accountUuid == activeAccount { return true }
            if b.accountUuid == activeAccount { return false }
            return count(in: a) > count(in: b)
        }
    }

    func count(in column: Column) -> Int { sessions.filter { $0.columnId == column.id && !$0.isArchived }.count }

    /// Columns a card should render in: its own (unless moving away) plus any staged target.
    func displayColumns(for s: Session) -> [String] {
        guard let m = pending[s.id] else { return [s.columnId] }
        return m.copy ? [s.columnId, m.to] : [m.to]
    }

    /// Other Desktop accounts that already hold a copy of this session.
    func sharedWith(_ s: Session) -> [String] {
        guard s.isDesktop else { return [] }
        return sessions.filter { $0.sessionId == s.sessionId && $0.columnId != s.columnId }.map(\.columnId)
    }

    func name(for column: Column) -> String {
        if let n = prefs.nicknames[column.id], !n.isEmpty { return n }
        switch column.kind {
        case .cli: return "Claude Code CLI"
        case let .desktop(a, _): return "Account \(a.prefix(8))"
        }
    }

    /// Top repos in a column, to help tell accounts apart before they're named.
    func hint(for column: Column) -> String {
        var counts: [String: Int] = [:]
        for s in sessions where s.columnId == column.id { counts[s.repoName, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(3).map(\.key).joined(separator: ", ")
    }

    func rename(_ column: Column, to name: String) {
        prefs.nicknames[column.id] = name.trimmingCharacters(in: .whitespaces)
        savePrefs()
    }

    func setVisible(_ column: Column, _ visible: Bool) {
        if visible { prefs.hiddenColumns.remove(column.id) } else { prefs.hiddenColumns.insert(column.id) }
        savePrefs()
    }

    /// Drag-reorder: puts `columnId` where `target` currently sits.
    func reorderColumn(_ columnId: String, onto target: Column) {
        var ids = orderedColumns.map(\.id)
        guard let from = ids.firstIndex(of: columnId), let to = ids.firstIndex(of: target.id), from != to else { return }
        ids.remove(at: from)
        ids.insert(columnId, at: to)
        prefs.columnOrder = ids
        savePrefs()
    }

    func moveColumn(_ column: Column, by delta: Int) {
        var ids = orderedColumns.map(\.id)
        guard let i = ids.firstIndex(of: column.id) else { return }
        let j = max(0, min(ids.count - 1, i + delta))
        ids.swapAt(i, j)
        prefs.columnOrder = ids
        savePrefs()
    }

    // MARK: Staging

    enum DropOutcome { case staged, forkRequested(Session), ignored }

    /// `copy` shares the session with the target account instead of moving it (CLI imports always copy).
    func drop(cardId: String, on column: Column, copy: Bool) -> DropOutcome {
        guard let s = sessions.first(where: { $0.id == cardId }) else { return .ignored }
        if column.kind == .cli {
            // Desktop → CLI isn't an ownership change; it means "continue this in a terminal".
            return s.isDesktop ? .forkRequested(s) : .ignored
        }
        if column.id == s.columnId {
            pending[s.id] = nil
        } else {
            pending[s.id] = PendingMove(cardId: s.id, from: s.columnId, to: column.id, copy: copy || !s.isDesktop)
        }
        return .staged
    }

    /// Deletes this account's copy of a session that another account also holds. The transcript is untouched.
    func removeCopy(_ s: Session) async {
        guard let file = s.desktopFile, !sharedWith(s).isEmpty else { return }
        let relaunch = claudeIsRunning && s.columnId.hasPrefix((activeAccount ?? "-") + "/")
        await run([.remove(path: file.path)], relaunch: relaunch, label: "Removed from \(name(for: column(s.columnId)))")
    }

    func column(_ id: String) -> Column { columns.first { $0.id == id } ?? Column(kind: .cli) }

    func discardPending() { pending = [:] }

    var claudeIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleId).isEmpty
    }

    /// Changes touching the signed-in account must happen while Desktop is closed,
    /// otherwise its in-memory copy can write the file back to the old folder.
    var pendingNeedsRelaunch: Bool {
        guard claudeIsRunning else { return false }
        let active = (activeAccount ?? "-") + "/"
        return pending.values.contains { m in m.to.hasPrefix(active) || (!m.copy && m.from.hasPrefix(active)) }
    }

    // MARK: Applying

    func applyPending() async {
        let ops = pending.values.compactMap { plan($0) }.flatMap { $0 }
        guard !ops.isEmpty else { pending = [:]; return }
        let relaunch = pendingNeedsRelaunch
        await run(ops, relaunch: relaunch, label: "Applied \(pending.count) change(s)")
        pending = [:]
    }

    func undoLast() async {
        guard let journal = lastJournal,
              let data = try? Data(contentsOf: journal.appendingPathComponent("undo.json")),
              let undo = try? JSONDecoder().decode([FileOp].self, from: data) else { return }
        let touchesActive = undo.contains { op in
            let paths: [String]
            switch op {
            case let .move(a, b), let .copy(a, b): paths = [a, b]
            case let .create(p, _), let .remove(p): paths = [p]
            }
            return paths.contains { $0.contains("/\(activeAccount ?? "-")/") }
        }
        await run(undo, relaunch: claudeIsRunning && touchesActive, label: "Undid last change", journal: false)
        try? FileManager.default.moveItem(at: journal, to: journal.appendingPathExtension("undone"))
        lastJournal = Self.latestJournal()
    }

    private func plan(_ move: PendingMove) -> [FileOp]? {
        guard let s = sessions.first(where: { $0.id == move.cardId }),
              let target = columns.first(where: { $0.id == move.to })?.directory else { return nil }
        if let file = s.desktopFile {
            let dest = target.appendingPathComponent(file.lastPathComponent).path
            let alreadyThere = FileManager.default.fileExists(atPath: dest)
            switch (move.copy, alreadyThere) {
            case (true, true): return []
            case (true, false): return [.copy(from: file.path, to: dest)]
            case (false, true): return [.remove(path: file.path)]   // target already has it; just drop this copy
            case (false, false): return [.move(from: file.path, to: dest)]
            }
        }
        // CLI → Desktop: write a minimal Desktop metadata record pointing at the existing transcript.
        let id = "local_" + UUID().uuidString.lowercased()
        let now = Date().timeIntervalSince1970 * 1000
        var meta: [String: Any] = [
            "sessionId": id,
            "cliSessionId": s.cliSessionId,
            "cwd": s.cwd,
            "originCwd": s.originCwd,
            "createdAt": s.lastActivity.timeIntervalSince1970 * 1000,
            "lastActivityAt": s.lastActivity.timeIntervalSince1970 * 1000,
            "lastFocusedAt": now,
            "model": s.model ?? "claude-opus-5-5",
            "effort": "high",
            "isArchived": false,
            "title": s.title,
            "titleSource": "user",
            "permissionMode": "default",
        ]
        if let b = s.branch { meta["branch"] = b }
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return [.create(path: target.appendingPathComponent(id + ".json").path, data: data)]
    }

    private func run(_ ops: [FileOp], relaunch: Bool, label: String, journal: Bool = true) async {
        isApplying = true
        defer { isApplying = false }
        do {
            if relaunch { try await quitClaude() }
            let undo = try execute(ops)
            if journal { lastJournal = try writeJournal(ops: ops, undo: undo) }
            if relaunch { relaunchClaude() }
            message = label + (relaunch ? " — relaunched Claude." : ".")
        } catch {
            message = "Failed: \(error.localizedDescription)"
            if relaunch { relaunchClaude() }
        }
        await refresh()
    }

    /// Executes ops, returning the inverse ops (in reverse order). Rolls back on failure.
    private func execute(_ ops: [FileOp]) throws -> [FileOp] {
        let fm = FileManager.default
        // Safety net: only ever touch local_*.json files inside Claude's session folders.
        let root = Paths.desktopSessions.standardizedFileURL.path + "/"
        for op in ops {
            let paths: [String]
            switch op {
            case let .move(a, b), let .copy(a, b): paths = [a, b]
            case let .create(p, _), let .remove(p): paths = [p]
            }
            for p in paths {
                let std = URL(fileURLWithPath: p).standardizedFileURL
                guard std.path.hasPrefix(root), std.lastPathComponent.hasPrefix("local_"), std.pathExtension == "json" else {
                    throw err("Refusing to touch \(p): outside Claude's session folders.")
                }
            }
        }
        var undo: [FileOp] = []
        do {
            for op in ops {
                switch op {
                case let .move(from, to):
                    guard !fm.fileExists(atPath: to) else { throw err("A session with this ID already exists in the target account.") }
                    try backup(from)
                    try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try fm.moveItem(atPath: from, toPath: to)
                    undo.insert(.move(from: to, to: from), at: 0)
                case let .copy(from, to):
                    guard !fm.fileExists(atPath: to) else { throw err("A session with this ID already exists in the target account.") }
                    try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try fm.copyItem(atPath: from, toPath: to)
                    undo.insert(.remove(path: to), at: 0)
                case let .create(path, data):
                    guard !fm.fileExists(atPath: path) else { throw err("File exists: \(path)") }
                    try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                    undo.insert(.remove(path: path), at: 0)
                case let .remove(path):
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    try backup(path)
                    try fm.removeItem(atPath: path)
                    undo.insert(.create(path: path, data: data), at: 0)
                }
            }
        } catch {
            _ = try? execute(undo)
            throw error
        }
        return undo
    }

    private func backup(_ path: String) throws {
        let rel = path.replacingOccurrences(of: Paths.desktopSessions.path + "/", with: "")
        let dest = Paths.backups.appendingPathComponent(Self.stamp()).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(atPath: path, toPath: dest.path)
        }
    }

    private func writeJournal(ops: [FileOp], undo: [FileOp]) throws -> URL {
        let dir = Paths.backups.appendingPathComponent(Self.stamp())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try enc.encode(ops).write(to: dir.appendingPathComponent("ops.json"))
        try enc.encode(undo).write(to: dir.appendingPathComponent("undo.json"))
        return dir
    }

    private static var currentStamp: String?
    private static func stamp() -> String {
        if let s = currentStamp { return s }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let s = f.string(from: Date())
        currentStamp = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { currentStamp = nil }
        return s
    }

    private static func latestJournal() -> URL? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { $0.pathExtension.isEmpty && FileManager.default.fileExists(atPath: $0.appendingPathComponent("undo.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    // MARK: Claude Desktop lifecycle

    private func quitClaude() async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleId)
        apps.forEach { $0.terminate() }
        for _ in 0..<60 {
            if apps.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw err("Claude didn't quit within 15s (a dialog may be asking to confirm). Nothing was changed.")
    }

    private func relaunchClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeBundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Prefs

    private func loadPrefs() {
        if let d = try? Data(contentsOf: Paths.hubPrefs), let p = try? JSONDecoder().decode(AccountPrefs.self, from: d) { prefs = p }
    }

    private func savePrefs() {
        try? FileManager.default.createDirectory(at: Paths.hubSupport, withIntermediateDirectories: true)
        try? JSONEncoder().encode(prefs).write(to: Paths.hubPrefs)
    }

    private func err(_ s: String) -> NSError { NSError(domain: "SessionHub", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
