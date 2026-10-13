package main

import "base:runtime"
import "core:log"
import "core:os"
import "core:slice"
import vma "shared:vma"
import "vendor:glfw"
import vk "vendor:vulkan"

NUM_FRAMES_IN_FLIGHT :: 2
NUM_SWAP_CHAIN_IMAGES :: NUM_FRAMES_IN_FLIGHT + 1


FrameData :: struct {
	vkFrameFence:       vk.Fence,
	vkCommandPool:      vk.CommandPool,
	vkCommandBuffer:    vk.CommandBuffer,
	vkAcquireSemaphore: vk.Semaphore,
}

SwapchainInfo :: struct {
	vkSwapChain:         vk.SwapchainKHR,
	vkPresentSemaphore:  []vk.Semaphore,
	swapChainImageCount: u32,
	images:              []vk.Image,
	image_views:         []vk.ImageView,
	width, height:       u32,
	format:              vk.Format,
}

DepthBuffer :: struct {
	vkImage:       vk.Image,
	vkImageView:   vk.ImageView,
	vmaAllocation: vma.Allocation,
	format:        vk.Format,
}

Globals :: struct {
	global_context:    runtime.Context,
	window:            glfw.WindowHandle,
	vkInstance:        vk.Instance,
	vkDebugMessenger:  vk.DebugUtilsMessengerEXT,
	vkSurface:         vk.SurfaceKHR,
	vkPhysicalDevice:  vk.PhysicalDevice,
	vkDevice:          vk.Device,
	vkQueue:           vk.Queue,
	vkFamilyIndex:     u32,
	swapchain:         SwapchainInfo,
	frames:            [NUM_FRAMES_IN_FLIGHT]FrameData,
	frameIndex:        u32,
	vmaAllocator:      vma.Allocator,
	depthBuffer:       DepthBuffer,
	triangleShader:    vk.ShaderModule,
	pipelineLayout:    vk.PipelineLayout,
	graphicsPipeline:  vk.Pipeline,
	timelineSemaphore: vk.Semaphore,
	nextSignalValue:   u64,
}

globals: Globals

