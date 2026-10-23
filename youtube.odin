package oracle

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

YOUTUBE_API_BASE :: "https://www.googleapis.com/youtube/v3"
GOOGLE_TOKEN_URL :: "https://oauth2.googleapis.com/token"
YOUTUBE_SCOPE :: "https://www.googleapis.com/auth/youtube.force-ssl"

Live_Chat_Message :: struct {
	id           : string         `json:"id"`,
	snippet      : Message_Snippet `json:"snippet"`,
	authorDetails: Author_Details  `json:"authorDetails"`,
}

Message_Snippet :: struct {
	type             : string                `json:"type"`,
	publishedAt      : string                `json:"publishedAt"`,
	displayMessage   : string                `json:"displayMessage"`,
	textMessageDetails: Text_Message_Details `json:"textMessageDetails"`,
}

Text_Message_Details :: struct {
	messageText: string `json:"messageText"`,
}

Author_Details :: struct {
	channelId      : string `json:"channelId"`,
	displayName    : string `json:"displayName"`,
	isChatOwner    : bool   `json:"isChatOwner"`,
	isChatSponsor  : bool   `json:"isChatSponsor"`,
	isChatModerator: bool   `json:"isChatModerator"`,
	profileImageUrl: string `json:"profileImageUrl"`,
}

Live_Chat_Page :: struct {
	items               : []Live_Chat_Message,
	next_page_token     : string,
	polling_interval_ms : int,
	offline_at          : string,
	status              : int,
	error_reason        : string,
}

Token_Response :: struct {
	access_token     : string `json:"access_token"`,
	refresh_token    : string `json:"refresh_token"`,
	expires_in       : int    `json:"expires_in"`,
	token_type       : string `json:"token_type"`,
	error            : string `json:"error"`,
	error_description: string `json:"error_description"`,
}

Google_Error :: struct {
	code   : int                  `json:"code"`,
	message: string               `json:"message"`,
	status : string               `json:"status"`,
	errors : []Google_Error_Detail `json:"errors"`,
}

Google_Error_Detail :: struct {
	message: string `json:"message"`,
	domain : string `json:"domain"`,
	reason : string `json:"reason"`,
}

Google_Error_Envelope :: struct {
	error: Google_Error `json:"error"`,
}

YouTube_Client :: struct {
	config              : ^Config,
	access_token        : string,
	token_expiry        : time.Time,
	has_oauth           : bool,
	bot_channel_id      : string,
	uploads_playlist_id : string,
}

oauth_refresh :: proc(config: ^Config, allocator := context.allocator) -> (token: string, expires_in: int, ok: bool) {
	form := fmt.aprintf(
		"client_id=%s&client_secret=%s&refresh_token=%s&grant_type=refresh_token",
		url_encode(config.youtube.client_id, context.temp_allocator),
		url_encode(config.youtube.client_secret, context.temp_allocator),
		url_encode(config.youtube.refresh_token, context.temp_allocator),
	)
	response := http_request(
		Http_Request {
			method = "POST",
			url = GOOGLE_TOKEN_URL,
			body = form,
			content_type = "application/x-www-form-urlencoded",
			timeout_seconds = 20,
		},
		context.temp_allocator,
	)

	if response.error != "" {
		log_error("oauth: token refresh failed: %s", response.error)
		return
	}
	if response.status != 200 {
		message := api_error_message(response.body)
		if message != "" {
			log_error("oauth: token refresh failed (%d): %s", response.status, message)
		} else {
			log_error("oauth: token refresh failed with HTTP %d", response.status)
		}
		return
	}

	parsed: Token_Response
	if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err != nil {
		log_error("oauth: could not parse token response: %v", err)
		return
	}
	if parsed.access_token == "" {
		log_error("oauth: token response did not contain an access token")
		return
	}

	return strings.clone(parsed.access_token, allocator), parsed.expires_in, true
}

api_error_message :: proc(body: string) -> string {
	if body == "" {
		return ""
	}
	envelope: Google_Error_Envelope
	if err := json.unmarshal_string(body, &envelope, allocator = context.temp_allocator); err == nil {
		if envelope.error.message != "" {
			return envelope.error.message
		}
	}
	return ""
}

