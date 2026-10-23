package oracle

import "core:fmt"
import "core:os"
import "core:strings"

VERSION :: "0.1.0"

usage :: proc() {
	fmt.println("The Oracle - YouTube live chat bot")
	fmt.println()
	fmt.println("Usage:")
	fmt.println("  oracle run [--config PATH] [--dry-run]")
	fmt.println("  oracle check [--config PATH]")
	fmt.println("  oracle auth [--config PATH]")
	fmt.println("  oracle simulate [--config PATH]")
	fmt.println("  oracle db init [PATH] [--db PATH]")
	fmt.println("  oracle db import <words.txt> [PATH] [--db PATH]")
	fmt.println("  oracle db list [PATH] [--db PATH]")
	fmt.println("  oracle version")
	fmt.println()
	fmt.println("Commands in chat:")
	fmt.println("  !oracle github")
	fmt.println("  !oracle twitter")
	fmt.println("  !oracle help")
}

CLI_Options :: struct {
	command   : string,
	config    : string,
	database  : string,
	dry_run   : bool,
	positionals: []string,
}

parse_cli :: proc(args: []string) -> (options: CLI_Options, ok: bool) {
	options.config = DEFAULT_CONFIG_PATH
	positionals: [dynamic]string

	index := 0
	for index < len(args) {
		arg := args[index]
		switch {
		case arg == "--config" || arg == "-c":
			index += 1
			if index >= len(args) {
				log_error("cli: --config needs a path")
				return options, false
			}
			options.config = args[index]
		case arg == "--db":
			index += 1
			if index >= len(args) {
				log_error("cli: --db needs a path")
				return options, false
			}
			options.database = args[index]
		case arg == "--dry-run":
			options.dry_run = true
		case arg == "--help" || arg == "-h":
			options.command = "help"
		case arg == "--version" || arg == "-v":
			options.command = "version"
		case strings.has_prefix(arg, "-"):
			log_error("cli: unknown option %q", arg)
			return options, false
		case:
			append(&positionals, arg)
		}
		index += 1
	}

	positional_slice := positionals[:]
	if options.command == "" {
		if len(positional_slice) == 0 {
			options.command = "run"
		} else {
			options.command = positional_slice[0]
			positional_slice = positional_slice[1:]
		}
	}
	options.positionals = positional_slice
	return options, true
}

main :: proc() {
	code := run_cli()
	if code != 0 {
		os.exit(code)
	}
}

run_cli :: proc() -> int {
	options, ok := parse_cli(os.args[1:])
	if !ok {
		return 2
	}

	switch options.command {
	case "help":
		usage()
		return 0
	case "version":
		fmt.printf("the-oracle %s\n", VERSION)
		return 0
	case "run":
		return cli_run(options)
	case "check":
		return cli_check(options)
	case "auth":
		return cli_auth(options)
	case "simulate":
		return simulate_command(options)
	case "db":
		return cli_db(options)
	case:
		log_error("cli: unknown command %q", options.command)
		usage()
		return 2
	}
}

cli_run :: proc(options: CLI_Options) -> int {
	loaded := load_config(options.config)
	if !loaded.ok {
		return 1
	}
	if options.dry_run {
		loaded.config.bot.dry_run = true
	}
	if !run_bot(&loaded.config, loaded.path) {
		return 1
	}
	return 0
}

cli_check :: proc(options: CLI_Options) -> int {
	loaded := load_config(options.config)
	if !loaded.ok {
		return 1
	}
	if !validate_config(&loaded.config) {
		return 1
	}
	log_config_summary(&loaded.config, loaded.path)

	if loaded.config.moderation.enabled {
		if !db_check_command(loaded.config.moderation.database) {
			return 1
		}
	}

	log_info("check: configuration looks usable")
	return 0
}

cli_auth :: proc(options: CLI_Options) -> int {
	loaded := load_config(options.config)
	if !loaded.ok {
		// The auth flow only needs the client credentials, so a config with
		// placeholders for everything else is still usable.
		log_error("auth: fix the config file before authorizing")
		return 1
	}
	if !auth_command(&loaded.config) {
		return 1
	}
	log_info("auth: remember to leave youtube.refresh_token out of version control")
	return 0
}

cli_db :: proc(options: CLI_Options) -> int {
	if len(options.positionals) == 0 {
		log_error("cli: expected `db init`, `db import`, or `db list`")
		usage()
		return 2
	}

	subcommand := options.positionals[0]
	rest := options.positionals[1:]

	database := options.database
	if database == "" {
		database = default_database_path(options.config)
	}

	switch subcommand {
	case "init":
		if len(rest) > 0 && options.database == "" {
			database = rest[0]
		}
		if !db_init_command(database) {
			return 1
		}
		return 0
	case "import":
		if len(rest) == 0 {
			log_error("cli: `db import` needs a words file")
			return 2
		}
		words_file := rest[0]
		if len(rest) > 1 && options.database == "" {
			database = rest[1]
		}
		if !db_import_command(database, words_file) {
			return 1
		}
		return 0
	case "list":
		if len(rest) > 0 && options.database == "" {
			database = rest[0]
		}
		if !db_list_command(database) {
			return 1
		}
		return 0
	case:
		log_error("cli: unknown db subcommand %q", subcommand)
		usage()
		return 2
	}
}

@(private = "file")
default_database_path :: proc(config_path: string) -> string {
	if os.exists(config_path) {
		loaded := load_config(config_path)
		if loaded.ok {
			return loaded.config.moderation.database
		}
	}
	return DEFAULT_DATABASE
}