main :: proc() {
	context.logger = log.create_console_logger()
	globals.global_context = context


	glfw.SetErrorCallback(proc "c" (error: i32, description: cstring) {
		context = globals.global_context
		log.errorf("GLFW Error {}: {}", error, description)
	})

	// Initialize GLFW
	if !glfw.Init() do return
	defer glfw.Terminate()
	log.info("GLFW initialized successfully")

	// Create window
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	globals.window = glfw.CreateWindow(800, 600, "Vox", nil, nil)
	if globals.window == nil do return
	defer glfw.DestroyWindow(globals.window)

	glfw.SetFramebufferSizeCallback(
		globals.window,
		proc "c" (window: glfw.WindowHandle, width, height: i32) {
			context = globals.global_context
			resize_window()
		},
	)
	log.info("Window created successfully")

	// Initialize Vulkan
	create_vulkan_instance()
	defer destroy_vulkan_instance()

	create_surface()
	defer destroy_surface()

	create_vulkan_device()
	defer destroy_vulkan_device()

	create_vma_allocator()
	defer destroy_vma_allocator()

	create_swap_chain()
	defer destroy_swap_chain()

	create_shader_objects()
	defer destroy_shader_objects()

	create_frames()
	defer destroy_frames()

	create_graphics_pipeline()
	defer destroy_graphics_pipeline()

	globals.frameIndex = 0
	globals.nextSignalValue = NUM_FRAMES_IN_FLIGHT + 1
	for !glfw.WindowShouldClose(globals.window) {
		free_all(context.temp_allocator)
		glfw.PollEvents()

		current_frame := globals.frames[globals.frameIndex]
		signal_value := globals.nextSignalValue
		globals.nextSignalValue += 1
		waitValue := signal_value - NUM_FRAMES_IN_FLIGHT

		wait_info := vk.SemaphoreWaitInfo {
			sType          = .SEMAPHORE_WAIT_INFO,
			semaphoreCount = 1,
			pSemaphores    = &globals.timelineSemaphore,
			pValues        = &waitValue,
		}
		vk_check(vk.WaitSemaphores(globals.vkDevice, &wait_info, max(u64)))

		image_index: u32
		vk_check(
			vk.AcquireNextImageKHR(
				globals.vkDevice,
				globals.swapchain.vkSwapChain,
				max(u64),
				current_frame.vkAcquireSemaphore,
				0,
				&image_index,
			),
		)

		present_semaphore := globals.swapchain.vkPresentSemaphore[image_index]

		vk_check(vk.ResetCommandPool(globals.vkDevice, current_frame.vkCommandPool, {}))

		begin_command_info := vk.CommandBufferBeginInfo {
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		vk_check(vk.BeginCommandBuffer(current_frame.vkCommandBuffer, &begin_command_info))

		transition_rendering_barrier := [2]vk.ImageMemoryBarrier2 {
			{
				sType = .IMAGE_MEMORY_BARRIER_2,
				image = globals.swapchain.images[image_index],
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
				oldLayout = .UNDEFINED,
				newLayout = .COLOR_ATTACHMENT_OPTIMAL,
				srcStageMask = {.ALL_COMMANDS},
				srcAccessMask = {.MEMORY_READ},
				dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
			},
			{
				sType = .IMAGE_MEMORY_BARRIER_2,
				image = globals.depthBuffer.vkImage,
				subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
				oldLayout = .UNDEFINED,
				newLayout = .DEPTH_ATTACHMENT_OPTIMAL,
				srcStageMask = {.ALL_COMMANDS},
				srcAccessMask = {.MEMORY_READ},
				dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
				dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			},
		}
		vk.CmdPipelineBarrier2(
			current_frame.vkCommandBuffer,
			&vk.DependencyInfo {
				sType = .DEPENDENCY_INFO,
				imageMemoryBarrierCount = len(transition_rendering_barrier),
				pImageMemoryBarriers = raw_data(&transition_rendering_barrier),
			},
		)

		color_attachment := vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = globals.swapchain.image_views[image_index],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = {color = {float32 = {0, 0.2, 0.8, 1}}},
		}
		depth_attachment := vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = globals.depthBuffer.vkImageView,
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .DONT_CARE,
			clearValue = {depthStencil = {depth = 1, stencil = 0}},
		}
		rendering_info := vk.RenderingInfo {
			sType = .RENDERING_INFO,
			renderArea = {
				offset = {0, 0},
				extent = {globals.swapchain.width, globals.swapchain.height},
			},
			layerCount = 1,
			colorAttachmentCount = 1,
			pColorAttachments = &color_attachment,
			pDepthAttachment = &depth_attachment,
		}
		vk.CmdBeginRendering(current_frame.vkCommandBuffer, &rendering_info)


		view_port := vk.Viewport {
			x        = 0,
			y        = 0,
			width    = f32(globals.swapchain.width),
			height   = f32(globals.swapchain.height),
			minDepth = 0,
			maxDepth = 1,
		}
		vk.CmdSetViewport(current_frame.vkCommandBuffer, 0, 1, &view_port)

		scissor := vk.Rect2D {
			offset = {0, 0},
			extent = {globals.swapchain.width, globals.swapchain.height},
		}
		vk.CmdSetScissor(current_frame.vkCommandBuffer, 0, 1, &scissor)

		// draw
		vk.CmdBindPipeline(current_frame.vkCommandBuffer, .GRAPHICS, globals.graphicsPipeline)
		vk.CmdDraw(current_frame.vkCommandBuffer, 3, 1, 0, 0)

		vk.CmdEndRendering(current_frame.vkCommandBuffer)

		transition_present_barrier := vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			image = globals.swapchain.images[image_index],
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
			newLayout = .PRESENT_SRC_KHR,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstStageMask = {},
			dstAccessMask = {},
		}
		vk.CmdPipelineBarrier2(
			current_frame.vkCommandBuffer,
			&vk.DependencyInfo {
				sType = .DEPENDENCY_INFO,
				imageMemoryBarrierCount = 1,
				pImageMemoryBarriers = &transition_present_barrier,
			},
		)
		vk_check(vk.EndCommandBuffer(current_frame.vkCommandBuffer))


		acquire_wait_info := vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = current_frame.vkAcquireSemaphore,
			stageMask = {.COLOR_ATTACHMENT_OUTPUT},
		}
		semaphore_signals := []vk.SemaphoreSubmitInfo {
			{
				sType = .SEMAPHORE_SUBMIT_INFO,
				semaphore = present_semaphore,
				stageMask = {.ALL_GRAPHICS},
			},
			{
				sType = .SEMAPHORE_SUBMIT_INFO,
				semaphore = globals.timelineSemaphore,
				value = signal_value,
				stageMask = {.ALL_COMMANDS},
			},
		}
		command_submit_info := vk.CommandBufferSubmitInfo {
			sType = .COMMAND_BUFFER_SUBMIT_INFO,
			commandBuffer = current_frame.vkCommandBuffer,
		}
		submit_info := vk.SubmitInfo2 {
			sType = .SUBMIT_INFO_2,
			commandBufferInfoCount = 1,
			pCommandBufferInfos = &command_submit_info,
			waitSemaphoreInfoCount = 1,
			pWaitSemaphoreInfos = &acquire_wait_info,
			signalSemaphoreInfoCount = cast(u32)len(semaphore_signals),
			pSignalSemaphoreInfos = raw_data(semaphore_signals),
		}
		vk_check(vk.QueueSubmit2(globals.vkQueue, 1, &submit_info, {}))

		present_info := vk.PresentInfoKHR {
			sType              = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores    = &present_semaphore,
			pSwapchains        = &globals.swapchain.vkSwapChain,
			pImageIndices      = &image_index,
			swapchainCount     = 1,
		}
		vk_check(vk.QueuePresentKHR(globals.vkQueue, &present_info))

		globals.frameIndex = (globals.frameIndex + 1) % NUM_FRAMES_IN_FLIGHT

	}

	vk_check(vk.DeviceWaitIdle(globals.vkDevice))
	log.info("Exiting application")
}

