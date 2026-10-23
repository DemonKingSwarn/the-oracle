package oracle

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

/*
	OAuth onboarding helper.

	The bot needs a refresh token with the youtube.force-ssl scope so it can
	post messages, delete messages, and time out users. This helper prints the
	consent URL, accepts either the code or the full redirected URL, and
	exchanges it for a refresh token.
*/

AUTH_ENDPOINT :: "https://accounts.google.com/o/oauth2/v2/auth"

read_line :: proc() -> (line: string, ok: bool) {
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&scanner)

	if !bufio.scan(&scanner) {
		return "", false
	}
	text := bufio.scanner_text(&scanner)
	return strings.clone(text), true
}

auth_command :: proc(config: ^Config) -> bool {
	if config.youtube.client_id == "" || config.youtube.client_secret == "" {
		log_error("auth: set youtube.client_id and youtube.client_secret in the config first")
		return false
	}

	redirect_uri := "http://127.0.0.1:8765"
	url := fmt.aprintf(
		"%s?client_id=%s&redirect_uri=%s&response_type=code&scope=%s&access_type=offline&prompt=consent",
		AUTH_ENDPOINT,
		url_encode(config.youtube.client_id, context.temp_allocator),
		url_encode(redirect_uri, context.temp_allocator),
		url_encode(YOUTUBE_SCOPE, context.temp_allocator),
	)

	fmt.println()
	fmt.println("1. Open this URL in a browser signed in as the bot account:")
	fmt.println()
	fmt.println(url)
	fmt.println()
	fmt.println("2. Approve the YouTube permission. The browser will be sent to")
	fmt.println("   http://127.0.0.1:8765/?code=... and may show a connection error.")
	fmt.println("   That is expected. Copy the entire address bar URL.")
	fmt.println()
	fmt.println("3. Paste the full URL (or just the code parameter) below and press Enter:")
	fmt.println()

	fmt.printf("> ")
	line, read_ok := read_line()
	if !read_ok || strings.trim_space(line) == "" {
		log_error("auth: no authorization code was entered")
		return false
	}
	defer delete(line)

	code := strings.trim_space(line)
	if strings.contains(code, "code=") {
		code = query_param(code, "code")
	}
	if code == "" {
		log_error("auth: could not find a code= parameter in the pasted value")
		return false
	}

	form := fmt.aprintf(
		"code=%s&client_id=%s&client_secret=%s&redirect_uri=%s&grant_type=authorization_code",
		url_encode(code, context.temp_allocator),
		url_encode(config.youtube.client_id, context.temp_allocator),
		url_encode(config.youtube.client_secret, context.temp_allocator),
		url_encode(redirect_uri, context.temp_allocator),
	)

	response := http_request(
		Http_Request {
			method = "POST",
			url = GOOGLE_TOKEN_URL,
			body = form,
			content_type = "application/x-www-form-urlencoded",
			timeout_seconds = 30,
		},
		context.temp_allocator,
	)

	if response.error != "" {
		log_error("auth: token exchange failed: %s", response.error)
		return false
	}
	if response.status != 200 {
		message := api_error_message(response.body)
		if message != "" {
			log_error("auth: token exchange failed (%d): %s", response.status, message)
		} else {
			log_error("auth: token exchange failed with HTTP %d", response.status)
		}
		return false
	}

	parsed: Token_Response
	if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err != nil {
		log_error("auth: could not parse token response: %v", err)
		return false
	}
	if parsed.refresh_token == "" {
		log_error("auth: Google did not return a refresh token")
		log_error("auth: remove this app's access at https://myaccount.google.com/permissions and try again")
		return false
	}

	fmt.println()
	fmt.println("Success. Add this to the youtube section of your config:")
	fmt.println()
	fmt.printf("  \"refresh_token\": %q\n", parsed.refresh_token)
	fmt.println()
	fmt.println("Keep the refresh token secret. It grants posting access to the channel.")
	return true
}
