package main

import "core:os"
import vk "vendor:vulkan"
import "core:log"
import "base:runtime"   

vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan failure: {}", result, location = location)
}

load_file :: proc(
	path: string,
	allocator: runtime.Allocator,
	location := #caller_location,
) -> []byte {
	data, ok := os.read_entire_file_from_path(path, allocator, location)
	if ok != nil do log.panicf("Failed to load file: {}", path, location = location)
	return data
}