resize_window :: proc() {
	vk.DeviceWaitIdle(globals.vkDevice)
	destroy_swap_chain()
	create_swap_chain()
}

create_vulkan_instance :: proc() {
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	log.assert(vk.CreateInstance != nil, "Failed to load Vulkan API")

	layers := []cstring{"VK_LAYER_KHRONOS_validation", "VK_LAYER_KHRONOS_shader_object"}

	extensions := slice.concatenate(
		[][]cstring{glfw.GetRequiredInstanceExtensions(), {vk.EXT_DEBUG_UTILS_EXTENSION_NAME}},
		context.temp_allocator,
	)

	debug_messenger_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.VALIDATION, .PERFORMANCE},
		pfnUserCallback = proc "system" (
			messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
			messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
			pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
			pUserData: rawptr,
		) -> b32 {
			context = globals.global_context
			level: log.Level
			if .ERROR in messageSeverity do level = .Error
			else if .WARNING in messageSeverity do level = .Warning
			else if .INFO in messageSeverity do level = .Info
			else do level = .Debug
			log.log(level, pCallbackData.pMessage)
			return false
		},
	}

	pNextExtension: rawptr
	pNextExtension = &debug_messenger_info

	instance_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &{sType = .APPLICATION_INFO, apiVersion = vk.API_VERSION_1_4},
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pNext                   = pNextExtension,
	}

	vk_check(vk.CreateInstance(&instance_info, nil, &globals.vkInstance))
	vk.load_proc_addresses_instance(globals.vkInstance)
	log.assert(vk.DestroyInstance != nil, "Failed to load Vulkan instance API")
	vk_check(
		vk.CreateDebugUtilsMessengerEXT(
			globals.vkInstance,
			&debug_messenger_info,
			nil,
			&globals.vkDebugMessenger,
		),
	)
}

destroy_vulkan_instance :: proc() {
	vk.DestroyDebugUtilsMessengerEXT(globals.vkInstance, globals.vkDebugMessenger, nil)
	vk.DestroyInstance(globals.vkInstance, nil)
}

create_surface :: proc() {
	vk_check(glfw.CreateWindowSurface(globals.vkInstance, globals.window, nil, &globals.vkSurface))
}

destroy_surface :: proc() {
	vk.DestroySurfaceKHR(globals.vkInstance, globals.vkSurface, nil)
}

