package engine

import "base:runtime"
import "core:c"
import "core:log"
import glm "core:math/linalg/glsl"
import "core:slice"
import vma "shared:vma"
import "vendor:glfw"
import vk "vendor:vulkan"

DESCRIPTOR_SET_BINDING_COUNT :: 22 // VS-11: +19 (template_uvs); VS-13: +20 (mirror_heightmap_ring); VS-20: +21 (target_highlight, UBO dinâmico)
PUSH_CONSTANTS_SIZE :: 92 // VS-08 (REQ-CFG-06): + visible_chunk_capacity

REQUIRED_DEVICE_EXTENSIONS :: []cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	vk.EXT_MESH_SHADER_EXTENSION_NAME,
	vk.EXT_SHADER_OBJECT_EXTENSION_NAME,
	vk.EXT_MEMORY_BUDGET_EXTENSION_NAME,
}

DeviceFeatureChain :: struct {
	base:          vk.PhysicalDeviceFeatures,
	v11:           vk.PhysicalDeviceVulkan11Features,
	v12:           vk.PhysicalDeviceVulkan12Features,
	v13:           vk.PhysicalDeviceVulkan13Features,
	v14:           vk.PhysicalDeviceVulkan14Features,
	shader_object: vk.PhysicalDeviceShaderObjectFeaturesEXT,
	mesh_shader:   vk.PhysicalDeviceMeshShaderFeaturesEXT,
}

@(private)
create_vulkan_instance :: proc() {
	log.info("Creating Vulkan instance")
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	log.assert(vk.CreateInstance != nil, "Failed to load Vulkan API")

	requested_layers := []cstring{"VK_LAYER_KHRONOS_validation"}
	layers := make([dynamic]cstring, 0, len(requested_layers), context.temp_allocator)
	available_layer_count: u32
	vk_check(vk.EnumerateInstanceLayerProperties(&available_layer_count, nil))
	available_layers := make([]vk.LayerProperties, available_layer_count, context.temp_allocator)
	vk_check(vk.EnumerateInstanceLayerProperties(&available_layer_count, raw_data(available_layers)))
	for requested in requested_layers {
		found := false
		for &available in available_layers {
			if string(cstring(&available.layerName[0])) == string(requested) {
				found = true
				break
			}
		}
		if found {
			append(&layers, requested)
		} else {
			log.warnf("Validation layer {} ausente; continuando sem validation", requested)
		}
	}
	app.validationLayersEnabled = len(layers) > 0
	if app.validationLayersEnabled {
		log.infof("Validation layers ativas: {}", layers[:])
	}

	extensions := make([dynamic]cstring, 0, 8, context.temp_allocator)
	append(&extensions, ..glfw.GetRequiredInstanceExtensions())
	append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	if app.validationLayersEnabled {
		append(&extensions, vk.EXT_VALIDATION_FEATURES_EXTENSION_NAME)
	}

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

	enabled_features := []vk.ValidationFeatureEnableEXT{.SYNCHRONIZATION_VALIDATION}
	validation_features := vk.ValidationFeaturesEXT {
		sType                          = .VALIDATION_FEATURES_EXT,
		pNext                          = &debug_messenger_info,
		enabledValidationFeatureCount  = u32(len(enabled_features)),
		pEnabledValidationFeatures     = raw_data(enabled_features),
	}

	pNextExtension: rawptr = &debug_messenger_info
	if app.validationLayersEnabled {
		pNextExtension = &validation_features
	}

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
init_device_feature_chain :: proc(chain: ^DeviceFeatureChain) {
	chain.base = {
		shaderInt16 = true,
	}
	chain.v11 = {
		sType                 = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters  = true,
		storageBuffer16BitAccess = true,
		uniformAndStorageBuffer16BitAccess = true,
	}
	chain.v12 = {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext            = &chain.v11,
		timelineSemaphore = true,
		scalarBlockLayout = true,
	}
	chain.v13 = {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &chain.v12,
		dynamicRendering = true,
		synchronization2 = true,
	}
	chain.v14 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
		pNext = &chain.v13,
	}
	chain.shader_object = {
		sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		pNext        = &chain.v14,
		shaderObject = true,
	}
	chain.mesh_shader = {
		sType      = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
		pNext      = &chain.shader_object,
		meshShader = true,
		taskShader = true,
	}
}

@(private)
collect_missing_features :: proc(chain: ^DeviceFeatureChain, missing: ^[dynamic]string) {
	if !chain.base.shaderInt16 do append(missing, "shaderInt16")
	if !chain.v11.shaderDrawParameters do append(missing, "shaderDrawParameters")
	if !chain.v11.storageBuffer16BitAccess do append(missing, "storageBuffer16BitAccess")
	if !chain.v11.uniformAndStorageBuffer16BitAccess do append(missing, "uniformAndStorageBuffer16BitAccess")
	if !chain.v12.timelineSemaphore do append(missing, "timelineSemaphore")
	if !chain.v12.scalarBlockLayout do append(missing, "scalarBlockLayout")
	if !chain.v13.dynamicRendering do append(missing, "dynamicRendering")
	if !chain.v13.synchronization2 do append(missing, "synchronization2")
	if !chain.shader_object.shaderObject do append(missing, "shaderObject")
	if !chain.mesh_shader.meshShader do append(missing, "meshShader")
	if !chain.mesh_shader.taskShader do append(missing, "taskShader")
}

