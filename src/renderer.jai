
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
	buffer: Vk.Buffer;
	device_address: Vk.DeviceAddress;
}

Vulkan_Texture :: struct {
	allocation: VmaAllocation;
	image: Vk.Image;
	view: Vk.ImageView;
	sampler: Vk.Sampler;
}

// Verticies and indicies are stored in the same buffer
Vulkan_Mesh :: struct {
	mesh_buffer: Vk.Buffer;
	mesh_buffer_allocation: VmaAllocation;
}

Vulkan_Context :: struct {
	instance: Vk.Instance;
	debug_utils_messenger: Vk.DebugUtilsMessengerEXT;
	physical_device: Vk.PhysicalDevice;
	device: Vk.Device;
	queue: Vk.Queue;
	allocator: VmaAllocator;
	surface: Vk.SurfaceKHR;
	window: Window_Type;
	swapchain_image_format: Vk.Format;
	swapchain: Vk.SwapchainKHR;
	swapchain_images: [] Vk.Image;
	swapchain_image_views: [] Vk.ImageView;
	render_complete_semaphores: [] Vk.Semaphore;
	window_size: Vk.Extent2D;
	depth_image_format: Vk.Format;
	depth_image: Vk.Image;
	depth_image_allocation: VmaAllocation;
	depth_image_view: Vk.ImageView;
	shader_data_buffers: [MAX_FRAMES_IN_FLIGHT] Shader_Data_Buffer;
	command_buffers: [MAX_FRAMES_IN_FLIGHT] Vk.CommandBuffer;
	fences: [MAX_FRAMES_IN_FLIGHT] Vk.Fence;
	image_acquired_semaphores: [MAX_FRAMES_IN_FLIGHT] Vk.Semaphore;
	shader_data: Vulkan_Shader_Data;
	shader_module: Vk.ShaderModule;
	command_pool: Vk.CommandPool;
	queue_family: u32;
	textures: [3] Vulkan_Texture;
	descriptor_set_layout_tex: Vk.DescriptorSetLayout;
	descriptor_pool: Vk.DescriptorPool;
	descriptor_set_tex: Vk.DescriptorSet;
	pipeline_layout: Vk.PipelineLayout;
	pipeline: Vk.Pipeline;
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

	if Vk.initialize() != .SUCCESS  return;

	enabled_layers := make_temp_dyn_array(string);
	validation_enabled := false;
	{
		desired_instance_layers := make_temp_dyn_array(string);
		#if want_validation_layers then array_add(*desired_instance_layers, "VK_LAYER_KHRONOS_validation");

		properties := vulkan_fill_array(Vk.LayerProperties, Vk.EnumerateInstanceLayerProperties);
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
		#if want_debug_extensions then array_add(*desired_instance_extensions, Vk.EXT_DEBUG_UTILS_EXTENSION_NAME);

		instance_properties := vulkan_fill_array(Vk.ExtensionProperties, Vk.EnumerateInstanceExtensionProperties, null);
		for desired: desired_instance_extensions {
			for property: instance_properties {
				if desired == to_string(property.extensionName.data) {
					array_add(*enabled_instance_extensions, desired);
				}
			}
		}

		debug_extensions_enabled = array_find(enabled_instance_extensions, Vk.EXT_DEBUG_UTILS_EXTENSION_NAME);
		assert(array_find(enabled_instance_extensions, Vk.KHR_SURFACE_EXTENSION_NAME));
	}

	{
		app_info: Vk.ApplicationInfo;
		app_info.pApplicationName = "Vulkan 2026";
		app_info.apiVersion = Vk.API_VERSION_1_3;

		instance_info: Vk.InstanceCreateInfo;
		instance_info.pApplicationInfo = *app_info;
		instance_info.enabledLayerCount = enabled_layers.count.(u32);
		instance_info.ppEnabledLayerNames = strings_to_cstrings(enabled_layers).data;
		instance_info.enabledExtensionCount = enabled_instance_extensions.count.(u32);
		instance_info.ppEnabledExtensionNames = strings_to_cstrings(enabled_instance_extensions).data;

		chk(Vk.CreateInstance(*instance_info, null, *instance));
	}

	Vk.load_instance(instance);

	if debug_extensions_enabled {
		debug_utils_user_data := null;
		debug_utils_callback :: (message_severity : Vk.DebugUtilsMessageSeverityFlagBitsEXT,
					 message_types : Vk.DebugUtilsMessageTypeFlagsEXT,
					 callback_data : *Vk.DebugUtilsMessengerCallbackDataEXT,
					 user_data : *void) -> Vk.Bool32 #c_call
		{
			is_error   : bool = xx message_severity & .ERROR_BIT_EXT;
			is_warning : bool = xx message_severity & .WARNING_BIT_EXT;
			is_info    : bool = xx message_severity & .INFO_BIT_EXT;
			is_verbose : bool = xx message_severity & .VERBOSE_BIT_EXT;
			is_general     : bool = xx message_types & .GENERAL_BIT_EXT;
			is_validation  : bool = xx message_types & .VALIDATION_BIT_EXT;
			is_performance : bool = xx message_types & .PERFORMANCE_BIT_EXT;
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
			return Vk.FALSE;
		}

		debug_utils_create_info: Vk.DebugUtilsMessengerCreateInfoEXT;
		debug_utils_create_info.messageSeverity =
			.VERBOSE_BIT_EXT |
			.INFO_BIT_EXT |
			.WARNING_BIT_EXT |
			.ERROR_BIT_EXT;
		debug_utils_create_info.messageType =
			.GENERAL_BIT_EXT |
			.VALIDATION_BIT_EXT |
			.PERFORMANCE_BIT_EXT;
		debug_utils_create_info.pfnUserCallback = debug_utils_callback;
		debug_utils_create_info.pUserData = debug_utils_user_data;
		chk(Vk.CreateDebugUtilsMessengerEXT(instance, *debug_utils_create_info, null, *debug_utils_messenger));
	}

	{
		physical_devices := vulkan_fill_array(Vk.PhysicalDevice, Vk.EnumeratePhysicalDevices, instance);
		device_index := 0;
		physical_device = physical_devices[device_index];

		device_properties: Vk.PhysicalDeviceProperties2;
		Vk.GetPhysicalDeviceProperties2(physical_device, *device_properties);
		log("Selected device: %", to_string(device_properties.properties.deviceName));

		queue_families := vulkan_fill_array(Vk.QueueFamilyProperties, Vk.GetPhysicalDeviceQueueFamilyProperties, physical_device);
		for queue_families {
			if it.queueFlags & .GRAPHICS_BIT {
				queue_family = xx it_index;
				break;
			}
		}
		chk(supports_presentation(physical_device, queue_family));
	}

	{
		qf_priorities := 1.0;
		queue_ci: Vk.DeviceQueueCreateInfo;
		queue_ci.queueFamilyIndex = queue_family;
		queue_ci.queueCount = 1;
		queue_ci.pQueuePriorities = *qf_priorities;

		device_extensions := (*u8).[Vk.KHR_SWAPCHAIN_EXTENSION_NAME];

		enabled_1_2_features: Vk.PhysicalDeviceVulkan12Features;
		enabled_1_2_features.descriptorIndexing = Vk.TRUE;
		enabled_1_2_features.shaderSampledImageArrayNonUniformIndexing = Vk.TRUE;
		enabled_1_2_features.descriptorBindingVariableDescriptorCount = Vk.TRUE;
		enabled_1_2_features.runtimeDescriptorArray = Vk.TRUE;
		enabled_1_2_features.bufferDeviceAddress = Vk.TRUE;
		enabled_1_3_features: Vk.PhysicalDeviceVulkan13Features;
		enabled_1_3_features.pNext = *enabled_1_2_features;
		enabled_1_3_features.synchronization2 = Vk.TRUE;
		enabled_1_3_features.dynamicRendering = Vk.TRUE;
		enabled_1_0_features: Vk.PhysicalDeviceFeatures;
		enabled_1_0_features.samplerAnisotropy = Vk.TRUE;
		device_info: Vk.DeviceCreateInfo;
		device_info.pNext = *enabled_1_3_features;
		device_info.queueCreateInfoCount = 1;
		device_info.pQueueCreateInfos = *queue_ci;
		device_info.enabledExtensionCount = xx device_extensions.count;
		device_info.ppEnabledExtensionNames = device_extensions.data;
		device_info.pEnabledFeatures = *enabled_1_0_features;

		chk(Vk.CreateDevice(physical_device, *device_info, null, *device));
	}

	Vk.load_device(device);

	Vk.GetDeviceQueue(device, queue_family, 0, *queue);

	{
		vk_functions := VmaVulkanFunctions.{
			vkGetInstanceProcAddr = Vk.GetInstanceProcAddr,
			vkGetDeviceProcAddr = Vk.GetDeviceProcAddr,
			vkCreateImage = Vk.CreateImage,
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
		Vk.DestroyFence(device, fences[it], null);
		Vk.DestroySemaphore(device, image_acquired_semaphores[it], null);
	}
	for render_complete_semaphores Vk.DestroySemaphore(device, it, null);
	vmaDestroyImage(allocator, depth_image, depth_image_allocation);
	Vk.DestroyImageView(device, depth_image_view, null);
	for swapchain_image_views Vk.DestroyImageView(device, it, null);
	for textures {
		Vk.DestroyImageView(device, it.view, null);
		Vk.DestroySampler(device, it.sampler, null);
		vmaDestroyImage(allocator, it.image, it.allocation);
	}
	Vk.DestroyDescriptorSetLayout(device, descriptor_set_layout_tex, null);
	Vk.DestroyDescriptorPool(device, descriptor_pool, null);
	Vk.DestroyPipelineLayout(device, pipeline_layout, null);
	Vk.DestroyPipeline(device, pipeline, null);
	Vk.DestroySwapchainKHR(device, swapchain, null);
	Vk.DestroySurfaceKHR(instance, surface, null);
	Vk.DestroyCommandPool(device, command_pool, null);
	Vk.DestroyShaderModule(device, shader_module, null);
	vmaDestroyAllocator(allocator);
	Vk.DestroyDevice(device, null);
	if debug_utils_messenger then Vk.DestroyDebugUtilsMessengerEXT(instance, debug_utils_messenger, null);
	Vk.DestroyInstance(instance, null);
	Vk.finalize();
}

vulkan_create_swapchain :: (vk_context: *Vulkan_Context, width: int = -1, height: int = -1) -> bool {
	chk(Vk.DeviceWaitIdle(vk_context.device));
	surface_capabilities: Vk.SurfaceCapabilitiesKHR;
	chk(Vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk_context.physical_device, vk_context.surface, *surface_capabilities));

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

	vk_context.swapchain_image_format = .B8G8R8A8_SRGB;
	swapchain_info: Vk.SwapchainCreateInfoKHR;
	swapchain_info.surface = vk_context.surface;
	swapchain_info.minImageCount = surface_capabilities.minImageCount;
	swapchain_info.imageFormat = vk_context.swapchain_image_format;
	swapchain_info.imageColorSpace = .SRGB_NONLINEAR_KHR;
	swapchain_info.imageExtent = vk_context.window_size;
	swapchain_info.imageArrayLayers = 1;
	swapchain_info.imageUsage = .COLOR_ATTACHMENT_BIT;
	swapchain_info.preTransform = .IDENTITY_BIT_KHR;
	swapchain_info.compositeAlpha = .OPAQUE_BIT_KHR;
	swapchain_info.presentMode = .FIFO_KHR;
	swapchain_info.oldSwapchain = vk_context.swapchain;
	chk(Vk.CreateSwapchainKHR(vk_context.device, *swapchain_info, null, *vk_context.swapchain));

	if swapchain_info.oldSwapchain then Vk.DestroySwapchainKHR(vk_context.device, swapchain_info.oldSwapchain, null);

	images := vulkan_fill_array(Vk.Image, Vk.GetSwapchainImagesKHR, vk_context.device, vk_context.swapchain);
	if vk_context.swapchain_images.count == 0 {
		vk_context.swapchain_images = alloc_and_copy_array(images);
	} else if vk_context.swapchain_images.count == images.count {
		copy_array_dst_src(vk_context.swapchain_images, images);
	} else {
		assert(false, "Missmatch between old and new swapchain image count");
	}

	for vk_context.swapchain_image_views Vk.DestroyImageView(vk_context.device, it, null);

	new_image_views := make_temp_dyn_array(Vk.ImageView);
	for vk_context.swapchain_images {
		view_info: Vk.ImageViewCreateInfo;
		view_info.image = it;
		view_info.viewType = ._2D;
		view_info.format = vk_context.swapchain_image_format;
		view_info.subresourceRange = {aspectMask=.COLOR_BIT, levelCount=1, layerCount=1};
		image_view: Vk.ImageView;
		chk(Vk.CreateImageView(vk_context.device, *view_info, null, *image_view));
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

	new_render_complete_semaphores := make_temp_dyn_array(Vk.Semaphore);
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
		Vk.DestroyImageView(vk_context.device, vk_context.depth_image_view, null);
	}

	depth_format_list :: Vk.Format.[
		.D32_SFLOAT_S8_UINT,
		.D24_UNORM_S8_UINT
	];

	for depth_format_list {
		format_properties: Vk.FormatProperties2;
		Vk.GetPhysicalDeviceFormatProperties2(vk_context.physical_device, it, *format_properties);
		if format_properties.formatProperties.optimalTilingFeatures & .DEPTH_STENCIL_ATTACHMENT_BIT {
			vk_context.depth_image_format = it;
			break;
		}
	}

	assert(vk_context.depth_image_format != .UNDEFINED);

	depth_image_info: Vk.ImageCreateInfo;
	depth_image_info.imageType = ._2D;
	depth_image_info.format = vk_context.depth_image_format;
	depth_image_info.extent = {vk_context.window_size.width, vk_context.window_size.height, 1};
	depth_image_info.mipLevels = 1;
	depth_image_info.arrayLayers = 1;
	depth_image_info.samples = ._1_BIT;
	depth_image_info.tiling = .OPTIMAL;
	depth_image_info.usage = .DEPTH_STENCIL_ATTACHMENT_BIT;
	depth_image_info.initialLayout = .UNDEFINED;

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

	depth_view_info: Vk.ImageViewCreateInfo;
	depth_view_info.image = vk_context.depth_image;
	depth_view_info.viewType = ._2D;
	depth_view_info.format = vk_context.depth_image_format;
	depth_view_info.subresourceRange = {aspectMask=.DEPTH_BIT, levelCount=1, layerCount=1};
	chk(Vk.CreateImageView(vk_context.device, *depth_view_info, null, *vk_context.depth_image_view));
}

