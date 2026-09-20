import Foundation

/// Whether a path in a shared directory is really ours.
///
/// Everything the island exchanges with its hooks lives in /tmp, which every account on the
/// machine can write to. Creating a directory there says nothing: if somebody else got there
/// first it is theirs, `chmod` quietly fails, and what we then read out of it is their text —
/// which for approvals and queued input is a decision the user never made.
enum TmpDir {
    static func ours(_ path: String) -> Bool {
        var st = stat()
        // lstat, not stat: a symlink pointing somewhere we do own would otherwise pass.
        guard lstat(path, &st) == 0 else { return false }
        return st.st_uid == geteuid() && (st.st_mode & S_IFMT) != S_IFLNK
    }
}
