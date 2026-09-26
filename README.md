# Session Hub

A small macOS app for people who switch between several Claude accounts. It shows your Claude Code sessions as a Kanban board, one column per Claude Desktop account plus one for the Claude Code CLI, so you can move or share sessions between accounts and continue any of them in iTerm2.

## Features

- **Board of every local session.** Each Desktop account and organization gets its own column, and the CLI gets one more. Rename a column by double-clicking its header, and drag headers to reorder columns.
- **Move or share between accounts.** Drag a card to another account to move it; hold ⌥ while dropping to copy it so both accounts see it. Changes stay pending until you click **Apply**. If a change involves the account Claude Desktop is signed into, Apply quits Claude, updates the files, and reopens it. Every change is backed up, and **Undo** reverts the last batch.
- **Continue in iTerm2.** Drop a Desktop card on the CLI column, or right-click any card, and choose:
  - **Fork here:** `claude --resume <id> --fork-session` in the session's folder.
  - **Fork into a new worktree:** creates `.claude/worktrees/fork-…` from the session's current commit, so both sessions can edit in parallel.
  - **Resume:** continues the same session ID.
- **Bulk select.** Every card has a checkbox. Click a card to select it (it gets a highlighted border), ⌘-click to add or remove cards, and ⇧-click to select a range. Dragging any selected card moves the whole selection, and right-click actions apply to all selected cards.
- **Archive filter.** Switch between Active, Archived, or All sessions from the toolbar.
- **This Mac only.** Sessions whose working folder isn't on this machine are hidden. The app refuses to write anything other than `local_*.json` files in Claude's session folders.

## How Claude Code stores sessions

The app relies on this layout, which I worked out from what's on disk; it isn't a documented API.

| What | Where |
| --- | --- |
| Desktop session metadata, one file per session | `~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json` |
| Transcripts, shared by all accounts and the CLI | `~/.claude/projects/<cwd-slug>/<cliSessionId>.jsonl` |
| Desktop worktrees | `<repo>/.claude/worktrees/<name>` |
| Worktree ownership list, shared by all accounts | `~/Library/Application Support/Claude/git-worktrees.json` (linked by session ID) |

A session file doesn't record which account owns it, so moving it into another account's folder changes the owner. The transcript and worktree stay where they are.

## Build

You need Xcode. The Command Line Tools alone can't build SwiftUI apps against the macOS 27 SDK.

```bash
./build.sh
```

This builds `SessionHub.app` and installs it to `~/Applications`. To print what the scanner finds without opening the UI:

```bash
~/Applications/SessionHub.app/Contents/MacOS/SessionHub --dump
```

## Caveats

- This is an unofficial tool, not affiliated with Anthropic. Claude's storage format can change without notice.
- Cloud sessions (claude.ai/code) don't have files on your Mac, so they don't appear.
- Dragging a CLI session into a Desktop account creates a basic Desktop record for it. This is experimental.

## License

MIT. See [LICENSE](LICENSE).
