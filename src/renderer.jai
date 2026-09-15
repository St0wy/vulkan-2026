
MAX_FRAMES_IN_FLIGHT :: 2;

Vulkan_Shader_Data :: struct {
	projection: Matrix4;
	view: Matrix4;
	model: [3] Matrix4;
	light_pos: Vector4 = {0, -10, 10, 0};
	selected: u32 = 1;
}

Shader_Data_Buffer :: struct {
	allocation: VmaAllocation;
	allocation_info: VmaAllocationInfo;
	buffer: VkBuffer;
	device_address: VkDeviceAddress;
}

Vulkan_Texture :: struct {
	allocation: VmaAllocation;
	image: VkImage;
	view: VkImageView;
	sampler: VkSampler;
}

// Verticies and indicies are stored in the same buffer
Vulkan_Mesh :: struct {
	mesh_buffer: VkBuffer;
	mesh_buffer_allocation: VmaAllocation;
}

Vulkan_Context :: struct {
	instance: VkInstance;
	debug_utils_messenger: VkDebugUtilsMessengerEXT;
	physical_device: VkPhysicalDevice;
	device: VkDevice;
	queue: VkQueue;
	allocator: VmaAllocator;
	surface: VkSurfaceKHR;
	window: Window_Type;
	swapchain_image_format: VkFormat;
	swapchain: VkSwapchainKHR;
	swapchain_images: [] VkImage;
	swapchain_image_views: [] VkImageView;
	render_complete_semaphores: [] VkSemaphore;
	window_size: VkExtent2D;
	depth_image_format: VkFormat;
	depth_image: VkImage;
	depth_image_allocation: VmaAllocation;
	depth_image_view: VkImageView;
	shader_data_buffers: [MAX_FRAMES_IN_FLIGHT] Shader_Data_Buffer;
	command_buffers: [MAX_FRAMES_IN_FLIGHT] VkCommandBuffer;
	fences: [MAX_FRAMES_IN_FLIGHT] VkFence;
	image_acquired_semaphores: [MAX_FRAMES_IN_FLIGHT] VkSemaphore;
	shader_data: Vulkan_Shader_Data;
	shader_module: VkShaderModule;
	command_pool: VkCommandPool;
	queue_family: u32;
	textures: [3] Vulkan_Texture;
	descriptor_set_layout_tex: VkDescriptorSetLayout;
	descriptor_pool: VkDescriptorPool;
	descriptor_set_tex: VkDescriptorSet;
	pipeline_layout: VkPipelineLayout;
	pipeline: VkPipeline;
	frame_index: u32;
	image_index: u32;
	update_swapchain: bool;
}

