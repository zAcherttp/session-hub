import AppKit
import SwiftUI

@main
struct SessionHubApp: App {
    @StateObject private var store = Store()

    init() {
        // `SessionHub --dump` prints what the scanner sees, for debugging without the UI.
        if CommandLine.arguments.contains("--dump") {
            let r = Scanner.scan()
            print("active account:", r.activeAccount ?? "?", "| hidden non-local:", r.hiddenNonLocal)
            for c in r.columns {
                let items = r.sessions.filter { $0.columnId == c.id }
                print("\(c.id): \(items.count) sessions, \(items.filter(\.isArchived).count) archived, \(items.filter(\.isWorktree).count) in worktrees")
                for s in items.sorted(by: { $0.lastActivity > $1.lastActivity }).prefix(3) {
                    print("   \(s.title.prefix(60)) | \(s.repoName) | \(s.branch ?? "-")")
                }
            }
            if let wt = r.sessions.first(where: { $0.isWorktree && !$0.cwdExists }) ?? r.sessions.first(where: \.isWorktree) {
                print("\nsample fork:", Launcher.command(for: wt, mode: .fork))
                print("sample new worktree:", Launcher.command(for: wt, mode: .forkNewWorktree))
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Session Hub") {
            BoardView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
                .task { await store.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if store.pending.isEmpty { Task { await store.refresh() } }
                }
        }
        .defaultSize(width: 1400, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

struct BoardView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var showArchived = false
    @State private var forkTarget: Session?
    @State private var confirmApply = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if !store.pending.isEmpty { pendingBar }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(store.orderedColumns.filter { !store.prefs.hiddenColumns.contains($0.id) }) { column in
                        ColumnView(column: column, search: search, showArchived: showArchived) { outcome in
                            if case let .forkRequested(s) = outcome { forkTarget = s }
                        } onAction: { s, mode in launch(s, mode) }
                    }
                }
                .padding(12)
            }
            if store.hiddenNonLocal > 0 {
                Text("\(store.hiddenNonLocal) session(s) from other machines/users hidden")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }
            if let msg = store.message {
                HStack {
                    Text(msg).font(.callout)
                    Spacer()
                    Button("Dismiss") { store.message = nil }.buttonStyle(.link)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter sessions")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showArchived) { Label("Archived", systemImage: "archivebox") }
                    .help("Show archived Desktop sessions")
                Menu {
                    ForEach(store.orderedColumns) { c in
                        Toggle(store.name(for: c), isOn: Binding(
                            get: { !store.prefs.hiddenColumns.contains(c.id) },
                            set: { store.setVisible(c, $0) }))
                    }
                } label: { Label("Columns", systemImage: "rectangle.split.3x1") }
                Button { Task { await store.undoLast() } } label: { Label("Undo last change", systemImage: "arrow.uturn.backward") }
                    .disabled(store.lastJournal == nil || store.isApplying)
                    .help("Revert the last applied batch of moves")
                Button { Task { await store.refresh() } } label: {
                    if store.isScanning { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
        }
        .sheet(item: $forkTarget) { s in ForkSheet(session: s) { mode in launch(s, mode); forkTarget = nil } }
        .confirmationDialog(applyTitle, isPresented: $confirmApply, titleVisibility: .visible) {
            Button(store.pendingNeedsRelaunch ? "Quit Claude, Apply & Relaunch" : "Apply") { Task { await store.applyPending() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.pendingNeedsRelaunch
                 ? "These changes touch the account Claude Desktop is signed into. Claude will quit (stopping any running sessions), the files will be updated, and Claude will reopen. A backup is kept and you can undo."
                 : "Session files will be moved or copied between account folders. A backup is kept and you can undo.")
        }
        .alert("Couldn't open iTerm2", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var applyTitle: String { "Apply \(store.pending.count) change(s)?" }

    private var pendingBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(.orange)
            Text("\(store.pending.count) pending change(s)").fontWeight(.medium)
            if store.pendingNeedsRelaunch {
                Text("Claude Desktop will quit and reopen").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") { store.discardPending() }
            Button("Apply") { confirmApply = true }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(store.isApplying)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private func launch(_ s: Session, _ mode: Launcher.Mode) {
        do { try Launcher.runInITerm(Launcher.command(for: s, mode: mode)) } catch { self.error = error.localizedDescription }
    }
}

struct ColumnView: View {
    static let dragPrefix = "sessionhub-column:"
    @EnvironmentObject var store: Store
    let column: Column
    let search: String
    let showArchived: Bool
    let onDrop: (Store.DropOutcome) -> Void
    let onAction: (Session, Launcher.Mode) -> Void
    @State private var targeted = false
    @State private var editing = false
    @State private var draft = ""
    @State private var limit = 150

    private var items: [Session] {
        let q = search.lowercased()
        return store.sessions.filter { s in
            store.displayColumns(for: s).contains(column.id)
                && (showArchived || !s.isArchived)
                && (q.isEmpty || s.title.lowercased().contains(q) || s.cwd.lowercased().contains(q) || (s.branch ?? "").lowercased().contains(q))
        }
    }

    var body: some View {
        let list = items
        VStack(alignment: .leading, spacing: 0) {
            header(count: list.count)
                .contentShape(Rectangle())
                .draggable(ColumnView.dragPrefix + column.id) {
                    Text(store.name(for: column)).font(.headline).padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.25)))
                }
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(list.prefix(limit)) { s in
                        SessionCard(session: s, onAction: onAction)
                            .draggable(s.id) { SessionCard(session: s, onAction: { _, _ in }).frame(width: 300).opacity(0.9) }
                    }
                    if list.count > limit {
                        Button("Show \(min(150, list.count - limit)) more…") { limit += 150 }.buttonStyle(.link).padding(6)
                    }
                    if list.isEmpty {
                        Text(column.kind == .cli ? "Drop a Desktop session here to fork it in iTerm2" : "Drop sessions here")
                            .font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: targeted ? 2 : 1))
        .dropDestination(for: String.self) { ids, _ in
            // Column header dropped here → reorder columns.
            if let c = ids.first(where: { $0.hasPrefix(ColumnView.dragPrefix) }) {
                store.reorderColumn(String(c.dropFirst(ColumnView.dragPrefix.count)), onto: column)
                return true
            }
            // Hold ⌥ while dropping to share (copy) instead of move.
            let copy = NSEvent.modifierFlags.contains(.option)
            for id in ids { onDrop(store.drop(cardId: id, on: column, copy: copy)) }
            return true
        } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: column.kind == .cli ? "terminal" : "person.crop.circle")
                if editing {
                    TextField("Name", text: $draft).textFieldStyle(.roundedBorder)
                        .onSubmit { store.rename(column, to: draft); editing = false }
                } else {
                    Text(store.name(for: column)).font(.headline).lineLimit(1)
                        .onTapGesture(count: 2) { draft = store.name(for: column); editing = true }
                }
                if column.accountUuid != nil && column.accountUuid == store.activeAccount {
                    Text("SIGNED IN").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.2))).foregroundStyle(.green)
                        .help("Claude Desktop's last signed-in account")
                }
                Spacer()
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Menu {
                    Button("Rename…") { draft = store.name(for: column); editing = true }
                    Button("Move column left") { store.moveColumn(column, by: -1) }
                    Button("Move column right") { store.moveColumn(column, by: 1) }
                    if column.kind != .cli {
                        Divider()
                        Button("Copy account ID") { Launcher.copy(column.accountUuid ?? "") }
                        Button("Reveal folder in Finder") { if let d = column.directory { NSWorkspace.shared.activateFileViewerSelecting([d]) } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Group {
                if let a = column.accountUuid, let o = column.orgUuid {
                    Text("acct \(a.prefix(8)) · org \(o.prefix(8))")
                } else {
                    Text("~/.claude/projects · not tied to an account")
                }
            }.font(.caption.monospaced()).foregroundStyle(.tertiary)
            let hint = store.hint(for: column)
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(10)
    }
}

struct SessionCard: View {
    @EnvironmentObject var store: Store
    let session: Session
    let onAction: (Session, Launcher.Mode) -> Void

    var body: some View {
        let s = session
        let move = store.pending[s.id]
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 4) {
                if s.isStarred { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.caption2)
                Text(s.repoName).lineLimit(1)
                if let b = s.branch {
                    Image(systemName: "arrow.triangle.branch").font(.caption2)
                    Text(b).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let st = s.statusLine {
                Text(st).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                if s.isWorktree {
                    tag(s.cwdExists ? "worktree" : "worktree gone", color: s.cwdExists ? .purple : .red)
                }
                if s.isArchived { tag("archived", color: .gray) }
                if s.prCount > 0 { tag("\(s.prCount) PR", color: .blue) }
                if let m = move {
                    tag((m.copy ? "+ " : "→ ") + store.name(for: store.column(m.to)), color: .orange)
                }
                let shared = store.sharedWith(s)
                if !shared.isEmpty {
                    tag("shared ×\(shared.count + 1)", color: .teal)
                        .help("Also in: " + shared.map { store.name(for: store.column($0)) }.joined(separator: ", "))
                }
                Spacer()
                Text(s.lastActivity, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(move != nil ? Color.orange : Color.secondary.opacity(0.15), lineWidth: move != nil ? 1.5 : 1))
        .opacity(s.isArchived ? 0.6 : 1)
        .contextMenu { menu(s) }
        .help(s.cwd)
    }

    @ViewBuilder private func menu(_ s: Session) -> some View {
        Button("Fork in iTerm2") { onAction(s, .fork) }
        Button("Fork into new worktree in iTerm2") { onAction(s, .forkNewWorktree) }
        Button("Resume in iTerm2 (same session ID)") { onAction(s, .resume) }
        Divider()
        let targets = store.orderedColumns.filter { $0.kind != .cli && $0.id != s.columnId }
        if s.isDesktop {
            Menu("Move to") {
                ForEach(targets) { c in Button(store.name(for: c)) { _ = store.drop(cardId: s.id, on: c, copy: false) } }
            }
        }
        Menu(s.isDesktop ? "Share with (copy)" : "Add to Desktop account") {
            ForEach(targets) { c in Button(store.name(for: c)) { _ = store.drop(cardId: s.id, on: c, copy: true) } }
        }
        if store.pending[s.id] != nil { Button("Cancel pending change") { store.pending[s.id] = nil } }
        if !store.sharedWith(s).isEmpty {
            Button("Remove from this account (keep other copies)") { Task { await store.removeCopy(s) } }
        }
        Divider()
        Button("Copy fork command") { Launcher.copy(Launcher.command(for: s, mode: .fork)) }
        Button("Copy session ID") { Launcher.copy(s.cliSessionId) }
        Button("Reveal transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.transcriptURL]) }
        if s.cwdExists { Button("Open working folder") { NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd)) } }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
    }
}

struct ForkSheet: View {
    let session: Session
    let onPick: (Launcher.Mode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue in iTerm2").font(.title3.bold())
            Text(session.title).font(.headline)
            Text(session.cwd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 8) {
                option("Fork here", "New session ID, same folder\(session.cwdExists ? "" : " (worktree is gone — uses the repo root)"). Desktop's session is untouched.", .fork)
                option("Fork into a new worktree", "Creates .claude/worktrees/fork-… from the current commit so both sessions can edit in parallel. Uncommitted changes stay behind.", .forkNewWorktree)
                option("Resume (same ID)", "Continues the exact session. Don't use while Desktop is running it.", .resume)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func option(_ title: String, _ detail: String, _ mode: Launcher.Mode) -> some View {
        Button { onPick(mode) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
