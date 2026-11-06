package engine

import vma "shared:vma"
import vk "vendor:vulkan"

GpuBuffer :: struct {
	handle:     vk.Buffer,
	allocation: vma.Allocation,
	size:       vk.DeviceSize,
}

gpu_buffer_create :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags) -> (buffer: GpuBuffer) {
    buffer.size = size

	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	allocation_info := vma.AllocationCreateInfo {
		usage = .AUTO,
		flags = {},
	}
	vk_check(
		vma.CreateBuffer(
			app.vmaAllocator,
			buffer_info,
			allocation_info,
			&buffer.handle,
			&buffer.allocation,
			nil,
		),
	)
	return
}

gpu_buffer_destroy :: proc(buffer: ^GpuBuffer) {
	if buffer.handle == {} do return
	vma.DestroyBuffer(app.vmaAllocator, buffer.handle, buffer.allocation)
	buffer^ = {}
}