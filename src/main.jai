using Basic :: #import "Basic";
#import "Window_Creation";
#import "Input";
#import "Math";
#import "File";
#import "File_Utilities";
Debug :: #import "Debug";

#import "stb_image";
#import "jai-vma";

#import "osor_vulkan";

#load "platform.jai";
#load "model.jai";
#load "image.jai";
#load "utils.jai";
#load "ktx.jai";

MAX_FRAMES_IN_FLIGHT :: 2;

ShaderData :: struct {
	projection: Matrix4;
	view: Matrix4;
	model: [3] Matrix4;
	light_pos: Vector4 = {0, -10, 10, 0};
	selected: u32 = 1;
}

ShaderDataBuffer :: struct {
	allocation: VmaAllocation = VK_NULL_HANDLE;
	allocation_info: VmaAllocationInfo;
	buffer: VkBuffer = VK_NULL_HANDLE;
	device_address: VkDeviceAddress;
}

Texture :: struct {
	allocation: VmaAllocation;
	image: VkImage;
	view: VkImageView;
	sampler: VkSampler;
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
	vertex_buffer: VkBuffer;
	vertex_buffer_allocation: VmaAllocation;
	shader_data_buffers: [MAX_FRAMES_IN_FLIGHT] ShaderDataBuffer;
	command_buffers: [MAX_FRAMES_IN_FLIGHT] VkCommandBuffer;
	fences: [MAX_FRAMES_IN_FLIGHT] VkFence;
	image_acquired_semaphores: [MAX_FRAMES_IN_FLIGHT] VkSemaphore;
	shader_data: ShaderData;
	shader_module: VkShaderModule;
	command_pool: VkCommandPool;
	queue_family: u32;
	textures: [3] Texture;
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
	chk(vkDeviceWaitIdle(device));
	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		vkDestroyFence(device, fences[it], null);
		vkDestroySemaphore(device, image_acquired_semaphores[it], null);
		vmaDestroyBuffer(allocator, shader_data_buffers[it].buffer, shader_data_buffers[it].allocation);
	}
	for render_complete_semaphores vkDestroySemaphore(device, it, null);
	vmaDestroyImage(allocator, depth_image, depth_image_allocation);
	vkDestroyImageView(device, depth_image_view, null);
	for swapchain_image_views vkDestroyImageView(device, it, null);
	vmaDestroyBuffer(allocator, vertex_buffer, vertex_buffer_allocation);
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

