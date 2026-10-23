package oracle

import "core:fmt"
import "core:strings"
import "core:time"

/*
	Commands are kept in a small registry so adding a new one is a matter of
	writing a handler and adding a row to `COMMANDS`.
*/

Command_Context :: struct {
	config: ^Config,
}

Command_Handler :: #type proc(ctx: ^Command_Context) -> string

Command :: struct {
	name       : string,
	description: string,
	handler    : Command_Handler,
}

command_github :: proc(ctx: ^Command_Context) -> string {
	return ctx.config.bot.github_url
}

command_twitter :: proc(ctx: ^Command_Context) -> string {
	return ctx.config.bot.twitter_url
}

command_help :: proc(ctx: ^Command_Context) -> string {
	prefix := ctx.config.bot.prefix
	return fmt.aprintf(
		"Oracle commands: %s github | %s twitter | %s help",
		prefix,
		prefix,
		prefix,
		allocator = context.temp_allocator,
	)
}

COMMANDS := []Command {
	{name = "github", description = "Share the GitHub profile", handler = command_github},
	{name = "twitter", description = "Share the Twitter profile", handler = command_twitter},
	{name = "help", description = "List the available commands", handler = command_help},
}

Parsed_Command :: struct {
	matched: bool,
	name   : string,
}

/*
	Parse a chat message. The prefix is matched case-insensitively and must be
	followed by whitespace or the end of the message, so `!oraclex` does not
	accidentally trigger the bot. A bare prefix is treated as `help`.
*/
parse_command :: proc(text, prefix: string) -> Parsed_Command {
	trimmed := strings.trim_space(text)
	if prefix == "" || len(trimmed) < len(prefix) {
		return {}
	}
	if !strings.equal_fold(trimmed[:len(prefix)], prefix) {
		return {}
	}
	if len(trimmed) > len(prefix) {
		next := trimmed[len(prefix)]
		if next != ' ' && next != '\t' && next != '\r' && next != '\n' {
			return {}
		}
	}

	rest := strings.trim_space(trimmed[len(prefix):])
	if rest == "" {
		return Parsed_Command{matched = true, name = "help"}
	}

	end := 0
	for end < len(rest) && rest[end] != ' ' && rest[end] != '\t' && rest[end] != '\r' && rest[end] != '\n' {
		end += 1
	}
	name := strings.to_lower(rest[:end], context.temp_allocator)
	return Parsed_Command{matched = true, name = name}
}

find_command :: proc(name: string) -> (command: Command, found: bool) {
	for candidate in COMMANDS {
		if strings.equal_fold(candidate.name, name) {
			return candidate, true
		}
	}
	return {}, false
}

dispatch_command :: proc(config: ^Config, name: string) -> (reply: string, found: bool) {
	command, ok := find_command(name)
	if !ok {
		return command_help(&Command_Context{config = config}), false
	}
	command_context := Command_Context{config = config}
	return command.handler(&command_context), true
}

/*
	Per-command cooldown. This keeps chat from being flooded when several
	viewers ask for the same link, and it protects the YouTube API quota.
*/
Command_Cooldowns :: struct {
	last: map[string]time.Time,
}

cooldowns_init :: proc(cooldowns: ^Command_Cooldowns) {
	cooldowns.last = make(map[string]time.Time)
}

cooldowns_destroy :: proc(cooldowns: ^Command_Cooldowns) {
	delete(cooldowns.last)
	cooldowns.last = nil
}

cooldowns_ready :: proc(cooldowns: ^Command_Cooldowns, name: string, seconds: int, now: time.Time) -> bool {
	if seconds <= 0 {
		return true
	}
	if last, ok := cooldowns.last[name]; ok {
		if time.diff(last, now) < time.Duration(seconds) * time.Second {
			return false
		}
	}
	cooldowns.last[name] = now
	return true
}

cooldowns_forget :: proc(cooldowns: ^Command_Cooldowns, name: string) {
	delete_key(&cooldowns.last, name)
}
