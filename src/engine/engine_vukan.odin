package engine

import glm "core:math/linalg/glsl"
import vma "shared:vma"
import vk "vendor:vulkan"


import "base:runtime"
import "core:c"
import "core:log"
import "core:slice"
import "vendor:glfw"

@(private)
create_vulkan_instance :: proc() {
	log.info("Creating Vulkan instance")
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
			context = app.runtimeContext
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

	vk_check(vk.CreateInstance(&instance_info, nil, &app.vkInstance))
	vk.load_proc_addresses_instance(app.vkInstance)
	log.assert(vk.DestroyInstance != nil, "Failed to load Vulkan instance API")
	vk_check(
		vk.CreateDebugUtilsMessengerEXT(
			app.vkInstance,
			&debug_messenger_info,
			nil,
			&app.vkDebugMessenger,
		),
	)
	log.info("Vulkan instance created successfully")
}

@(private)
destroy_vulkan_instance :: proc() {
	log.info("Destroying Vulkan instance")
	vk.DestroyDebugUtilsMessengerEXT(app.vkInstance, app.vkDebugMessenger, nil)
	vk.DestroyInstance(app.vkInstance, nil)
	log.info("Vulkan instance destroyed successfully")
}

@(private)
create_vulkan_surface :: proc() {
	log.info("Creating Vulkan surface")
	vk_check(glfw.CreateWindowSurface(app.vkInstance, app.glfwWindow, nil, &app.vkSurface))
	log.info("Vulkan surface created successfully")
}

@(private)
destroy_vulkan_surface :: proc() {
	log.info("Destroying Vulkan surface")
	vk.DestroySurfaceKHR(app.vkInstance, app.vkSurface, nil)
	log.info("Vulkan surface destroyed successfully")
}

@(private)
create_vulkan_device :: proc() {
	log.info("Creating Vulkan device")
	app.vkPhysicalDevice = select_physical_device()
	log.info("Selected physical device successfully")

	queue_priorities: f32 = 1.0
	presenting_queue_create_info := []vk.DeviceQueueCreateInfo {
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = app.queues[.Graphics].familyIndex,
			queueCount = 1,
			pQueuePriorities = &queue_priorities,
		},
	}

	extensions := []cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		vk.EXT_SHADER_OBJECT_EXTENSION_NAME,
		vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
		vk.EXT_MESH_SHADER_EXTENSION_NAME,
		vk.KHR_SHADER_FLOAT_CONTROLS_EXTENSION_NAME,
		vk.KHR_SPIRV_1_4_EXTENSION_NAME 
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
	features_ext_chain = &vk.PhysicalDeviceMeshShaderFeaturesEXT{
		sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
		meshShader = true,
		taskShader = true,
		pNext = features_ext_chain
	}

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = u32(len(presenting_queue_create_info)),
		pQueueCreateInfos       = raw_data(presenting_queue_create_info),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pNext                   = features_ext_chain,
	}

	vk_check(vk.CreateDevice(app.vkPhysicalDevice, &device_create_info, nil, &app.vkDevice))

	vk.load_proc_addresses_device(app.vkDevice)
	log.info("Functions loaded successfully")
	vk.GetDeviceQueue(
		app.vkDevice,
		app.queues[.Graphics].familyIndex,
		0,
		&app.queues[.Graphics].queue,
	)
	log.info("Vulkan device created successfully")
}

@(private)
destroy_vulkan_device :: proc() {
	log.info("Destroying Vulkan device")
	vk.DestroyDevice(app.vkDevice, nil)
	log.info("Vulkan device destroyed successfully")
}

@(private)
create_swap_chain :: proc() {
	log.info("Creating swap chain")
	width, height := glfw.GetFramebufferSize(app.glfwWindow)
	app.windowWidth = u32(width)
	app.windowHeight = u32(height)


	surface_capabilities, image_count := get_swap_chain_capabilities()
	surface_format := select_surface_format()
	present_mode := select_present_mode()

	app.presentation = {
		width  = u32(width),
		height = u32(height),
		format = surface_format.format,
	}

	swap_chain_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = app.vkSurface,
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
			app.vkDevice,
			&swap_chain_create_info,
			nil,
			&app.presentation.vkSwapChain,
		),
	)

	setup_swap_chain_frames()
	log.info("Swap chain created successfully")
}