main :: () {
	window_handle := create_window(1920, 1080, "Vulkan 2026");
	vk_context: Vulkan_Context;
	vulkan_init(*vk_context, window_handle);
	defer vulkan_deinit(*vk_context);

	ok := vulkan_create_swapchain(*vk_context);
	assert(ok, "Could not create the first swapchain");
	vulkan_create_depth(*vk_context);

	ok=, mesh, materials := load_model_obj("data/suzanne.obj");
	object_rotations: [3] Vector3;

	v_buf_size := cast(VkDeviceSize, size_of(type_of(mesh.vertices[0])) * mesh.vertices.count);
	i_buf_size := cast(VkDeviceSize, size_of(type_of(mesh.indices[0])) * mesh.indices.count);
	alloc_info: VmaAllocationInfo;
	vk_context.vertex_buffer, vk_context.vertex_buffer_allocation, alloc_info = vulkan_create_buffer(
		vk_context.allocator,
		v_buf_size + i_buf_size,
		VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
		.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT | .MAPPED_BIT
	);
	memcpy(alloc_info.pMappedData, mesh.vertices.data, xx v_buf_size);
	memcpy(alloc_info.pMappedData.(*u8) + v_buf_size, mesh.indices.data, xx i_buf_size);
	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		data_buff :=  *vk_context.shader_data_buffers[it];
		data_buff.buffer, data_buff.allocation, data_buff.allocation_info = vulkan_create_buffer(
			vk_context.allocator,
			size_of(ShaderData),
			.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
			.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT | .MAPPED_BIT,
		);
		uniform_buffer_bda_info: VkBufferDeviceAddressInfo;
		uniform_buffer_bda_info.buffer = data_buff.buffer;
		data_buff.device_address = vkGetBufferDeviceAddress(vk_context.device, *uniform_buffer_bda_info);
	}

	command_pool_info: VkCommandPoolCreateInfo;
	command_pool_info.flags = .VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	command_pool_info.queueFamilyIndex = vk_context.queue_family;
	chk(vkCreateCommandPool(vk_context.device, *command_pool_info, null, *vk_context.command_pool));
	cb_alloc_info: VkCommandBufferAllocateInfo;
	cb_alloc_info.commandPool = vk_context.command_pool;
	cb_alloc_info.commandBufferCount = MAX_FRAMES_IN_FLIGHT;
	chk(vkAllocateCommandBuffers(vk_context.device, *cb_alloc_info, vk_context.command_buffers.data));

	texture_descriptors: [vk_context.textures.count] VkDescriptorImageInfo;
	for * vk_context.textures {
		ktx_data := read_entire_file(tprint("data/suzanne%.ktx2", it_index));
		defer free(ktx_data);
		ok=, ktx_image := ktx_load(ktx_data);
		assert(ok, "Could not load texture");

		texture_info: VkImageCreateInfo;
		texture_info.imageType = .VK_IMAGE_TYPE_2D;
		texture_info.format = ktx_image.vulkan_format;
		texture_info.extent = {width=ktx_image.width, height=ktx_image.height, depth=1};
		texture_info.mipLevels = ktx_image.level_count;
		texture_info.arrayLayers = 1;
		texture_info.samples = .VK_SAMPLE_COUNT_1_BIT;
		texture_info.tiling = .VK_IMAGE_TILING_OPTIMAL;
		texture_info.usage = .VK_IMAGE_USAGE_TRANSFER_DST_BIT | .VK_IMAGE_USAGE_SAMPLED_BIT;
		texture_info.initialLayout = .VK_IMAGE_LAYOUT_UNDEFINED;

		texture_alloc_info := VmaAllocationCreateInfo.{usage=.AUTO};
		chk(vmaCreateImage(vk_context.allocator, *texture_info, *texture_alloc_info, *it.image, *it.allocation, null));

		texture_view_info: VkImageViewCreateInfo;
		texture_view_info.image = it.image;
		texture_view_info.viewType = .VK_IMAGE_VIEW_TYPE_2D;
		texture_view_info.format = texture_info.format;
		texture_view_info.subresourceRange = {
			aspectMask = .VK_IMAGE_ASPECT_COLOR_BIT,
			levelCount = ktx_image.level_count,
			layerCount = 1
		};
		chk(vkCreateImageView(vk_context.device, *texture_view_info, null, *it.view));

		image_source_buffer, image_source_allocation, image_source_allocation_info := vulkan_create_buffer(
			vk_context.allocator,
			xx ktx_image.image_data.count,
			.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
			.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .MAPPED_BIT
		);

		memcpy(image_source_allocation_info.pMappedData, ktx_image.image_data.data, ktx_image.image_data.count);

		fence_one_time_info: VkFenceCreateInfo;
		fence_one_time: VkFence;
		chk(vkCreateFence(vk_context.device, *fence_one_time_info, null, *fence_one_time));

		cb_one_time: VkCommandBuffer;
		cb_one_time_info: VkCommandBufferAllocateInfo;
		cb_one_time_info.commandPool = vk_context.command_pool;
		cb_one_time_info.commandBufferCount = 1;
		chk(vkAllocateCommandBuffers(vk_context.device, *cb_one_time_info, *cb_one_time));

		cb_one_time_bi: VkCommandBufferBeginInfo;
		cb_one_time_bi.flags = .VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
		chk(vkBeginCommandBuffer(cb_one_time, *cb_one_time_bi));
		barrier_tex_image: VkImageMemoryBarrier2;
		barrier_tex_image.srcStageMask = .VK_PIPELINE_STAGE_2_NONE;
		barrier_tex_image.srcAccessMask = .VK_ACCESS_2_NONE;
		barrier_tex_image.dstStageMask = .VK_PIPELINE_STAGE_2_TRANSFER_BIT;
		barrier_tex_image.dstAccessMask = .VK_ACCESS_2_TRANSFER_WRITE_BIT;
		barrier_tex_image.oldLayout = .VK_IMAGE_LAYOUT_UNDEFINED;
		barrier_tex_image.newLayout = .VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		barrier_tex_image.image = it.image;
		barrier_tex_image.subresourceRange = {aspectMask=.VK_IMAGE_ASPECT_COLOR_BIT, levelCount=ktx_image.level_count, layerCount = 1};
		barrier_tex_info: VkDependencyInfo;
		barrier_tex_info.imageMemoryBarrierCount = 1;
		barrier_tex_info.pImageMemoryBarriers = *barrier_tex_image;
		vkCmdPipelineBarrier2(cb_one_time, *barrier_tex_info);

		copy_regions := make_temp_dyn_array(VkBufferImageCopy);
		total : u64 = 0;
		for ktx_image.mipmap_offsets {
			region_width := ktx_image.width >> it_index;
			region_height := ktx_image.height >> it_index;
			region := VkBufferImageCopy.{
				bufferOffset = it.byte_offset,
				imageSubresource = {aspectMask=.VK_IMAGE_ASPECT_COLOR_BIT, mipLevel=xx it_index, layerCount=1},
				imageExtent = {width=region_width, height=region_height, depth=1},
			};
			array_add(*copy_regions, region);
		}

		vkCmdCopyBufferToImage(
			cb_one_time,
			image_source_buffer,
			it.image,
			.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			xx copy_regions.count,
			copy_regions.data
		);

		barrier_tex_read: VkImageMemoryBarrier2;
		barrier_tex_read.srcStageMask = .VK_PIPELINE_STAGE_2_TRANSFER_BIT;
		barrier_tex_read.srcAccessMask = .VK_ACCESS_2_TRANSFER_WRITE_BIT;
		barrier_tex_read.dstStageMask = .VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
		barrier_tex_read.dstAccessMask = .VK_ACCESS_2_SHADER_READ_BIT;
		barrier_tex_read.oldLayout = .VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		barrier_tex_read.newLayout = .VK_IMAGE_LAYOUT_READ_ONLY_OPTIMAL;
		barrier_tex_read.image = it.image;
		barrier_tex_read.subresourceRange = {aspectMask=.VK_IMAGE_ASPECT_COLOR_BIT, levelCount=ktx_image.level_count, layerCount=1};
		barrier_tex_info.pImageMemoryBarriers = *barrier_tex_read;
		vkCmdPipelineBarrier2(cb_one_time, *barrier_tex_info);

		chk(vkEndCommandBuffer(cb_one_time));

		cb_one_time_submit_info: VkCommandBufferSubmitInfo;
		cb_one_time_submit_info.commandBuffer = cb_one_time;
		one_time_si: VkSubmitInfo2;
		one_time_si.commandBufferInfoCount = 1;
		one_time_si.pCommandBufferInfos = *cb_one_time_submit_info;
		chk(vkQueueSubmit2(vk_context.queue, 1, *one_time_si, fence_one_time));
		chk(vkWaitForFences(vk_context.device, 1, *fence_one_time, VK_TRUE, U64_MAX));
		vkDestroyFence(vk_context.device, fence_one_time, null);
		vmaDestroyBuffer(vk_context.allocator, image_source_buffer, image_source_allocation);

		sampler_info: VkSamplerCreateInfo;
		sampler_info.magFilter = .VK_FILTER_LINEAR;
		sampler_info.minFilter = .VK_FILTER_LINEAR;
		sampler_info.mipmapMode = .VK_SAMPLER_MIPMAP_MODE_LINEAR;
		sampler_info.anisotropyEnable = VK_TRUE;
		sampler_info.maxAnisotropy = 8.0;
		sampler_info.maxLod = ktx_image.level_count.(float);
		chk(vkCreateSampler(vk_context.device, *sampler_info, null, *it.sampler));

		texture_descriptors[it_index] = {
			sampler = it.sampler,
			imageView = it.view,
			imageLayout = .VK_IMAGE_LAYOUT_READ_ONLY_OPTIMAL
		};
	}

	desc_variable_flag := VkDescriptorBindingFlags.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;
	desc_binding_flags: VkDescriptorSetLayoutBindingFlagsCreateInfo;
	desc_binding_flags.bindingCount = 1;
	desc_binding_flags.pBindingFlags = *desc_variable_flag;
	desc_layout_binding_tex: VkDescriptorSetLayoutBinding;
	desc_layout_binding_tex.descriptorType = .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
	desc_layout_binding_tex.descriptorCount = xx vk_context.textures.count;
	desc_layout_binding_tex.stageFlags = .VK_SHADER_STAGE_FRAGMENT_BIT;
	desc_layout_tex_ci: VkDescriptorSetLayoutCreateInfo;
	desc_layout_tex_ci.pNext = *desc_binding_flags;
	desc_layout_tex_ci.bindingCount = 1;
	desc_layout_tex_ci.pBindings = *desc_layout_binding_tex;
	chk(vkCreateDescriptorSetLayout(vk_context.device, *desc_layout_tex_ci, null, *vk_context.descriptor_set_layout_tex));

	pool_size: VkDescriptorPoolSize;
	pool_size.type = .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
	pool_size.descriptorCount = xx vk_context.textures.count;
	desc_pool_ci: VkDescriptorPoolCreateInfo;
	desc_pool_ci.maxSets = 1;
	desc_pool_ci.poolSizeCount = 1;
	desc_pool_ci.pPoolSizes = *pool_size;
	chk(vkCreateDescriptorPool(vk_context.device, *desc_pool_ci, null, *vk_context.descriptor_pool));

	variable_desc_count := vk_context.textures.count.(u32);
	variable_desc_count_ai: VkDescriptorSetVariableDescriptorCountAllocateInfo;
	variable_desc_count_ai.descriptorSetCount = 1;
	variable_desc_count_ai.pDescriptorCounts = *variable_desc_count;
	tex_desc_set_alloc: VkDescriptorSetAllocateInfo;
	tex_desc_set_alloc.pNext = *variable_desc_count_ai;
	tex_desc_set_alloc.descriptorPool = vk_context.descriptor_pool;
	tex_desc_set_alloc.descriptorSetCount = 1;
	tex_desc_set_alloc.pSetLayouts = *vk_context.descriptor_set_layout_tex;
	chk(vkAllocateDescriptorSets(vk_context.device, *tex_desc_set_alloc, *vk_context.descriptor_set_tex));

	write_desc_set: VkWriteDescriptorSet;
	write_desc_set.dstSet = vk_context.descriptor_set_tex;
	write_desc_set.dstBinding = 0;
	write_desc_set.descriptorType = .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
	write_desc_set.descriptorCount = xx texture_descriptors.count;
	write_desc_set.pImageInfo = texture_descriptors.data;
	vkUpdateDescriptorSets(vk_context.device, 1, *write_desc_set, 0, null);

	shader_data := read_entire_file("data/shader.spriv");
	shader_module_ci: VkShaderModuleCreateInfo;
	shader_module_ci.codeSize = xx shader_data.count;
	shader_module_ci.pCode = shader_data.data.(*u32);
	chk(vkCreateShaderModule(vk_context.device, *shader_module_ci, null, *vk_context.shader_module));

	push_constant_range: VkPushConstantRange;
	push_constant_range.stageFlags = .VK_SHADER_STAGE_VERTEX_BIT;
	push_constant_range.size = size_of(VkDeviceAddress);
	pipeline_layout_ci: VkPipelineLayoutCreateInfo;
	pipeline_layout_ci.setLayoutCount = 1;
	pipeline_layout_ci.pSetLayouts = *vk_context.descriptor_set_layout_tex;
	pipeline_layout_ci.pushConstantRangeCount = 1;
	pipeline_layout_ci.pPushConstantRanges = *push_constant_range;
	chk(vkCreatePipelineLayout(vk_context.device, *pipeline_layout_ci, null, *vk_context.pipeline_layout));

	vertex_binding: VkVertexInputBindingDescription;
	vertex_binding.stride = size_of(Vertex);
	vertex_binding.inputRate = .VK_VERTEX_INPUT_RATE_VERTEX;
	// TODO Try to generate this automatically
	vertex_attributes := VkVertexInputAttributeDescription.[
		{location=0, binding=0, format=.VK_FORMAT_R32G32B32_SFLOAT},
		{location=1, binding=0, format=.VK_FORMAT_R32G32B32_SFLOAT, offset=xx offset_of(Vertex, #code normal)},
		{location=2, binding=0, format=.VK_FORMAT_R32G32_SFLOAT, offset=xx offset_of(Vertex, #code tex_coords)},
	];

	vertex_input_state: VkPipelineVertexInputStateCreateInfo;
	vertex_input_state.vertexBindingDescriptionCount = 1;
	vertex_input_state.pVertexBindingDescriptions = *vertex_binding;
	vertex_input_state.vertexAttributeDescriptionCount = vertex_attributes.count;
	vertex_input_state.pVertexAttributeDescriptions = vertex_attributes.data;

	input_assembly_state: VkPipelineInputAssemblyStateCreateInfo;
	input_assembly_state.topology = .VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

	shader_stages := VkPipelineShaderStageCreateInfo.[
		{stage=.VK_SHADER_STAGE_VERTEX_BIT, module=vk_context.shader_module, pName="main"},
		{stage=.VK_SHADER_STAGE_FRAGMENT_BIT, module=vk_context.shader_module, pName="main"},
	];

	viewport_state: VkPipelineViewportStateCreateInfo;
	viewport_state.viewportCount = 1;
	viewport_state.scissorCount = 1;
	dynamic_states := VkDynamicState.[.VK_DYNAMIC_STATE_VIEWPORT, .VK_DYNAMIC_STATE_SCISSOR];
	dynamic_state: VkPipelineDynamicStateCreateInfo;
	dynamic_state.dynamicStateCount = dynamic_states.count;
	dynamic_state.pDynamicStates = dynamic_states.data;

	depth_stencil_state: VkPipelineDepthStencilStateCreateInfo;
	depth_stencil_state.depthTestEnable = VK_TRUE;
	depth_stencil_state.depthWriteEnable = VK_TRUE;
	depth_stencil_state.depthCompareOp = .VK_COMPARE_OP_LESS_OR_EQUAL;

	rendering_ci: VkPipelineRenderingCreateInfo;
	rendering_ci.colorAttachmentCount = 1;
	rendering_ci.pColorAttachmentFormats = *vk_context.swapchain_image_format;
	rendering_ci.depthAttachmentFormat = vk_context.depth_image_format;

	blend_attachment := VkPipelineColorBlendAttachmentState.{colorWriteMask=0xF};
	color_blend_state: VkPipelineColorBlendStateCreateInfo;
	color_blend_state.attachmentCount = 1;
	color_blend_state.pAttachments = *blend_attachment;
	rasterization_state: VkPipelineRasterizationStateCreateInfo;
	rasterization_state.lineWidth = 1.0;
	multisample_state: VkPipelineMultisampleStateCreateInfo;
	multisample_state.rasterizationSamples = .VK_SAMPLE_COUNT_1_BIT;

	pipeline_ci: VkGraphicsPipelineCreateInfo;
	pipeline_ci.pNext = *rendering_ci;
	pipeline_ci.stageCount = shader_stages.count;
	pipeline_ci.pStages = shader_stages.data;
	pipeline_ci.pVertexInputState = *vertex_input_state;
	pipeline_ci.pInputAssemblyState = *input_assembly_state;
	pipeline_ci.pViewportState = *viewport_state;
	pipeline_ci.pRasterizationState = *rasterization_state;
	pipeline_ci.pMultisampleState = *multisample_state;
	pipeline_ci.pDepthStencilState = *depth_stencil_state;
	pipeline_ci.pColorBlendState = *color_blend_state;
	pipeline_ci.pDynamicState = *dynamic_state;
	pipeline_ci.layout = vk_context.pipeline_layout;
	chk(vkCreateGraphicsPipelines(vk_context.device, VK_NULL_HANDLE, 1, *pipeline_ci, null, *vk_context.pipeline));

	last_time := current_time_monotonic();
	quit := false;
	while !quit {
		chk(vkWaitForFences(vk_context.device, 1, *vk_context.fences[vk_context.frame_index], VK_TRUE, U64_MAX));
		chk(vkResetFences(vk_context.device, 1, *vk_context.fences[vk_context.frame_index]));

		result := vkAcquireNextImageKHR(vk_context.device, vk_context.swapchain, U64_MAX, vk_context.image_acquired_semaphores[vk_context.frame_index], VK_NULL_HANDLE, *vk_context.image_index);
		if result == .VK_ERROR_OUT_OF_DATE_KHR {
			vk_context.update_swapchain = true;
		} else {
			chk(result);
		}

		cam_pos := Vector3.{0, 0, -6};
		aspect_ratio := vk_context.window_size.width.(float) / vk_context.window_size.height.(float);
		vk_context.shader_data.projection = make_projection_matrix(45, aspect_ratio, 0.1, 32, depth_range_01=true);
		vk_context.shader_data.view = make_look_at_matrix(cam_pos, {0,0,0}, {0, 1, 0}, x_is_forward=false);
		for 0..2 {
			instance_pos := Vector3.{(it - 1).(float) * 3, 0, 0};
			rotation := rotation_matrix(Matrix4, euler_to_quaternion(object_rotations[it]));
			vk_context.shader_data.model[it] = make_translation_matrix4(instance_pos) * rotation;
		}

		memcpy(vk_context.shader_data_buffers[vk_context.frame_index].allocation_info.pMappedData, *vk_context.shader_data, size_of(ShaderData));

		cb := vk_context.command_buffers[vk_context.frame_index];
		chk(vkResetCommandBuffer(cb, 0));

		cb_bi: VkCommandBufferBeginInfo;
		cb_bi.flags = .VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
		chk(vkBeginCommandBuffer(cb, *cb_bi));

		output_barriers := VkImageMemoryBarrier2.[
			{
				srcStageMask = .VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
				dstStageMask = .VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
				dstAccessMask = .VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | .VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
				oldLayout = .VK_IMAGE_LAYOUT_UNDEFINED,
				newLayout = .VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
				image = vk_context.swapchain_images[vk_context.image_index],
				subresourceRange = {aspectMask=.VK_IMAGE_ASPECT_COLOR_BIT, levelCount=1, layerCount=1},
			},
			{
				srcStageMask = .VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
				srcAccessMask = .VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
				dstStageMask = .VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT,
				dstAccessMask = .VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
				oldLayout = .VK_IMAGE_LAYOUT_UNDEFINED,
				newLayout = .VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
				image = vk_context.depth_image,
				subresourceRange = {aspectMask=.VK_IMAGE_ASPECT_DEPTH_BIT | .VK_IMAGE_ASPECT_STENCIL_BIT, levelCount=1, layerCount=1},
			}
		];

		barrier_dependency_info: VkDependencyInfo;
		barrier_dependency_info.imageMemoryBarrierCount = output_barriers.count;
		barrier_dependency_info.pImageMemoryBarriers = output_barriers.data;
		vkCmdPipelineBarrier2(cb, *barrier_dependency_info);

		color_attachment_info: VkRenderingAttachmentInfo;
		color_attachment_info.imageView = vk_context.swapchain_image_views[vk_context.image_index];
		color_attachment_info.imageLayout = .VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL;
		color_attachment_info.loadOp = .VK_ATTACHMENT_LOAD_OP_CLEAR;
		color_attachment_info.storeOp = .VK_ATTACHMENT_STORE_OP_STORE;
		color_attachment_info.clearValue.color.float32_ = .[0, 0, 0.2, 1.0];
		depth_attachment_info: VkRenderingAttachmentInfo;
		depth_attachment_info.imageView = vk_context.depth_image_view;
		depth_attachment_info.imageLayout = .VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL;
		depth_attachment_info.loadOp = .VK_ATTACHMENT_LOAD_OP_CLEAR;
		depth_attachment_info.storeOp = .VK_ATTACHMENT_STORE_OP_DONT_CARE;
		depth_attachment_info.clearValue.depthStencil = {1.0, 0};

		rendering_info: VkRenderingInfo;
		rendering_info.renderArea = {extent=vk_context.window_size};
		rendering_info.layerCount = 1;
		rendering_info.colorAttachmentCount = 1;
		rendering_info.pColorAttachments = *color_attachment_info;
		rendering_info.pDepthAttachment = *depth_attachment_info;
		vkCmdBeginRendering(cb, *rendering_info);

		vp := VkViewport.{
			width = vk_context.window_size.width.(float),
			height = vk_context.window_size.height.(float),
			minDepth = 0,
			maxDepth = 1,
		};
		vkCmdSetViewport(cb, 0, 1, *vp);
		scissor := VkRect2D.{extent=vk_context.window_size};
		vkCmdSetScissor(cb, 0, 1, *scissor);

		vkCmdBindPipeline(cb, .VK_PIPELINE_BIND_POINT_GRAPHICS, vk_context.pipeline);
		v_offset: VkDeviceSize;
		vkCmdBindDescriptorSets(cb, .VK_PIPELINE_BIND_POINT_GRAPHICS, vk_context.pipeline_layout, 0, 1, *vk_context.descriptor_set_tex, 0, null);
		vkCmdBindVertexBuffers(cb, 0, 1, *vk_context.vertex_buffer, *v_offset);
		vkCmdBindIndexBuffer(cb, vk_context.vertex_buffer, v_buf_size, .VK_INDEX_TYPE_UINT16);

		vkCmdPushConstants(
			cb,
			vk_context.pipeline_layout,
			.VK_SHADER_STAGE_VERTEX_BIT,
			0,
			size_of(VkDeviceAddress),
			*vk_context.shader_data_buffers[vk_context.frame_index].device_address
		);

		index_count := mesh.indices.count.(u32);
		vkCmdDrawIndexed(cb, index_count, 3, 0, 0, 0);

		vkCmdEndRendering(cb);

		barrier_present: VkImageMemoryBarrier2;
		barrier_present.srcStageMask = .VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
		barrier_present.srcAccessMask = .VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
		barrier_present.dstStageMask = .VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
		barrier_present.oldLayout = .VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL;
		barrier_present.newLayout = .VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
		barrier_present.image = vk_context.swapchain_images[vk_context.image_index];
		barrier_present.subresourceRange = {aspectMask=.VK_IMAGE_ASPECT_COLOR_BIT, levelCount=1, layerCount = 1};
		barrier_present_dependency_info: VkDependencyInfo;
		barrier_present_dependency_info.imageMemoryBarrierCount = 1;
		barrier_present_dependency_info.pImageMemoryBarriers = *barrier_present;
		vkCmdPipelineBarrier2(cb, *barrier_present_dependency_info);

		vkEndCommandBuffer(cb);

		wait_semaphore_info: VkSemaphoreSubmitInfo;
		wait_semaphore_info.semaphore = vk_context.image_acquired_semaphores[vk_context.frame_index];
		wait_semaphore_info.stageMask = .VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
		command_buffer_submit_info: VkCommandBufferSubmitInfo;
		command_buffer_submit_info.commandBuffer = cb;
		signal_semaphore_info: VkSemaphoreSubmitInfo;
		signal_semaphore_info.semaphore = vk_context.render_complete_semaphores[vk_context.image_index];
		signal_semaphore_info.stageMask = .VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
		submit_info: VkSubmitInfo2;
		submit_info.waitSemaphoreInfoCount = 1;
		submit_info.pWaitSemaphoreInfos = *wait_semaphore_info;
		submit_info.commandBufferInfoCount = 1;
		submit_info.pCommandBufferInfos = *command_buffer_submit_info;
		submit_info.signalSemaphoreInfoCount = 1;
		submit_info.pSignalSemaphoreInfos = *signal_semaphore_info;
		chk(vkQueueSubmit2(vk_context.queue, 1, *submit_info, vk_context.fences[vk_context.frame_index]));

		vk_context.frame_index = (vk_context.frame_index + 1) % MAX_FRAMES_IN_FLIGHT;

		present_info: VkPresentInfoKHR;
		present_info.waitSemaphoreCount = 1;
		present_info.pWaitSemaphores = *vk_context.render_complete_semaphores[vk_context.image_index];
		present_info.swapchainCount = 1;
		present_info.pSwapchains = *vk_context.swapchain;
		present_info.pImageIndices = *vk_context.image_index;
		result = vkQueuePresentKHR(vk_context.queue, *present_info);
		if result == .VK_ERROR_OUT_OF_DATE_KHR {
			vk_context.update_swapchain = true;
		} else {
			chk(result);
		}

		now := current_time_monotonic();
		delta_time := to_float64_seconds(now - last_time).(float32);
		last_time = now;

		update_window_events();
		for events_this_frame {
			if it.type == {
			case .QUIT;
				quit = true;
			case .KEYBOARD;
				if it.key_pressed == 0 continue;

				if it.key_code == {
				case .ESCAPE;
					quit = true;
					break;
				case .ARROW_RIGHT;
					vk_context.shader_data.selected = ifx vk_context.shader_data.selected < 2 then vk_context.shader_data.selected + 1 else 0;
				case .ARROW_LEFT;
					vk_context.shader_data.selected = ifx vk_context.shader_data.selected > 0 then vk_context.shader_data.selected - 1 else 2;
				}
			case .MOUSE_WHEEL;
				cam_pos.z += it.wheel_delta.(float) * delta_time * 10;
			}
		}

		object_rotations[vk_context.shader_data.selected].x -= mouse_delta_y.(float) * delta_time;
		object_rotations[vk_context.shader_data.selected].y += mouse_delta_x.(float) * delta_time;

		resizes := get_window_resizes();
		for record: resizes {
			if record.window == window_handle {
				vk_context.window_size = {xx record.width, xx record.height};
				vk_context.update_swapchain = true;
			}
		}

		if vk_context.update_swapchain {
			vk_context.update_swapchain = false;
			vulkan_create_swapchain(*vk_context, vk_context.window_size.width, vk_context.window_size.height);
			vulkan_create_depth(*vk_context);
		}

	}
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