api_error_reason :: proc(body: string) -> string {
	if body == "" {
		return ""
	}
	envelope: Google_Error_Envelope
	if err := json.unmarshal_string(body, &envelope, allocator = context.temp_allocator); err == nil {
		if len(envelope.error.errors) > 0 {
			return envelope.error.errors[0].reason
		}
	}
	return ""
}

log_api_failure :: proc(operation: string, response: Http_Response) {
	if response.error != "" {
		log_error("%s: %s", operation, response.error)
		return
	}
	message := api_error_message(response.body)
	if message != "" {
		log_error("%s: HTTP %d: %s", operation, response.status, message)
	} else {
		log_error("%s: HTTP %d", operation, response.status)
	}
}

youtube_client_init :: proc(client: ^YouTube_Client, config: ^Config) {
	client.config = config
	client.has_oauth = has_oauth(config)
	client.bot_channel_id = config.youtube.bot_channel_id

	if !client.has_oauth {
		return
	}

	if !ensure_access_token(client) {
		log_warn("oauth: could not obtain an access token at startup; will retry when needed")
		return
	}

	if client.bot_channel_id == "" {
		client.bot_channel_id = fetch_my_channel_id(client)
	}
}

youtube_client_destroy :: proc(client: ^YouTube_Client) {
	delete(client.access_token)
	delete(client.uploads_playlist_id)
	client.access_token = ""
	client.uploads_playlist_id = ""
}

ensure_access_token :: proc(client: ^YouTube_Client) -> bool {
	if !client.has_oauth {
		return false
	}
	if client.access_token != "" && time.diff(time.now(), client.token_expiry) > 60 * time.Second {
		return true
	}

	token, expires_in, ok := oauth_refresh(client.config, context.allocator)
	if !ok {
		return false
	}

	delete(client.access_token)
	client.access_token = token
	if expires_in <= 0 {
		expires_in = 3600
	}
	client.token_expiry = time.time_add(time.now(), time.Duration(expires_in - 60) * time.Second)
	log_info("oauth: access token refreshed (valid for about %d minutes)", expires_in / 60)
	return true
}

youtube_get :: proc(client: ^YouTube_Client, url: string) -> Http_Response {
	return http_request(
		Http_Request {
			method = "GET",
			url = url,
			timeout_seconds = 20,
		},
		context.temp_allocator,
	)
}

youtube_get_authorized :: proc(client: ^YouTube_Client, url: string) -> Http_Response {
	if !ensure_access_token(client) {
		return Http_Response{error = "not authenticated"}
	}
	return http_request(
		Http_Request {
			method = "GET",
			url = url,
			bearer_token = client.access_token,
			timeout_seconds = 20,
		},
		context.temp_allocator,
	)
}

Channels_Response :: struct {
	items: []Channel_Item `json:"items"`,
}

Channel_Item :: struct {
	id            : string                 `json:"id"`,
	contentDetails: Channel_Content_Details `json:"contentDetails"`,
}

Channel_Content_Details :: struct {
	relatedPlaylists: Related_Playlists `json:"relatedPlaylists"`,
}

Related_Playlists :: struct {
	uploads: string `json:"uploads"`,
}

fetch_my_channel_id :: proc(client: ^YouTube_Client) -> string {
	url := fmt.aprintf("%s/channels?part=id&mine=true", YOUTUBE_API_BASE)
	response := youtube_get_authorized(client, url)
	if response.error != "" || response.status != 200 {
		if response.error != "not authenticated" {
			log_api_failure("youtube: fetching bot channel", response)
		}
		return ""
	}

	parsed: Channels_Response
	if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err != nil {
		log_error("youtube: could not parse channel response: %v", err)
		return ""
	}
	if len(parsed.items) == 0 || parsed.items[0].id == "" {
		log_warn("youtube: OAuth account does not have a channel id")
		return ""
	}
	return strings.clone(parsed.items[0].id, context.allocator)
}

Videos_Response :: struct {
	items: []Video_Item `json:"items"`,
}

