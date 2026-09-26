# Changelog

## 1.0.1

### Added
- **Session status and ranking.** Each card shows Running, Needs you, Interrupted, In review, Idle or Done, based on Claude's end-of-turn summary, PR states and how the conversation ends. Columns sort by status, then most recent; the Sort button switches to pure recency. Hover a chip to see why.
- **Stash.** A pinned column for sessions you want to keep outside every account. Stashing moves the session file into Session Hub's own folder and backs up its conversation in case Claude Code's cleanup deletes the original. Drag it onto an account to restore it. Each column's ⋯ menu has **Stash all Done**.
- **Data shape tracking.** A bundled baseline records how Claude stores sessions (fields, record types, status values, folder layout, versions). Each scan compares against it: breaking changes pause moves, new fields and values appear as informational changes you can accept, and snapshots are saved when the differences change. `SessionHub --schema` regenerates the baseline.
- **Liquid Glass design** on macOS 26+: glass toolbar and a floating dock for pending changes, selection and messages, while columns and cards stay solid. Earlier macOS versions use standard materials.
- Columns popover with checkboxes that stays open while you toggle columns. Accounts with two organizations include the org in their default name.

### Changed
- **Continuing a session now copies a CLI command** to paste into any terminal, instead of typing it into iTerm2.
- Card checkboxes moved to the top-right corner. Status and time have their own row, and the time reads "active 5 min ago".
- The board keeps an even margin inside the window, with equal spacing above and below the toolbar controls.
- Much lighter on resources: idle CPU dropped from about 1% to 0%, and peak memory from 136 MB to about 70 MB. Rescans now run only when Claude's files change and reuse cached results.

### Fixed
- Long commands typed into a new iTerm2 tab were cut off, leaving the shell at a `quote>` prompt.
- The toolbar didn't render as Liquid Glass, because the app was marked as built with an old SDK.
- Cards flashed when selected.

## 1.0.0

First release: a Kanban board of local Claude Code sessions with one column per Claude Desktop account plus the CLI. Move or share sessions between accounts by dragging, with bulk select, backup and undo.
