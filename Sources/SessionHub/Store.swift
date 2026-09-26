import AppKit
import Foundation

enum FileOp: Codable, Hashable {
    case move(from: String, to: String)
    case copy(from: String, to: String)
    case create(path: String, data: Data)
    case remove(path: String)
}

@MainActor
@Observable
final class Store {
    static let claudeBundleId = "com.anthropic.claudefordesktop"

    var columns: [Column] = []
    var sessions: [Session] = [] { didSet { rebuildIndexes() } }
    var activeAccount: String?
    var prefs = AccountPrefs()
    var pending: [String: PendingMove] = [:] { didSet { rebuildColumnItems() } }
    var isScanning = false
    var isApplying = false
    var message: Toast?
    var lastJournal: URL?
    var hiddenNonLocal = 0
    /// Sidebar selection: all sessions, or only one status across every column.
    var sidebarFilter: SidebarFilter? = .all
    var statusFilter: SessionStatus? {
        if case let .status(s) = sidebarFilter { return s }
        return nil
    }
    /// Selected card ids (`Session.id`).
    var selection: Set<String> = []
    /// Latest observed data shape and how it differs from the baseline.
    private(set) var shape = ShapeProfile()
    private(set) var drift = ShapeDrift()
    @ObservationIgnored private var baseline = ShapeStore.loadBaseline()
    /// Moves are refused while Claude's format differs in ways the app depends on.
    var writesBlocked: Bool { drift.isBreaking }
    /// Kept current from NSWorkspace launch/quit notifications instead of polled per render.
    private(set) var claudeRunning = false

    // Derived once per scan / pending change rather than on every render.
    /// Cards per column, including staged moves, sorted newest first.
    private(set) var columnItems: [String: [Session]] = [:]
    private(set) var counts: [String: Int] = [:]
    private(set) var hints: [String: String] = [:]
    @ObservationIgnored private var byId: [String: Session] = [:]
    @ObservationIgnored private var shared: [String: [String]] = [:]   // sessionId → columns holding it

