import Foundation

/// Made-up sessions for `SessionHub --demo`: screenshots and walkthroughs without real
/// titles, paths or account IDs. Demo mode never reads or writes Claude's files.
enum DemoData {
    static let acme = Column(kind: .desktop(account: "0a11ce00-0000-4000-8000-000000000001", org: "0a11ce00-0000-4000-8000-0000000000a1"))
    static let globex = Column(kind: .desktop(account: "0b0b0b00-0000-4000-8000-000000000002", org: "0b0b0b00-0000-4000-8000-0000000000b2"))
    static let school = Column(kind: .desktop(account: "0c0ffee0-0000-4000-8000-000000000003", org: "0c0ffee0-0000-4000-8000-0000000000c3"))
    static let stash = Column(kind: .stash)
    static let cli = Column(kind: .cli)

    static let nicknames = [acme.id: "Acme · work", globex.id: "Globex · work", school.id: "University"]

    static var columns: [Column] { [stash, acme, globex, school, cli] }

    /// The demo board also stages one change and selects two cards, so the floating dock shows.
    static let pendingCardTitle = "Lab report LaTeX template"
    static let selectedTitles: Set<String> = ["Fix flaky checkout test", "Bump dependencies"]

    static func sessions(now: Date = Date()) -> [Session] {
        var out: [Session] = []
        var n = 0
        func add(_ column: Column, _ title: String, repo: String, branch: String? = nil, worktree: Bool = false,
                 minutesAgo: Double, status: SessionStatus, reason: String, line: String? = nil,
                 prs: Int = 0, open: Int = 0, starred: Bool = false, archived: Bool = false, id: String? = nil) {
            n += 1
            let sid = id ?? String(format: "local_demo-%04d", n)
            let origin = "/Users/demo/dev/\(repo)"
            let cwd = worktree ? "\(origin)/.claude/worktrees/\(branch?.split(separator: "/").last ?? "wt")" : origin
            let isCLI = column.kind == .cli
            var s = Session(
                sessionId: isCLI ? UUID().uuidString.lowercased() : sid,
                source: isCLI ? .cli : .desktop(fileURL: URL(fileURLWithPath: "/dev/null/\(sid).json")),
                columnId: column.id,
                cliSessionId: UUID().uuidString.lowercased(),
                title: title, cwd: cwd, originCwd: origin, branch: branch,
                worktreeName: worktree ? branch : nil,
                lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                isArchived: archived, isStarred: starred, model: "claude-opus-5-5",
                statusLine: line, prCount: prs, cwdExists: true,
                searchKey: Scanner.searchKey(title, cwd, branch))
            s.openPRs = open
            s.finishedPRs = prs - open
            s.status = status
            s.statusReason = reason
            out.append(s)
        }

        add(acme, "Add SSO login with Okta", repo: "web-app", branch: "claude/sso-okta-3f2a1c", worktree: true,
            minutesAgo: 0.5, status: .running, reason: "Conversation written 20s ago", line: "Wiring the callback route; unit tests passing")
        add(acme, "Fix flaky checkout test", repo: "api-server", branch: "claude/flaky-checkout-81d0e2", worktree: true,
            minutesAgo: 14, status: .needsYou, reason: "Claude is blocked on you",
            line: "Should I quarantine the retry test or fix the clock mock first?")
        add(acme, "Migrate billing to Stripe 2025 API", repo: "api-server", branch: "claude/stripe-2025-c47b19", worktree: true,
            minutesAgo: 95, status: .inReview, reason: "1 open PR", line: "PR #412 open; CI green, waiting on review", prs: 1, open: 1)
        add(acme, "Bump dependencies", repo: "web-app", minutesAgo: 180, status: .interrupted,
            reason: "Stopped on a tool call that never returned")
        add(acme, "Onboarding copy review", repo: "docs", minutesAgo: 60 * 26, status: .idle,
            reason: "Finished its turn; nothing pending", starred: true)
        add(acme, "Dark mode for settings page", repo: "web-app", branch: "claude/dark-settings-5e93aa", worktree: true,
            minutesAgo: 60 * 50, status: .done, reason: "All 2 PRs merged or closed", line: "PR #398 merged; cleanup complete", prs: 2)
        add(acme, "Weekly metrics notebook", repo: "analytics", minutesAgo: 60 * 30, status: .idle,
            reason: "Finished its turn; nothing pending", id: "local_demo-shared")

        add(globex, "Rate limiter for the public API", repo: "gateway", branch: "claude/rate-limit-b21f07", worktree: true,
            minutesAgo: 40, status: .needsYou, reason: "Claude's last message asks you something",
            line: "Token bucket per API key or per IP?")
        add(globex, "Postgres index audit", repo: "gateway", branch: "claude/pg-indexes-0c7d55", worktree: true,
            minutesAgo: 60 * 5, status: .inReview, reason: "Ready for review", line: "3 indexes proposed; migration drafted", prs: 1, open: 1)
        add(globex, "Incident 4521 follow-ups", repo: "ops", minutesAgo: 60 * 9, status: .interrupted,
            reason: "You interrupted the last turn")
        add(globex, "Weekly metrics notebook", repo: "analytics", minutesAgo: 60 * 30, status: .idle,
            reason: "Finished its turn; nothing pending", id: "local_demo-shared")
        add(globex, "Terraform module cleanup", repo: "infra", branch: "claude/tf-cleanup-9aa310", worktree: true,
            minutesAgo: 60 * 72, status: .done, reason: "All 3 PRs merged or closed", prs: 3)

        add(school, "Compilers assignment 4: register allocation", repo: "cs-compilers", minutesAgo: 75, status: .needsYou,
            reason: "Claude's last message asks you something", line: "Linear scan or graph coloring for the report?")
        add(school, "Thesis chapter 3 figures", repo: "thesis", minutesAgo: 60 * 20, status: .idle,
            reason: "Finished its turn; nothing pending", starred: true)
        add(school, pendingCardTitle, repo: "latex", minutesAgo: 60 * 24 * 9, status: .done,
            reason: "Claude marked this complete", line: "Template compiled; bibliography fixed")

        add(cli, "Homelab backup script", repo: "homelab", branch: "main", minutesAgo: 35, status: .idle,
            reason: "Finished its turn; nothing pending")
        add(cli, "Game prototype: movement controller", repo: "game-proto", branch: "movement", minutesAgo: 60 * 6,
            status: .interrupted, reason: "Your last message has no reply")
        add(cli, "Dotfiles cleanup", repo: "dotfiles", branch: "main", minutesAgo: 60 * 24 * 3, status: .idle,
            reason: "Finished its turn; nothing pending")

        add(stash, "Spike: GraphQL gateway", repo: "api-server", minutesAgo: 60 * 24 * 40, status: .done,
            reason: "Claude marked this complete", archived: true)
        add(stash, "Portfolio site redesign", repo: "portfolio", minutesAgo: 60 * 24 * 21, status: .idle,
            reason: "Finished its turn; nothing pending")
        return out
    }
}
