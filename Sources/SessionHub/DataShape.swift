import Foundation

/// The inferred shape of Claude's on-disk session data: which fields each record kind has,
/// their JSON types, a few enum-like values, and the folder layout. Session Hub compares the
/// shape it observes against a baseline to notice when a Claude update changes the format.
struct ShapeProfile: Codable, Equatable {
    struct Field: Codable, Equatable {
        var types: Set<String> = []
        var count = 0
    }

    struct Record: Codable, Equatable {
        var count = 0
        var fields: [String: Field] = [:]
    }

    var generatedAt = Date()
    var claudeDesktopVersion: String?
    var claudeCodeVersion: String?
    var layout: [String: Bool] = [:]
    var records: [String: Record] = [:]
    var enums: [String: Set<String>] = [:]

    /// Enum-like values worth tracking (a new value usually means new behavior).
    static let trackedEnums: Set<String> = [
        "desktopSession.postTurnSummary.status_category",
        "desktopSession.prs[].state",
        "transcript.entrypoint",
    ]

    mutating func observe(_ kind: String, _ object: [String: Any]) {
        var record = records[kind] ?? Record()
        record.count += 1
        for (key, value) in object {
            record.fields[key, default: Field()].types.insert(Self.jsonType(value))
            record.fields[key, default: Field()].count += 1
            let path = kind + "." + key
            if Self.trackedEnums.contains(path), let s = value as? String { enums[path, default: []].insert(s) }
        }
        records[kind] = record
    }

    mutating func noteValue(_ path: String, _ value: String) { enums[path, default: []].insert(value) }

    mutating func merge(_ other: ShapeProfile) {
        for (kind, r) in other.records {
            var mine = records[kind] ?? Record()
            mine.count += r.count
            for (k, f) in r.fields {
                mine.fields[k, default: Field()].types.formUnion(f.types)
                mine.fields[k, default: Field()].count += f.count
            }
            records[kind] = mine
        }
        for (k, v) in other.enums { enums[k, default: []].formUnion(v) }
    }

    static func jsonType(_ v: Any) -> String {
        switch v {
        case is NSNull: return "null"
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return "unknown"
        }
    }

    /// Observes a Desktop session file plus the nested records the app reads.
    mutating func observeDesktopSession(_ j: [String: Any]) {
        observe("desktopSession", j)
        if let s = j["postTurnSummary"] as? [String: Any] { observe("desktopSession.postTurnSummary", s) }
        for pr in (j["prs"] as? [[String: Any]]) ?? [] { observe("desktopSession.prs[]", pr) }
        if let v = (j["promptAppendSnapshot"] as? [String: Any])?["cliVersion"] as? String { noteValue("version.claudeCode", v) }
    }

    /// Observes one transcript line, keyed by its `type`.
    mutating func observeTranscriptLine(_ o: [String: Any]) {
        let type = (o["type"] as? String) ?? "(no type)"
        observe("transcript." + type, o)
        if let e = o["entrypoint"] as? String { noteValue("transcript.entrypoint", e) }
        if let v = o["version"] as? String { noteValue("version.claudeCode", v) }
        if let m = o["message"] as? [String: Any], type == "user" || type == "assistant" {
            observe("transcript.\(type).message", m)
        }
    }

    /// Folder layout facts the app depends on.
    static func observeLayout() -> [String: Bool] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let accounts = (try? fm.contentsOfDirectory(atPath: Paths.desktopSessions.path)) ?? []
        let uuidAccounts = accounts.filter { UUID(uuidString: $0) != nil }
        let hasOrgFolders = uuidAccounts.contains { a in
            ((try? fm.contentsOfDirectory(atPath: Paths.desktopSessions.appendingPathComponent(a).path)) ?? [])
                .contains { UUID(uuidString: $0) != nil }
        }
        let config = (try? Data(contentsOf: Paths.desktopConfig)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return [
            "claude-code-sessions folder": fm.fileExists(atPath: Paths.desktopSessions.path, isDirectory: &isDir) && isDir.boolValue,
            "claude-code-sessions/<account>/<org> folders": hasOrgFolders,
            "~/.claude/projects folder": fm.fileExists(atPath: Paths.cliProjects.path),
            "config.json lastKnownAccountUuid": config?["lastKnownAccountUuid"] is String,
            "git-worktrees.json": fm.fileExists(atPath: Paths.worktreeRegistry.path),
        ]
    }

