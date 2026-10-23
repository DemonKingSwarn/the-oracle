package oracle

import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_normalize_text :: proc(t: ^testing.T) {
	testing.expect_value(t, normalize_text("H3LL0!!!", false, context.temp_allocator), "hello")
	testing.expect_value(t, normalize_text("1d10t", false, context.temp_allocator), "idiot")
	testing.expect_value(t, normalize_text("You  are\tan IDIOT!!", true, context.temp_allocator), " you are an idiot ")
	testing.expect_value(t, normalize_text("   ", true, context.temp_allocator), "  ")
	testing.expect_value(t, normalize_text("", false, context.temp_allocator), "")
}

@(test)
test_parse_command :: proc(t: ^testing.T) {
	parsed := parse_command("!oracle github", "!oracle")
	testing.expect(t, parsed.matched)
	testing.expect_value(t, parsed.name, "github")

	parsed = parse_command("  !ORACLE   TWITTER ", "!oracle")
	testing.expect(t, parsed.matched)
	testing.expect_value(t, parsed.name, "twitter")

	parsed = parse_command("!oracle", "!oracle")
	testing.expect(t, parsed.matched)
	testing.expect_value(t, parsed.name, "help")

	parsed = parse_command("!oraclex github", "!oracle")
	testing.expect(t, !parsed.matched)

	parsed = parse_command("hello !oracle github", "!oracle")
	testing.expect(t, !parsed.matched)
}

@(test)
test_url_helpers :: proc(t: ^testing.T) {
	encoded := url_encode("a b/c?d=e&f", context.temp_allocator)
	testing.expect_value(t, encoded, "a%20b%2Fc%3Fd%3De%26f")
	testing.expect_value(t, url_decode(encoded, context.temp_allocator), "a b/c?d=e&f")

	url := "http://localhost/?state=abc&code=4%2F0AbC%2Fdef&scope=x"
	testing.expect_value(t, query_param(url, "code"), "4/0AbC/def")
	testing.expect_value(t, query_param(url, "missing"), "")
}

@(test)
test_offensive_matching :: proc(t: ^testing.T) {
	database := Offensive_DB {
		words = make(map[string]int),
		loaded = true,
	}
	defer unload_offensive_db(&database)

	database.words[strings.clone("idiot")] = 1
	append(&database.phrases, Offensive_Phrase {
		padded = strings.clone(" bad phrase "),
		display = strings.clone("bad phrase"),
		severity = 2,
	})

	if matched, severity, found := find_offensive(&database, "you IDIOT"); found {
		testing.expect_value(t, matched, "idiot")
		testing.expect_value(t, severity, 1)
	} else {
		testing.expect(t, false, "expected `idiot` to match")
	}

	if matched, severity, found := find_offensive(&database, "that was a b4d phr4se"); found {
		testing.expect_value(t, matched, "bad phrase")
		testing.expect_value(t, severity, 2)
	} else {
		testing.expect(t, false, "expected the phrase to match")
	}

	_, _, found := find_offensive(&database, "idiotic")
	testing.expect(t, !found, "substrings inside a larger word must not match")
}

@(test)
test_spam_threshold :: proc(t: ^testing.T) {
	config := Moderation_Config {
		enabled = true,
		spam_threshold = 10,
		spam_window_seconds = 120,
	}
	state := Moderation_State{config = &config}
	defer moderation_destroy(&state)

	start := time.now()
	for index in 0 ..< 9 {
		spam := check_spam(&state, "user-1", "msg", "same message!!", time.time_add(start, time.Duration(index) * time.Second))
		testing.expect(t, !spam, "the first nine messages must not trigger a timeout")
	}
	spam := check_spam(&state, "user-1", "msg", "SAME   message", time.time_add(start, time.Duration(9) * time.Second))
	testing.expect(t, spam, "the tenth identical message must trigger a timeout")
}

@(test)
test_spam_window_expiry :: proc(t: ^testing.T) {
	config := Moderation_Config {
		enabled = true,
		spam_threshold = 3,
		spam_window_seconds = 10,
	}
	state := Moderation_State{config = &config}
	defer moderation_destroy(&state)

	start := time.now()
	testing.expect(t, !check_spam(&state, "user-1", "a", "hello", start))
	testing.expect(t, !check_spam(&state, "user-1", "b", "hello", time.time_add(start, time.Duration(1) * time.Second)))
	testing.expect(t, !check_spam(&state, "user-1", "c", "hello", time.time_add(start, time.Duration(30) * time.Second)))
	testing.expect(t, !check_spam(&state, "user-1", "d", "hello", time.time_add(start, time.Duration(31) * time.Second)))
	testing.expect(t, check_spam(&state, "user-1", "e", "hello", time.time_add(start, time.Duration(32) * time.Second)))
}

@(test)
test_spam_is_per_user :: proc(t: ^testing.T) {
	config := Moderation_Config {
		enabled = true,
		spam_threshold = 3,
		spam_window_seconds = 120,
	}
	state := Moderation_State{config = &config}
	defer moderation_destroy(&state)

	now := time.now()
	testing.expect(t, !check_spam(&state, "user-1", "a", "hello", now))
	testing.expect(t, !check_spam(&state, "user-2", "b", "hello", now))
	testing.expect(t, !check_spam(&state, "user-3", "c", "hello", now))
}

@(test)
test_command_registry :: proc(t: ^testing.T) {
	config := default_config()
	reply, found := dispatch_command(&config, "github")
	testing.expect(t, found)
	testing.expect_value(t, reply, DEFAULT_GITHUB_URL)

	reply, found = dispatch_command(&config, "twitter")
	testing.expect(t, found)
	testing.expect_value(t, reply, DEFAULT_TWITTER_URL)

	reply, found = dispatch_command(&config, "nope")
	testing.expect(t, !found)
	testing.expect(t, strings.contains(reply, "github"))
}

@(test)
test_command_cooldown :: proc(t: ^testing.T) {
	cooldowns: Command_Cooldowns
	cooldowns_init(&cooldowns)
	defer cooldowns_destroy(&cooldowns)

	start := time.now()
	testing.expect(t, cooldowns_ready(&cooldowns, "github", 10, start))
	testing.expect(t, !cooldowns_ready(&cooldowns, "github", 10, time.time_add(start, time.Duration(5) * time.Second)))
	testing.expect(t, cooldowns_ready(&cooldowns, "github", 10, time.time_add(start, time.Duration(11) * time.Second)))
}