@(private)
query_device_features :: proc(device: vk.PhysicalDevice) -> DeviceFeatureChain {
	chain: DeviceFeatureChain
	chain.v11.sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
	chain.v12 = {sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, pNext = &chain.v11}
	chain.v13 = {sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, pNext = &chain.v12}
	chain.v14 = {sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, pNext = &chain.v13}
	chain.shader_object = {sType = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT, pNext = &chain.v14}
	chain.mesh_shader = {sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT, pNext = &chain.shader_object}
	features2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &chain.mesh_shader,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features2)
	chain.base = features2.features
	return chain
}

@(private)
collect_missing_extensions :: proc(device: vk.PhysicalDevice, missing: ^[dynamic]string) {
	count: u32
	vk_check(vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil))
	available := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk_check(vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available)))

	for required in REQUIRED_DEVICE_EXTENSIONS {
		found := false
		for &ext in available {
			if string(cstring(&ext.extensionName[0])) == string(required) {
				found = true
				break
			}
		}
		if !found do append(missing, string(required))
	}
}

@(private)
create_vulkan_device :: proc() {
	log.info("Creating Vulkan device")
	if !select_physical_device() {
		log.panic("Nenhum dispositivo Vulkan atende aos requisitos obrigatórios (ver diagnóstico acima)")
	}
	log.info("Selected physical device successfully")

	queue_priorities: f32 = 1.0
	queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, 2, context.temp_allocator)
	append(&queue_create_infos, vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = app.queues[.Graphics].familyIndex,
		queueCount       = 1,
		pQueuePriorities = &queue_priorities,
	})
	compute_family := app.queues[.Compute].familyIndex
	if compute_family != app.queues[.Graphics].familyIndex {
		append(&queue_create_infos, vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = compute_family,
			queueCount       = 1,
			pQueuePriorities = &queue_priorities,
		})
	}

	extensions := []cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		vk.EXT_SHADER_OBJECT_EXTENSION_NAME,
		vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
		vk.EXT_MESH_SHADER_EXTENSION_NAME,
		vk.KHR_SHADER_FLOAT_CONTROLS_EXTENSION_NAME,
		vk.KHR_SPIRV_1_4_EXTENSION_NAME,
		vk.EXT_MEMORY_BUDGET_EXTENSION_NAME,
	}

	enabled_features: DeviceFeatureChain
	init_device_feature_chain(&enabled_features)

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = u32(len(queue_create_infos)),
		pQueueCreateInfos       = raw_data(queue_create_infos),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pNext                   = &enabled_features.mesh_shader,
		pEnabledFeatures        = &enabled_features.base,
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
	vk.GetDeviceQueue(
		app.vkDevice,
		app.queues[.Compute].familyIndex,
		0,
		&app.queues[.Compute].queue,
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
		flags            = {.EXT_MEMORY_BUDGET},
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
	create_timeline :: proc(device: vk.Device, initial: u64, semaphore: ^vk.Semaphore) {
		type_info := vk.SemaphoreTypeCreateInfo {
			sType         = .SEMAPHORE_TYPE_CREATE_INFO,
			semaphoreType = .TIMELINE,
			initialValue  = initial,
		}
		info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
			pNext = &type_info,
		}
		vk_check(vk.CreateSemaphore(device, &info, nil, semaphore))
	}
	create_timeline(app.vkDevice, NUM_FRAMES_IN_FLIGHT, &app.timelineSemaphore)
	create_timeline(app.vkDevice, 0, &app.computeTimelineSemaphore)
	log.info("Sync objects created successfully")
}

@(private)
destroy_sync_objects :: proc() {
	log.info("Destroying sync objects")
	vk.DestroySemaphore(app.vkDevice, app.timelineSemaphore, nil)
	vk.DestroySemaphore(app.vkDevice, app.computeTimelineSemaphore, nil)
	log.info("Sync objects destroyed successfully")
}