Video_Item :: struct {
	id                  : string                 `json:"id"`,
	liveStreamingDetails: Live_Streaming_Details `json:"liveStreamingDetails"`,
}

Live_Streaming_Details :: struct {
	activeLiveChatId: string `json:"activeLiveChatId"`,
	actualStartTime : string `json:"actualStartTime"`,
	actualEndTime   : string `json:"actualEndTime"`,
}

lookup_video_chat_id :: proc(client: ^YouTube_Client, video_id: string) -> string {
	url := fmt.aprintf(
		"%s/videos?part=liveStreamingDetails&id=%s&key=%s",
		YOUTUBE_API_BASE,
		url_encode(video_id, context.temp_allocator),
		url_encode(client.config.youtube.api_key, context.temp_allocator),
	)
	response := youtube_get(client, url)
	if response.error != "" || response.status != 200 {
		log_api_failure("youtube: looking up video", response)
		return ""
	}

	parsed: Videos_Response
	if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err != nil {
		log_error("youtube: could not parse video response: %v", err)
		return ""
	}
	if len(parsed.items) == 0 {
		return ""
	}
	chat_id := parsed.items[0].liveStreamingDetails.activeLiveChatId
	if chat_id == "" {
		return ""
	}
	return strings.clone(chat_id, context.allocator)
}

Playlist_Items_Response :: struct {
	items: []Playlist_Item `json:"items"`,
}

Playlist_Item :: struct {
	contentDetails: Playlist_Content_Details `json:"contentDetails"`,
}

Playlist_Content_Details :: struct {
	videoId: string `json:"videoId"`,
}

/*
	Resolve the channel's uploads playlist. This is much cheaper than
	search.list (1 quota unit instead of 100) and is enough to discover a new
	live stream from the streamer's own channel.
*/
get_uploads_playlist_id :: proc(client: ^YouTube_Client) -> string {
	if client.uploads_playlist_id != "" {
		return client.uploads_playlist_id
	}
	if client.config.youtube.channel_id == "" {
		return ""
	}

	url := fmt.aprintf(
		"%s/channels?part=contentDetails&id=%s&key=%s",
		YOUTUBE_API_BASE,
		url_encode(client.config.youtube.channel_id, context.temp_allocator),
		url_encode(client.config.youtube.api_key, context.temp_allocator),
	)
	response := youtube_get(client, url)
	if response.error == "" && response.status == 200 {
		parsed: Channels_Response
		if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err == nil {
			for item in parsed.items {
				if item.contentDetails.relatedPlaylists.uploads != "" {
					client.uploads_playlist_id = strings.clone(item.contentDetails.relatedPlaylists.uploads, context.allocator)
					return client.uploads_playlist_id
				}
			}
		}
	} else {
		log_api_failure("youtube: looking up channel uploads", response)
	}

	// Public channel ids conventionally use UC... for the channel and UU...
	// for its uploads playlist. This fallback avoids an extra API call on the
	// next attempt if the contentDetails request failed.
	channel_id := client.config.youtube.channel_id
	if len(channel_id) > 2 && strings.has_prefix(channel_id, "UC") {
		fallback := strings.concatenate({"UU", channel_id[2:]}, context.allocator)
		client.uploads_playlist_id = fallback
		return client.uploads_playlist_id
	}
	return ""
}

