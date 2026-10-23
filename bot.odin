package oracle

import "core:strings"
import "core:time"

Bot :: struct {
	config             : ^Config,
	client             : YouTube_Client,
	moderation         : Moderation_State,
	cooldowns          : Command_Cooldowns,
	chat_id            : string,
	page_token         : string,
	consecutive_failures: int,
	discovery_notice_at: time.Time,
	skip_next_batch    : bool,
}

bot_init :: proc(bot: ^Bot, config: ^Config) -> bool {
	bot.config = config
	youtube_client_init(&bot.client, config)
	moderation_init(&bot.moderation, &config.moderation)
	cooldowns_init(&bot.cooldowns)

	if bot.client.has_oauth && bot.client.bot_channel_id == "" {
		log_warn("youtube: could not determine the bot's channel id; replies are not checked against it")
	} else if bot.client.bot_channel_id != "" {
		log_info("youtube: bot channel id is %s", bot.client.bot_channel_id)
	}

	return true
}

bot_destroy :: proc(bot: ^Bot) {
	youtube_client_destroy(&bot.client)
	moderation_destroy(&bot.moderation)
	cooldowns_destroy(&bot.cooldowns)
	delete(bot.chat_id)
	delete(bot.page_token)
	bot.chat_id = ""
	bot.page_token = ""
}

bot_send_reply :: proc(bot: ^Bot, text: string) -> bool {
	if text == "" {
		return false
	}
	if bot.config.bot.dry_run {
		log_info("[dry-run] would send: %s", text)
		return true
	}

	message_id, ok := send_chat_message(&bot.client, bot.chat_id, text)
	if ok {
		delete(message_id)
	}
	return ok
}

bot_delete_message :: proc(bot: ^Bot, message_id: string, author: string) {
	if bot.config.bot.dry_run {
		log_info("[dry-run] would delete message %s from %s", message_id, author)
		bot.moderation.deleted_messages += 1
		return
	}
	if delete_chat_message(&bot.client, message_id) {
		bot.moderation.deleted_messages += 1
		log_info("moderation: deleted message %s from %s", message_id, author)
	}
}

bot_timeout_user :: proc(bot: ^Bot, channel_id, author: string) {
	seconds := bot.config.moderation.timeout_seconds
	if bot.config.bot.dry_run {
		log_info("[dry-run] would time out %s (%s) for %ds", author, channel_id, seconds)
		bot.moderation.timeouts += 1
		return
	}
	if timeout_chat_user(&bot.client, bot.chat_id, channel_id, seconds) {
		bot.moderation.timeouts += 1
		log_info("moderation: timed out %s (%s) for %ds", author, channel_id, seconds)
	}
}

process_message :: proc(bot: ^Bot, message: ^Live_Chat_Message) {
	if message.snippet.type != "textMessageEvent" {
		return
	}

	text := message.snippet.textMessageDetails.messageText
	if text == "" {
		text = message.snippet.displayMessage
	}
	if text == "" {
		return
	}

	author := message.authorDetails
	if bot.client.bot_channel_id != "" && author.channelId == bot.client.bot_channel_id {
		return
	}

	if bot.config.moderation.enabled {
		exempt := bot.config.moderation.exempt_moderators &&
		          (author.isChatOwner || author.isChatModerator)
		if !exempt {
			if matched, _, found := find_offensive(&bot.moderation.offensive, text); found {
				log_warn("moderation: offensive content from %s: %q (matched %q)",
					author.displayName, text, matched)
				if bot.config.moderation.delete_offensive {
					bot_delete_message(bot, message.id, author.displayName)
				}
				return
			}

			if check_spam(&bot.moderation, author.channelId, message.id, text, time.now()) {
				log_warn("moderation: spam from %s: %d identical messages", author.displayName, bot.config.moderation.spam_threshold)
				bot_timeout_user(bot, author.channelId, author.displayName)
				return
			}
		}
	}

	parsed := parse_command(text, bot.config.bot.prefix)
	if !parsed.matched {
		return
	}

	command, found := find_command(parsed.name)
	if !found {
		return
	}

	if !cooldowns_ready(&bot.cooldowns, command.name, bot.config.bot.reply_cooldown_seconds, time.now()) {
		return
	}

	reply, _ := dispatch_command(bot.config, command.name)
	if reply == "" {
		return
	}

	log_info("command: %s used by %s", command.name, author.displayName)
	if !bot_send_reply(bot, reply) {
		// Let the next identical command retry instead of waiting out the
		// cooldown after a failed send.
		cooldowns_forget(&bot.cooldowns, command.name)
	}
}

