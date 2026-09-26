import AppKit
import SwiftUI

@main
struct SessionHubApp: App {
    @State private var store = Store()

    init() {
        // `SessionHub --schema` prints the observed data shape (used to regenerate the bundled baseline).
        if CommandLine.arguments.contains("--schema") {
            FileHandle.standardOutput.write(Scanner().scan().shape.encoded())
            exit(0)
        }
        // `SessionHub --dump` prints what the scanner sees, for debugging without the UI.
        if CommandLine.arguments.contains("--dump") {
            let r = Scanner().scan()
            print("active account:", r.activeAccount ?? "?", "| hidden non-local:", r.hiddenNonLocal)
            for c in r.columns {
                let items = r.sessions.filter { $0.columnId == c.id }
                print("\(c.id): \(items.count) sessions, \(items.filter(\.isArchived).count) archived, \(items.filter(\.isWorktree).count) in worktrees")
                let byStatus = Dictionary(grouping: items.filter { !$0.isArchived }, by: \.status)
                print("   active by status:", SessionStatus.allCases.compactMap { st in byStatus[st].map { "\(st.label) \($0.count)" } }.joined(separator: ", "))
                for s in items.sorted(by: { $0.lastActivity > $1.lastActivity }).prefix(3) {
                    print("   \(s.title.prefix(60)) | \(s.repoName) | \(s.branch ?? "-")")
                }
            }
            let drift = ShapeDrift.compare(observed: r.shape, baseline: ShapeStore.loadBaseline())
            print("shape: \(drift.breaking.count) breaking, \(drift.info.count) changed")
            drift.items.prefix(10).forEach { print("   ", $0.severity == .breaking ? "BREAKING" : "changed", $0.text) }
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
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                // Initial scan only; after that FSEvents drives rescans when files actually change.
                .task {
                    await store.refresh()
                    // Startup (first scan + first layout) frees large temporary buffers that malloc
                    // would otherwise keep cached; return them once the board has settled.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    malloc_zone_pressure_relief(nil, 0)
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
    @Environment(Store.self) private var store
    @State private var search = ""
    @AppStorage("archiveFilter") private var archiveFilter: ArchiveFilter = .active
    @State private var forkRequest: ForkRequest?
    @State private var confirmApply = false
    @State private var showColumns = false
    @State private var showShape = false
    @AppStorage("sortByStatus") private var sortByStatus = true

    @Namespace private var dock

    var body: some View {
        // The board keeps an even margin from every window edge; no top margin because the toolbar
        // already leaves the same gap below its controls as above them.
        HStack(alignment: .top, spacing: 0) {
            // The Stash is pinned like a sidebar; account columns scroll beside it.
            if store.columns.contains(where: { $0.kind == .stash }) {
                columnView(store.column("stash"))
                    .padding(.leading, Metrics.windowPadding)
                    .padding(.bottom, Metrics.windowPadding)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Metrics.windowPadding) {
                    ForEach(store.orderedColumns.filter { $0.kind != .stash && !store.prefs.hiddenColumns.contains($0.id) }) { column in
                        columnView(column)
                    }
                }
                .padding([.horizontal, .bottom], Metrics.windowPadding)
            }
            .scrollIndicators(.never)
        }
        .floatingToolbar()
        // Floating controls over the content: they never push the board around.
        .overlay(alignment: .bottom) { dockView }
        .task(id: store.message) {
            guard store.message != nil else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            store.message = nil
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter sessions")
        .toolbar { toolbarContent }
        .sheet(item: $forkRequest) { req in
            CommandSheet(sessions: req.sessions) { mode in announceCopy(req.sessions, mode); forkRequest = nil }
        }
        .confirmationDialog(applyTitle, isPresented: $confirmApply, titleVisibility: .visible) {
            Button(store.pendingNeedsRelaunch ? "Quit Claude, Apply & Relaunch" : "Apply") { Task { await store.applyPending() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.pendingNeedsRelaunch
                 ? "These changes touch the account Claude Desktop is signed into. Claude will quit (stopping any running sessions), the files will be updated, and Claude will reopen. A backup is kept and you can undo."
                 : "Session files will be moved or copied between account folders. A backup is kept and you can undo.")
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("Show", selection: $archiveFilter) {
                ForEach(ArchiveFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Filter by archived state (CLI sessions are never archived)")
        }
        ToolbarItem {
            Menu {
                Picker("Sort", selection: $sortByStatus) {
                    Label("Status, then recent", systemImage: "list.bullet.indent").tag(true)
                    Label("Most recent", systemImage: "clock").tag(false)
                }
                .pickerStyle(.inline)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .help("Sort cards within each column")
        }
        ToolbarItem {
            Button { showShape.toggle() } label: {
                Label("Data shape", systemImage: store.drift.isBreaking ? "exclamationmark.octagon.fill"
                      : store.drift.items.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
            }
            .foregroundStyle(store.drift.isBreaking ? AnyShapeStyle(.red) : store.drift.items.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .help(store.drift.isBreaking ? "Claude's data format changed in a way Session Hub depends on; moves are paused"
                  : store.drift.items.isEmpty ? "Claude's data format matches the baseline" : "Claude's data format has new or changed fields")
            .popover(isPresented: $showShape, arrowEdge: .bottom) { ShapePopover() }
        }
        ToolbarItemGroup {
            // A popover (not a menu) so it stays open while several columns are toggled —
            // macOS menus always close on click.
            Button { showColumns.toggle() } label: { Label("Columns", systemImage: "rectangle.split.3x1") }
                .help("Show or hide columns")
                .popover(isPresented: $showColumns, arrowEdge: .bottom) { ColumnsPopover() }
            Button { Task { await store.undoLast() } } label: { Label("Undo last change", systemImage: "arrow.uturn.backward") }
                .disabled(store.lastJournal == nil || store.isApplying)
                .help("Revert the last applied batch of changes")
            Button { Task { await store.refresh() } } label: {
                if store.isScanning { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .help("Rescan sessions")
        }
    }

    private func columnView(_ column: Column) -> some View {
        ColumnView(column: column, search: search, archiveFilter: archiveFilter) { sessions in
            forkRequest = ForkRequest(sessions: sessions)
        } onAction: { group, mode in copyCommands(group, mode) }
    }

    private var applyTitle: String { "Apply \(store.pending.count) change(s)?" }

    /// Pending changes, selection and messages as glass capsules that morph in and out together.
    private var dockView: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                if !store.pending.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(store.pending.count) pending change(s)").fontWeight(.semibold)
                            if store.pendingNeedsRelaunch {
                                Text("Claude will quit and reopen").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Discard") { store.discardPending() }.glassButton()
                        Button("Apply") { confirmApply = true }
                            .help(store.writesBlocked ? "Paused: Claude's data format changed (see Data shape)" : "Apply staged changes")
                            .glassButton(prominent: true)
                            .tint(.orange)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(store.isApplying || store.writesBlocked)
                    }
                    .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                    .glassPanel(in: Capsule())
                    .glassID("pending", in: dock)
                }
                if !store.selection.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        Text("\(store.selection.count) selected").fontWeight(.semibold)
                            .help("Drag any selected card to move them together · ⌘-click toggles · ⇧-click selects a range")
                        Button("Clear") { store.clearSelection() }
                            .glassButton()
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                    .glassPanel(in: Capsule())
                    .glassID("selection", in: dock)
                }
                if let msg = store.message {
                    HStack(spacing: 10) {
                        Text(msg).font(.callout).lineLimit(2)
                        Button { store.message = nil } label: { Image(systemName: "xmark") }
                            .glassButton()
                            .buttonBorderShape(.circle)
                    }
                    .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                    .frame(maxWidth: 520)
                    .glassPanel(in: Capsule())
                    .glassID("message", in: dock)
                }
            }
        }
        .padding(.bottom, Metrics.windowPadding + 12)
        // Animate only the dock itself; board-wide animation made every card flash on selection.
        .animation(.smooth(duration: 0.3), value: store.pending.isEmpty)
        .animation(.smooth(duration: 0.3), value: store.selection.isEmpty)
        .animation(.smooth(duration: 0.3), value: store.message)
    }

    private func copyCommands(_ sessions: [Session], _ mode: Launcher.Mode) {
        Launcher.copy(Launcher.commands(for: sessions, mode: mode))
        announceCopy(sessions, mode)
    }

    private func announceCopy(_ sessions: [Session], _ mode: Launcher.Mode) {
        let what = sessions.count == 1 ? "“\(sessions[0].title)”" : "\(sessions.count) sessions"
        store.message = "Copied \(mode.label.lowercased()) command for \(what). Paste it into a terminal."
    }
}

struct ForkRequest: Identifiable {
    let id = UUID()
    let sessions: [Session]
}

enum ArchiveFilter: String, CaseIterable, Identifiable {
    case active, archived, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: return "Active"
        case .archived: return "Archived"
        case .all: return "All"
        }
    }
    func includes(_ s: Session) -> Bool {
        switch self {
        case .active: return !s.isArchived
        case .archived: return s.isArchived
        case .all: return true
        }
    }
}

struct ColumnView: View {
    static let dragPrefix = "sessionhub-column:"
    @Environment(Store.self) private var store
    let column: Column
    let search: String
    let archiveFilter: ArchiveFilter
    let onFork: ([Session]) -> Void
    let onAction: ([Session], Launcher.Mode) -> Void
    @State private var targeted = false
    @State private var editing = false
    @State private var draft = ""
    /// Cards built up front per column; more load on demand to keep SwiftUI's view state small.
    @State private var limit = 50

    @AppStorage("sortByStatus") private var sortByStatus = true

    private var items: [Session] {
        let q = search.lowercased()
        let filtered = (store.columnItems[column.id] ?? []).filter { s in
            (column.kind == .stash || archiveFilter.includes(s)) && (q.isEmpty || s.searchKey.contains(q))
        }
        guard sortByStatus else { return filtered }   // already newest first
        return filtered.sorted { ($0.status.rawValue, $1.lastActivity) < ($1.status.rawValue, $0.lastActivity) }
    }

    var body: some View {
        let list = items
        VStack(alignment: .leading, spacing: 0) {
            header(count: list.count)
                .contentShape(Rectangle())
                .draggable(ColumnView.dragPrefix + column.id) {
                    Text(store.name(for: column)).font(.headline).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.tint.opacity(0.25), in: Capsule())
                }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(list.prefix(limit)) { s in
                        SessionCard(session: s, onSelect: { store.click(s, in: list) }, onAction: onAction)
                            .draggable(store.dragPayload(for: s)) { DragPreview(session: s, count: store.group(for: s).count) }
                    }
                    if list.count > limit {
                        Button("Show \(min(100, list.count - limit)) more…") { limit += 100 }.buttonStyle(.link).padding(6)
                    }
                    if list.isEmpty {
                        Text(emptyHint)
                            .font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, Metrics.columnPadding)
                .padding(.bottom, Metrics.dockClearance)
            }
            .scrollIndicators(.automatic)
            .softScrollEdge()
        }
        .frame(width: 320)
        // Content layer: an opaque, softly tinted well — no glass here (glass stays on controls).
        .background(
            RoundedRectangle(cornerRadius: Metrics.columnRadius, style: .continuous)
                .fill(targeted ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(0.045)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.columnRadius, style: .continuous)
                .strokeBorder(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.07)), lineWidth: targeted ? 2 : 1)
        )
        .dropDestination(for: String.self) { ids, _ in
            // Column header dropped here → reorder columns.
            if let c = ids.first(where: { $0.hasPrefix(ColumnView.dragPrefix) }) {
                store.reorderColumn(String(c.dropFirst(ColumnView.dragPrefix.count)), onto: column)
                return true
            }
            // Hold ⌥ while dropping to share (copy) instead of move.
            let copy = NSEvent.modifierFlags.contains(.option)
            var forks: [Session] = []
            for id in ids.flatMap({ $0.split(separator: "\n").map(String.init) }) {
                if case let .forkRequested(s) = store.drop(cardId: id, on: column, copy: copy) { forks.append(s) }
            }
            if !forks.isEmpty { onFork(forks) }
            store.clearSelection()
            return true
        } isTargeted: { targeted = $0 }
    }

