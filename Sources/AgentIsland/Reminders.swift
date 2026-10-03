import Foundation

/// When to nudge again about something still waiting on the user. Pure: no timer, no clock —
/// every call takes `now`, and the owner arms one one-shot timer for `nextDue`, or none.
struct Reminders {
    enum Kind: Int, Comparable {
        case approval, question, completion
        /// A blocked agent is worth a few nudges; a finished turn blocks nothing, so one.
        var cap: Int { self == .completion ? 1 : 3 }
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Session AND item: keying by session alone let one session's answer cancel another's ask.
    struct Key: Hashable {
        let session: String
        let item: String
    }

    struct Due: Equatable {
        let key: Key
        let kind: Kind
        let attempt: Int
        let catchUp: Bool
    }

    private struct Entry {
        let kind: Kind
        let since: Date
        var anchor: Date      // the arrival, then the last nudge; the next is an interval later
        var sent = 0
        var owed = false      // came due while locked; delivered on unlock, at most once
    }

    private(set) var interval: TimeInterval?
    private var entries: [Key: Entry] = [:]

    init(interval: TimeInterval?) { setInterval(interval) }

    var isEmpty: Bool { entries.isEmpty }
    var keys: Set<Key> { Set(entries.keys) }

    /// nil or zero is Off, and Off forgets everything so turning it back on cannot fire a backlog.
    mutating func setInterval(_ seconds: TimeInterval?) {
        interval = (seconds ?? 0) > 0 ? seconds : nil
        if interval == nil { entries.removeAll() }
    }

    /// A re-report of the same ask keeps its timing; a new finish replaces the last one.
    mutating func track(_ kind: Kind, session: String, item: String, now: Date) {
        guard interval != nil else { return }
        let key = Key(session: session, item: item)
        if entries[key] != nil, kind != .completion { return }
        entries[key] = Entry(kind: kind, since: now, anchor: now)
    }

    mutating func cancel(session: String, item: String) {
        entries[Key(session: session, item: item)] = nil
    }

    /// Jumping to a session is looking at all of it.
    mutating func cancel(session: String) {
        entries = entries.filter { $0.key.session != session }
    }

    /// Drops whatever the agent has since moved past, by whoever answered it. `since` lets the
    /// owner ignore state older than the ask, which hooks can deliver out of order.
    mutating func keep(where alive: (Key, Kind, _ since: Date) -> Bool) {
        entries = entries.filter { alive($0.key, $0.value.kind, $0.value.since) }
    }

    /// Owed entries wait for the unlock, not the clock, so they set no time.
    var nextDue: Date? {
        guard let interval else { return nil }
        return entries.values.filter { !$0.owed }.map { $0.anchor.addingTimeInterval(interval) }.min()
    }

    /// Locked: due entries become owed. Looking: an ask waits another interval without spending
    /// an attempt, and a finish counts as seen. Unlocked again: owed nudges collapse into one.
    mutating func collect(now: Date, locked: Bool, looking: Bool) -> [Due] {
        guard let interval else { return [] }
        let order = entries.keys.sorted {
            let a = entries[$0]!, b = entries[$1]!
            if a.kind != b.kind { return a.kind < b.kind }
            return a.anchor != b.anchor ? a.anchor < b.anchor : $0.session < $1.session
        }
        var out: [Due] = []
        var caughtUp = false
        for key in order {
            guard var e = entries[key], e.owed || now >= e.anchor.addingTimeInterval(interval)
            else { continue }
            if locked { e.owed = true; entries[key] = e; continue }
            if looking {
                if e.kind == .completion { entries[key] = nil; continue }
                e.owed = false; e.anchor = now; entries[key] = e; continue
            }
            let catchUp = e.owed
            if catchUp && caughtUp { e.owed = false; e.anchor = now; entries[key] = e; continue }
            caughtUp = caughtUp || catchUp
            e.sent += 1; e.owed = false; e.anchor = now
            entries[key] = e.sent >= e.kind.cap ? nil : e
            out.append(Due(key: key, kind: e.kind, attempt: e.sent, catchUp: catchUp))
        }
        return out
    }
}