vulkan_init :: (
	using vk_context: *Vulkan_Context,
	handle: Window_Type,
	$want_validation_layers := true,
	$want_debug_extensions := true,
) {
	vk_context.window = handle;

	load_vulkan("vulkan-1.dll");

	enabled_layers := make_temp_dyn_array(string);
	validation_enabled := false;
	{
		desired_instance_layers := make_temp_dyn_array(string);
		#if want_validation_layers then array_add(*desired_instance_layers, "VK_LAYER_KHRONOS_validation");

		properties := vulkan_fill_array(VkLayerProperties, vkEnumerateInstanceLayerProperties);
		for desired: desired_instance_layers {
			for property: properties {
				if desired == to_string(property.layerName.data) {
					array_add(*enabled_layers, desired);
				}
			}
		}

		validation_enabled = array_find(enabled_layers, "VK_LAYER_KHRONOS_validation");
	}

	enabled_instance_extensions := make_temp_dyn_array(string);
	debug_extensions_enabled := false;
	{
		desired_instance_extensions := get_desired_surface_extensions();
		#if want_debug_extensions then array_add(*desired_instance_extensions, VK_EXT_DEBUG_UTILS_EXTENSION_NAME);

		instance_properties := vulkan_fill_array(VkExtensionProperties, vkEnumerateInstanceExtensionProperties, null);
		for desired: desired_instance_extensions {
			for property: instance_properties {
				if desired == to_string(property.extensionName.data) {
					array_add(*enabled_instance_extensions, desired);
				}
			}
		}

		debug_extensions_enabled = array_find(enabled_instance_extensions, VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
		assert(array_find(enabled_instance_extensions, VK_KHR_SURFACE_EXTENSION_NAME));
	}

	{
		app_info: VkApplicationInfo;
		app_info.pApplicationName = "Vulkan 2026";
		app_info.apiVersion = VK_API_VERSION_1_3;

		instance_info: VkInstanceCreateInfo;
		instance_info.pApplicationInfo = *app_info;
		instance_info.enabledLayerCount = enabled_layers.count.(u32);
		instance_info.ppEnabledLayerNames = strings_to_cstrings(enabled_layers).data;
		instance_info.enabledExtensionCount = enabled_instance_extensions.count.(u32);
		instance_info.ppEnabledExtensionNames = strings_to_cstrings(enabled_instance_extensions).data;

		chk(vkCreateInstance(*instance_info, null, *instance));
	}

	load_vulkan_instance_procedures(instance);

	if debug_extensions_enabled {
		debug_utils_user_data := null;
		debug_utils_callback :: (message_severity : VkDebugUtilsMessageSeverityFlagBitsEXT,
					 message_types : VkDebugUtilsMessageTypeFlagsEXT,
					 callback_data : *VkDebugUtilsMessengerCallbackDataEXT,
					 user_data : *void) -> VkBool32 #c_call
		{
			is_error   : bool = xx message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
			is_warning : bool = xx message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT;
			is_info    : bool = xx message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
			is_verbose : bool = xx message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT;
			is_general     : bool = xx message_types & VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT;
			is_validation  : bool = xx message_types & VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT;
			is_performance : bool = xx message_types & VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
			message := callback_data.pMessage;
			should_log := (!is_info && !is_verbose);
			if should_log
			{
				severity_string := ifx is_error "[ERROR]"
								   else ifx is_warning "[WARNING]"
								   else ifx is_info "[INFO]"
								   else ifx is_verbose "[VERBOSE]"
								   else "";
				type_string := ifx is_validation "[VALIDATION]"
							   else ifx is_performance "[PERFORMANCE]"
							   else ifx is_general "[GENERAL]"
							   else "";

				temp_context : #Context;
				push_context temp_context
				{
					print("\n\nVulkan Debug Message % %:\n\n%\n\n",
						severity_string, type_string, to_string(message), to_standard_error=is_error);
					if is_error then Debug.breakpoint();
				}
			}
			return VK_FALSE;
		}

		debug_utils_create_info: VkDebugUtilsMessengerCreateInfoEXT;
		debug_utils_create_info.messageSeverity =
			VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
			VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
			VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
			VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
		debug_utils_create_info.messageType =
			VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
			VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
			VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
		debug_utils_create_info.pfnUserCallback = debug_utils_callback;
		debug_utils_create_info.pUserData = debug_utils_user_data;
		chk(vkCreateDebugUtilsMessengerEXT(instance, *debug_utils_create_info, null, *debug_utils_messenger));
	}

	{
		physical_devices := vulkan_fill_array(VkPhysicalDevice, vkEnumeratePhysicalDevices, instance);
		device_index := 0;
		physical_device = physical_devices[device_index];

		device_properties: VkPhysicalDeviceProperties2;
		vkGetPhysicalDeviceProperties2(physical_device, *device_properties);
		log("Selected device: %", to_string(device_properties.properties.deviceName));

		queue_families := vulkan_fill_array(VkQueueFamilyProperties, vkGetPhysicalDeviceQueueFamilyProperties, physical_device);
		for queue_families {
			if it.queueFlags & VK_QUEUE_GRAPHICS_BIT {
				queue_family = xx it_index;
				break;
			}
		}
		chk(supports_presentation(physical_device, queue_family));
	}

	{
		qf_priorities := 1.0;
		queue_ci: VkDeviceQueueCreateInfo;
		queue_ci.queueFamilyIndex = queue_family;
		queue_ci.queueCount = 1;
		queue_ci.pQueuePriorities = *qf_priorities;

		device_extensions := (*u8).[VK_KHR_SWAPCHAIN_EXTENSION_NAME];

		enabled_1_2_features: VkPhysicalDeviceVulkan12Features;
		enabled_1_2_features.descriptorIndexing = VK_TRUE;
		enabled_1_2_features.shaderSampledImageArrayNonUniformIndexing = VK_TRUE;
		enabled_1_2_features.descriptorBindingVariableDescriptorCount = VK_TRUE;
		enabled_1_2_features.runtimeDescriptorArray = VK_TRUE;
		enabled_1_2_features.bufferDeviceAddress = VK_TRUE;
		enabled_1_3_features: VkPhysicalDeviceVulkan13Features;
		enabled_1_3_features.pNext = *enabled_1_2_features;
		enabled_1_3_features.synchronization2 = VK_TRUE;
		enabled_1_3_features.dynamicRendering = VK_TRUE;
		enabled_1_0_features: VkPhysicalDeviceFeatures;
		enabled_1_0_features.samplerAnisotropy = VK_TRUE;
		device_info: VkDeviceCreateInfo;
		device_info.pNext = *enabled_1_3_features;
		device_info.queueCreateInfoCount = 1;
		device_info.pQueueCreateInfos = *queue_ci;
		device_info.enabledExtensionCount = xx device_extensions.count;
		device_info.ppEnabledExtensionNames = device_extensions.data;
		device_info.pEnabledFeatures = *enabled_1_0_features;

		chk(vkCreateDevice(physical_device, *device_info, null, *device));
	}

	load_vulkan_device_procedures(device);

	vkGetDeviceQueue(device, queue_family, 0, *queue);

	{
		vk_functions := VmaVulkanFunctions.{
			vkGetInstanceProcAddr = vkGetInstanceProcAddr,
			vkGetDeviceProcAddr = vkGetDeviceProcAddr,
			vkCreateImage = vkCreateImage,
		};
		allocator_info := VmaAllocatorCreateInfo.{
			flags = .BUFFER_DEVICE_ADDRESS_BIT,
			physicalDevice = physical_device,
			device = device,
			pVulkanFunctions = *vk_functions,
			instance = instance,
		};
		chk(vmaCreateAllocator(*allocator_info, *allocator));
	}

	surface = create_surface(instance, vk_context.window);
}

vulkan_deinit :: (using vk_context: *Vulkan_Context) {
	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		vkDestroyFence(device, fences[it], null);
		vkDestroySemaphore(device, image_acquired_semaphores[it], null);
	}
	for render_complete_semaphores vkDestroySemaphore(device, it, null);
	vmaDestroyImage(allocator, depth_image, depth_image_allocation);
	vkDestroyImageView(device, depth_image_view, null);
	for swapchain_image_views vkDestroyImageView(device, it, null);
	for textures {
		vkDestroyImageView(device, it.view, null);
		vkDestroySampler(device, it.sampler, null);
		vmaDestroyImage(allocator, it.image, it.allocation);
	}
	vkDestroyDescriptorSetLayout(device, descriptor_set_layout_tex, null);
	vkDestroyDescriptorPool(device, descriptor_pool, null);
	vkDestroyPipelineLayout(device, pipeline_layout, null);
	vkDestroyPipeline(device, pipeline, null);
	vkDestroySwapchainKHR(device, swapchain, null);
	vkDestroySurfaceKHR(instance, surface, null);
	vkDestroyCommandPool(device, command_pool, null);
	vkDestroyShaderModule(device, shader_module, null);
	vmaDestroyAllocator(allocator);
	vkDestroyDevice(device, null);
	if debug_utils_messenger then vkDestroyDebugUtilsMessengerEXT(instance, debug_utils_messenger, null);
	vkDestroyInstance(instance, null);
}