@(private)
destroy_swap_chain :: proc() {
	log.info("Destroying swap chain")
	for frame in app.presentation.frames {
		vk.DestroyImageView(app.vkDevice, frame.image_view, nil)
		vk.DestroySemaphore(app.vkDevice, frame.vkPresentSemaphore, nil)
	}
	vk.DestroySwapchainKHR(app.vkDevice, app.presentation.vkSwapChain, nil)
	delete(app.presentation.frames)
	log.info("Swap chain destroyed successfully")
}

@(private)
create_vma_allocator :: proc() {
	log.info("Creating VMA allocator")
	vma_functions := vma.create_vulkan_functions()
	allocator_create_info := vma.AllocatorCreateInfo {
		flags            = {},
		physicalDevice   = app.vkPhysicalDevice,
		device           = app.vkDevice,
		instance         = app.vkInstance,
		pVulkanFunctions = &vma_functions,
		vulkanApiVersion = vk.API_VERSION_1_4,
	}
	vk_check(vma.CreateAllocator(allocator_create_info, &app.vmaAllocator))
	log.info("VMA allocator created successfully")
}

@(private)
destroy_vma_allocator :: proc() {
	log.info("Destroying VMA allocator")
	vma.DestroyAllocator(app.vmaAllocator)
	log.info("VMA allocator destroyed successfully")
}

@(private)
create_depth_buffer :: proc() {
	log.info("Creating depth buffer")
	depth_buffer_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = .D32_SFLOAT,
		extent = vk.Extent3D {
			width = app.presentation.width,
			height = app.presentation.height,
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
			app.vmaAllocator,
			depth_buffer_create_info,
			depth_buffer_allocation_info,
			&app.depthBuffer.vkImage,
			&app.depthBuffer.vmaAllocation,
			nil,
		),
	)

	depth_buffer_view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = app.depthBuffer.vkImage,
		viewType = .D2,
		format = depth_buffer_create_info.format,
		subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}
	vk_check(
		vk.CreateImageView(
			app.vkDevice,
			&depth_buffer_view_create_info,
			nil,
			&app.depthBuffer.vkImageView,
		),
	)
	app.depthBuffer.format = depth_buffer_create_info.format
	log.info("Depth buffer created successfully")
}

@(private)
destroy_depth_buffer :: proc() {
	log.info("Destroying depth buffer")
	vk.DestroyImageView(app.vkDevice, app.depthBuffer.vkImageView, nil)
	vma.DestroyImage(app.vmaAllocator, app.depthBuffer.vkImage, app.depthBuffer.vmaAllocation)
	log.info("Depth buffer destroyed successfully")
}

@(private)
create_sync_objects :: proc() {
	log.info("Creating sync objects")
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
		vk.CreateSemaphore(app.vkDevice, &timeline_semaphore_info, nil, &app.timelineSemaphore),
	)
	log.info("Sync objects created successfully")
}

@(private)
destroy_sync_objects :: proc() {
	log.info("Destroying sync objects")
	vk.DestroySemaphore(app.vkDevice, app.timelineSemaphore, nil)
	log.info("Sync objects destroyed successfully")
}

@(private)
create_frame_data :: proc() {
	log.info("Creating frame data")
	for &frame in app.frameData {

		// command pool
		command_pool_create_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			queueFamilyIndex = app.queues[QueueType.Graphics].familyIndex,
			flags            = {.TRANSIENT},
		}
		vk_check(
			vk.CreateCommandPool(
				app.vkDevice,
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
				app.vkDevice,
				&command_buffer_allocate_info,
				&frame.vkCommandBuffer,
			),
		)

		// semaphore
		semaphore_create_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(
			vk.CreateSemaphore(
				app.vkDevice,
				&semaphore_create_info,
				nil,
				&frame.vkAcquireSemaphore,
			),
		)
	}
	log.info("Frame data created successfully")
}

@(private)
destroy_frame_data :: proc() {
	log.info("Destroying frame data")
	for &frame in app.frameData {
		vk.DestroySemaphore(app.vkDevice, frame.vkAcquireSemaphore, nil)
		vk.FreeCommandBuffers(app.vkDevice, frame.vkCommandPool, 1, &frame.vkCommandBuffer)
		vk.DestroyCommandPool(app.vkDevice, frame.vkCommandPool, nil)
	}
	log.info("Frame data destroyed successfully")
}

