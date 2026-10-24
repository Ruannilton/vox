package engine

import "core:os"

import glm "core:math/linalg/glsl"
import vma "shared:vma"
import vk "vendor:vulkan"


import "base:runtime"
import "core:c"
import "core:log"
import "vendor:glfw"


NUM_FRAMES_IN_FLIGHT :: 2
NUM_SWAP_CHAIN_IMAGES :: NUM_FRAMES_IN_FLIGHT + 1


VoxEngine :: struct {
	runtimeContext:            runtime.Context,

	// glfw
	glfwWindow:                glfw.WindowHandle,
	windowWidth, windowHeight: u32,

	// vulkan
	vkInstance:                vk.Instance,
	vkDebugMessenger:          vk.DebugUtilsMessengerEXT,
	vkSurface:                 vk.SurfaceKHR,
	vkPhysicalDevice:          vk.PhysicalDevice,
	vkDevice:                  vk.Device,
	queues:                    [QueueType]QueueTuple,
	presentation:              PresentationInfo,
	vmaAllocator:              vma.Allocator,
	depthBuffer:               DepthBuffer,
	frameData:                 [NUM_FRAMES_IN_FLIGHT]FrameResource,

	// sync
	timelineSemaphore:         vk.Semaphore,
	currentTimelineValue:      u64,
	nextTimelineValue:         u64,

	// time
	deltaTime:                 f64,
	lastFrameTime:             f64,
	currentTime:               f64,
	tick:                      u64,
	frameIndex:                u32,
}

app: VoxEngine

CreateEngine :: proc(widht: u32 = 800, height: u32 = 600) {
	app = {
		windowWidth       = widht,
		windowHeight      = height,
		runtimeContext    = context,
		deltaTime         = 0.0,
		lastFrameTime     = glfw.GetTime(),
		currentTime       = 0.0,
		tick              = 0,
		nextTimelineValue = NUM_FRAMES_IN_FLIGHT + 1,
	}

	initGlfw()
	create_vulkan_instance()
	create_vulkan_surface()
	create_vulkan_device()
	create_vma_allocator()
	create_swap_chain()
	create_depth_buffer()
	create_sync_objects()
	create_frame_data()
	log.info("Engine created successfully")
}

DestroyEngine :: proc() {
	destroy_frame_data()
	destroy_sync_objects()
	destroy_depth_buffer()
	destroy_vma_allocator()
	destroy_swap_chain()
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

AcquireNextImage :: proc() -> SwapChainFrameData {
	image_index: u32
	vk_check(
		vk.AcquireNextImageKHR(
			app.vkDevice,
			app.presentation.vkSwapChain,
			max(u64),
			app.frameData[app.frameIndex].vkAcquireSemaphore,
			0,
			&image_index,
		),
	)
	app.presentation.imageIndex = image_index
	return app.presentation.frames[image_index]
}

AcquireFrameResource :: proc() -> ^FrameResource {
	return &app.frameData[app.frameIndex]
}

Present :: proc() {
	image_index := app.presentation.imageIndex
	swapChainFrame := &app.presentation.frames[image_index]
	presentQueue := app.queues[QueueType.Graphics].queue
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapChainFrame.vkPresentSemaphore,
		pSwapchains        = &app.presentation.vkSwapChain,
		pImageIndices      = &image_index,
		swapchainCount     = 1,
	}
	vk_check(vk.QueuePresentKHR(presentQueue, &present_info))
}

WaitTimelineSemaphore :: proc() -> u64 {
	signal_value := app.currentTimelineValue
	waitValue := signal_value - NUM_FRAMES_IN_FLIGHT


	wait_info := vk.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &app.timelineSemaphore,
		pValues        = &waitValue,
	}
	vk_check(vk.WaitSemaphores(app.vkDevice, &wait_info, max(u64)))
	return signal_value
}

@(private)
initGlfw :: proc() {

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
			destroy_swap_chain()
			create_swap_chain()
		},
	)

	log.info("GLFW initialized created successfully")
}

@(private)
vk_check :: proc(result: vk.Result, exp := #caller_expression, location := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Vulkan failure: {} ({})", result, exp, location = location)
	} else {
		//	log.info(" Success:", exp, location = location)
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