    static var installedDesktopVersion: String? {
        Bundle(url: URL(fileURLWithPath: "/Applications/Claude.app"))?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Highest Claude Code version seen in the data (versions compare numerically per component).
    var latestCodeVersion: String? {
        enums["version.claudeCode"]?.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> ShapeProfile? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ShapeProfile.self, from: data)
    }
}

/// Differences between an observed shape and the baseline.
struct ShapeDrift: Equatable {
    enum Severity: Int, Comparable {
        case info, breaking
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    struct Item: Identifiable, Hashable {
        var id: String { severity == .breaking ? "!" + text : text }
        let severity: Severity
        let text: String
    }

    var items: [Item] = []
    var isBreaking: Bool { items.contains { $0.severity == .breaking } }
    var breaking: [Item] { items.filter { $0.severity == .breaking } }
    var info: [Item] { items.filter { $0.severity == .info } }

    /// A stable fingerprint, so a snapshot is saved only when the set of differences changes.
    var signature: String { items.map(\.id).sorted().joined(separator: "\n") }

    /// Fields the app reads. Missing or retyped ones make moves unsafe.
    static let requirements: [(kind: String, field: String, type: String)] = [
        ("desktopSession", "sessionId", "string"),
        ("desktopSession", "cliSessionId", "string"),
        ("desktopSession", "cwd", "string"),
        ("desktopSession", "lastActivityAt", "number"),
        ("desktopSession", "title", "string"),
        ("desktopSession.prs[]", "state", "string"),
        ("transcript.user", "cwd", "string"),
        ("transcript.user", "message", "object"),
        ("transcript.custom-title", "customTitle", "string"),
        ("transcript.ai-title", "aiTitle", "string"),
    ]

    static func compare(observed: ShapeProfile, baseline: ShapeProfile?) -> ShapeDrift {
        var items: [Item] = []

        for (fact, ok) in observed.layout.sorted(by: { $0.key < $1.key }) where !ok && baseline?.layout[fact] != false {
            items.append(Item(severity: .breaking, text: "Layout: \(fact) not found"))
        }
        for r in requirements {
            guard let rec = observed.records[r.kind], rec.count > 0 else { continue }
            let field = rec.fields[r.field]
            let present = Double(field?.count ?? 0) / Double(rec.count)
            if present < 0.9 {
                items.append(Item(severity: .breaking,
                                  text: "\(r.kind).\(r.field) missing in \(Int((1 - present) * 100))% of records"))
            } else if let types = field?.types, !types.contains(r.type) {
                items.append(Item(severity: .breaking,
                                  text: "\(r.kind).\(r.field) is \(types.sorted().joined(separator: "/")), expected \(r.type)"))
            }
        }

        guard let baseline else { return ShapeDrift(items: items) }

        for kind in Set(observed.records.keys).subtracting(baseline.records.keys).sorted() {
            items.append(Item(severity: .info, text: "New record type: \(kind)"))
        }
        for kind in Set(baseline.records.keys).subtracting(observed.records.keys).sorted()
        where (baseline.records[kind]?.count ?? 0) >= 20 {
            items.append(Item(severity: .info, text: "Record type no longer seen: \(kind)"))
        }
        for (kind, rec) in observed.records.sorted(by: { $0.key < $1.key }) {
            guard let base = baseline.records[kind] else { continue }
            for key in Set(rec.fields.keys).subtracting(base.fields.keys).sorted() {
                items.append(Item(severity: .info, text: "New field: \(kind).\(key)"))
            }
            for key in Set(base.fields.keys).subtracting(rec.fields.keys).sorted() {
                // Only flag fields the baseline saw often; rare optional fields come and go.
                let share = Double(base.fields[key]?.count ?? 0) / Double(max(base.count, 1))
                if share >= 0.5, rec.count >= 10 {
                    items.append(Item(severity: .info, text: "Field no longer seen: \(kind).\(key)"))
                }
            }
            // Type changes only matter for Desktop session files and fields the app reads;
            // transcript payloads (tool results etc.) vary by tool and would just be noise.
            let required = Set(requirements.filter { $0.kind == kind }.map(\.field))
            for (key, f) in rec.fields.sorted(by: { $0.key < $1.key })
            where kind.hasPrefix("desktopSession") || required.contains(key) {
                guard let b = base.fields[key] else { continue }
                let added = f.types.subtracting(b.types).subtracting(["null"])
                if !added.isEmpty {
                    items.append(Item(severity: .info,
                                      text: "Type change: \(kind).\(key) now also \(added.sorted().joined(separator: "/"))"))
                }
            }
        }
        for (path, values) in observed.enums.sorted(by: { $0.key < $1.key }) where ShapeProfile.trackedEnums.contains(path) {
            let new = values.subtracting(baseline.enums[path] ?? [])
            if !new.isEmpty {
                items.append(Item(severity: .info, text: "New value for \(path): \(new.sorted().joined(separator: ", "))"))
            }
        }
        // Keep requirement failures first, then info items in a stable order.
        return ShapeDrift(items: items)
    }