find_live_chat_in_uploads :: proc(client: ^YouTube_Client) -> string {
	playlist_id := get_uploads_playlist_id(client)
	if playlist_id == "" {
		return ""
	}

	url := fmt.aprintf(
		"%s/playlistItems?part=contentDetails&playlistId=%s&maxResults=10&key=%s",
		YOUTUBE_API_BASE,
		url_encode(playlist_id, context.temp_allocator),
		url_encode(client.config.youtube.api_key, context.temp_allocator),
	)
	response := youtube_get(client, url)
	if response.error != "" || response.status != 200 {
		log_api_failure("youtube: listing channel uploads", response)
		return ""
	}

	parsed: Playlist_Items_Response
	if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err != nil {
		log_error("youtube: could not parse uploads response: %v", err)
		return ""
	}

	video_ids: [dynamic]string
	defer delete(video_ids)
	for item in parsed.items {
		if item.contentDetails.videoId != "" {
			append(&video_ids, item.contentDetails.videoId)
		}
	}
	if len(video_ids) == 0 {
		return ""
	}

	joined := join_strings(video_ids[:], ",", context.temp_allocator)
	video_url := fmt.aprintf(
		"%s/videos?part=liveStreamingDetails&id=%s&key=%s",
		YOUTUBE_API_BASE,
		url_encode(joined, context.temp_allocator),
		url_encode(client.config.youtube.api_key, context.temp_allocator),
	)
	video_response := youtube_get(client, video_url)
	if video_response.error != "" || video_response.status != 200 {
		log_api_failure("youtube: checking recent uploads for a live chat", video_response)
		return ""
	}

	videos: Videos_Response
	if err := json.unmarshal_string(video_response.body, &videos, allocator = context.temp_allocator); err != nil {
		log_error("youtube: could not parse recent-video response: %v", err)
		return ""
	}
	for item in videos.items {
		if item.liveStreamingDetails.activeLiveChatId != "" {
			return strings.clone(item.liveStreamingDetails.activeLiveChatId, context.allocator)
		}
	}
	return ""
}

resolve_live_chat_id :: proc(client: ^YouTube_Client) -> string {
	if client.config.youtube.live_chat_id != "" {
		return strings.clone(client.config.youtube.live_chat_id, context.allocator)
	}

	if client.config.youtube.video_id != "" {
		chat_id := lookup_video_chat_id(client, client.config.youtube.video_id)
		if chat_id != "" {
			return chat_id
		}
		log_warn("youtube: video %s does not have an active live chat", client.config.youtube.video_id)
	}

	if client.config.youtube.channel_id != "" {
		chat_id := find_live_chat_in_uploads(client)
		if chat_id != "" {
			log_info("youtube: found live chat in the channel's recent uploads")
			return chat_id
		}
	}

	return ""
}

Live_Chat_List_Response :: struct {
	nextPageToken        : string              `json:"nextPageToken"`,
	pollingIntervalMillis: int                 `json:"pollingIntervalMillis"`,
	offlineAt            : string              `json:"offlineAt"`,
	items                : []Live_Chat_Message `json:"items"`,
}

list_live_chat_messages :: proc(client: ^YouTube_Client, live_chat_id, page_token: string) -> (page: Live_Chat_Page, ok: bool) {
	url := fmt.aprintf(
		"%s/liveChat/messages?liveChatId=%s&part=snippet,authorDetails&maxResults=200&key=%s",
		YOUTUBE_API_BASE,
		url_encode(live_chat_id, context.temp_allocator),
		url_encode(client.config.youtube.api_key, context.temp_allocator),
	)
	if page_token != "" {
		url = fmt.aprintf("%s&pageToken=%s", url, url_encode(page_token, context.temp_allocator))
	}

	response := youtube_get(client, url)
	if response.error != "" || response.status != 200 {
		log_api_failure("youtube: listing chat messages", response)
		page.status = response.status
		page.error_reason = api_error_reason(response.body)
		return page, false
	}

	parsed: Live_Chat_List_Response
	if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err != nil {
		log_error("youtube: could not parse chat response: %v", err)
		page.status = response.status
		return page, false
	}

	page.items = parsed.items
	page.next_page_token = parsed.nextPageToken
	page.polling_interval_ms = parsed.pollingIntervalMillis
	page.offline_at = parsed.offlineAt
	page.status = response.status
	return page, true
}

Send_Message_Body :: struct {
	snippet: Send_Message_Snippet `json:"snippet"`,
}

Send_Message_Snippet :: struct {
	liveChatId        : string            `json:"liveChatId"`,
	type              : string            `json:"type"`,
	textMessageDetails: Send_Text_Details `json:"textMessageDetails"`,
}

Send_Text_Details :: struct {
	messageText: string `json:"messageText"`,
}

Send_Message_Response :: struct {
	id: string `json:"id"`,
}