@(private)
select_physical_device :: proc() -> vk.PhysicalDevice {
	device_count: u32
	vk_check(vk.EnumeratePhysicalDevices(app.vkInstance, &device_count, nil))
	log.assert(device_count > 0, "No GPUs found")
	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_check(vk.EnumeratePhysicalDevices(app.vkInstance, &device_count, raw_data(devices)))

	selected_device: vk.PhysicalDevice = nil

	candidate_loop: for candidate in devices {

		queue_families := list_queue_families(candidate)

		for family, i in queue_families {
			suitable := is_queue_family_suitable(candidate, u32(i), family)

			if suitable {
				app.queues[.Graphics] = QueueTuple {
					queue       = {},
					familyIndex = u32(i),
				}
				selected_device = candidate
				break candidate_loop
			}
		}
	}

	log.assert(selected_device != nil, "No suitable GPU found")
	return selected_device
}

@(private)
list_queue_families :: proc(device: vk.PhysicalDevice) -> []vk.QueueFamilyProperties {
	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)
	return queue_families
}

@(private)
is_queue_family_suitable :: proc(
	physical_device: vk.PhysicalDevice,
	family_index: u32,
	family: vk.QueueFamilyProperties,
) -> b32 {
	support_present: b32 = false
	vk_check(
		vk.GetPhysicalDeviceSurfaceSupportKHR(
			physical_device,
			family_index,
			app.vkSurface,
			&support_present,
		),
	)

	return (.GRAPHICS in family.queueFlags) && (.COMPUTE in family.queueFlags) && support_present
}

@(private)
build_feature_chain :: proc() -> rawptr {
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

	return features_ext_chain
}

@(private)
select_surface_format :: proc() -> vk.SurfaceFormatKHR {
	formats_count: u32
	vk_check(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			app.vkPhysicalDevice,
			app.vkSurface,
			&formats_count,
			nil,
		),
	)
	formats := make([]vk.SurfaceFormatKHR, formats_count, context.temp_allocator)
	vk_check(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			app.vkPhysicalDevice,
			app.vkSurface,
			&formats_count,
			raw_data(formats),
		),
	)

	for candidate in formats {
		if candidate == {.B8G8R8A8_SRGB, .SRGB_NONLINEAR} {
			return candidate
		}
	}

	return formats[0]
}

@(private)
select_present_mode :: proc() -> vk.PresentModeKHR {
	present_modes_count: u32
	vk_check(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			app.vkPhysicalDevice,
			app.vkSurface,
			&present_modes_count,
			nil,
		),
	)
	present_modes := make([]vk.PresentModeKHR, present_modes_count, context.temp_allocator)
	vk_check(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			app.vkPhysicalDevice,
			app.vkSurface,
			&present_modes_count,
			raw_data(present_modes),
		),
	)

	for candidate in present_modes {
		if candidate == .MAILBOX {
			return candidate
		}
	}

	return .FIFO
}

@(private)
get_swap_chain_capabilities :: proc() -> (vk.SurfaceCapabilitiesKHR, u32) {
	surface_capabilities: vk.SurfaceCapabilitiesKHR
	vk_check(
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			app.vkPhysicalDevice,
			app.vkSurface,
			&surface_capabilities,
		),
	)

	image_count: u32 = max(3, surface_capabilities.minImageCount)
	if surface_capabilities.maxImageCount != 0 do image_count = min(NUM_SWAP_CHAIN_IMAGES, surface_capabilities.maxImageCount)
	return surface_capabilities, image_count
}

@(private)
setup_swap_chain_frames :: proc() {
	images_count: u32
	vk_check(
		vk.GetSwapchainImagesKHR(app.vkDevice, app.presentation.vkSwapChain, &images_count, nil),
	)

	app.presentation.frames = make([]SwapChainFrameData, images_count)
	images := make([]vk.Image, images_count, context.temp_allocator)

	vk_check(
		vk.GetSwapchainImagesKHR(
			app.vkDevice,
			app.presentation.vkSwapChain,
			&images_count,
			raw_data(images),
		),
	)


	app.presentation.swapChainImageCount = images_count

	for image, i in images {

		image_view: vk.ImageView
		image_view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = app.presentation.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}

		vk_check(vk.CreateImageView(app.vkDevice, &image_view_create_info, nil, &image_view))

		semaphore: vk.Semaphore
		semaphore_create_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(vk.CreateSemaphore(app.vkDevice, &semaphore_create_info, nil, &semaphore))

		app.presentation.frames[i] = SwapChainFrameData {
			image              = image,
			image_view         = image_view,
			vkPresentSemaphore = semaphore,
		}
	}
}