bot_loop :: proc(bot: ^Bot) {
	config := bot.config

	for {
		free_all(context.temp_allocator)

		if bot.chat_id == "" {
			bot.chat_id = resolve_live_chat_id(&bot.client)
			if bot.chat_id == "" {
				if time.since(bot.discovery_notice_at) > 5 * time.Minute {
					log_info("youtube: waiting for a live chat (checking again every %ds)", config.poll.idle_seconds)
					bot.discovery_notice_at = time.now()
				}
				time.sleep(time.Duration(config.poll.idle_seconds) * time.Second)
				continue
			}

			log_info("youtube: connected to live chat %s", bot.chat_id)
			delete(bot.page_token)
			bot.page_token = ""
			bot.consecutive_failures = 0
			bot.skip_next_batch = true
		}

		page, ok := list_live_chat_messages(&bot.client, bot.chat_id, bot.page_token)
		if !ok {
			switch page.error_reason {
			case "liveChatEnded", "liveChatNotFound":
				log_info("youtube: live chat ended (%s); looking for a new chat", page.error_reason)
				delete(bot.chat_id)
				bot.chat_id = ""
				delete(bot.page_token)
				bot.page_token = ""
				time.sleep(time.Duration(config.poll.idle_seconds) * time.Second)
				continue
			case "quotaExceeded", "dailyLimitExceeded":
				log_error("youtube: daily API quota exhausted; backing off for %ds", config.poll.max_backoff_seconds)
				time.sleep(time.Duration(config.poll.max_backoff_seconds) * time.Second)
				continue
			}

			bot.consecutive_failures += 1
			backoff := config.poll.idle_seconds
			for _ in 0 ..< bot.consecutive_failures {
				if backoff >= config.poll.max_backoff_seconds {
					break
				}
				backoff *= 2
			}
			backoff = clamp_int(backoff, config.poll.idle_seconds, config.poll.max_backoff_seconds)
			log_warn("youtube: polling failed; retrying in %ds", backoff)
			time.sleep(time.Duration(backoff) * time.Second)
			continue
		}

		bot.consecutive_failures = 0

		if bot.skip_next_batch {
			// The first response contains holdover messages from before the
			// bot connected. Do not reply to old commands or moderate the
			// backlog; start from the next page token instead.
			log_info("youtube: ignoring %d message(s) from before startup", len(page.items))
			bot.skip_next_batch = false
		} else {
			for &message in page.items {
				process_message(bot, &message)
			}
		}

		if page.next_page_token != "" {
			if page.next_page_token != bot.page_token {
				delete(bot.page_token)
				bot.page_token = strings.clone(page.next_page_token)
			}
		} else {
			delete(bot.page_token)
			bot.page_token = ""
		}

		if page.offline_at != "" {
			log_info("youtube: chat ended at %s; waiting for the next live stream", page.offline_at)
			delete(bot.chat_id)
			bot.chat_id = ""
			delete(bot.page_token)
			bot.page_token = ""
			time.sleep(time.Duration(config.poll.idle_seconds) * time.Second)
			continue
		}

		interval := config.poll.min_interval_ms
		if page.polling_interval_ms > interval {
			interval = page.polling_interval_ms
		}
		interval = clamp_int(interval, 1000, 30_000)
		time.sleep(time.Duration(interval) * time.Millisecond)
	}
}

run_bot :: proc(config: ^Config, config_path: string) -> bool {
	if !validate_config(config) {
		return false
	}

	log_config_summary(config, config_path)

	bot: Bot
	bot_init(&bot, config)
	defer bot_destroy(&bot)

	if !config.bot.dry_run && !bot.client.has_oauth {
		log_error("youtube: OAuth credentials are required to run the bot")
		return false
	}

	bot_loop(&bot)
	return true
}
