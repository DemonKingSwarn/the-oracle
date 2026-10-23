package oracle

import "core:encoding/json"
import "core:os"
import "core:path/filepath"

DEFAULT_CONFIG_PATH :: "config.json"
DEFAULT_PREFIX :: "!oracle"
DEFAULT_DATABASE :: "offensive.db"
DEFAULT_GITHUB_URL :: "https://swarn.space/github"
DEFAULT_TWITTER_URL :: "https://swarn.space/twitter"

Config :: struct {
	youtube:    YouTube_Config    `json:"youtube"`,
	bot:        Bot_Config        `json:"bot"`,
	moderation: Moderation_Config `json:"moderation"`,
	poll:       Poll_Config       `json:"poll"`,
}

YouTube_Config :: struct {
	api_key       : string `json:"api_key"`,
	client_id     : string `json:"client_id"`,
	client_secret : string `json:"client_secret"`,
	refresh_token : string `json:"refresh_token"`,
	live_chat_id  : string `json:"live_chat_id"`,
	video_id      : string `json:"video_id"`,
	channel_id    : string `json:"channel_id"`,
	bot_channel_id: string `json:"bot_channel_id"`,
}

Bot_Config :: struct {
	prefix                : string `json:"prefix"`,
	dry_run               : bool   `json:"dry_run"`,
	reply_cooldown_seconds: int    `json:"reply_cooldown_seconds"`,
	github_url            : string `json:"github_url"`,
	twitter_url           : string `json:"twitter_url"`,
}

Moderation_Config :: struct {
	enabled             : bool   `json:"enabled"`,
	database            : string `json:"database"`,
	delete_offensive    : bool   `json:"delete_offensive"`,
	spam_threshold      : int    `json:"spam_threshold"`,
	spam_window_seconds : int    `json:"spam_window_seconds"`,
	timeout_seconds     : int    `json:"timeout_seconds"`,
	exempt_moderators   : bool   `json:"exempt_moderators"`,
}

Poll_Config :: struct {
	idle_seconds       : int `json:"idle_seconds"`,
	max_backoff_seconds: int `json:"max_backoff_seconds"`,
	min_interval_ms    : int `json:"min_interval_ms"`,
}

Config_Load_Result :: struct {
	config: Config,
	path:   string,
	ok:     bool,
}

default_config :: proc() -> Config {
	return Config {
		youtube = YouTube_Config {
			live_chat_id = "",
			video_id = "",
			channel_id = "",
		},
		bot = Bot_Config {
			prefix = DEFAULT_PREFIX,
			dry_run = false,
			reply_cooldown_seconds = 10,
			github_url = DEFAULT_GITHUB_URL,
			twitter_url = DEFAULT_TWITTER_URL,
		},
		moderation = Moderation_Config {
			enabled = true,
			database = DEFAULT_DATABASE,
			delete_offensive = true,
			spam_threshold = 10,
			spam_window_seconds = 120,
			timeout_seconds = 600,
			exempt_moderators = true,
		},
		poll = Poll_Config {
			idle_seconds = 60,
			max_backoff_seconds = 300,
			min_interval_ms = 10_000,
		},
	}
}

apply_env_overrides :: proc(config: ^Config) {
	if value := os.get_env("YOUTUBE_API_KEY", context.allocator); value != "" {
		config.youtube.api_key = value
	}
	if value := os.get_env("YOUTUBE_CLIENT_ID", context.allocator); value != "" {
		config.youtube.client_id = value
	}
	if value := os.get_env("YOUTUBE_CLIENT_SECRET", context.allocator); value != "" {
		config.youtube.client_secret = value
	}
	if value := os.get_env("YOUTUBE_REFRESH_TOKEN", context.allocator); value != "" {
		config.youtube.refresh_token = value
	}
	if value := os.get_env("YOUTUBE_LIVE_CHAT_ID", context.allocator); value != "" {
		config.youtube.live_chat_id = value
	}
	if value := os.get_env("YOUTUBE_VIDEO_ID", context.allocator); value != "" {
		config.youtube.video_id = value
	}
	if value := os.get_env("YOUTUBE_CHANNEL_ID", context.allocator); value != "" {
		config.youtube.channel_id = value
	}
	if value := os.get_env("YOUTUBE_BOT_CHANNEL_ID", context.allocator); value != "" {
		config.youtube.bot_channel_id = value
	}
	if value := os.get_env("ORACLE_OFFENSIVE_DB", context.allocator); value != "" {
		config.moderation.database = value
	}
}

