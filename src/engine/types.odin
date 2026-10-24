package engine

import glm "core:math/linalg/glsl"
import vma "shared:vma"
import vk "vendor:vulkan"


import "base:runtime"
import "core:c"
import "core:log"
import "vendor:glfw"

QueueType :: enum {
	Graphics,
	Compute,
	Transfer,
}

QueueTuple :: struct {
	queue:       vk.Queue,
	familyIndex: u32,
}

FrameResource :: struct {
	vkCommandPool:      vk.CommandPool,
	vkCommandBuffer:    vk.CommandBuffer,
	vkAcquireSemaphore: vk.Semaphore,
}

SwapChainFrameData :: struct {
	vkPresentSemaphore: vk.Semaphore,
	image:              vk.Image,
	image_view:         vk.ImageView,
}

PresentationInfo :: struct {
	vkSwapChain:         vk.SwapchainKHR,
	swapChainImageCount: u32,
	width, height:       u32,
	frames:              []SwapChainFrameData,
	format:              vk.Format,
	imageIndex:          u32,
}

DepthBuffer :: struct {
	vkImage:       vk.Image,
	vkImageView:   vk.ImageView,
	vmaAllocation: vma.Allocation,
	format:        vk.Format,
}

RenderSet :: struct {
	pipelineLayout:   vk.PipelineLayout,
	graphicsPipeline: vk.Pipeline,
}
