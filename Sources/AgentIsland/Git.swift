import Foundation

/// The checkout a session runs in: branch (or short sha when detached), whether it is a linked
/// worktree, and the main repo's directory, which is what "group by project" keys on.
struct GitInfo: Equatable {
    let branch: String
    let isWorktree: Bool
    let root: String

    /// Middle-truncated: `feat/` and the distinguishing tail both survive a long name.
    var chip: String {
        let b = branch.count > 24 ? branch.prefix(11) + "…" + branch.suffix(12) : branch
        return "⎇ " + b + (isWorktree ? " · wt" : "")
    }
}

/// Reads `.git` with FileManager only: a refresh must spawn nothing, and `git` per row per
/// cycle would be the app's largest cost. Cached per cwd until HEAD or a `gitdir:` file changes.
enum Git {
    /// HEAD, plus the `gitdir:` file when there is one. Never a `.git` directory: every
    /// `git status` touches its mtime, which would turn each refresh into a re-read.
    private struct Entry { var watched: [String]; var mtimes: [Date?]; var info: GitInfo? }
    private static var cache: [String: Entry] = [:]
    private static let lock = NSLock()

    static func retain(_ cwds: Set<String>) {
        lock.lock(); cache = cache.filter { cwds.contains($0.key) }; lock.unlock()
    }

    static func info(cwd: String) -> GitInfo? {
        lock.lock(); let hit = cache[cwd]; lock.unlock()
        if let hit, hit.watched.map(mtime) == hit.mtimes { return hit.info }
        guard let e = resolve(cwd) else {
            lock.lock(); cache[cwd] = nil; lock.unlock()
            return nil
        }
        lock.lock(); cache[cwd] = e; lock.unlock()
        return e.info
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Relative to the pointer file's own directory. Standardized because git writes /private/var
    /// where a cwd walk says /var, and the two must group as one project.
    private static func absolute(_ p: String, from dir: String) -> String {
        ((p.hasPrefix("/") ? p : (dir as NSString).appendingPathComponent(p)) as NSString).standardizingPath
    }

    private static func resolve(_ cwd: String) -> Entry? {
        let fm = FileManager.default
        var dir = (cwd as NSString).standardizingPath
        while true {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                var gitDir = dotGit, root = dir, isWorktree = false, watched: [String] = []
                if !isDir.boolValue {
                    watched.append(dotGit)
                    // Worktrees and submodules: `.git` is a file naming the real git dir.
                    guard let line = read(dotGit), line.hasPrefix("gitdir:") else { return nil }
                    gitDir = absolute(line.dropFirst(7).trimmingCharacters(in: .whitespaces), from: dir)
                    // Only a linked worktree has `commondir`; a submodule's gitdir does not.
                    if let common = read((gitDir as NSString).appendingPathComponent("commondir")) {
                        let c = absolute(common, from: gitDir)
                        isWorktree = true
                        root = (c as NSString).lastPathComponent == ".git"
                            ? (c as NSString).deletingLastPathComponent : c
                    }
                }
                let head = (gitDir as NSString).appendingPathComponent("HEAD")
                watched.append(head)
                return Entry(watched: watched, mtimes: watched.map(mtime),
                             info: read(head).flatMap(branch(fromHead:)).map {
                                 GitInfo(branch: $0, isWorktree: isWorktree, root: root) })
            }
            let up = (dir as NSString).deletingLastPathComponent
            if up == dir || up.isEmpty { return nil }
            dir = up
        }
    }

    /// Runs in first-seen order, so grouping keeps the list's own ordering within and across groups.
    static func grouped<T>(_ items: [T], by key: (T) -> String) -> [(key: String, items: [T])] {
        var order: [String] = [], byKey: [String: [T]] = [:]
        for i in items {
            let k = key(i)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(i)
        }
        return order.map { ($0, byKey[$0]!) }
    }

    /// HEAD names its branch symbolically, so packed refs never need reading; detached is a sha.
    static func branch(fromHead head: String) -> String? {
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
            return name.isEmpty ? nil : name
        }
        return head.count >= 7 && head.allSatisfy(\.isHexDigit) ? String(head.prefix(7)) : nil
    }
}
