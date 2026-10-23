package oracle

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode"

/*
	Automoderation is split into two independent checks:

	1. An offensive-word database (SQLite) loaded at startup.
	2. A rolling spam history kept in memory.

	Both normalizers collapse punctuation, leetspeak, and case so that
	variants like "Idiot!!!", "1d10t", and "idiot" are treated the same.
*/

MAX_SPAM_ENTRIES :: 20_000

Offensive_Phrase :: struct {
	padded  : string, // " phrase with spaces "
	display : string, // original word, used in logs
	severity: int,
}

Offensive_DB :: struct {
	path   : string,
	words  : map[string]int, // normalized single word -> severity
	phrases: [dynamic]Offensive_Phrase,
	loaded : bool,
	entries: int,
}

Spam_Entry :: struct {
	channel_id: string,
	message_id: string,
	text      : string,
	at        : time.Time,
}

Moderation_State :: struct {
	config   : ^Moderation_Config,
	offensive: Offensive_DB,
	spam     : [dynamic]Spam_Entry,
	// Diagnostics for the run summary.
	deleted_messages: int,
	timeouts        : int,
}

@(private = "file")
leet_char :: proc(r: rune) -> rune {
	switch r {
	case '0':
		return 'o'
	case '1', '|':
		return 'i'
	case '3':
		return 'e'
	case '4', '@':
		return 'a'
	case '5', '$':
		return 's'
	case '7':
		return 't'
	case '8':
		return 'b'
	}
	return r
}

/*
	Normalize text for matching. With keep_spaces = true the result is padded
	with one leading and one trailing space, which makes phrase matching a
	simple substring check with token boundaries. With keep_spaces = false
	all separators are removed, producing a compact form used for spam
	comparison.
*/
normalize_text :: proc(input: string, keep_spaces: bool, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)

	last_was_space := true // suppress leading separators
	for r in input {
		lowered := unicode.to_lower(leet_char(unicode.to_lower(r)))
		if unicode.is_letter(lowered) || unicode.is_digit(lowered) {
			strings.write_rune(&builder, lowered)
			last_was_space = false
		} else if keep_spaces && !last_was_space {
			strings.write_byte(&builder, ' ')
			last_was_space = true
		}
	}

	normalized := strings.to_string(builder)
	if keep_spaces {
		padded := fmt.aprintf(" %s ", strings.trim_space(normalized), allocator = allocator)
		strings.builder_destroy(&builder)
		return padded
	}
	return normalized
}

load_offensive_db :: proc(database: ^Offensive_DB, path: string) {
	database.path = path
	database.words = make(map[string]int)

	if !os.exists(path) {
		log_warn("moderation: %s does not exist; offensive-word filtering is disabled", path)
		log_warn("moderation: create it with `./oracle db init %s` and add words with `./oracle db import`", path)
		return
	}

	db, opened := db_open(path, true)
	if !opened {
		return
	}
	defer db_close(&db)

	statement, prepared := db_prepare(&db, "SELECT word, severity FROM offensive_words")
	if !prepared {
		log_warn("moderation: could not read offensive_words from %s; is this the right database?", path)
		return
	}
	defer finalize(statement)

	for {
		rc := step(statement)
		if rc == SQLITE_DONE {
			break
		}
		if rc != SQLITE_ROW {
			log_error("moderation: failed while reading %s: %s", path, db_error(&db))
			return
		}

		word_c := column_text(statement, 0)
		if word_c == nil {
			continue
		}
		word := string(word_c)
		if strings.trim_space(word) == "" {
			continue
		}
		severity := int(column_int(statement, 1))
		if severity < 1 {
			severity = 1
		}

		padded := normalize_text(word, true, context.temp_allocator)
		trimmed := strings.trim_space(padded)
		if trimmed == "" {
			continue
		}

		if strings.index_byte(trimmed, ' ') >= 0 {
			append(&database.phrases, Offensive_Phrase {
				padded = strings.clone(padded),
				display = strings.clone(word),
				severity = severity,
			})
		} else {
			key := strings.clone(trimmed)
			database.words[key] = severity
		}
		database.entries += 1
	}

	database.loaded = true
	log_info("moderation: loaded %d offensive entries from %s", database.entries, path)
}