vulkan_create_swapchain :: (vk_context: *Vulkan_Context, width: int = -1, height: int = -1) -> bool {
	chk(vkDeviceWaitIdle(vk_context.device));
	surface_capabilities: VkSurfaceCapabilitiesKHR;
	chk(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vk_context.physical_device, vk_context.surface, *surface_capabilities));

	if surface_capabilities.maxImageExtent.width == 0 || surface_capabilities.maxImageExtent.height == 0 {
		return false;
	}

	vk_context.window_size = surface_capabilities.currentExtent;
	if width != -1 || height != -1 {
		vk_context.window_size = {xx width, xx height};
	} else if vk_context.window_size.width == 0xFFFFFFFF {
		x, y, win_width, win_height, ok := get_dimensions(vk_context.window, right_handed=false);
		assert(ok);
		vk_context.window_size = {xx win_width, xx win_height};
	}

	vk_context.swapchain_image_format = VkFormat.VK_FORMAT_B8G8R8A8_SRGB;
	swapchain_info: VkSwapchainCreateInfoKHR;
	swapchain_info.surface = vk_context.surface;
	swapchain_info.minImageCount = surface_capabilities.minImageCount;
	swapchain_info.imageFormat = vk_context.swapchain_image_format;
	swapchain_info.imageColorSpace = VK_COLORSPACE_SRGB_NONLINEAR_KHR;
	swapchain_info.imageExtent = vk_context.window_size;
	swapchain_info.imageArrayLayers = 1;
	swapchain_info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
	swapchain_info.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
	swapchain_info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
	swapchain_info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
	swapchain_info.oldSwapchain = vk_context.swapchain;
	chk(vkCreateSwapchainKHR(vk_context.device, *swapchain_info, null, *vk_context.swapchain));

	if swapchain_info.oldSwapchain then vkDestroySwapchainKHR(vk_context.device, swapchain_info.oldSwapchain, null);

	images := vulkan_fill_array(VkImage, vkGetSwapchainImagesKHR, vk_context.device, vk_context.swapchain);
	if vk_context.swapchain_images.count == 0 {
		vk_context.swapchain_images = alloc_and_copy_array(images);
	} else if vk_context.swapchain_images.count == images.count {
		copy_array_dst_src(vk_context.swapchain_images, images);
	} else {
		assert(false, "Missmatch between old and new swapchain image count");
	}

	for vk_context.swapchain_image_views vkDestroyImageView(vk_context.device, it, null);

	new_image_views := make_temp_dyn_array(VkImageView);
	for vk_context.swapchain_images {
		view_info: VkImageViewCreateInfo;
		view_info.image = it;
		view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
		view_info.format = vk_context.swapchain_image_format;
		view_info.subresourceRange = {aspectMask=VK_IMAGE_ASPECT_COLOR_BIT, levelCount=1, layerCount=1};
		image_view: VkImageView;
		chk(vkCreateImageView(vk_context.device, *view_info, null, *image_view));
		array_add(*new_image_views, image_view);
	}

	if vk_context.swapchain_image_views.count == 0 {
		vk_context.swapchain_image_views = alloc_and_copy_array(new_image_views);
	} else if vk_context.swapchain_image_views.count == images.count {
		copy_array_dst_src(vk_context.swapchain_image_views, new_image_views);
	} else {
		assert(false, "Missmatch between old and new swapchain image views count");
	}

	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		if !vk_context.fences[it]
			vk_context.fences[it] = vulkan_create_fence(vk_context.device, signaled=true);
		if !vk_context.image_acquired_semaphores[it]
			vk_context.image_acquired_semaphores[it] = vulkan_create_semaphore(vk_context.device);
	}

	new_render_complete_semaphores := make_temp_dyn_array(VkSemaphore);
	for 0..vk_context.swapchain_images.count - 1 {
		array_add(*new_render_complete_semaphores, vulkan_create_semaphore(vk_context.device));
	}

	for * vk_context.render_complete_semaphores {
		vulkan_destroy_semaphore(vk_context.device, it);
	}

	if vk_context.render_complete_semaphores.count == 0 {
		vk_context.render_complete_semaphores = alloc_and_copy_array(new_render_complete_semaphores);
	} else if vk_context.render_complete_semaphores.count == vk_context.swapchain_images.count {
		copy_array_dst_src(vk_context.render_complete_semaphores, new_render_complete_semaphores);
	} else {
		assert(false, "Missmatch between old and new render_complete_semaphores count");
	}

	return true;
}