create_vulkan_device :: proc() {
	device_count: u32
	vk_check(vk.EnumeratePhysicalDevices(globals.vkInstance, &device_count, nil))
	log.assert(device_count > 0, "No GPUs found")
	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_check(vk.EnumeratePhysicalDevices(globals.vkInstance, &device_count, raw_data(devices)))

	candidate_loop: for candidate in devices {
		queue_family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(candidate, &queue_family_count, nil)
		queue_families := make(
			[]vk.QueueFamilyProperties,
			queue_family_count,
			context.temp_allocator,
		)
		vk.GetPhysicalDeviceQueueFamilyProperties(
			candidate,
			&queue_family_count,
			raw_data(queue_families),
		)

		for family, i in queue_families {
			support_graphics := .GRAPHICS in family.queueFlags
			support_compute := .COMPUTE in family.queueFlags
			support_present: b32 = false
			vk_check(
				vk.GetPhysicalDeviceSurfaceSupportKHR(
					candidate,
					u32(i),
					globals.vkSurface,
					&support_present,
				),
			)

			if support_compute && support_graphics && support_present {
				globals.vkFamilyIndex = u32(i)
				globals.vkPhysicalDevice = candidate
				break candidate_loop
			}
		}
	}

	log.assert(globals.vkPhysicalDevice != nil, "No suitable GPU found")

	queue_priority := f32(1.0)
	device_queue_create_info := []vk.DeviceQueueCreateInfo {
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = globals.vkFamilyIndex,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		},
	}

	extensions := []cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		vk.EXT_SHADER_OBJECT_EXTENSION_NAME,
		vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
	}

	features_ext_chain: rawptr
	features_ext_chain = &vk.PhysicalDeviceVulkan14Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
		pNext = features_ext_chain,
	}
	features_ext_chain = &vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
		pNext = features_ext_chain,
	}
	features_ext_chain = &vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		timelineSemaphore = true,
		pNext = features_ext_chain,
	}
	features_ext_chain = &vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters = true,
		pNext = features_ext_chain,
	}
	features_ext_chain = &vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		pNext = features_ext_chain,
		shaderObject = true,
	}


	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = u32(len(device_queue_create_info)),
		pQueueCreateInfos       = raw_data(device_queue_create_info),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pNext                   = features_ext_chain,
	}

	vk_check(
		vk.CreateDevice(globals.vkPhysicalDevice, &device_create_info, nil, &globals.vkDevice),
	)

	vk.load_proc_addresses_device(globals.vkDevice)

	vk.GetDeviceQueue(globals.vkDevice, globals.vkFamilyIndex, 0, &globals.vkQueue)
}

destroy_vulkan_device :: proc() {
	vk.DestroyDevice(globals.vkDevice, nil)
}

create_swap_chain :: proc() {
	width, height := glfw.GetFramebufferSize(globals.window)
	globals.swapchain.width = u32(width)
	globals.swapchain.height = u32(height)

	surface_capabilities: vk.SurfaceCapabilitiesKHR
	vk_check(
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			globals.vkPhysicalDevice,
			globals.vkSurface,
			&surface_capabilities,
		),
	)
	image_count: u32 = max(3, surface_capabilities.minImageCount)
	if surface_capabilities.maxImageCount != 0 do image_count = min(NUM_SWAP_CHAIN_IMAGES, surface_capabilities.maxImageCount)

	surface_formats_count: u32
	vk_check(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			globals.vkPhysicalDevice,
			globals.vkSurface,
			&surface_formats_count,
			nil,
		),
	)
	surface_formats := make([]vk.SurfaceFormatKHR, surface_formats_count, context.temp_allocator)
	vk_check(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			globals.vkPhysicalDevice,
			globals.vkSurface,
			&surface_formats_count,
			raw_data(surface_formats),
		),
	)

	surface_format := surface_formats[0]
	for candidate in surface_formats {
		if candidate == {.B8G8R8A8_SRGB, .SRGB_NONLINEAR} {
			surface_format = candidate
			break
		}
	}
	globals.swapchain.format = surface_format.format

	present_mdoe_count: u32
	vk_check(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			globals.vkPhysicalDevice,
			globals.vkSurface,
			&present_mdoe_count,
			nil,
		),
	)
	present_modes := make([]vk.PresentModeKHR, present_mdoe_count, context.temp_allocator)
	vk_check(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			globals.vkPhysicalDevice,
			globals.vkSurface,
			&present_mdoe_count,
			raw_data(present_modes),
		),
	)
	present_mode := vk.PresentModeKHR.FIFO

	for candidate in present_modes {
		if candidate == .MAILBOX {
			present_mode = candidate
			break
		}
	}


	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = globals.vkSurface,
		minImageCount    = image_count,
		imageFormat      = surface_format.format,
		imageColorSpace  = surface_format.colorSpace,
		imageExtent      = {u32(width), u32(height)},
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = surface_capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
	}


	vk_check(
		vk.CreateSwapchainKHR(
			globals.vkDevice,
			&swapchain_create_info,
			nil,
			&globals.swapchain.vkSwapChain,
		),
	)


	vk_check(
		vk.GetSwapchainImagesKHR(
			globals.vkDevice,
			globals.swapchain.vkSwapChain,
			&globals.swapchain.swapChainImageCount,
			nil,
		),
	)
	globals.swapchain.images = make(
		[]vk.Image,
		globals.swapchain.swapChainImageCount,
		context.allocator,
	)
	vk.GetSwapchainImagesKHR(
		globals.vkDevice,
		globals.swapchain.vkSwapChain,
		&globals.swapchain.swapChainImageCount,
		raw_data(globals.swapchain.images),
	)


	globals.swapchain.image_views = make([]vk.ImageView, image_count, context.allocator)

	for image, i in globals.swapchain.images {
		image_view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = surface_format.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk_check(
			vk.CreateImageView(
				globals.vkDevice,
				&image_view_create_info,
				nil,
				&globals.swapchain.image_views[i],
			),
		)
	}

	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	globals.swapchain.vkPresentSemaphore = make(
		[]vk.Semaphore,
		int(globals.swapchain.swapChainImageCount),
		context.allocator,
	)
	for &semaphore in globals.swapchain.vkPresentSemaphore {
		vk_check(vk.CreateSemaphore(globals.vkDevice, &semaphore_create_info, nil, &semaphore))
	}

	create_depth_buffer()
}

