package engine

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import glm "core:math/linalg/glsl"
import vma "shared:vma"
import "vendor:glfw"
import vk "vendor:vulkan"

NUM_FRAMES_IN_FLIGHT :: 2
NUM_SWAP_CHAIN_IMAGES :: NUM_FRAMES_IN_FLIGHT + 1
ACQUIRE_TIMEOUT_NS :: 100_000_000 // 100 ms

VoxEngine :: struct {
	runtimeContext: runtime.Context,

	// glfw
	glfwWindow:                glfw.WindowHandle,
	windowWidth, windowHeight: u32,

	// vulkan
	vkInstance:               vk.Instance,
	vkDebugMessenger:         vk.DebugUtilsMessengerEXT,
	vkSurface:                vk.SurfaceKHR,
	vkPhysicalDevice:         vk.PhysicalDevice,
	vkDevice:                 vk.Device,
	queues:                   [QueueType]QueueTuple,
	presentation:             PresentationInfo,
	vmaAllocator:             vma.Allocator,
	depthBuffer:              DepthBuffer,
	frameData:                [NUM_FRAMES_IN_FLIGHT]FrameResource,

	// sync
	timelineSemaphore:        vk.Semaphore,
	computeTimelineSemaphore: vk.Semaphore,
	currentTimelineValue:     u64,
	nextTimelineValue:        u64,

	// descriptors
	descriptorSetLayout:      vk.DescriptorSetLayout,
	graphicsPipelineLayout:   vk.PipelineLayout,
	computePipelineLayout:    vk.PipelineLayout,

	// estado
	validationLayersEnabled:  bool,
	swapchainNeedsRecreate:   bool,

	// time
	deltaTime:                f64,
	lastFrameTime:            f64,
	currentTime:              f64,
	tick:                     u64,
	frameIndex:               u32,
}

app: VoxEngine

CreateEngine :: proc(width: u32 = 800, height: u32 = 600) {
	app = {
		windowWidth       = width,
		windowHeight      = height,
		runtimeContext    = context,
		deltaTime         = 0.0,
		lastFrameTime     = glfw.GetTime(),
		currentTime       = 0.0,
		tick              = 0,
		nextTimelineValue = NUM_FRAMES_IN_FLIGHT + 1,
	}

	init_glfw()
	create_vulkan_instance()
	create_vulkan_surface()
	create_vulkan_device()
	create_vma_allocator()
	config_validate_machine()
	create_swap_chain()
	create_depth_buffer()
	create_sync_objects()
	create_frame_data()
	create_descriptor_layouts()
	telemetry_init()
	log.info("Engine created successfully")
}

DestroyEngine :: proc() {
	vk_check(vk.DeviceWaitIdle(app.vkDevice))
	telemetry_destroy()
	destroy_descriptor_layouts()
	destroy_frame_data()
	destroy_sync_objects()
	destroy_depth_buffer()
	destroy_swap_chain()
	destroy_vma_allocator()
	destroy_vulkan_device()
	destroy_vulkan_surface()
	destroy_vulkan_instance()
	glfw.DestroyWindow(app.glfwWindow)
	glfw.Terminate()
}

Update :: proc() {
	current_time := glfw.GetTime()
	app.deltaTime = current_time - app.lastFrameTime
	app.lastFrameTime = app.currentTime
	app.currentTime = current_time
	app.tick += 1
	app.frameIndex = (app.frameIndex + 1) % NUM_FRAMES_IN_FLIGHT
	app.currentTimelineValue = app.nextTimelineValue
	app.nextTimelineValue += 1
}

AcquireNextImage :: proc() -> (frame: SwapChainFrameData, ok: bool) {
	if app.swapchainNeedsRecreate {
		if !recreate_swapchain() {
			return {}, false
		}
	}

	image_index: u32
	result := vk.AcquireNextImageKHR(
		app.vkDevice,
		app.presentation.vkSwapChain,
		ACQUIRE_TIMEOUT_NS,
		app.frameData[app.frameIndex].vkAcquireSemaphore,
		0,
		&image_index,
	)
	if result == .TIMEOUT || result == .NOT_READY {
		return {}, false
	}
	if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
		app.swapchainNeedsRecreate = true
		return {}, false
	}
	vk_check(result)
	app.presentation.imageIndex = image_index
	return app.presentation.frames[image_index], true
}

AcquireFrameResource :: proc() -> ^FrameResource {
	return &app.frameData[app.frameIndex]
}

Present :: proc() {
	image_index := app.presentation.imageIndex
	swapchain_frame := &app.presentation.frames[image_index]
	present_queue := app.queues[QueueType.Graphics].queue
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapchain_frame.vkPresentSemaphore,
		pSwapchains        = &app.presentation.vkSwapChain,
		pImageIndices      = &image_index,
		swapchainCount     = 1,
	}
	result := vk.QueuePresentKHR(present_queue, &present_info)
	if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
		app.swapchainNeedsRecreate = true
	} else {
		vk_check(result)
	}
}

CancelFrameReservation :: proc() {
	app.frameIndex = (app.frameIndex + NUM_FRAMES_IN_FLIGHT - 1) % NUM_FRAMES_IN_FLIGHT
	app.currentTimelineValue -= 1
	app.nextTimelineValue -= 1
}

WaitTimelineSemaphore :: proc() -> u64 {
	signal_value := app.currentTimelineValue
	wait_value := signal_value - NUM_FRAMES_IN_FLIGHT

	wait_info := vk.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &app.timelineSemaphore,
		pValues        = &wait_value,
	}
	vk_check(vk.WaitSemaphores(app.vkDevice, &wait_info, max(u64)))
	return signal_value
}

@(private)
init_glfw :: proc() {
	glfw.SetErrorCallback(proc "c" (error: i32, description: cstring) {
		context = app.runtimeContext
		log.errorf("GLFW Error {}: {}", error, description)
	})

	if !glfw.Init() do log.panic("Failed to initialize GLFW")
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

	app.glfwWindow = glfw.CreateWindow(
		c.int(app.windowWidth),
		c.int(app.windowHeight),
		"Vox Engine",
		nil,
		nil,
	)

	if app.glfwWindow == nil {
		log.panic("Failed to create GLFW window")
	}

	glfw.SetFramebufferSizeCallback(
		app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, width, height: i32) {
			context = app.runtimeContext
			app.windowWidth = u32(width)
			app.windowHeight = u32(height)
			app.swapchainNeedsRecreate = true
		},
	)

	log.info("GLFW initialized created successfully")
}

@(private)
recreate_swapchain :: proc() -> bool {
	width, height := glfw.GetFramebufferSize(app.glfwWindow)
	if width == 0 || height == 0 {
		return false
	}
	app.swapchainNeedsRecreate = false
	vk_check(vk.DeviceWaitIdle(app.vkDevice))
	destroy_depth_buffer()
	destroy_swap_chain()
	create_swap_chain()
	create_depth_buffer()
	return true
}

@(private)
vk_check :: proc(result: vk.Result, exp := #caller_expression, location := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Vulkan failure: {} ({})", result, exp, location = location)
	}
}

@(private)
load_file :: proc(
	path: string,
	allocator: runtime.Allocator,
	location := #caller_location,
) -> []byte {
	data, ok := os.read_entire_file_from_path(path, allocator, location)
	if ok != nil do log.panicf("Failed to load file: {}", path, location = location)
	return data
}
