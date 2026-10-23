package oracle

import "base:runtime"
import c "core:c"
import "core:strings"
import curl "vendor:curl"

/*
	A thin synchronous libcurl wrapper. YouTube's REST API is simple enough
	that a single request per call is all the bot needs, and keeping the
	wrapper small makes failures easy to reason about.
*/

Http_Request :: struct {
	method         : string, // "GET", "POST", or "DELETE"
	url            : string,
	body           : string,
	content_type   : string,
	bearer_token   : string,
	extra_headers  : []string,
	timeout_seconds: int,
}

Http_Response :: struct {
	status: int,
	body:   string,
	error:  string,
}

@(private = "file")
Write_Context :: struct {
	buffer:    ^[dynamic]u8,
	allocator: runtime.Allocator,
}

@(private = "file")
write_callback :: proc "c" (data: rawptr, size, count: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	ctx := cast(^Write_Context)userdata
	context.allocator = ctx.allocator

	total := int(size * count)
	if total > 0 {
		source := cast([^]u8)data
		append(ctx.buffer, ..source[:total])
	}
	return c.size_t(total)
}

@(private = "file")
add_header :: proc(headers: ^^curl.slist, line: string) {
	if line == "" {
		return
	}
	c_line := strings.clone_to_cstring(line, context.temp_allocator)
	if c_line == nil {
		return
	}
	updated := curl.slist_append(headers^, c_line)
	if updated != nil {
		headers^ = updated
	}
}

http_request :: proc(request: Http_Request, allocator := context.allocator) -> Http_Response {
	response := Http_Response{}

	handle := curl.easy_init()
	if handle == nil {
		response.error = "could not initialize libcurl"
		return response
	}
	defer curl.easy_cleanup(handle)

	body: [dynamic]u8
	defer delete(body)

	write_context := Write_Context {
		buffer = &body,
		allocator = allocator,
	}

	url_cstring := strings_clone_cstring(request.url)
	if url_cstring == nil {
		response.error = "out of memory while building request URL"
		return response
	}

	timeout := request.timeout_seconds
	if timeout <= 0 {
		timeout = 20
	}

	headers: ^curl.slist
	defer curl.slist_free_all(headers)

	add_header(&headers, "Accept: application/json")
	if request.bearer_token != "" {
		add_header(&headers, strings.concatenate({"Authorization: Bearer ", request.bearer_token}, context.temp_allocator))
	}
	if request.content_type != "" {
		add_header(&headers, strings.concatenate({"Content-Type: ", request.content_type}, context.temp_allocator))
	}
	for extra in request.extra_headers {
		add_header(&headers, extra)
	}

	error_buffer: [512]u8

	curl.easy_setopt(handle, .URL, url_cstring)
	curl.easy_setopt(handle, .NOPROGRESS, c.long(1))
	curl.easy_setopt(handle, .NOSIGNAL, c.long(1))
	curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(handle, .MAXREDIRS, c.long(3))
	curl.easy_setopt(handle, .CONNECTTIMEOUT, c.long(10))
	curl.easy_setopt(handle, .TIMEOUT, c.long(timeout))
	curl.easy_setopt(handle, .USERAGENT, cstring("the-oracle/0.1"))
	curl.easy_setopt(handle, .ERRORBUFFER, rawptr(&error_buffer[0]))
	curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &write_context)
	curl.easy_setopt(handle, .HTTPHEADER, headers)

	if request.method == "POST" {
		curl.easy_setopt(handle, .POST, c.long(1))
		if request.body != "" {
			body_cstring := strings_clone_cstring(request.body)
			if body_cstring == nil {
				response.error = "out of memory while building request body"
				return response
			}
			curl.easy_setopt(handle, .POSTFIELDS, body_cstring)
			curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(len(request.body)))
		}
	} else if request.method == "DELETE" {
		curl.easy_setopt(handle, .CUSTOMREQUEST, cstring("DELETE"))
	}

	code := curl.easy_perform(handle)
	if code != curl.code.E_OK {
		if error_buffer[0] != 0 {
			response.error = strings.clone(string(cstring(&error_buffer[0])), allocator)
		} else if error_text := curl.easy_strerror(code); error_text != nil {
			response.error = strings.clone(string(error_text), allocator)
		} else {
			response.error = "libcurl request failed"
		}
		return response
	}

	status: c.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	response.status = int(status)

	if len(body) > 0 {
		response.body = strings.clone(string(body[:]), allocator)
	}
	return response
}

http_status_is_success :: proc(status: int) -> bool {
	return status >= 200 && status < 300
}
