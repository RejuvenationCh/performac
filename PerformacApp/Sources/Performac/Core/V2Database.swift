// Core/V2Database.swift — v2 works on its own copy of v1's database.
//
// plan-v2 step 5 correction (user's instruction): never open v1's performac.db
// directly — v1's launchd agent is live and writing to it, and two samplers on one
// SQLite file means contention and duplicate rows. On first run, the database is
// copied to ~/Library/Application Support/com.chris.performac.v2/performac.db;
// history carries over, the two apps diverge cleanly, and v1 stays untouched as
// the fallback. The copy uses SQLite's online backup API so WAL content is included
// and v1's file is only ever opened read-only.
import SQLite3
import Foundation

let V2_SUPPORT_DIR = NSHomeDirectory() + "/Library/Application Support/com.chris.performac.v2"

func v2DatabasePath() -> String {
    V2_SUPPORT_DIR + "/performac.db"
}

/// Copy v1's database to the v2 location on first run. Returns the v2 path.
/// v1's file is opened read-only; nothing is ever written to it.
func copyV1DatabaseIfNeeded(v1Path: String) -> String {
    let dest = v2DatabasePath()
    let fm = FileManager.default
    if !fm.fileExists(atPath: dest) {
        try? fm.createDirectory(atPath: V2_SUPPORT_DIR, withIntermediateDirectories: true)
        if !sqliteBackup(from: v1Path, to: dest) {
            // plain file copy fallback (no WAL checkpoint — best effort)
            try? fm.copyItem(atPath: v1Path, toPath: dest)
        }
    }
    return dest
}

/// sqlite3 online backup: consistent snapshot including WAL contents, source read-only.
private func sqliteBackup(from src: String, to dest: String) -> Bool {
    var srcHandle: OpaquePointer?
    var dstHandle: OpaquePointer?
    guard sqlite3_open_v2(src, &srcHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let srcHandle,
          sqlite3_open(dest, &dstHandle) == SQLITE_OK, let dstHandle
    else {
        if let srcHandle { sqlite3_close(srcHandle) }
        if let dstHandle { sqlite3_close(dstHandle) }
        return false
    }
    defer {
        sqlite3_close(srcHandle)
        sqlite3_close(dstHandle)
    }
    guard let backup = sqlite3_backup_init(dstHandle, "main", srcHandle, "main") else { return false }
    var rc = sqlite3_backup_step(backup, -1)
    if rc == SQLITE_DONE || rc == SQLITE_OK { rc = sqlite3_backup_finish(backup) } else { sqlite3_backup_finish(backup) }
    return rc == SQLITE_OK
}
