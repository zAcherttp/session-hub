import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claudeSupport = home.appendingPathComponent("Library/Application Support/Claude")
    static let desktopSessions = claudeSupport.appendingPathComponent("claude-code-sessions")
    static let desktopConfig = claudeSupport.appendingPathComponent("config.json")
    static let worktreeRegistry = claudeSupport.appendingPathComponent("git-worktrees.json")
    static let cliProjects = home.appendingPathComponent(".claude/projects")
    static let hubSupport = home.appendingPathComponent("Library/Application Support/SessionHub")
    static let hubPrefs = hubSupport.appendingPathComponent("accounts.json")
    static let backups = hubSupport.appendingPathComponent("backups")

    /// Claude Code's project-dir slug: every non-alphanumeric character becomes "-".
    static func projectSlug(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func transcript(cwd: String, cliSessionId: String) -> URL {
        cliProjects.appendingPathComponent(projectSlug(for: cwd)).appendingPathComponent("\(cliSessionId).jsonl")
    }
}

/// One Desktop account + organization pair, i.e. one `claude-code-sessions/<account>/<org>` folder.
struct Column: Identifiable, Hashable {
    enum Kind: Hashable { case desktop(account: String, org: String), cli }
    let kind: Kind
    var id: String {
        switch kind {
        case let .desktop(a, o): return "\(a)/\(o)"
        case .cli: return "cli"
        }
    }
    var directory: URL? {
        if case let .desktop(a, o) = kind { return Paths.desktopSessions.appendingPathComponent(a).appendingPathComponent(o) }
        return nil
    }
    var accountUuid: String? {
        if case let .desktop(a, _) = kind { return a }
        return nil
    }
    var orgUuid: String? {
        if case let .desktop(_, o) = kind { return o }
        return nil
    }
}

struct Session: Identifiable, Hashable {
    enum Source: Hashable { case desktop(fileURL: URL), cli }

    /// Desktop: `local_…` id. CLI: the transcript UUID. The same Desktop session can sit in several accounts.
    let sessionId: String
    let source: Source
    let columnId: String
    /// Unique per card: a session shared by two accounts shows up as two cards.
    var id: String { columnId + "|" + sessionId }
    let cliSessionId: String
    let title: String
    let cwd: String
    let originCwd: String
    let branch: String?
    let worktreeName: String?
    let lastActivity: Date
    let isArchived: Bool
    let isStarred: Bool
    let model: String?
    let statusLine: String?
    let prCount: Int

    var isDesktop: Bool { if case .desktop = source { return true } else { return false } }
    var desktopFile: URL? { if case let .desktop(u) = source { return u } else { return nil } }
    var isWorktree: Bool { cwd.contains("/.claude/worktrees/") }
    var cwdExists: Bool { FileManager.default.fileExists(atPath: cwd) }
    var transcriptURL: URL { Paths.transcript(cwd: cwd, cliSessionId: cliSessionId) }
    var repoName: String { (originCwd as NSString).lastPathComponent }
}

struct AccountPrefs: Codable {
    var nicknames: [String: String] = [:]      // key: column id
    var hiddenColumns: Set<String> = []
    var columnOrder: [String] = []
}

/// A staged change for one card (keyed by `Session.id`). `copy` keeps the session in its source account too.
struct PendingMove: Hashable {
    let cardId: String
    let from: String
    let to: String
    let copy: Bool
}