vulkan_create_depth :: (vk_context: *Vulkan_Context) {
	if vk_context.depth_image && vk_context.depth_image_allocation {
		vmaDestroyImage(vk_context.allocator, vk_context.depth_image, vk_context.depth_image_allocation);
		vkDestroyImageView(vk_context.device, vk_context.depth_image_view, null);
	}

	depth_format_list :: VkFormat.[
		VK_FORMAT_D32_SFLOAT_S8_UINT,
		VK_FORMAT_D24_UNORM_S8_UINT
	];

	for depth_format_list {
		format_properties: VkFormatProperties2;
		vkGetPhysicalDeviceFormatProperties2(vk_context.physical_device, it, *format_properties);
		if format_properties.formatProperties.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT {
			vk_context.depth_image_format = it;
			break;
		}
	}

	assert(vk_context.depth_image_format != VK_FORMAT_UNDEFINED);

	depth_image_info: VkImageCreateInfo;
	depth_image_info.imageType = VK_IMAGE_TYPE_2D;
	depth_image_info.format = vk_context.depth_image_format;
	depth_image_info.extent = {vk_context.window_size.width, vk_context.window_size.height, 1};
	depth_image_info.mipLevels = 1;
	depth_image_info.arrayLayers = 1;
	depth_image_info.samples = VK_SAMPLE_COUNT_1_BIT;
	depth_image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
	depth_image_info.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
	depth_image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

	alloc_info := VmaAllocationCreateInfo.{
		flags = .DEDICATED_MEMORY_BIT,
		usage = .AUTO,
	};
	chk(vmaCreateImage(
		vk_context.allocator,
		*depth_image_info,
		*alloc_info,
		*vk_context.depth_image,
		*vk_context.depth_image_allocation,
		null
	));

	depth_view_info: VkImageViewCreateInfo;
	depth_view_info.image = vk_context.depth_image;
	depth_view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
	depth_view_info.format = vk_context.depth_image_format;
	depth_view_info.subresourceRange = {aspectMask=VK_IMAGE_ASPECT_DEPTH_BIT, levelCount=1, layerCount=1};
	chk(vkCreateImageView(vk_context.device, *depth_view_info, null, *vk_context.depth_image_view));
}

