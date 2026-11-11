package engine

import "core:fmt"
import "core:os"

debug_log_path: string
telemetry_output_directory: string
events_output_directory: string
tracy_output_directory: string

debug_paths_init :: proc(version: string) {
	os.make_directory("debug")
	version_directory := fmt.aprintf("debug/%s", version)
	os.make_directory(version_directory)
	telemetry_output_directory = fmt.aprintf("%s/telemetry", version_directory)
	events_output_directory = fmt.aprintf("%s/events", version_directory)
	tracy_output_directory = fmt.aprintf("%s/tracy", version_directory)
	os.make_directory(telemetry_output_directory)
	os.make_directory(events_output_directory)
	os.make_directory(tracy_output_directory)
	debug_log_path = fmt.aprintf("%s/log.txt", version_directory)
}
