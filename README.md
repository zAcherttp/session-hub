# Session Hub

A small macOS app for people who switch between several Claude accounts. It shows your Claude Code sessions as a Kanban board, one column per Claude Desktop account plus one for the Claude Code CLI, so you can move or share sessions between accounts and continue any of them from the CLI.

## Features

- **Board of every local session.** Each Desktop account and organization gets its own column, and the CLI gets one more. Rename a column by double-clicking its header, and drag headers to reorder columns.
- **Move or share between accounts.** Drag a card to another account to move it; hold ⌥ while dropping to copy it so both accounts see it. Changes stay pending until you click **Apply**. If a change involves the account Claude Desktop is signed into, Apply quits Claude, updates the files, and reopens it. Every change is backed up, and **Undo** reverts the last batch.
- **Continue from the CLI.** Drop a Desktop card on the CLI column, or right-click any card, to copy a ready-to-paste command. It works in any terminal:
  - **Fork here:** `claude --resume <id> --fork-session` in the session's folder.
  - **Fork into a new worktree:** creates `.claude/worktrees/fork-…` from the session's current commit, so both sessions can edit in parallel.
  - **Resume:** continues the same session ID.
- **Status and ranking.** Each card gets a status, and by default columns sort by status, then by most recent activity (switch with the Sort button):
  | Status | Meaning |
  | --- | --- |
  | Running | The conversation was written in the last 90 seconds |
  | Needs you | Claude's end-of-turn summary says it's blocked, or its last message asks you a question |
  | Interrupted | The conversation ends on your interrupt, on a tool call or tool result with no reply, or on your message with no reply |
  | In review | It has an open PR, or the summary says it's ready for review |
  | Idle | Claude finished its turn and nothing is pending |
  | Done | Every PR is merged or closed, or the summary says it's complete. Each column's ⋯ menu has **Stash all Done** |
- **Data shape tracking.** `Schema/claude-storage-baseline.json` records how Claude stores sessions today: the fields and types in each session file, the record types in conversation files, known status values, the folder layout, and the Claude versions it came from. Every scan compares against it. If a field or folder Session Hub depends on disappears or changes type, moving and stashing pause. New fields or values show as informational changes you can accept as the new baseline. Each time the set of differences changes, a snapshot tagged with the Claude versions is saved in `~/Library/Application Support/SessionHub/schema/snapshots/`. Regenerate the bundled baseline with `SessionHub --schema > Schema/claude-storage-baseline.json`.
- **Stash.** A pinned column for sessions you want to keep but take out of every account. Stashed session files live in `~/Library/Application Support/SessionHub/stash/`, so no Claude Desktop login lists them. Stashing also backs up the conversation transcript, since Claude Code's cleanup can delete old ones. Drag a stashed session onto an account to restore it.
- **Bulk select.** Every card has a checkbox. Click a card to select it (it gets a highlighted border), ⌘-click to add or remove cards, and ⇧-click to select a range. Dragging any selected card moves the whole selection, and right-click actions apply to all selected cards.
- **Archive filter.** Switch between Active, Archived, or All sessions from the toolbar.
- **Liquid Glass design.** On macOS 26 and later, the toolbar and a floating dock (pending changes, selection, messages) use Liquid Glass, while columns and cards stay solid, following Apple's rule that glass belongs to controls rather than content. Earlier macOS versions fall back to standard materials.
- **This Mac only.** Sessions whose working folder isn't on this machine are hidden. The app refuses to write anything other than `local_*.json` files in Claude's session folders.

## How Claude Code stores sessions

The app relies on this layout, which I worked out from what's on disk; it isn't a documented API.

| What | Where |
| --- | --- |
| Desktop session metadata, one file per session | `~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json` |
| Transcripts, shared by all accounts and the CLI | `~/.claude/projects/<cwd-slug>/<cliSessionId>.jsonl` |
| Desktop worktrees | `<repo>/.claude/worktrees/<name>` |
| Stashed sessions (Session Hub's own folder) | `~/Library/Application Support/SessionHub/stash/` |
| Worktree ownership list, shared by all accounts | `~/Library/Application Support/Claude/git-worktrees.json` (linked by session ID) |

A session file doesn't record which account owns it, so moving it into another account's folder changes the owner. The transcript and worktree stay where they are.

## Install

Download `SessionHub-<version>.zip` from [Releases](https://github.com/zAcherttp/session-hub/releases), unzip it, and move `SessionHub.app` to Applications. The build is ad-hoc signed rather than notarized, so macOS blocks the first launch. Allow it once with:

```bash
xattr -dr com.apple.quarantine /Applications/SessionHub.app
```

It runs on macOS 14 or later, on both Apple Silicon and Intel Macs.

## Build

You need Xcode. The Command Line Tools alone can't build SwiftUI apps against the macOS 27 SDK.

```bash
./build.sh
```

This builds `SessionHub.app` and installs it to `~/Applications`. To print what the scanner finds without opening the UI:

```bash
~/Applications/SessionHub.app/Contents/MacOS/SessionHub --dump
```

To make a universal release zip in `dist/`:

```bash
./release.sh 1.0.0
```

## Caveats

- This is an unofficial tool, not affiliated with Anthropic. Claude's storage format can change without notice.
- Cloud sessions (claude.ai/code) don't have files on your Mac, so they don't appear.
- Dragging a CLI session into a Desktop account creates a basic Desktop record for it. This is experimental.

## License

MIT. See [LICENSE](LICENSE).