vulkan_upload_mesh :: (allocator: VmaAllocator, mesh: Mesh) -> Vulkan_Mesh {
	vulkan_mesh: Vulkan_Mesh;
	v_buf_size := cast(Vk.DeviceSize, size_of(type_of(mesh.vertices[0])) * mesh.vertices.count);
	i_buf_size := cast(Vk.DeviceSize, size_of(type_of(mesh.indices[0])) * mesh.indices.count);
	alloc_info: VmaAllocationInfo;
	vulkan_mesh.mesh_buffer, vulkan_mesh.mesh_buffer_allocation, alloc_info = vulkan_create_buffer(
		allocator,
		v_buf_size + i_buf_size,
		.VERTEX_BUFFER_BIT | .INDEX_BUFFER_BIT,
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
			.SHADER_DEVICE_ADDRESS_BIT,
			.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT | .MAPPED_BIT,
		);
		uniform_buffer_bda_info: Vk.BufferDeviceAddressInfo;
		uniform_buffer_bda_info.buffer = data_buff.buffer;
		data_buff.device_address = Vk.GetBufferDeviceAddress(vk_context.device, *uniform_buffer_bda_info);
	}
}

vulkan_free_shader_data_buffers :: (using vk_context: *Vulkan_Context) {
	for * shader_data_buffers {
		vmaDestroyBuffer(allocator, it.buffer, it.allocation);
	}
}