    func report(observed: ShapeProfile, baseline: ShapeProfile?) -> String {
        var lines = ["# Claude storage shape report", ""]
        lines.append("- Claude Desktop: \(observed.claudeDesktopVersion ?? "?") (baseline \(baseline?.claudeDesktopVersion ?? "none"))")
        lines.append("- Claude Code: \(observed.claudeCodeVersion ?? "?") (baseline \(baseline?.claudeCodeVersion ?? "none"))")
        lines.append("")
        if items.isEmpty { lines.append("No differences from the baseline.") }
        if !breaking.isEmpty {
            lines.append("## Breaking")
            lines += breaking.map { "- " + $0.text }
            lines.append("")
        }
        if !info.isEmpty {
            lines.append("## Changed")
            lines += info.map { "- " + $0.text }
        }
        return lines.joined(separator: "\n")
    }
}

/// Where baselines and snapshots live.
enum ShapeStore {
    static let folder = Paths.hubSupport.appendingPathComponent("schema")
    static let acceptedBaseline = folder.appendingPathComponent("baseline.json")
    static let snapshots = folder.appendingPathComponent("snapshots")
    static let lastSignature = folder.appendingPathComponent("last-drift.txt")

    /// The user's accepted baseline, else the one bundled with the app.
    static func loadBaseline() -> ShapeProfile? {
        if let d = try? Data(contentsOf: acceptedBaseline), let p = ShapeProfile.decode(d) { return p }
        if let url = Bundle.main.url(forResource: "claude-storage-baseline", withExtension: "json"),
           let d = try? Data(contentsOf: url) { return ShapeProfile.decode(d) }
        return nil
    }

    static func accept(_ profile: ShapeProfile) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try profile.encoded().write(to: acceptedBaseline, options: .atomic)
    }

    /// Saves a snapshot when the set of differences changes, so drift can be traced to a Claude update.
    static func recordIfChanged(_ drift: ShapeDrift, observed: ShapeProfile) {
        let old = (try? String(contentsOf: lastSignature, encoding: .utf8)) ?? ""
        guard old != drift.signature else { return }
        try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(f.string(from: Date()))-desktop\(observed.claudeDesktopVersion ?? "x")-code\(observed.claudeCodeVersion ?? "x")"
        try? observed.encoded().write(to: snapshots.appendingPathComponent(name + ".json"))
        try? drift.report(observed: observed, baseline: loadBaseline())
            .write(to: snapshots.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
        try? drift.signature.write(to: lastSignature, atomically: true, encoding: .utf8)
    }
}