    private var emptyHint: String {
        switch column.kind {
        case .cli: return "Drop a Desktop session here to get a CLI command"
        case .stash: return "Drop sessions here to stash them. Stashed sessions belong to no account; drag one onto an account to restore it."
        case .desktop: return "Drop sessions here"
        }
    }

    private var icon: String {
        switch column.kind {
        case .cli: return "terminal"
        case .stash: return "archivebox"
        case .desktop: return "person.crop.circle"
        }
    }

    @ViewBuilder private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if editing {
                    TextField("Name", text: $draft).textFieldStyle(.roundedBorder)
                        .onSubmit { store.rename(column, to: draft); editing = false }
                } else {
                    Text(store.name(for: column)).font(.headline).lineLimit(1)
                        .onTapGesture(count: 2) { draft = store.name(for: column); editing = true }
                }
                if column.accountUuid != nil && column.accountUuid == store.activeAccount {
                    Text("Signed in").font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                        .help("Claude Desktop's last signed-in account")
                }
                Spacer()
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Menu {
                    Button("Select all in column") { store.select(items) }
                    if column.kind != .stash {
                        let done = (store.columnItems[column.id] ?? []).filter { $0.status == .done && $0.columnId == column.id }
                        Button("Stash all Done (\(done.count))") {
                            for s in done { _ = store.drop(cardId: s.id, on: store.column("stash"), copy: false) }
                        }
                        .disabled(done.isEmpty)
                    }
                    Divider()
                    Button("Rename…") { draft = store.name(for: column); editing = true }
                    Button("Move column left") { store.moveColumn(column, by: -1) }
                    Button("Move column right") { store.moveColumn(column, by: 1) }
                    if case .desktop = column.kind {
                        Divider()
                        Button("Copy account ID") { Launcher.copy(column.accountUuid ?? "") }
                        Button("Reveal folder in Finder") { if let d = column.directory { NSWorkspace.shared.activateFileViewerSelecting([d]) } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Group {
                switch column.kind {
                case let .desktop(a, o): Text("acct \(a.prefix(8)) · org \(o.prefix(8))")
                case .cli: Text("~/.claude/projects · not tied to an account")
                case .stash: Text("not in any account · transcripts backed up")
                }
            }.font(.caption.monospaced()).foregroundStyle(.tertiary)
            let hint = store.hint(for: column)
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }
}

struct SessionCard: View {
    @Environment(Store.self) private var store
    let session: Session
    var onSelect: () -> Void = {}
    @State private var hovering = false
    let onAction: ([Session], Launcher.Mode) -> Void

    var body: some View {
        let s = session
        let move = store.pending[s.id]
        let selected = store.selection.contains(s.id)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                if s.isStarred { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { selected }, set: { _ in store.toggle(s) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .help("Select for bulk move")
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
            // Status and time get their own row so chips never truncate.
            HStack(spacing: 6) {
                StatusChip(status: s.status, reason: s.statusReason)
                Spacer(minLength: 4)
                RelativeTime(date: s.lastActivity)
            }
            let shared = store.sharedWith(s)
            if s.isWorktree || s.isArchived || s.prCount > 0 || move != nil || !shared.isEmpty {
                HStack(spacing: 6) {
                    if s.isWorktree {
                        tag(s.cwdExists ? "worktree" : "worktree gone", color: s.cwdExists ? .purple : .red)
                    }
                    if s.isArchived { tag("archived", color: .gray) }
                    if s.prCount > 0 { tag("\(s.prCount) PR", color: .blue) }
                    if let m = move {
                        tag((m.copy ? "+ " : "→ ") + store.name(for: store.column(m.to)), color: .orange)
                    }
                    if !shared.isEmpty {
                        tag("shared ×\(shared.count + 1)", color: .teal)
                            .help("Also in: " + shared.map { store.name(for: store.column($0)) }.joined(separator: ", "))
                    }
            }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.fill(selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear)))
                // Shadow only while hovered: hundreds of always-on shadows cost GPU time when scrolling.
                .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: hovering ? 6 : 0, y: hovering ? 3 : 0)
        }
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(
            selected ? AnyShapeStyle(.tint) : move != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary.opacity(0.06)),
            lineWidth: selected ? 2 : move != nil ? 1.5 : 1))
        .opacity(s.isArchived && !selected ? 0.6 : 1)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .onTapGesture { onSelect() }
        // The menu's items are only built for the card under the pointer (right-click always is).
        .contextMenu { if hovering { menu(s) } }
        .help(s.cwd)
    }

    @ViewBuilder private func menu(_ s: Session) -> some View {
        let group = store.group(for: s)
        let suffix = group.count > 1 ? " (\(group.count) sessions)" : ""
        Button("Copy fork command" + suffix) { onAction(group, .fork) }
        Button("Copy fork-into-new-worktree command" + suffix) { onAction(group, .forkNewWorktree) }
        Button("Copy resume command (same session ID)" + suffix) { onAction(group, .resume) }
        Divider()
        let targets = store.orderedColumns.filter { $0.kind != .cli && $0.kind != .stash && $0.id != s.columnId }
        if !s.isStashed {
            Button("Move to Stash" + suffix) { stage(group, on: store.column("stash"), copy: false) }
        }
        if s.isDesktop {
            Menu((s.isStashed ? "Restore to" : "Move to") + suffix) {
                ForEach(targets) { c in Button(store.name(for: c)) { stage(group, on: c, copy: false) } }
            }
        }
        Menu((s.isDesktop ? "Share with (copy)" : "Add to Desktop account") + suffix) {
            ForEach(targets) { c in Button(store.name(for: c)) { stage(group, on: c, copy: true) } }
        }
        if store.pending[s.id] != nil { Button("Cancel pending change") { store.pending[s.id] = nil } }
        if !store.sharedWith(s).isEmpty {
            Button("Remove from this account (keep other copies)") { Task { await store.removeCopy(s) } }
        }
        Divider()
        Button("Copy session ID") { Launcher.copy(s.cliSessionId) }
        Button("Reveal transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.transcriptURL]) }
        if s.cwdExists { Button("Open working folder") { NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd)) } }
    }

    private func stage(_ group: [Session], on c: Column, copy: Bool) {
        for g in group { _ = store.drop(cardId: g.id, on: c, copy: copy) }
        store.clearSelection()
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct DragPreview: View {
    let session: Session
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if count > 1 {
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 280, height: 44).offset(x: 6, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)).offset(x: 6, y: 6))
            }
            Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .padding(12).frame(width: 280, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(.tint, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            if count > 1 {
                Text("\(count)").font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.tint, in: Capsule()).offset(x: 8, y: -8)
            }
        }
        .padding(10)
    }
}

