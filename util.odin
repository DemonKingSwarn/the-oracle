package oracle

import "core:strings"

/*
	Small helpers shared by the configuration, HTTP, and command layers.
*/

strings_clone_cstring :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

/*
	Percent-encode a value for use in a query string or a form body.
	Spaces are encoded as %20 (not '+') so the same helper is valid in both
	places.
*/
url_encode :: proc(s: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)

	for i in 0 ..< len(s) {
		ch := s[i]
		switch {
		case 'a' <= ch && ch <= 'z',
		     'A' <= ch && ch <= 'Z',
		     '0' <= ch && ch <= '9',
		     ch == '-', ch == '_', ch == '.', ch == '~':
			strings.write_byte(&builder, ch)
		case:
			strings.write_byte(&builder, '%')
			strings.write_byte(&builder, hex_digit(ch >> 4))
			strings.write_byte(&builder, hex_digit(ch & 0x0f))
		}
	}
	return strings.to_string(builder)
}

@(private = "file")
hex_digit :: proc(value: byte) -> byte {
	if value < 10 {
		return '0' + value
	}
	return 'A' + (value - 10)
}

@(private = "file")
hex_value :: proc(ch: byte) -> (int, bool) {
	switch {
	case '0' <= ch && ch <= '9':
		return int(ch - '0'), true
	case 'a' <= ch && ch <= 'f':
		return int(ch - 'a') + 10, true
	case 'A' <= ch && ch <= 'F':
		return int(ch - 'A') + 10, true
	}
	return 0, false
}

/*
	Decode a percent-encoded string. '+' is treated as a space, which is the
	convention used by application/x-www-form-urlencoded bodies. The OAuth
	authorization-code flow also uses this encoding.
*/
url_decode :: proc(s: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)

	i := 0
	for i < len(s) {
		ch := s[i]
		switch {
		case ch == '+':
			strings.write_byte(&builder, ' ')
			i += 1
		case ch == '%' && i + 2 < len(s):
			hi, hi_ok := hex_value(s[i + 1])
			lo, lo_ok := hex_value(s[i + 2])
			if hi_ok && lo_ok {
				strings.write_byte(&builder, byte(hi << 4 | lo))
				i += 3
			} else {
				strings.write_byte(&builder, ch)
				i += 1
			}
		case:
			strings.write_byte(&builder, ch)
			i += 1
		}
	}
	return strings.to_string(builder)
}

/*
	Extract a query-string parameter from a URL or a bare query string.
	Returns an empty string when the parameter is not present.
*/
query_param :: proc(url: string, key: string) -> string {
	query := url
	if index := strings.index_byte(url, '?'); index >= 0 {
		query = url[index + 1:]
	}
	if index := strings.index_byte(query, '#'); index >= 0 {
		query = query[:index]
	}

	rest := query
	for len(rest) > 0 {
		part := rest
		if index := strings.index_byte(rest, '&'); index >= 0 {
			part = rest[:index]
			rest = rest[index + 1:]
		} else {
			rest = ""
		}
		eq := strings.index_byte(part, '=')
		if eq < 0 {
			continue
		}
		name := part[:eq]
		if strings.equal_fold(name, key) {
			return url_decode(part[eq + 1:], context.temp_allocator)
		}
	}
	return ""
}

clamp_int :: proc(value, low, high: int) -> int {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

join_strings :: proc(values: []string, separator: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	for value, index in values {
		if index > 0 {
			strings.write_string(&builder, separator)
		}
		strings.write_string(&builder, value)
	}
	return strings.to_string(builder)
}