@(private)
create_descriptor_layouts :: proc() {
	log.info("Creating descriptor set and pipeline layouts")

	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(app.vkPhysicalDevice, &properties)
	if properties.limits.maxDescriptorSetStorageBuffers < DESCRIPTOR_SET_BINDING_COUNT {
		log.panicf(
			"Dispositivo suporta apenas {} storage buffers por descriptor set (necessários {})",
			properties.limits.maxDescriptorSetStorageBuffers,
			DESCRIPTOR_SET_BINDING_COUNT,
		)
	}
	if properties.limits.maxPushConstantsSize < PUSH_CONSTANTS_SIZE {
		log.panicf(
			"Dispositivo suporta apenas {} B de push constants (necessários {} B)",
			properties.limits.maxPushConstantsSize,
			PUSH_CONSTANTS_SIZE,
		)
	}

	shader_stages := vk.ShaderStageFlags{.COMPUTE, .MESH_EXT, .FRAGMENT}
	bindings: [DESCRIPTOR_SET_BINDING_COUNT]vk.DescriptorSetLayoutBinding
	for &binding, i in bindings {
		binding = {
			binding         = u32(i),
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags      = shader_stages,
		}
	}

	bindings[8].descriptorType = .COMBINED_IMAGE_SAMPLER
	bindings[9].descriptorType = .COMBINED_IMAGE_SAMPLER
	// VS-20 (REQ-GPL-03): UBO dinâmico do realce — offset por frame no bind,
	// visível só ao fragment; demais bindings permanecem STORAGE_BUFFER.
	bindings[21] = {
		binding         = 21,
		descriptorType  = .UNIFORM_BUFFER_DYNAMIC,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	set_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings    = raw_data(&bindings),
	}
	vk_check(
		vk.CreateDescriptorSetLayout(app.vkDevice, &set_layout_info, nil, &app.descriptorSetLayout),
	)

	set_layouts := []vk.DescriptorSetLayout{app.descriptorSetLayout}
	graphics_push_range := vk.PushConstantRange {
		stageFlags = {.MESH_EXT, .FRAGMENT},
		offset     = 0,
		size       = PUSH_CONSTANTS_SIZE,
	}
	graphics_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = u32(len(set_layouts)),
		pSetLayouts            = raw_data(set_layouts),
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &graphics_push_range,
	}
	vk_check(
		vk.CreatePipelineLayout(app.vkDevice, &graphics_layout_info, nil, &app.graphicsPipelineLayout),
	)

	compute_push_range := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		offset     = 0,
		size       = PUSH_CONSTANTS_SIZE,
	}
	compute_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = u32(len(set_layouts)),
		pSetLayouts            = raw_data(set_layouts),
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &compute_push_range,
	}
	vk_check(
		vk.CreatePipelineLayout(app.vkDevice, &compute_layout_info, nil, &app.computePipelineLayout),
	)
	log.info("Descriptor set and pipeline layouts created successfully")
}

@(private)
destroy_descriptor_layouts :: proc() {
	log.info("Destroying descriptor set and pipeline layouts")
	vk.DestroyPipelineLayout(app.vkDevice, app.computePipelineLayout, nil)
	vk.DestroyPipelineLayout(app.vkDevice, app.graphicsPipelineLayout, nil)
	vk.DestroyDescriptorSetLayout(app.vkDevice, app.descriptorSetLayout, nil)
	log.info("Descriptor set and pipeline layouts destroyed successfully")
}

@(private)
create_frame_data :: proc() {
	log.info("Creating frame data")
	for &frame in app.frameData {

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
select_physical_device :: proc() -> bool {
	device_count: u32
	vk_check(vk.EnumeratePhysicalDevices(app.vkInstance, &device_count, nil))
	if device_count == 0 {
		log.error("Nenhuma GPU Vulkan encontrada")
		return false
	}
	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_check(vk.EnumeratePhysicalDevices(app.vkInstance, &device_count, raw_data(devices)))

	for candidate in devices {
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(candidate, &properties)
		name := string(cstring(&properties.deviceName[0]))

		missing := make([dynamic]string, context.temp_allocator)
		collect_missing_extensions(candidate, &missing)
		features := query_device_features(candidate)
		collect_missing_features(&features, &missing)

		graphics_family, compute_family, queues_ok := find_queue_families(candidate)
		if !queues_ok {
			append(&missing, "fila gráfica com suporte a present")
		}

		if len(missing) > 0 {
			log.errorf("Dispositivo rejeitado: {} — faltando: {}", name, missing[:])
			continue
		}

		app.vkPhysicalDevice = candidate
		app.queues[.Graphics] = QueueTuple{familyIndex = u32(graphics_family)}
		app.queues[.Compute] = QueueTuple{familyIndex = u32(compute_family)}
		log.infof("Dispositivo selecionado: {} (todas as capabilities obrigatórias presentes)", name)

		if compute_family == graphics_family {
			log.warn("Sem família de compute dedicada; fila de compute compartilha a família gráfica")
		} else {
			log.infof("Fila de compute dedicada na família {}", compute_family)
		}
		return true
	}

	return false
}

@(private)
find_queue_families :: proc(device: vk.PhysicalDevice) -> (graphics, compute: int, ok: bool) {
	graphics = -1
	compute = -1
	queue_families := list_queue_families(device)
	for family, i in queue_families {
		support_present: b32
		vk_check(
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), app.vkSurface, &support_present),
		)
		if graphics == -1 &&
		   .GRAPHICS in family.queueFlags &&
		   .COMPUTE in family.queueFlags &&
		   support_present {
			graphics = i
		}
		if compute == -1 && .COMPUTE in family.queueFlags && .GRAPHICS not_in family.queueFlags {
			compute = i
		}
	}
	if graphics == -1 {
		return -1, -1, false
	}
	if compute == -1 {
		compute = graphics
	}
	return graphics, compute, true
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