load_config :: proc(path: string) -> (result: Config_Load_Result) {
	result.path = path
	result.config = default_config()

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log_error("config: cannot read %q: %s", path, os.error_string(err))
		return
	}
	defer delete(data)

	if json_err := json.unmarshal(data, &result.config); json_err != nil {
		log_error("config: cannot parse %q: %v", path, json_err)
		return
	}

	apply_env_overrides(&result.config)
	result.config.moderation.database = resolve_relative(path, result.config.moderation.database)

	if result.config.bot.prefix == "" {
		result.config.bot.prefix = DEFAULT_PREFIX
	}
	if result.config.bot.reply_cooldown_seconds < 0 {
		result.config.bot.reply_cooldown_seconds = 0
	}
	if result.config.moderation.spam_threshold < 2 {
		result.config.moderation.spam_threshold = 10
	}
	if result.config.moderation.spam_window_seconds < 1 {
		result.config.moderation.spam_window_seconds = 120
	}
	if result.config.moderation.timeout_seconds < 1 {
		result.config.moderation.timeout_seconds = 600
	}
	if result.config.poll.idle_seconds < 1 {
		result.config.poll.idle_seconds = 60
	}
	if result.config.poll.max_backoff_seconds < 1 {
		result.config.poll.max_backoff_seconds = 300
	}
	if result.config.poll.min_interval_ms < 1000 {
		result.config.poll.min_interval_ms = 10_000
	}
	if result.config.bot.github_url == "" {
		result.config.bot.github_url = DEFAULT_GITHUB_URL
	}
	if result.config.bot.twitter_url == "" {
		result.config.bot.twitter_url = DEFAULT_TWITTER_URL
	}

	result.ok = true
	return
}

resolve_relative :: proc(config_path, target: string) -> string {
	if target == "" || filepath.is_abs(target) {
		return target
	}
	directory := filepath.dir(config_path)
	if directory == "" || directory == "." {
		return target
	}
	joined, err := filepath.join({directory, target}, context.allocator)
	if err != nil {
		return target
	}
	return joined
}

validate_config :: proc(config: ^Config) -> bool {
	ok := true

	if config.youtube.api_key == "" {
		log_error("config: youtube.api_key is required")
		ok = false
	}

	if config.youtube.live_chat_id == "" && config.youtube.video_id == "" && config.youtube.channel_id == "" {
		log_error("config: set youtube.live_chat_id, youtube.video_id, or youtube.channel_id so the bot can find the chat")
		ok = false
	}

	if !config.bot.dry_run && !has_oauth(config) {
		log_error("config: youtube.client_id, youtube.client_secret, and youtube.refresh_token are required unless bot.dry_run is true")
		log_error("config: run `./oracle auth` to create a refresh token")
		ok = false
	}

	if config.moderation.enabled {
		if config.moderation.spam_threshold < 2 {
			log_error("config: moderation.spam_threshold must be at least 2")
			ok = false
		}
	}

	return ok
}

has_oauth :: proc(config: ^Config) -> bool {
	return config.youtube.client_id != "" &&
	       config.youtube.client_secret != "" &&
	       config.youtube.refresh_token != ""
}

/*
	Print a redacted summary of the loaded configuration so the user can
	verify what the bot will do without leaking any secrets.
*/
log_config_summary :: proc(config: ^Config, path: string) {
	target := config.youtube.live_chat_id
	if target == "" {
		target = config.youtube.video_id
	}
	if target == "" {
		target = config.youtube.channel_id
	}
	log_info("config: %s", path)
	log_info("chat target: %s", target)
	log_info("prefix: %s", config.bot.prefix)
	log_info("dry run: %v", config.bot.dry_run)
	if config.moderation.enabled {
		log_info("moderation: enabled (spam threshold %d in %ds, timeout %ds, db %s)",
			config.moderation.spam_threshold,
			config.moderation.spam_window_seconds,
			config.moderation.timeout_seconds,
			config.moderation.database)
	} else {
		log_info("moderation: disabled")
	}
}