unload_offensive_db :: proc(database: ^Offensive_DB) {
	for key in database.words {
		delete(key)
	}
	delete(database.words)
	database.words = nil
	for phrase in database.phrases {
		delete(phrase.padded)
		delete(phrase.display)
	}
	delete(database.phrases)
	database.phrases = nil
	database.loaded = false
}

/*
	Return the first offensive word or phrase found in text. The match is
	reported for logging; callers decide what action to take.
*/
find_offensive :: proc(database: ^Offensive_DB, text: string) -> (matched: string, severity: int, found: bool) {
	if !database.loaded {
		return "", 0, false
	}

	padded := normalize_text(text, true, context.temp_allocator)
	tokens := strings.fields(padded, context.temp_allocator)
	for token in tokens {
		if value, ok := database.words[token]; ok {
			return token, value, true
		}
	}

	for phrase in database.phrases {
		if strings.contains(padded, phrase.padded) {
			return phrase.display, phrase.severity, true
		}
	}
	return "", 0, false
}

moderation_init :: proc(state: ^Moderation_State, config: ^Moderation_Config) {
	state.config = config
	load_offensive_db(&state.offensive, config.database)
}

moderation_destroy :: proc(state: ^Moderation_State) {
	unload_offensive_db(&state.offensive)
	for &entry in state.spam {
		spam_entry_destroy(&entry)
	}
	delete(state.spam)
	state.spam = nil
}

@(private = "file")
spam_entry_destroy :: proc(entry: ^Spam_Entry) {
	delete(entry.channel_id)
	delete(entry.text)
	delete(entry.message_id)
	entry.channel_id = ""
	entry.text = ""
	entry.message_id = ""
}

@(private = "file")
prune_spam :: proc(state: ^Moderation_State, now: time.Time) {
	window := time.Duration(state.config.spam_window_seconds) * time.Second

	for len(state.spam) > 0 {
		entry := &state.spam[0]
		if time.diff(entry.at, now) <= window {
			break
		}
		spam_entry_destroy(entry)
		ordered_remove(&state.spam, 0)
	}

	for len(state.spam) > MAX_SPAM_ENTRIES {
		spam_entry_destroy(&state.spam[0])
		ordered_remove(&state.spam, 0)
	}
}

/*
	Records a message and reports whether this user has now sent the same
	normalized text at least `spam_threshold` times inside the window.
*/
check_spam :: proc(state: ^Moderation_State, channel_id, message_id, text: string, now: time.Time) -> bool {
	if state.config == nil || !state.config.enabled {
		return false
	}

	normalized := normalize_text(text, false, context.temp_allocator)
	if normalized == "" {
		return false
	}

	prune_spam(state, now)

	window := time.Duration(state.config.spam_window_seconds) * time.Second
	matches := 0
	for entry in state.spam {
		if entry.channel_id == channel_id && entry.text == normalized {
			if time.diff(entry.at, now) <= window {
				matches += 1
			}
		}
	}

	append(&state.spam, Spam_Entry {
		channel_id = strings.clone(channel_id),
		message_id = strings.clone(message_id),
		text = strings.clone(normalized),
		at = now,
	})

	if matches + 1 >= state.config.spam_threshold {
		purge_user_spam(state, channel_id)
		return true
	}
	return false
}

@(private = "file")
purge_user_spam :: proc(state: ^Moderation_State, channel_id: string) {
	index := 0
	for index < len(state.spam) {
		entry := &state.spam[index]
		if entry.channel_id == channel_id {
			spam_entry_destroy(entry)
			ordered_remove(&state.spam, index)
		} else {
			index += 1
		}
	}
}

/*
	Convenience wrapper used by tests and by the command line database tools.
	It inserts a word or phrase and returns a normalized description.
*/
describe_offensive_entry :: proc(value: string) -> string {
	padded := normalize_text(value, true, context.temp_allocator)
	return strings.trim_space(padded)
}
