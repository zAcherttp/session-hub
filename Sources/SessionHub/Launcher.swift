import AppKit
import Foundation

/// Builds `claude` shell commands for a session and runs them in iTerm2.
enum Launcher {
    enum Mode { case resume, fork, forkNewWorktree }

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
        return steps.joined(separator: " && ")
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").prefix(5).joined(separator: "-")
        return collapsed.isEmpty ? "session" : String(collapsed.prefix(40))
    }

    private static let script = """
    on run argv
        set cmd to item 1 of argv
        tell application id "com.googlecode.iterm2"
            activate
            if (count of windows) = 0 then
                set w to (create window with default profile)
            else
                set w to current window
                tell w to create tab with default profile
            end if
            tell current session of w to write text cmd
        end tell
    end run
    """

    static func runInITerm(_ command: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, command]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "SessionHub", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "iTerm2 automation failed: \(msg)"])
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
