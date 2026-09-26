import AppKit
import Foundation

/// Builds `claude` shell commands for a session, to paste into any terminal.
enum Launcher {
    enum Mode: Hashable {
        case resume, fork, forkNewWorktree
        var label: String {
            switch self {
            case .fork: return "Fork here"
            case .forkNewWorktree: return "Fork into a new worktree"
            case .resume: return "Resume"
            }
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where the transcript currently lives (its project dir follows the session's cwd).
    static func transcriptDir(_ s: Session) -> URL { s.transcriptURL.deletingLastPathComponent() }

    /// Shell steps that make the transcript resumable from `targetCwd` (the CLI looks sessions up per project dir).
    static func copyTranscriptSteps(_ s: Session, to targetCwd: String) -> [String] {
        let targetDir = Paths.cliProjects.appendingPathComponent(Paths.projectSlug(for: targetCwd))
        guard targetDir.standardizedFileURL != transcriptDir(s).standardizedFileURL else { return [] }
        let src = s.transcriptURL.path
        let sidecar = transcriptDir(s).appendingPathComponent(s.cliSessionId).path
        return [
            "mkdir -p \(shellQuote(targetDir.path))",
            "cp -n \(shellQuote(src)) \(shellQuote(targetDir.path + "/"))",
            "{ [ -d \(shellQuote(sidecar)) ] && cp -Rn \(shellQuote(sidecar)) \(shellQuote(targetDir.path + "/")) || true; }",
        ]
    }

    static func command(for s: Session, mode: Mode) -> String {
        var steps: [String] = []
        let flags = mode == .resume ? "" : " --fork-session"
        switch mode {
        case .resume, .fork:
            // A deleted worktree can't be resumed in place; fall back to the repo root.
            let target = s.cwdExists ? s.cwd : s.originCwd
            steps += copyTranscriptSteps(s, to: target)
            steps.append("cd \(shellQuote(target))")
        case .forkNewWorktree:
            let name = "fork-" + slug(s.title) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
            let wtPath = s.originCwd + "/.claude/worktrees/" + name
            let base: String
            if s.cwdExists {
                base = "$(git -C \(shellQuote(s.cwd)) rev-parse HEAD)"
            } else {
                // The worktree is gone; its branch may be too.
                base = "$(git rev-parse --verify -q \(shellQuote(s.branch ?? "HEAD")) || echo HEAD)"
            }
            steps.append("cd \(shellQuote(s.originCwd))")
            steps.append("git worktree add \(shellQuote(wtPath)) -b \(shellQuote("claude/" + name)) \(base)")
            steps += copyTranscriptSteps(s, to: wtPath)
            steps.append("cd \(shellQuote(wtPath))")
        }
        steps.append("claude --resume \(s.cliSessionId)\(flags)")
        // One step per line keeps long commands readable once pasted.
        return steps.joined(separator: " && \\\n  ")
    }

    /// Commands for several sessions, one block each. Pasted together, they run one after another.
    static func commands(for sessions: [Session], mode: Mode) -> String {
        sessions.map { command(for: $0, mode: mode) }.joined(separator: "\n\n")
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").prefix(5).joined(separator: "-")
        return collapsed.isEmpty ? "session" : String(collapsed.prefix(40))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