vulkan_allocate_command_buffers :: (vk_context: *Vulkan_Context) {
	command_pool_info: Vk.CommandPoolCreateInfo;
	command_pool_info.flags = .RESET_COMMAND_BUFFER_BIT;
	command_pool_info.queueFamilyIndex = vk_context.queue_family;
	chk(Vk.CreateCommandPool(vk_context.device, *command_pool_info, null, *vk_context.command_pool));
	cb_alloc_info: Vk.CommandBufferAllocateInfo;
	cb_alloc_info.commandPool = vk_context.command_pool;
	cb_alloc_info.commandBufferCount = MAX_FRAMES_IN_FLIGHT;
	chk(Vk.AllocateCommandBuffers(vk_context.device, *cb_alloc_info, vk_context.command_buffers.data));
}

vulkan_create_semaphore :: (device: Vk.Device) -> Vk.Semaphore
{
	create_info : Vk.SemaphoreCreateInfo;
	semaphore : Vk.Semaphore;
	chk(Vk.CreateSemaphore(device, *create_info, null, *semaphore));
	return semaphore;
}

vulkan_destroy_semaphore :: (device: Vk.Device, semaphore : *Vk.Semaphore)
{
	Vk.DestroySemaphore(device, semaphore.*, null);
	semaphore.* = null;
}

