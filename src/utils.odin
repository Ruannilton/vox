package main

import "core:log"
import vk "vendor:vulkan"

vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan failure: {}", result, location = location)
}
