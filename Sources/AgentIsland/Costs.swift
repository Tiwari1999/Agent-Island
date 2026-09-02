import Foundation

/// What the month's agent traffic would have cost at API list prices — an equivalence, not an
/// invoice (subscription usage is not billed per token, and the UI says so).
enum Costs {
    struct Line {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var cost = 0.0
        mutating func add(_ o: Line) {
            input += o.input; output += o.output
            cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
            cost += o.cost
        }
    }

    /// day ("2026-09-01", local calendar) -> model -> totals
    typealias Table = [String: [String: Line]]

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"   // the user's own midnight, not UTC's
        return f
    }()
    static func day(of date: Date) -> String { dayFmt.string(from: date) }

    /// USD per million tokens: input, output, cache read, cache write.
    /// Matched by substring so a dated model id ("claude-opus-5-20260115") still prices.
    private static let prices: [(key: String, i: Double, o: Double, cr: Double, cw: Double)] = [
        ("opus",   15.0, 75.0, 1.50, 18.75),
        ("fable",  15.0, 75.0, 1.50, 18.75),   // flagship-priced until Anthropic publishes it
        ("sonnet",  3.0, 15.0, 0.30,  3.75),
        ("haiku",   1.0,  5.0, 0.10,  1.25),
        ("gpt",    1.25, 10.0, 0.125, 1.25),
    ]

    static func price(model: String, _ l: inout Line) {
        let m = model.lowercased()
        guard let p = prices.first(where: { m.contains($0.key) }) else { return }
        l.cost = (Double(l.input) * p.i + Double(l.output) * p.o
                  + Double(l.cacheRead) * p.cr + Double(l.cacheWrite) * p.cw) / 1_000_000
    }

    // Per-file results survive between scans; an unchanged transcript cannot change its totals.
    private static var cache: [String: (mtime: Date, days: Table)] = [:]
    private static let lock = NSLock()

    /// Everything since the first of the current month, by day and model.
    static func scan(now: Date = Date()) -> Table {
        lock.lock(); defer { lock.unlock() }
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        var out = Table()
        var seen = Set<String>()

        func fold(_ path: String, _ parse: (String) -> Table) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= monthStart
            else { return }
            seen.insert(path)
            let days: Table
            if let hit = cache[path], hit.mtime == mtime {
                days = hit.days
            } else {
                days = parse(path)
                cache[path] = (mtime, days)
            }
            for (day, models) in days {
                for (model, line) in models {
                    out[day, default: [:]][model, default: Line()].add(line)
                }
            }
        }

        let fm = FileManager.default
        let projects = Home.path + "/.claude/projects"
        for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            for f in (try? fm.contentsOfDirectory(atPath: "\(projects)/\(dir)")) ?? []
            where f.hasSuffix(".jsonl") {
                fold("\(projects)/\(dir)/\(f)", claudeDays)
            }
        }
        if let e = fm.enumerator(atPath: Home.path + "/.codex/sessions") {
            for case let f as String in e where f.hasSuffix(".jsonl") {
                fold(Home.path + "/.codex/sessions/" + f, codexDays)
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return out
    }

    /// One Claude transcript. Every assistant turn carries its own usage and model.
    private static func claudeDays(path: String) -> Table {
        var out = Table()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return out }
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("\"usage\""), line.contains("\"model\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let model = msg["model"] as? String, model != "<synthetic>",
                  let stamp = obj["timestamp"] as? String,
                  let when = iso.date(from: stamp)
                        ?? ISO8601DateFormatter().date(from: stamp)
            else { continue }
            var l = Line()
            l.input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            l.output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            l.cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            l.cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            price(model: model, &l)
            out[day(of: when), default: [:]][model, default: Line()].add(l)
        }
        return out
    }

    /// One Codex rollout. The accounting is cumulative, so only the last total counts, and the
    /// whole session is attributed to the day it last ran — sessions rarely straddle midnight,
    /// and a split would be invented precision from data Codex does not provide.
    private static func codexDays(path: String) -> Table {
        var out = Table()
        let text = Tail.head(path: path, bytes: 256 * 1024) + "\n"
                 + Tail.read(path: path, bytes: 2 * 1024 * 1024)
        var model = "gpt"
        var last: [String: Any]?
        for line in text.split(whereSeparator: \.isNewline) {
            if model == "gpt", line.contains("\"model\""),
               let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let payload = obj["payload"] as? [String: Any] ?? obj
                if let m = payload["model"] as? String { model = m }
            }
            if line.contains("total_token_usage"),
               let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let payload = obj["payload"] as? [String: Any] ?? obj
                let info = (payload["info"] as? [String: Any]) ?? payload
                if let u = info["total_token_usage"] as? [String: Any] { last = u }
            }
        }
        guard let u = last else { return out }
        var l = Line()
        let cached = (u["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
        l.input = max(0, ((u["input_tokens"] as? NSNumber)?.intValue ?? 0) - cached)
        l.cacheRead = cached
        l.output = (u["output_tokens"] as? NSNumber)?.intValue ?? 0
        l.cacheWrite = (u["cache_write_input_tokens"] as? NSNumber)?.intValue ?? 0
        price(model: model, &l)
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                     as? Date) ?? Date()
        out[day(of: mtime)] = [model: l]
        return out
    }

    // MARK: - presentation

    static func today(_ t: Table, now: Date = Date()) -> [String: Line] {
        t[day(of: now)] ?? [:]
    }

    /// A transcript touched this month can carry entries from earlier ones, so the month view
    /// filters by each entry's own day rather than trusting the file's mtime.
    static func monthTotal(_ t: Table, now: Date = Date()) -> [String: Line] {
        let cal = Calendar.current
        let start = day(of: cal.date(from: cal.dateComponents([.year, .month], from: now))!)
        var out: [String: Line] = [:]
        for (d, models) in t where d >= start {
            for (model, line) in models { out[model, default: Line()].add(line) }
        }
        return out
    }

    /// Which agent a model belongs to, so spend can be read per agent rather than in total.
    static func vendor(ofModel model: String) -> Vendor? {
        let m = model.lowercased()
        if m.contains("claude") || m.contains("opus") || m.contains("sonnet")
            || m.contains("haiku") || m.contains("fable") { return .claude }
        if m.contains("gpt") || m.contains("codex") || m.contains("o1") { return .codex }
        return nil
    }

    /// Every token the account processed, cache included — that is what was consumed, even
    /// though cache reads dominate it.
    static func tokens(_ models: [String: Line], for v: Vendor) -> Int {
        models.filter { vendor(ofModel: $0.key) == v }.values
            .reduce(0) { $0 + $1.input + $1.output + $1.cacheRead + $1.cacheWrite }
    }

    static func spend(_ models: [String: Line], for v: Vendor) -> Double {
        models.filter { vendor(ofModel: $0.key) == v }.values.reduce(0) { $0 + $1.cost }
    }

    static func dollars(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    /// The whole table as JSON, for the test suite to check the arithmetic against a fixture.
    static func json() -> String {
        let t = scan()
        var obj: [String: [String: [String: Any]]] = [:]
        for (day, models) in t {
            for (model, l) in models {
                obj[day, default: [:]][model] = ["input": l.input, "output": l.output,
                                                "cacheRead": l.cacheRead, "cacheWrite": l.cacheWrite,
                                                "cost": (l.cost * 10000).rounded() / 10000]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