destroy_swap_chain :: proc() {
	destroy_depth_buffer()
	for semaphore in globals.swapchain.vkPresentSemaphore do vk.DestroySemaphore(globals.vkDevice, semaphore, nil)
	delete(globals.swapchain.vkPresentSemaphore)
	for image_view in globals.swapchain.image_views do vk.DestroyImageView(globals.vkDevice, image_view, nil)
	vk.DestroySwapchainKHR(globals.vkDevice, globals.swapchain.vkSwapChain, nil)
	delete(globals.swapchain.images)
	delete(globals.swapchain.image_views)
}

create_depth_buffer :: proc() {
	depth_buffer_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = .D32_SFLOAT,
		extent = vk.Extent3D {
			width = globals.swapchain.width,
			height = globals.swapchain.height,
			depth = 1,
		},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
		initialLayout = .UNDEFINED,
	}

	depth_buffer_allocation_info := vma.AllocationCreateInfo {
		usage = .AUTO,
		flags = {.DEDICATED_MEMORY},
	}

	vk_check(
		vma.CreateImage(
			globals.vmaAllocator,
			depth_buffer_create_info,
			depth_buffer_allocation_info,
			&globals.depthBuffer.vkImage,
			&globals.depthBuffer.vmaAllocation,
			nil,
		),
	)

	depth_buffer_view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = globals.depthBuffer.vkImage,
		viewType = .D2,
		format = depth_buffer_create_info.format,
		subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}
	vk_check(
		vk.CreateImageView(
			globals.vkDevice,
			&depth_buffer_view_create_info,
			nil,
			&globals.depthBuffer.vkImageView,
		),
	)
	globals.depthBuffer.format = depth_buffer_create_info.format
}

destroy_depth_buffer :: proc() {
	vk.DestroyImageView(globals.vkDevice, globals.depthBuffer.vkImageView, nil)
	vma.DestroyImage(
		globals.vmaAllocator,
		globals.depthBuffer.vkImage,
		globals.depthBuffer.vmaAllocation,
	)
}

create_frames :: proc() {
	// timeline semaphore
	timeline_semaphore_create_info := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue  = NUM_FRAMES_IN_FLIGHT,
	}
	timeline_semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &timeline_semaphore_create_info,
	}
	vk_check(
		vk.CreateSemaphore(
			globals.vkDevice,
			&timeline_semaphore_info,
			nil,
			&globals.timelineSemaphore,
		),
	)

	for &frame in globals.frames {

		// command pool
		command_pool_create_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			queueFamilyIndex = globals.vkFamilyIndex,
			flags            = {.TRANSIENT},
		}
		vk_check(
			vk.CreateCommandPool(
				globals.vkDevice,
				&command_pool_create_info,
				nil,
				&frame.vkCommandPool,
			),
		)

		// command buffer
		command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandBufferCount = 1,
			commandPool        = frame.vkCommandPool,
			level              = .PRIMARY,
		}
		vk_check(
			vk.AllocateCommandBuffers(
				globals.vkDevice,
				&command_buffer_allocate_info,
				&frame.vkCommandBuffer,
			),
		)

		// fence
		fence_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		vk_check(vk.CreateFence(globals.vkDevice, &fence_create_info, nil, &frame.vkFrameFence))

		// semaphore
		semaphore_create_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(
			vk.CreateSemaphore(
				globals.vkDevice,
				&semaphore_create_info,
				nil,
				&frame.vkAcquireSemaphore,
			),
		)
	}
}

