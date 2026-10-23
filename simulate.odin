package oracle

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strings"

/*
	`oracle simulate` is a development aid: it feeds messages through the same
	moderation and command logic as the real bot, but every outbound action is
	printed instead of being sent to YouTube.

	Input lines are either a plain message or "author|message".
*/

simulate_command :: proc(options: CLI_Options) -> int {
	config := default_config()
	config_path := options.config
	if os.exists(config_path) {
		loaded := load_config(config_path)
		if !loaded.ok {
			return 1
		}
		config = loaded.config
	} else {
		log_warn("simulate: %s not found; using built-in defaults and ./%s", config_path, DEFAULT_DATABASE)
	}
	config.bot.dry_run = true

	bot: Bot
	bot.config = &config
	moderation_init(&bot.moderation, &config.moderation)
	cooldowns_init(&bot.cooldowns)
	defer bot_destroy(&bot)

	log_info("simulate: type messages, use author|message to change the author, Ctrl-D to quit")
	log_info("simulate: try `!oracle github`, an offensive word, or the same message ten times")

	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&scanner)

	message_number := 0
	for bufio.scan(&scanner) {
		free_all(context.temp_allocator)
		line := strings.trim_space(bufio.scanner_text(&scanner))
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}

		author := "viewer"
		text := line
		if separator := strings.index_byte(line, '|'); separator >= 0 {
			author = strings.trim_space(line[:separator])
			text = strings.trim_space(line[separator + 1:])
		}
		if author == "" {
			author = "viewer"
		}
		if text == "" {
			continue
		}

		message_number += 1
		message := Live_Chat_Message {
			id = fmt.aprintf("sim-%d", message_number),
			snippet = Message_Snippet {
				type = "textMessageEvent",
				textMessageDetails = Text_Message_Details {messageText = text},
			},
			authorDetails = Author_Details {
				channelId = author,
				displayName = author,
			},
		}

		fmt.printf("[%s] %s\n", author, text)
		process_message(&bot, &message)
	}

	log_info("simulate: deleted messages: %d, timeouts: %d", bot.moderation.deleted_messages, bot.moderation.timeouts)
	return 0
}