struct CommandSheet: View {
    let sessions: [Session]
    /// Called after the chosen command is on the clipboard.
    let onCopied: (Launcher.Mode) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Generated once so the preview is exactly what gets copied (worktree names are random).
    @State private var commands: [Launcher.Mode: String] = [:]

    private var session: Session { sessions[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sessions.count > 1 ? "Continue \(sessions.count) sessions in a terminal" : "Continue in a terminal").font(.title3.bold())
            if sessions.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sessions.prefix(6)) { Text("• " + $0.title).lineLimit(1) }
                    if sessions.count > 6 { Text("and \(sessions.count - 6) more").foregroundStyle(.secondary) }
                }
                .font(.callout)
                Text("The copied text has one command per session; pasted together they run one after another.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(session.title).font(.headline)
                Text(session.cwd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                option("New session ID, same folder\(sessions.allSatisfy(\.cwdExists) ? "" : " (a gone worktree falls back to the repo root)"). Desktop's session is untouched.", .fork)
                option("Creates .claude/worktrees/fork-… from the current commit so both sessions can edit in parallel. Uncommitted changes stay behind.", .forkNewWorktree)
                option("Continues the exact session. Don't use while Desktop is running it.", .resume)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).glassButton()
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            for mode in [Launcher.Mode.fork, .forkNewWorktree, .resume] {
                commands[mode] = Launcher.commands(for: sessions, mode: mode)
            }
        }
    }

    private func option(_ detail: String, _ mode: Launcher.Mode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mode.label).fontWeight(.semibold)
                Spacer()
                Button {
                    Launcher.copy(commands[mode] ?? Launcher.commands(for: sessions, mode: mode))
                    onCopied(mode)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .glassButton(prominent: mode == .fork)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(commands[mode] ?? "")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(8).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Shared once-a-minute clock so timestamps refresh together instead of every second per card.
@MainActor
@Observable
final class MinuteClock {
    static let shared = MinuteClock()
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    private init() {
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { MinuteClock.shared.now = Date() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

struct RelativeTime: View {
    let date: Date
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        let now = MinuteClock.shared.now
        Text(now.timeIntervalSince(date) < 60 ? "active just now" : "active " + Self.formatter.localizedString(for: date, relativeTo: now))
            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            .help("Last activity: " + date.formatted(date: .abbreviated, time: .shortened))
    }
}

struct ColumnsPopover: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Columns").font(.headline)
            ForEach(store.orderedColumns.filter { $0.kind != .stash }) { c in
                Toggle(isOn: Binding(
                    get: { !store.prefs.hiddenColumns.contains(c.id) },
                    set: { store.setVisible(c, $0) })) {
                    HStack {
                        Text(store.name(for: c))
                        Spacer(minLength: 16)
                        Text("\(store.count(in: c))").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if store.hiddenNonLocal > 0 {
                Divider()
                Label("\(store.hiddenNonLocal) session(s) from other machines hidden", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 280)
    }
}

struct StatusChip: View {
    let status: SessionStatus
    let reason: String

    private var color: Color {
        switch status {
        case .running: return .green
        case .needsYou: return .orange
        case .interrupted: return .red
        case .inReview: return .blue
        case .idle: return .gray
        case .done: return .mint
        }
    }

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .help(reason)
    }
}

struct ShapePopover: View {
    @Environment(Store.self) private var store

    var body: some View {
        let drift = store.drift
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude data shape").font(.headline)
                Spacer()
                if drift.isBreaking {
                    Label("Moves paused", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                } else if drift.items.isEmpty {
                    Label("Matches baseline", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                } else {
                    Label("\(drift.info.count) change(s)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Claude Desktop").foregroundStyle(.secondary)
                    Text(store.shape.claudeDesktopVersion ?? "?").monospacedDigit()
                }
                GridRow {
                    Text("Claude Code").foregroundStyle(.secondary)
                    Text(store.shape.claudeCodeVersion ?? "?").monospacedDigit()
                }
            }
            .font(.caption)
            if !drift.items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(drift.breaking) { Label($0.text, systemImage: "xmark.octagon").foregroundStyle(.red) }
                        ForEach(drift.info) { Label($0.text, systemImage: "plus.circle").foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            Text(drift.isBreaking
                 ? "Fields or folders Session Hub relies on have changed. Moving and stashing are paused until the app is updated for the new format."
                 : "New fields and values are informational. Accept them once you've checked a Claude update behaves as expected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show snapshots") {
                    try? FileManager.default.createDirectory(at: ShapeStore.snapshots, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ShapeStore.snapshots)
                }
                Button("Copy report") { Launcher.copy(store.shapeReport) }
                Spacer()
                Button("Accept as baseline") { store.acceptShape() }
                    .disabled(drift.items.isEmpty)
                    .help("Treat the current format as expected from now on")
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
