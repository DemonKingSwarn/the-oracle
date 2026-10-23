package oracle

import "core:fmt"
import "core:time"

LOG_LEVEL_INFO :: 0
LOG_LEVEL_WARN :: 1
LOG_LEVEL_ERROR :: 2

log_write :: proc(level: int, format: string, args: ..any) {
	now := time.now()
	date_buf: [16]u8
	time_buf: [16]u8
	date := time.to_string_yyyy_mm_dd(now, date_buf[:])
	clock := time.to_string_hms(now, time_buf[:])

	label := "INFO"
	switch level {
	case LOG_LEVEL_WARN:
		label = "WARN"
	case LOG_LEVEL_ERROR:
		label = "ERROR"
	}

	message := fmt.aprintf(format, ..args)
	defer delete(message)

	if level == LOG_LEVEL_INFO {
		fmt.printf("%s %s %-5s %s\n", date, clock, label, message)
	} else {
		fmt.eprintf("%s %s %-5s %s\n", date, clock, label, message)
	}
}

log_info :: proc(format: string, args: ..any) {
	log_write(LOG_LEVEL_INFO, format, ..args)
}

log_warn :: proc(format: string, args: ..any) {
	log_write(LOG_LEVEL_WARN, format, ..args)
}

log_error :: proc(format: string, args: ..any) {
	log_write(LOG_LEVEL_ERROR, format, ..args)
}
