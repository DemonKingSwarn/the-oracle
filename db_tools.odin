package oracle

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import c "core:c"

/*
	Command-line helpers for maintaining offensive.db. The bot only needs
	read access at runtime; these tools are for the streamer.
*/

OFFENSIVE_SCHEMA :: `
CREATE TABLE IF NOT EXISTS offensive_words (
	word     TEXT PRIMARY KEY COLLATE NOCASE,
	severity INTEGER NOT NULL DEFAULT 1 CHECK (severity >= 1),
	added_at TEXT NOT NULL DEFAULT (datetime('now'))
);
`

db_init_command :: proc(path: string) -> bool {
	db, opened := db_open(path, false)
	if !opened {
		return false
	}
	defer db_close(&db)

	if !db_exec(&db, OFFENSIVE_SCHEMA) {
		return false
	}
	log_info("db: initialized %s", path)
	return true
}

db_import_command :: proc(database_path, words_path: string) -> bool {
	data, read_err := os.read_entire_file(words_path, context.allocator)
	if read_err != nil {
		log_error("db: cannot read %q: %s", words_path, os.error_string(read_err))
		return false
	}
	defer delete(data)

	db, opened := db_open(database_path, false)
	if !opened {
		return false
	}
	defer db_close(&db)

	if !db_exec(&db, OFFENSIVE_SCHEMA) {
		return false
	}

	statement, prepared := db_prepare(&db, "INSERT OR IGNORE INTO offensive_words (word, severity) VALUES (?1, ?2)")
	if !prepared {
		return false
	}
	defer finalize(statement)

	if !db_exec(&db, "BEGIN;") {
		return false
	}
	committed := false
	defer if !committed {
		db_exec(&db, "ROLLBACK;")
	}

	lines := strings.split(string(data), "\n", context.temp_allocator)
	imported := 0
	seen := 0

	for line, index in lines {
		value := strings.trim_space(line)
		if value == "" || strings.has_prefix(value, "#") {
			continue
		}

		severity := 1
		word := value
		if separator := strings.index_byte(value, '|'); separator >= 0 {
			word = strings.trim_space(value[:separator])
			severity_text := strings.trim_space(value[separator + 1:])
			if parsed, ok := strconv.parse_int(severity_text); ok {
				severity = parsed
			} else {
				log_warn("db: %s:%d has an invalid severity; using 1", words_path, index + 1)
			}
		}

		if word == "" {
			continue
		}
		if severity < 1 {
			severity = 1
		}

		c_word := strings_clone_cstring(word)
		rc := bind_text(statement, 1, c_word, -1, SQLITE_TRANSIENT)
		if rc != SQLITE_OK {
			log_error("db: could not bind word at %s:%d", words_path, index + 1)
			return false
		}
		bind_int(statement, 2, c.int(severity))

		rc = step(statement)
		if rc != SQLITE_DONE {
			log_error("db: insert failed at %s:%d: %s", words_path, index + 1, db_error(&db))
			return false
		}
		if changes(db.handle) > 0 {
			imported += 1
		}
		seen += 1

		reset(statement)
		clear_bindings(statement)
	}

	if !db_exec(&db, "COMMIT;") {
		return false
	}
	committed = true

	log_info("db: processed %d entries from %s into %s (%d new)", seen, words_path, database_path, imported)
	return true
}

/*
	Verify that the offensive database exists, has the expected table, and is
	readable. Used by `oracle check`.
*/
db_check_command :: proc(path: string) -> bool {
	if !os.exists(path) {
		log_error("db: %s does not exist; run `./oracle db init %s`", path, path)
		return false
	}
	db, opened := db_open(path, true)
	if !opened {
		return false
	}
	defer db_close(&db)

	statement, prepared := db_prepare(&db, "SELECT COUNT(*) FROM offensive_words")
	if !prepared {
		log_error("db: %s does not contain an offensive_words table", path)
		return false
	}
	defer finalize(statement)

	if step(statement) != SQLITE_ROW {
		log_error("db: could not count entries in %s: %s", path, db_error(&db))
		return false
	}
	count := int(column_int(statement, 0))
	log_info("db: %s is readable (%d offensive entries)", path, count)
	return true
}

db_list_command :: proc(path: string) -> bool {
	db, opened := db_open(path, true)
	if !opened {
		return false
	}
	defer db_close(&db)

	statement, prepared := db_prepare(&db, "SELECT word, severity FROM offensive_words ORDER BY word COLLATE NOCASE")
	if !prepared {
		log_error("db: could not read %s; run `./oracle db init %s` first", path, path)
		return false
	}
	defer finalize(statement)

	count := 0
	for step(statement) == SQLITE_ROW {
		word_c := column_text(statement, 0)
		word := ""
		if word_c != nil {
			word = string(word_c)
		}
		fmt.printf("%d\t%s\n", int(column_int(statement, 1)), word)
		count += 1
	}

	log_info("db: %d entries in %s", count, path)
	return true
}