    @ObservationIgnored private var selectionAnchor: String?
    @ObservationIgnored private let scanner = Scanner()
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var desktopCliIds = Set<String>()
    @ObservationIgnored private var rescanQueued = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    /// `--demo`: made-up sessions, no disk reads, no watcher, no writes.
    @ObservationIgnored let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            prefs.nicknames = DemoData.nicknames
            baseline = nil
            return
        }
        loadPrefs()
        lastJournal = Self.latestJournal()
        claudeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleId).isEmpty
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Store.claudeBundleId else { return }
                MainActor.assumeIsolated { self?.claudeRunning = name == NSWorkspace.didLaunchApplicationNotification }
            })
        }
        watcher = FolderWatcher(paths: [Paths.desktopSessions.path, Paths.cliProjects.path, Paths.desktopConfig.path]) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
    }

    // MARK: Loading

    func refresh() async {
        if isDemo { loadDemo(); return }
        guard !isScanning else { rescanQueued = true; return }
        isScanning = true
        let scanner = scanner
        let result = await Task.detached(priority: .utility) { scanner.scan() }.value
        let sorted = result.sessions.sorted { $0.lastActivity > $1.lastActivity }
        // Only publish what changed, so an unchanged rescan doesn't redraw anything.
        if columns != result.columns { columns = result.columns }
        if sessions != sorted { sessions = sorted }
        if activeAccount != result.activeAccount { activeAccount = result.activeAccount }
        if hiddenNonLocal != result.hiddenNonLocal { hiddenNonLocal = result.hiddenNonLocal }
        desktopCliIds = result.desktopCliIds
        if result.shape != shape {
            shape = result.shape
            let d = ShapeDrift.compare(observed: shape, baseline: baseline)
            if d != drift { drift = d }
            ShapeStore.recordIfChanged(drift, observed: shape)
        }
        let ids = Set(byId.keys)
        if pending.keys.contains(where: { !ids.contains($0) }) { pending = pending.filter { ids.contains($0.key) } }
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        isScanning = false
        if rescanQueued { rescanQueued = false; await refresh() }
    }

    private func loadDemo() {
        columns = DemoData.columns
        sessions = DemoData.sessions()
        activeAccount = DemoData.acme.accountUuid
        if let s = sessions.first(where: { $0.title == DemoData.pendingCardTitle }) {
            pending = [s.id: PendingMove(cardId: s.id, from: s.columnId, to: "stash", copy: false)]
        }
        selection = Set(sessions.filter { DemoData.selectedTitles.contains($0.title) }.map(\.id))
    }

    private var demoRefusal: Bool {
        if isDemo { message = Toast(.info, "Demo mode: nothing is saved") }
        return isDemo
    }

    /// FSEvents callback. Skips churn from transcripts the board doesn't show
    /// (Desktop-owned conversations and subagent logs are written constantly while Claude works).
    private func filesChanged(_ paths: [String]) {
        let projects = Paths.cliProjects.path + "/"
        let relevant = paths.contains { path in
            guard path.hasPrefix(projects) else { return true }   // Desktop metadata or config
            let rel = path.dropFirst(projects.count).split(separator: "/")
            guard rel.count == 2, rel[1].hasSuffix(".jsonl") else { return rel.count == 1 }  // new project dir
            return !desktopCliIds.contains(String(rel[1].dropLast(6)))
        }
        if relevant { Task { await refresh() } }
    }

    private func rebuildIndexes() {
        var byId: [String: Session] = [:], shared: [String: [String]] = [:]
        var counts: [String: Int] = [:], repos: [String: [String: Int]] = [:]
        for s in sessions {
            byId[s.id] = s
            if s.isDesktop { shared[s.sessionId, default: []].append(s.columnId) }
            if !s.isArchived { counts[s.columnId, default: 0] += 1 }
            repos[s.columnId, default: [:]][s.repoName, default: 0] += 1
        }
        self.byId = byId
        self.shared = shared
        if self.counts != counts { self.counts = counts }
        let hints = repos.mapValues { $0.sorted { $0.value > $1.value }.prefix(3).map(\.key).joined(separator: ", ") }
        if self.hints != hints { self.hints = hints }
        rebuildColumnItems()
    }

    private func rebuildColumnItems() {
        var items: [String: [Session]] = [:]
        for s in sessions {
            for c in displayColumns(for: s) { items[c, default: []].append(s) }
        }
        if columnItems != items { columnItems = items }
    }

    var orderedColumns: [Column] {
        let order = prefs.columnOrder
        return columns.sorted { a, b in
            // The Stash is a fixed first column.
            if a.kind == .stash { return b.kind != .stash }
            if b.kind == .stash { return false }
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            if a.kind == .cli { return false }
            if b.kind == .cli { return true }
            if a.accountUuid == activeAccount { return true }
            if b.accountUuid == activeAccount { return false }
            return count(in: a) > count(in: b)
        }
    }

    func count(in column: Column) -> Int { counts[column.id] ?? 0 }

    /// Columns a card should render in: its own (unless moving away) plus any staged target.
    func displayColumns(for s: Session) -> [String] {
        guard let m = pending[s.id] else { return [s.columnId] }
        return m.copy ? [s.columnId, m.to] : [m.to]
    }

    /// Other Desktop accounts that already hold a copy of this session.
    func sharedWith(_ s: Session) -> [String] {
        (shared[s.sessionId] ?? []).filter { $0 != s.columnId }
    }

    func name(for column: Column) -> String {
        if let n = prefs.nicknames[column.id], !n.isEmpty { return n }
        switch column.kind {
        case .cli: return "Claude Code CLI"
        case .stash: return "Stash"
        case let .desktop(a, o):
            // Accounts with several organizations get the org in the default name to tell them apart.
            let orgs = columns.filter { $0.accountUuid == a }.count
            return orgs > 1 ? "Account \(a.prefix(8)) · org \(o.prefix(8))" : "Account \(a.prefix(8))"
        }
    }

    /// Top repos in a column, to help tell accounts apart before they're named.
    func hint(for column: Column) -> String { hints[column.id] ?? "" }

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
        guard columnId != "stash", target.kind != .stash else { return }
        var ids = orderedColumns.map(\.id)
        guard let from = ids.firstIndex(of: columnId), let to = ids.firstIndex(of: target.id), from != to else { return }
        ids.remove(at: from)
        ids.insert(columnId, at: to)
        prefs.columnOrder = ids
        savePrefs()
    }

    func moveColumn(_ column: Column, by delta: Int) {
        var ids = orderedColumns.filter { $0.kind != .stash }.map(\.id)
        guard let i = ids.firstIndex(of: column.id) else { return }
        let j = max(0, min(ids.count - 1, i + delta))
        ids.swapAt(i, j)
        prefs.columnOrder = ids
        savePrefs()
    }

    // MARK: Selection

    /// Click = select only this, ⌘-click = toggle, ⇧-click = range within `list` (the column's visible order).
    func click(_ s: Session, in list: [Session]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let anchor = selectionAnchor,
           let a = list.firstIndex(where: { $0.id == anchor }), let b = list.firstIndex(where: { $0.id == s.id }) {
            selection.formUnion(list[min(a, b)...max(a, b)].map(\.id))
            return
        }
        if mods.contains(.command) {
            toggle(s)
        } else {
            selection = selection == [s.id] ? [] : [s.id]
            selectionAnchor = s.id
        }
    }

    func toggle(_ s: Session) {
        if selection.contains(s.id) { selection.remove(s.id) } else { selection.insert(s.id) }
        selectionAnchor = s.id
    }

    func select(_ list: [Session]) { selection.formUnion(list.map(\.id)) }

    func clearSelection() { selection = []; selectionAnchor = nil }

    /// Stages every selected card that isn't already stashed for a move into the Stash.
    func stashSelection() {
        let stash = column("stash")
        for id in selection where !(byId[id]?.isStashed ?? true) { _ = drop(cardId: id, on: stash, copy: false) }
        clearSelection()
    }

    /// What an action on `s` applies to: the whole selection if `s` is part of it, otherwise just `s`.
    func group(for s: Session) -> [Session] {
        guard selection.contains(s.id) else { return [s] }
        return selection.compactMap { byId[$0] }.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Drag payload: newline-separated card ids.
    func dragPayload(for s: Session) -> String { group(for: s).map(\.id).joined(separator: "\n") }

    // MARK: Staging

    enum DropOutcome { case staged, forkRequested(Session), ignored }

    /// `copy` shares the session with the target account instead of moving it (CLI imports always copy).
    func drop(cardId: String, on column: Column, copy: Bool) -> DropOutcome {
        guard let s = byId[cardId] else { return .ignored }
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
        if demoRefusal { return }
        guard !writesBlocked else { message = Toast(.error, "Changes are paused", "Claude's data format changed. See Data shape in the toolbar."); return }
        guard let file = s.desktopFile, !sharedWith(s).isEmpty else { return }
        let relaunch = claudeIsRunning && s.columnId.hasPrefix((activeAccount ?? "-") + "/")
        await run([.remove(path: file.path)], relaunch: relaunch, label: "Removed from \(name(for: column(s.columnId)))")
    }

    func column(_ id: String) -> Column { columns.first { $0.id == id } ?? Column(kind: .cli) }

    func discardPending() { pending = [:] }

    /// Live check used when actually applying changes (the cached `claudeRunning` drives the UI).
    var claudeIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleId).isEmpty
    }

    /// Changes touching the signed-in account must happen while Desktop is closed,
    /// otherwise its in-memory copy can write the file back to the old folder.
    var pendingNeedsRelaunch: Bool {
        guard claudeRunning else { return false }
        let active = (activeAccount ?? "-") + "/"
        return pending.values.contains { m in m.to.hasPrefix(active) || (!m.copy && m.from.hasPrefix(active)) }
    }

    private var pendingNeedsRelaunchIgnoringState: Bool {
        let active = (activeAccount ?? "-") + "/"
        return pending.values.contains { m in m.to.hasPrefix(active) || (!m.copy && m.from.hasPrefix(active)) }
    }

    // MARK: Applying

    /// Accepts the current shape as the new baseline (after checking a Claude update is understood).
    func acceptShape() {
        if demoRefusal { return }
        do {
            try ShapeStore.accept(shape)
            baseline = shape
            drift = ShapeDrift.compare(observed: shape, baseline: baseline)
            ShapeStore.recordIfChanged(drift, observed: shape)
            message = Toast(.success, "Accepted the current data shape as the baseline")
        } catch { message = Toast(.error, "Couldn't save the baseline", Self.describe(error)) }
    }

    var shapeReport: String { drift.report(observed: shape, baseline: baseline) }

    func applyPending() async {
        if demoRefusal { return }
        guard !writesBlocked else {
            message = Toast(.error, "Changes are paused", "Claude's data format changed. See Data shape in the toolbar.")
            return
        }
        let ops = pending.values.compactMap { plan($0) }.flatMap { $0 }
        guard !ops.isEmpty else { pending = [:]; return }
        let relaunch = claudeIsRunning && pendingNeedsRelaunchIgnoringState
        let n = pending.count
        let noun = n == 1 ? "1 change" : "\(n) changes"
        // Staged changes survive a failure so they can be retried.
        if await run(ops, relaunch: relaunch, label: "Applied \(noun)", failure: "Couldn't apply \(noun)") {
            pending = [:]
        }
    }

    func undoLast() async {
        if demoRefusal { return }
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
        await run(undo, relaunch: claudeIsRunning && touchesActive, label: "Undid the last change", failure: "Couldn't undo the last change", journal: false)
        try? FileManager.default.moveItem(at: journal, to: journal.appendingPathExtension("undone"))
        lastJournal = Self.latestJournal()
    }

    private func plan(_ move: PendingMove) -> [FileOp]? {
        guard let s = byId[move.cardId], let ops = metadataOps(for: s, move) else { return nil }
        return ops + transcriptOps(for: s, move)
    }

    /// Stashing keeps a backup of the conversation (Claude Code's cleanup can delete old transcripts);
    /// restoring from the Stash puts the backup back if the original has gone.
    private func transcriptOps(for s: Session, _ move: PendingMove) -> [FileOp] {
        let fm = FileManager.default
        let backup = Paths.stashTranscripts.appendingPathComponent(s.cliSessionId + ".jsonl").path
        let original = s.transcriptURL.path
        if move.to == "stash", fm.fileExists(atPath: original), !fm.fileExists(atPath: backup) {
            return [.copy(from: original, to: backup)]
        }
        if s.isStashed, move.to != "stash", !fm.fileExists(atPath: original), fm.fileExists(atPath: backup) {
            return [.copy(from: backup, to: original)]
        }
        return []
    }

    private func metadataOps(for s: Session, _ move: PendingMove) -> [FileOp]? {
        guard let target = columns.first(where: { $0.id == move.to })?.directory else { return nil }
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
        // Desktop reads "branch" on a worktree folder as a worktree it must re-lease, and refuses while the
        // branch is checked out there. Only pass it when the folder is gone, so Desktop can rebuild it.
        if let b = s.branch, !s.cwdExists { meta["branch"] = b }
        if move.to == "stash" { meta["isArchived"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return [.create(path: target.appendingPathComponent(id + ".json").path, data: data)]
    }

    @discardableResult
    private func run(_ ops: [FileOp], relaunch: Bool, label: String, failure: String? = nil, journal: Bool = true) async -> Bool {
        isApplying = true
        defer { isApplying = false }
        var ok = true
        do {
            if relaunch { try await quitClaude() }
            let undo = try execute(ops)
            if journal { lastJournal = try writeJournal(ops: ops, undo: undo) }
            if relaunch { relaunchClaude() }
            message = Toast(.success, label, relaunch ? "Claude was relaunched." : nil)
        } catch {
            ok = false
            message = Toast(.error, failure ?? "Something went wrong",
                            Self.describe(error) + " Nothing was changed.")
            if relaunch { relaunchClaude() }
        }
        await refresh()
        return ok
    }

    /// A short, human explanation for file errors instead of raw paths.
    static func describe(_ error: Error) -> String {
        let e = error as NSError
        guard e.domain == NSCocoaErrorDomain else { return e.localizedDescription }
        let name = (e.userInfo[NSFilePathErrorKey] as? String).map { ($0 as NSString).lastPathComponent }
        switch e.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return name.map { "A file or folder it needed was missing (\($0))." } ?? "A file or folder it needed was missing."
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return "Session Hub isn't allowed to change that file."
        case NSFileWriteFileExistsError:
            return "A session with the same ID is already there."
        case NSFileWriteOutOfSpaceError:
            return "The disk is full."
        default:
            return e.localizedFailureReason ?? e.localizedDescription
        }
    }

    /// Executes ops, returning the inverse ops (in reverse order). Rolls back on failure.
    private func execute(_ ops: [FileOp]) throws -> [FileOp] {
        let fm = FileManager.default
        // Safety net: session metadata (local_*.json) only inside account folders or the Stash;
        // transcripts (*.jsonl) only copied between ~/.claude/projects and the Stash backup, and a
        // transcript is only ever removed from ~/.claude/projects when a Stash backup of it exists.
        func isMetadata(_ u: URL) -> Bool {
            u.lastPathComponent.hasPrefix("local_") && u.pathExtension == "json"
                && (u.path.hasPrefix(Paths.desktopSessions.standardizedFileURL.path + "/")
                    || u.deletingLastPathComponent().path == Paths.stash.standardizedFileURL.path)
        }
        func isTranscript(_ u: URL) -> Bool {
            u.pathExtension == "jsonl"
                && (u.path.hasPrefix(Paths.cliProjects.standardizedFileURL.path + "/")
                    || u.deletingLastPathComponent().path == Paths.stashTranscripts.standardizedFileURL.path)
        }
        func hasBackup(_ u: URL) -> Bool {
            fm.fileExists(atPath: Paths.stashTranscripts.appendingPathComponent(u.lastPathComponent).path)
        }
        for op in ops {
            let ok: Bool
            switch op {
            case let .move(a, b):
                ok = isMetadata(URL(fileURLWithPath: a).standardizedFileURL) && isMetadata(URL(fileURLWithPath: b).standardizedFileURL)
            case let .copy(a, b):
                let (ua, ub) = (URL(fileURLWithPath: a).standardizedFileURL, URL(fileURLWithPath: b).standardizedFileURL)
                ok = (isMetadata(ua) && isMetadata(ub)) || (isTranscript(ua) && isTranscript(ub))
            case let .create(p, _):
                ok = isMetadata(URL(fileURLWithPath: p).standardizedFileURL)
            case let .remove(p):
                let u = URL(fileURLWithPath: p).standardizedFileURL
                let inProjects = u.path.hasPrefix(Paths.cliProjects.standardizedFileURL.path + "/")
                ok = isMetadata(u) || (isTranscript(u) && (!inProjects || hasBackup(u)))
            }
            guard ok else { throw err("Refusing an unexpected file change: \(op)") }
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
                    guard !fm.fileExists(atPath: path) else { throw err("A session with the same ID is already there.") }
                    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
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
        let rel = path.hasPrefix(Paths.hubSupport.path + "/")
            ? path.replacingOccurrences(of: Paths.hubSupport.path + "/", with: "")
            : path.replacingOccurrences(of: Paths.desktopSessions.path + "/", with: "")
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
        if isDemo { return }
        try? FileManager.default.createDirectory(at: Paths.hubSupport, withIntermediateDirectories: true)
        try? JSONEncoder().encode(prefs).write(to: Paths.hubPrefs)
    }

    private func err(_ s: String) -> NSError { NSError(domain: "SessionHub", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// A short message in the floating dock.
struct Toast: Equatable {
    enum Kind { case success, info, error }
    let kind: Kind
    let title: String
    let detail: String?

    init(_ kind: Kind, _ title: String, _ detail: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}