vulkan_create_fence :: (device: Vk.Device, signaled : bool) -> Vk.Fence
{
	create_info : Vk.FenceCreateInfo;
	if signaled create_info.flags = .SIGNALED_BIT;
	fence : Vk.Fence;
	result := Vk.CreateFence(device, *create_info, null, *fence);
	return fence;
}


vulkan_destroy_fence :: (device: Vk.Device, fence : *Vk.Fence)
{
	Vk.DestroyFence(device, fence.*, null);
	fence.* = null;
}

vulkan_create_buffer :: (
	allocator: VmaAllocator,
	size: Vk.DeviceSize,
	usage: Vk.BufferUsageFlags,
	alloc_flags: VmaAllocationCreateFlags
) -> Vk.Buffer, VmaAllocation, VmaAllocationInfo {
	buffer_info: Vk.BufferCreateInfo;
	buffer_info.size = size;
	buffer_info.usage = usage;
	buffer_alloc_create_info: VmaAllocationCreateInfo;
	buffer_alloc_create_info.flags = alloc_flags;
	buffer_alloc_create_info.usage = .AUTO;
	buffer_alloc_info: VmaAllocationInfo;

	buffer: Vk.Buffer;
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
		if type_info(Procedure).return_types.count != 0 then print(*builder, "assert(result == .SUCCESS);");
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