send_chat_message :: proc(client: ^YouTube_Client, live_chat_id, text: string) -> (message_id: string, ok: bool) {
	if text == "" {
		return "", false
	}
	if len(text) > 200 {
		log_error("youtube: refusing to send a message longer than 200 bytes")
		return "", false
	}
	if !ensure_access_token(client) {
		log_error("youtube: cannot send message without OAuth credentials")
		return "", false
	}

	body := Send_Message_Body {
		snippet = Send_Message_Snippet {
			liveChatId = live_chat_id,
			type = "textMessageEvent",
			textMessageDetails = Send_Text_Details {messageText = text},
		},
	}
	payload, marshal_err := json.marshal(body, allocator = context.temp_allocator)
	if marshal_err != nil {
		log_error("youtube: could not serialize message: %v", marshal_err)
		return "", false
	}

	response := http_request(
		Http_Request {
			method = "POST",
			url = fmt.aprintf("%s/liveChat/messages?part=snippet", YOUTUBE_API_BASE),
			body = string(payload),
			content_type = "application/json",
			bearer_token = client.access_token,
			timeout_seconds = 20,
		},
		context.temp_allocator,
	)
	if response.error != "" || response.status != 200 {
		log_api_failure("youtube: sending chat message", response)
		return "", false
	}

	parsed: Send_Message_Response
	if err := json.unmarshal_string(response.body, &parsed, allocator = context.temp_allocator); err != nil {
		log_error("youtube: could not parse sent-message response: %v", err)
		return "", false
	}
	return strings.clone(parsed.id, context.allocator), true
}

delete_chat_message :: proc(client: ^YouTube_Client, message_id: string) -> bool {
	if !ensure_access_token(client) {
		log_error("youtube: cannot delete message without OAuth credentials")
		return false
	}

	response := http_request(
		Http_Request {
			method = "DELETE",
			url = fmt.aprintf(
				"%s/liveChat/messages?id=%s",
				YOUTUBE_API_BASE,
				url_encode(message_id, context.temp_allocator),
			),
			bearer_token = client.access_token,
			timeout_seconds = 20,
		},
		context.temp_allocator,
	)

	if response.error != "" {
		log_error("youtube: deleting message failed: %s", response.error)
		return false
	}
	if response.status == 204 || response.status == 200 {
		return true
	}
	log_api_failure("youtube: deleting message", response)
	return false
}

Ban_User_Details :: struct {
	channelId: string `json:"channelId"`,
}

Ban_Snippet :: struct {
	liveChatId        : string          `json:"liveChatId"`,
	type              : string          `json:"type"`,
	banDurationSeconds: int             `json:"banDurationSeconds"`,
	bannedUserDetails : Ban_User_Details `json:"bannedUserDetails"`,
}

Ban_Body :: struct {
	snippet: Ban_Snippet `json:"snippet"`,
}

timeout_chat_user :: proc(client: ^YouTube_Client, live_chat_id, channel_id: string, seconds: int) -> bool {
	duration := seconds
	if duration < 1 {
		duration = 600
	}
	if !ensure_access_token(client) {
		log_error("youtube: cannot timeout user without OAuth credentials")
		return false
	}

	body := Ban_Body {
		snippet = Ban_Snippet {
			liveChatId = live_chat_id,
			type = "temporary",
			banDurationSeconds = duration,
			bannedUserDetails = Ban_User_Details {channelId = channel_id},
		},
	}
	payload, marshal_err := json.marshal(body, allocator = context.temp_allocator)
	if marshal_err != nil {
		log_error("youtube: could not serialize ban request: %v", marshal_err)
		return false
	}

	response := http_request(
		Http_Request {
			method = "POST",
			url = fmt.aprintf("%s/liveChat/bans?part=snippet", YOUTUBE_API_BASE),
			body = string(payload),
			content_type = "application/json",
			bearer_token = client.access_token,
			timeout_seconds = 20,
		},
		context.temp_allocator,
	)

	if response.error != "" || !http_status_is_success(response.status) {
		log_api_failure("youtube: timing out user", response)
		return false
	}
	return true
}
