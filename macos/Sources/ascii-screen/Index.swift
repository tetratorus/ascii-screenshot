import Foundation
import SQLite3

/// Search index over the history files, in `<dir>/index.sqlite`: one row per saved frame (its time and which
/// gzip member of which day file holds it) plus an FTS5 word index of the frame text. Text isn't stored
/// again (contentless, no word positions), so the index is about a quarter of the size of the history.
/// It is rebuilt from the day files whenever it falls behind, so the gzip files stay the source of truth.
final class HistoryIndex {
  private var db: OpaquePointer?
  let dir: URL

  init(dir: URL) throws {
    self.dir = dir
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard sqlite3_open(dir.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK else { throw error() }
    sqlite3_busy_timeout(db, 5000)
    try exec("""
      PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
      CREATE TABLE IF NOT EXISTS frames(id INTEGER PRIMARY KEY, time REAL NOT NULL, day TEXT NOT NULL,
                                        offset INTEGER NOT NULL, seq INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS frames_time ON frames(time);
      CREATE TABLE IF NOT EXISTS files(day TEXT PRIMARY KEY, indexed INTEGER NOT NULL);
      CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(text, content='', contentless_delete=1, detail=none);
      """)
  }

  deinit { sqlite3_close(db) }

  /// Index whatever has been appended to the day files since last time, and forget days whose file is gone.
  func catchUp() throws {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let days = Set(files.filter { $0.hasSuffix(".txt.gz") }.map { String($0.dropLast(7)) })
    let known = try query("SELECT day FROM files", []) { $0.text(0) }
    for day in known where !days.contains(day) { try drop(day) }
    for day in days.sorted() { try catchUp(day: day) }
  }

  func catchUp(day: String) throws {
    let url = dir.appendingPathComponent("\(day).txt.gz")
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
    try exec("BEGIN IMMEDIATE")
    do {
      var start = try query("SELECT indexed FROM files WHERE day = ?", [day]) { $0.int(0) }.first ?? 0
      if start > data.count { try drop(day); start = 0 } // file was replaced
      guard start < data.count else { try exec("COMMIT"); return }
      var members = GzipMembers(data: data, from: start)
      while let (offset, member) = members.next() {
        for (seq, (time, text)) in History.records(String(decoding: member, as: UTF8.self)).enumerated() {
          try run("INSERT INTO frames(time, day, offset, seq) VALUES (?, ?, ?, ?)",
                  [time.timeIntervalSince1970, day, offset, seq])
          try run("INSERT INTO words(rowid, text) VALUES (?, ?)",
                  [sqlite3_last_insert_rowid(db), text.replacingOccurrences(of: "\u{0332}", with: "")])
        }
      }
      try run("INSERT OR REPLACE INTO files(day, indexed) VALUES (?, ?)", [day, members.goodEnd])
      try exec("COMMIT")
    } catch { try? exec("ROLLBACK"); throw error }
  }

  func drop(_ day: String) throws {
    try run("DELETE FROM words WHERE rowid IN (SELECT id FROM frames WHERE day = ?)", [day])
    try run("DELETE FROM frames WHERE day = ?", [day])
    try run("DELETE FROM files WHERE day = ?", [day])
  }

  struct Location: Equatable { var time: Date; var day: String; var offset: Int; var seq: Int; var id = 0 }

  /// The gzip member holding the last frame saved at or before `time`.
  func locate(atOrBefore time: Date) throws -> Location? {
    try query("SELECT time, day, offset, seq, id FROM frames WHERE time <= ? ORDER BY time DESC LIMIT 1",
              [time.timeIntervalSince1970], Location.init).first
  }

  /// Frames between `from` and `to` containing every word of `words`, newest first.
  func candidates(_ words: [String], from: Date, to: Date, limit: Int, skip: Int) throws -> [Location] {
    let match = words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
    return try query("""
      SELECT f.time, f.day, f.offset, f.seq, f.id FROM words JOIN frames f ON f.id = words.rowid
      WHERE words MATCH ? AND f.time BETWEEN ? AND ? ORDER BY f.time DESC LIMIT ? OFFSET ?
      """, [match, from.timeIntervalSince1970, to.timeIntervalSince1970, limit, skip], Location.init)
  }

  // MARK: SQLite plumbing

  struct Row {
    let stmt: OpaquePointer?
    func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
  }

  private func error() -> NSError {
    NSError(domain: "ascii-screen", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "history index: " + String(cString: sqlite3_errmsg(db))])
  }

  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }

  private func run(_ sql: String, _ args: [Any]) throws { _ = try query(sql, args) { _ in () } }

  private func query<T>(_ sql: String, _ args: [Any], _ map: (Row) throws -> T) throws -> [T] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, a) in args.enumerated() {
      let n = Int32(i + 1)
      switch a {
      case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
      case let v as Int64: sqlite3_bind_int64(stmt, n, v)
      case let v as Double: sqlite3_bind_double(stmt, n, v)
      case let v as String: sqlite3_bind_text(stmt, n, v, -1, transient)
      default: fatalError("unsupported SQLite argument \(a)")
      }
    }
    var out: [T] = []
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_DONE { return out }
      guard rc == SQLITE_ROW else { throw error() }
      out.append(try map(Row(stmt: stmt)))
    }
  }
}

extension HistoryIndex.Location {
  init(_ r: HistoryIndex.Row) {
    self.init(time: Date(timeIntervalSince1970: r.double(0)), day: r.text(1), offset: r.int(2), seq: r.int(3), id: r.int(4))
  }
}