vulkan_upload_mesh :: (allocator: VmaAllocator, mesh: Mesh) -> Vulkan_Mesh {
	vulkan_mesh: Vulkan_Mesh;
	v_buf_size := cast(VkDeviceSize, size_of(type_of(mesh.vertices[0])) * mesh.vertices.count);
	i_buf_size := cast(VkDeviceSize, size_of(type_of(mesh.indices[0])) * mesh.indices.count);
	alloc_info: VmaAllocationInfo;
	vulkan_mesh.mesh_buffer, vulkan_mesh.mesh_buffer_allocation, alloc_info = vulkan_create_buffer(
		allocator,
		v_buf_size + i_buf_size,
		VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
		.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT | .MAPPED_BIT
	);
	memcpy(alloc_info.pMappedData, mesh.vertices.data, xx v_buf_size);
	memcpy(alloc_info.pMappedData.(*u8) + v_buf_size, mesh.indices.data, xx i_buf_size);

	return vulkan_mesh;
}

vulkan_destroy_mesh :: (allocator: VmaAllocator, vulkan_mesh: *Vulkan_Mesh) {
	vmaDestroyBuffer(allocator, vulkan_mesh.mesh_buffer, vulkan_mesh.mesh_buffer_allocation);
	vulkan_mesh.* = {};
}

vulkan_allocate_shader_data_buffer :: (vk_context: *Vulkan_Context) {
	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		data_buff := *vk_context.shader_data_buffers[it];
		data_buff.buffer, data_buff.allocation, data_buff.allocation_info = vulkan_create_buffer(
			vk_context.allocator,
			size_of(Vulkan_Shader_Data),
			.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
			.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT | .MAPPED_BIT,
		);
		uniform_buffer_bda_info: VkBufferDeviceAddressInfo;
		uniform_buffer_bda_info.buffer = data_buff.buffer;
		data_buff.device_address = vkGetBufferDeviceAddress(vk_context.device, *uniform_buffer_bda_info);
	}
}

