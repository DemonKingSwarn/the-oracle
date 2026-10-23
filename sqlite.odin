package oracle

/*
	Minimal SQLite3 bindings used by The Oracle.

	Only the handful of entry points needed to read the offensive-word
	database and to create/import it are declared here. Keeping the binding
	local means the project only needs the system `libsqlite3` (which is what
	most distributions ship) instead of an extra vendor package.
*/

import "core:c"

foreign import sqlite_lib "system:sqlite3"

sqlite3 :: struct {}
sqlite3_stmt :: struct {}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101

SQLITE_OPEN_READONLY :: 0x00000001
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004

/*
	SQLite has no special destructor value other than the sentinel -1 which
	means "make a private copy of the text". We bind with this so the caller
	can free its own buffers immediately after a step.
*/
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign sqlite_lib {
	open_v2 :: proc(filename: cstring, ppDb: ^^sqlite3, flags: c.int, zVfs: cstring) -> c.int ---
	close :: proc(db: ^sqlite3) -> c.int ---
	errmsg :: proc(db: ^sqlite3) -> cstring ---
	exec :: proc(db: ^sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	busy_timeout :: proc(db: ^sqlite3, ms: c.int) -> c.int ---
	prepare_v2 :: proc(db: ^sqlite3, zSql: cstring, nByte: c.int, ppStmt: ^^sqlite3_stmt, pzTail: ^cstring) -> c.int ---
	step :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	finalize :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	reset :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	clear_bindings :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	bind_text :: proc(stmt: ^sqlite3_stmt, index: c.int, text: cstring, length: c.int, destructor: rawptr) -> c.int ---
	bind_int :: proc(stmt: ^sqlite3_stmt, index: c.int, value: c.int) -> c.int ---
	column_text :: proc(stmt: ^sqlite3_stmt, column: c.int) -> cstring ---
	column_int :: proc(stmt: ^sqlite3_stmt, column: c.int) -> c.int ---
	column_count :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	column_name :: proc(stmt: ^sqlite3_stmt, column: c.int) -> cstring ---
	changes :: proc(db: ^sqlite3) -> c.int ---
	free :: proc(pointer: rawptr) ---
}

DB :: struct {
	handle: ^sqlite3,
	path:   string,
}

db_open :: proc(path: string, read_only: bool) -> (db: DB, ok: bool) {
	flags := c.int(SQLITE_OPEN_READONLY)
	if !read_only {
		flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
	}

	cpath := strings_clone_cstring(path)
	if cpath == nil {
		log_error("sqlite: unable to allocate database path")
		return
	}

	handle: ^sqlite3
	rc := open_v2(cpath, &handle, flags, nil)
	if rc != SQLITE_OK {
		msg := "unknown error"
		if handle != nil {
			msg = string(errmsg(handle))
			close(handle)
		}
		log_error("sqlite: cannot open %q: %s", path, msg)
		return
	}

	db = DB{handle = handle, path = path}
	db_exec(&db, "PRAGMA busy_timeout = 5000;")
	return db, true
}

db_close :: proc(db: ^DB) {
	if db.handle != nil {
		close(db.handle)
		db.handle = nil
	}
}

db_error :: proc(db: ^DB) -> string {
	if db == nil || db.handle == nil {
		return "database is not open"
	}
	msg := errmsg(db.handle)
	if msg == nil {
		return "unknown sqlite error"
	}
	return string(msg)
}

db_exec :: proc(db: ^DB, sql: string) -> bool {
	if db == nil || db.handle == nil {
		return false
	}
	csql := strings_clone_cstring(sql)
	if csql == nil {
		return false
	}

	errbuf: cstring
	rc := exec(db.handle, csql, nil, nil, &errbuf)
	if rc != SQLITE_OK {
		msg := "unknown error"
		if errbuf != nil {
			msg = string(errbuf)
			free(rawptr(errbuf))
		} else {
			msg = db_error(db)
		}
		log_error("sqlite: failed to execute statement: %s", msg)
		return false
	}
	return true
}

db_prepare :: proc(db: ^DB, sql: string) -> (stmt: ^sqlite3_stmt, ok: bool) {
	if db == nil || db.handle == nil {
		return nil, false
	}
	csql := strings_clone_cstring(sql)
	if csql == nil {
		return nil, false
	}

	rc := prepare_v2(db.handle, csql, -1, &stmt, nil)
	if rc != SQLITE_OK {
		log_error("sqlite: cannot prepare statement: %s", db_error(db))
		return nil, false
	}
	return stmt, true
}