destroy_frames :: proc() {
	vk.DestroySemaphore(globals.vkDevice, globals.timelineSemaphore, nil)
	for &frame in globals.frames {
		vk.DestroySemaphore(globals.vkDevice, frame.vkAcquireSemaphore, nil)
		vk.DestroyFence(globals.vkDevice, frame.vkFrameFence, nil)
		vk.FreeCommandBuffers(globals.vkDevice, frame.vkCommandPool, 1, &frame.vkCommandBuffer)
		vk.DestroyCommandPool(globals.vkDevice, frame.vkCommandPool, nil)
	}
}

create_vma_allocator :: proc() {
	vma_vulkan_functions := vma.create_vulkan_functions()
	vma_allocator_create_info := vma.AllocatorCreateInfo {
		flags            = {},
		physicalDevice   = globals.vkPhysicalDevice,
		device           = globals.vkDevice,
		instance         = globals.vkInstance,
		pVulkanFunctions = &vma_vulkan_functions,
		vulkanApiVersion = vk.API_VERSION_1_4,
	}

	vk_check(vma.CreateAllocator(vma_allocator_create_info, &globals.vmaAllocator))
}

destroy_vma_allocator :: proc() {
	// Implementation for destroying the VMA allocator goes here
	vma.DestroyAllocator(globals.vmaAllocator)
}

create_shader_objects :: proc() {
	shader_code := load_file("./triangle.spv", context.temp_allocator)

	sm_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_code),
		pCode    = auto_cast (&shader_code[0]),
	}

	vk_check(vk.CreateShaderModule(globals.vkDevice, &sm_info, nil, &globals.triangleShader))

}

destroy_shader_objects :: proc() {
	vk.DestroyShaderModule(globals.vkDevice, globals.triangleShader, nil)
}

create_graphics_pipeline :: proc() {
	pipeline_shader_stage_create_infos := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = globals.triangleShader,
			pName = "vertexMain",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = globals.triangleShader,
			pName = "fragmentMain",
		},
	}

	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	vk_check(
		vk.CreatePipelineLayout(
			globals.vkDevice,
			&pipeline_layout_create_info,
			nil,
			&globals.pipelineLayout,
		),
	)

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_create_infos := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = cast(u32)len(dynamic_states),
		pDynamicStates    = raw_data(dynamic_states),
	}
	rasterization_state_create_info := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {.BACK},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1.0,
	}

	color_blending_state_create_info := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &vk.PipelineColorBlendAttachmentState {
			colorWriteMask = {.R, .G, .B, .A},
			blendEnable = false,
		},
	}

	view_port_state_create_info := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	multisample_state_create_info := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	swapchain_image_format := globals.swapchain.image_views[0]
	pipeline_rendering_create_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &globals.swapchain.format,
		depthAttachmentFormat   = globals.depthBuffer.format,
	}

	vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	depth_stencil_state_create_info := vk.PipelineDepthStencilStateCreateInfo {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = true,
		depthWriteEnable      = true,
		depthCompareOp        = .LESS,
		depthBoundsTestEnable = false,
		stencilTestEnable     = false,
	}

	graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = cast(u32)len(pipeline_shader_stage_create_infos),
		pStages             = raw_data(pipeline_shader_stage_create_infos),
		pViewportState      = &view_port_state_create_info,
		pRasterizationState = &rasterization_state_create_info,
		pMultisampleState   = &multisample_state_create_info,
		pColorBlendState    = &color_blending_state_create_info,
		pDynamicState       = &dynamic_state_create_infos,
		layout              = globals.pipelineLayout,
		pNext               = &pipeline_rendering_create_info,
		pVertexInputState   = &vertex_input_state_create_info,
		pInputAssemblyState = &input_assembly_state_create_info,
		pDepthStencilState  = &depth_stencil_state_create_info,
		renderPass          = {},
	}

	vk_check(
		vk.CreateGraphicsPipelines(
			globals.vkDevice,
			{},
			1,
			&graphics_pipeline_create_info,
			nil,
			&globals.graphicsPipeline,
		),
	)
}

destroy_graphics_pipeline :: proc() {
	vk.DestroyPipelineLayout(globals.vkDevice, globals.pipelineLayout, nil)
	vk.DestroyPipeline(globals.vkDevice, globals.graphicsPipeline, nil)
}