vulkan_free_shader_data_buffers :: (using vk_context: *Vulkan_Context) {
	for * shader_data_buffers {
		vmaDestroyBuffer(allocator, it.buffer, it.allocation);
	}
}

vulkan_allocate_command_buffers :: (vk_context: *Vulkan_Context) {
	command_pool_info: VkCommandPoolCreateInfo;
	command_pool_info.flags = .VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	command_pool_info.queueFamilyIndex = vk_context.queue_family;
	chk(vkCreateCommandPool(vk_context.device, *command_pool_info, null, *vk_context.command_pool));
	cb_alloc_info: VkCommandBufferAllocateInfo;
	cb_alloc_info.commandPool = vk_context.command_pool;
	cb_alloc_info.commandBufferCount = MAX_FRAMES_IN_FLIGHT;
	chk(vkAllocateCommandBuffers(vk_context.device, *cb_alloc_info, vk_context.command_buffers.data));
}

vulkan_create_semaphore :: (device: VkDevice) -> VkSemaphore
{
	create_info : VkSemaphoreCreateInfo;
	semaphore : VkSemaphore;
	chk(vkCreateSemaphore(device, *create_info, null, *semaphore));
	return semaphore;
}

vulkan_destroy_semaphore :: (device: VkDevice, semaphore : *VkSemaphore)
{
	vkDestroySemaphore(device, semaphore.*, null);
	semaphore.* = null;
}

vulkan_create_fence :: (device: VkDevice, signaled : bool) -> VkFence
{
	create_info : VkFenceCreateInfo;
	if signaled create_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;
	fence : VkFence;
	result := vkCreateFence(device, *create_info, null, *fence);
	return fence;
}


vulkan_destroy_fence :: (device: VkDevice, fence : *VkFence)
{
	vkDestroyFence(device, fence.*, null);
	fence.* = null;
}

vulkan_create_buffer :: (
	allocator: VmaAllocator,
	size: VkDeviceSize,
	usage: VkBufferUsageFlags,
	alloc_flags: VmaAllocationCreateFlags
) -> VkBuffer, VmaAllocation, VmaAllocationInfo {
	buffer_info: VkBufferCreateInfo;
	buffer_info.size = size;
	buffer_info.usage = usage;
	buffer_alloc_create_info: VmaAllocationCreateInfo;
	buffer_alloc_create_info.flags = alloc_flags;
	buffer_alloc_create_info.usage = .AUTO;
	buffer_alloc_info: VmaAllocationInfo;

	buffer: VkBuffer;
	alloc: VmaAllocation;
	chk(vmaCreateBuffer(
		allocator,
		*buffer_info,
		*buffer_alloc_create_info,
		*buffer,
		*alloc,
		*buffer_alloc_info
	));

	return buffer, alloc, buffer_alloc_info;
}

// From modules/osor_vulkan/examples/src/main.jai
vulkan_fill_array :: ($type : Type, procedure : $Procedure, $arguments : ..Code) -> [] type #expand
{
	#insert #run -> string
	{
		builder : String_Builder;
		for arguments print(*builder, "argument_%1 := #insert arguments[%1];\n", it_index);
		return builder_to_string(*builder);
	};

	CALL_STRING :: #run -> string
	{
		builder : String_Builder;
		print(*builder, "{");
		if type_info(Procedure).return_types.count != 0 then print(*builder, "result := ");
		print(*builder, "procedure(");
		for arguments print(*builder, "argument_%, ", it_index);
		print(*builder, "*count, pointer);\n");
		if type_info(Procedure).return_types.count != 0 then print(*builder, "assert(result == VK_SUCCESS);");
		print(*builder, "}");
		return builder_to_string(*builder);
	};

	count : u32 = 0;
	pointer : *type = null;
	#insert CALL_STRING;
	array := make_temp_dyn_array(type, xx count);
	array_resize(*array, count);
	pointer = array.data;
	#insert CALL_STRING;
	return array;
}
