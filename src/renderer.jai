
#load "vk_init.jai";

MAX_FRAMES_IN_FLIGHT :: 2;

Shader_Data_Buffer :: struct {
	allocation: Vma.Allocation;
	allocation_info: Vma.AllocationInfo;
	buffer: Vk.Buffer;
	device_address: Vk.DeviceAddress;
}

Gpu_Texture :: struct {
	allocation: Vma.Allocation;
	image: Vk.Image;
	view: Vk.ImageView;
	sampler: Vk.Sampler;
}

// Verticies and indicies are stored in the same buffer
Gpu_Mesh :: struct {
	buffer: Vk.Buffer;
	allocation: Vma.Allocation;
	index_offset: Vk.DeviceSize;
	index_count: u32;
}

Renderer :: struct {
	instance: Vk.Instance;
	debug_utils_messenger: Vk.DebugUtilsMessengerEXT;
	physical_device: Vk.PhysicalDevice;
	device: Vk.Device;
	queue: Vk.Queue;
	allocator: Vma.Allocator;
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
	depth_image_allocation: Vma.Allocation;
	depth_image_view: Vk.ImageView;
	shader_data_buffers: [MAX_FRAMES_IN_FLIGHT] Shader_Data_Buffer;
	command_buffers: [MAX_FRAMES_IN_FLIGHT] Vk.CommandBuffer;
	fences: [MAX_FRAMES_IN_FLIGHT] Vk.Fence;
	image_acquired_semaphores: [MAX_FRAMES_IN_FLIGHT] Vk.Semaphore;
	shader_module: Vk.ShaderModule;
	queue_family: u32;
	descriptor_set_layout_tex: Vk.DescriptorSetLayout;
	descriptor_pool: Vk.DescriptorPool;
	descriptor_set_tex: Vk.DescriptorSet;
	pipeline_layout: Vk.PipelineLayout;
	pipeline: Vk.Pipeline;
	frame_index: u32;
	image_index: u32;
	update_swapchain: bool;
	current_cb: Vk.CommandBuffer;

	command_pool: Vk.CommandPool;
	immediate_fence: Vk.Fence;
	immediate_command_buffer: Vk.CommandBuffer;
}

rederer_init :: (
	using r: *Renderer,
	handle: Window_Type,
	$want_validation_layers := true,
) {
	r.window = handle;

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
		#if want_validation_layers then array_add(*desired_instance_extensions, Vk.EXT_DEBUG_UTILS_EXTENSION_NAME);

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
		vk_functions := Vma.VulkanFunctions.{
			vkGetInstanceProcAddr = Vk.GetInstanceProcAddr,
			vkGetDeviceProcAddr = Vk.GetDeviceProcAddr,
			vkCreateImage = Vk.CreateImage,
		};
		allocator_info := Vma.AllocatorCreateInfo.{
			flags = .BUFFER_DEVICE_ADDRESS_BIT,
			physicalDevice = physical_device,
			device = device,
			pVulkanFunctions = *vk_functions,
			instance = instance,
		};
		chk(Vma.CreateAllocator(*allocator_info, *allocator));
	}

	surface = create_surface(instance, r.window);

	ok := vulkan_create_swapchain(r);
	assert(ok, "Could not create the first swapchain");
	vulkan_create_depth(r);

	command_pool_info: Vk.CommandPoolCreateInfo;
	command_pool_info.flags = .RESET_COMMAND_BUFFER_BIT;
	command_pool_info.queueFamilyIndex = r.queue_family;
	chk(Vk.CreateCommandPool(r.device, *command_pool_info, null, *r.command_pool));
	cb_alloc_info: Vk.CommandBufferAllocateInfo;
	cb_alloc_info.commandPool = r.command_pool;
	cb_alloc_info.commandBufferCount = MAX_FRAMES_IN_FLIGHT;
	chk(Vk.AllocateCommandBuffers(r.device, *cb_alloc_info, r.command_buffers.data));

	r.immediate_fence = vulkan_create_fence(r.device, signaled=false);

	cb_one_time_info: Vk.CommandBufferAllocateInfo;
	cb_one_time_info.commandPool = r.command_pool;
	cb_one_time_info.commandBufferCount = 1;
	chk(Vk.AllocateCommandBuffers(r.device, *cb_one_time_info, *r.immediate_command_buffer));

	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		data_buff := *shader_data_buffers[it];
		data_buff.buffer, data_buff.allocation, data_buff.allocation_info = vulkan_create_buffer(
			allocator,
			size_of(Shader_Data),
			.SHADER_DEVICE_ADDRESS_BIT,
			.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT | .MAPPED_BIT,
		);
		uniform_buffer_bda_info: Vk.BufferDeviceAddressInfo;
		uniform_buffer_bda_info.buffer = data_buff.buffer;
		data_buff.device_address = Vk.GetBufferDeviceAddress(device, *uniform_buffer_bda_info);
	}
}

renderer_deinit :: (using r: *Renderer) {
	chk(Vk.DeviceWaitIdle(device));

	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		Vk.DestroyFence(device, fences[it], null);
		Vk.DestroySemaphore(device, image_acquired_semaphores[it], null);
		Vma.DestroyBuffer(allocator, shader_data_buffers[it].buffer, shader_data_buffers[it].allocation);
	}
	for render_complete_semaphores Vk.DestroySemaphore(device, it, null);
	Vma.DestroyImage(allocator, depth_image, depth_image_allocation);
	Vk.DestroyImageView(device, depth_image_view, null);
	for swapchain_image_views Vk.DestroyImageView(device, it, null);
	Vk.DestroyDescriptorSetLayout(device, descriptor_set_layout_tex, null);
	Vk.DestroyDescriptorPool(device, descriptor_pool, null);
	Vk.DestroyPipelineLayout(device, pipeline_layout, null);
	Vk.DestroyPipeline(device, pipeline, null);
	Vk.DestroySwapchainKHR(device, swapchain, null);
	Vk.DestroySurfaceKHR(instance, surface, null);
	Vk.DestroyCommandPool(device, command_pool, null);
	Vk.DestroyFence(device, immediate_fence, null);
	Vk.DestroyShaderModule(device, shader_module, null);
	Vma.DestroyAllocator(allocator);
	Vk.DestroyDevice(device, null);
	if debug_utils_messenger then Vk.DestroyDebugUtilsMessengerEXT(instance, debug_utils_messenger, null);
	Vk.DestroyInstance(instance, null);
	Vk.finalize();
}

renderer_resize :: (r: *Renderer, width: u32, height: u32) {
	r.window_size = {width, height};
	r.update_swapchain = true;
}

renderer_upload_mesh :: (r: *Renderer, mesh: Mesh) -> Gpu_Mesh {
	gpu_mesh: Gpu_Mesh;
	v_buf_size := cast(Vk.DeviceSize, size_of(type_of(mesh.vertices[0])) * mesh.vertices.count);
	i_buf_size := cast(Vk.DeviceSize, size_of(type_of(mesh.indices[0])) * mesh.indices.count);
	alloc_info: Vma.AllocationInfo;
	gpu_mesh.buffer, gpu_mesh.allocation, alloc_info = vulkan_create_buffer(
		r.allocator,
		v_buf_size + i_buf_size,
		.VERTEX_BUFFER_BIT | .INDEX_BUFFER_BIT,
		.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT | .MAPPED_BIT
	);
	memcpy(alloc_info.pMappedData, mesh.vertices.data, xx v_buf_size);
	memcpy(alloc_info.pMappedData.(*u8) + v_buf_size, mesh.indices.data, xx i_buf_size);

	gpu_mesh.index_offset = v_buf_size;
	gpu_mesh.index_count = xx mesh.indices.count;

	return gpu_mesh;
}

renderer_destroy_mesh :: (r: *Renderer, gpu_mesh: *Gpu_Mesh) {
	Vma.DestroyBuffer(r.allocator, gpu_mesh.buffer, gpu_mesh.allocation);
	gpu_mesh.* = {};
}

renderer_create_texture :: (r: *Renderer, ktx: Ktx_Image) -> Gpu_Texture {
	gpu_texture: Gpu_Texture;
	texture_info := image_create_info(
		ktx.vulkan_format,
		.TRANSFER_DST_BIT | .SAMPLED_BIT,
		{width=ktx.width, height=ktx.height, depth=1},
		ktx.level_count,
	);
	texture_alloc_ci := Vma.AllocationCreateInfo.{usage=.AUTO};
	chk(Vma.CreateImage(r.allocator, *texture_info, *texture_alloc_ci, *gpu_texture.image, *gpu_texture.allocation, null));

	texture_view_info: Vk.ImageViewCreateInfo;
	texture_view_info.image = gpu_texture.image;
	texture_view_info.viewType = ._2D;
	texture_view_info.format = texture_info.format;
	texture_view_info.subresourceRange = {
		aspectMask = .COLOR_BIT,
		levelCount = ktx.level_count,
		layerCount = 1
	};
	chk(Vk.CreateImageView(r.device, *texture_view_info, null, *gpu_texture.view));

	image_source_buffer, image_source_allocation, image_source_allocation_info := vulkan_create_buffer(
		r.allocator,
		xx ktx.image_data.count,
		.TRANSFER_SRC_BIT,
		.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .MAPPED_BIT
	);

	memcpy(image_source_allocation_info.pMappedData, ktx.image_data.data, ktx.image_data.count);

	begin_one_time_commands(r);

	transition_image(r.immediate_command_buffer, gpu_texture.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL);

	copy_regions := make_temp_dyn_array(Vk.BufferImageCopy);
	for ktx.mipmap_offsets {
		region_width := ktx.width >> it_index;
		region_height := ktx.height >> it_index;
		region := Vk.BufferImageCopy.{
			bufferOffset = it.byte_offset,
			imageSubresource = {aspectMask=.COLOR_BIT, mipLevel=xx it_index, layerCount=1},
			imageExtent = {width=region_width, height=region_height, depth=1},
		};
		array_add(*copy_regions, region);
	}

	Vk.CmdCopyBufferToImage(
		r.immediate_command_buffer,
		image_source_buffer,
		gpu_texture.image,
		.TRANSFER_DST_OPTIMAL,
		xx copy_regions.count,
		copy_regions.data
	);

	transition_image(r.immediate_command_buffer, gpu_texture.image, .TRANSFER_DST_OPTIMAL, .READ_ONLY_OPTIMAL);

	end_one_time_commands(*renderer);

	Vma.DestroyBuffer(r.allocator, image_source_buffer, image_source_allocation);

	sampler_info: Vk.SamplerCreateInfo;
	sampler_info.magFilter = .LINEAR;
	sampler_info.minFilter = .LINEAR;
	sampler_info.mipmapMode = .LINEAR;
	sampler_info.anisotropyEnable = Vk.TRUE;
	sampler_info.maxAnisotropy = 8.0;
	sampler_info.maxLod = ktx.level_count.(float);
	chk(Vk.CreateSampler(r.device, *sampler_info, null, *gpu_texture.sampler));

	return gpu_texture;
}

renderer_destroy_texture :: (r: *Renderer, tex: *Gpu_Texture) {
	chk(Vk.DeviceWaitIdle(r.device));
	Vk.DestroyImageView(r.device, tex.view, null);
	Vk.DestroySampler(r.device, tex.sampler, null);
	Vma.DestroyImage(r.allocator, tex.image, tex.allocation);
	tex.* = {};
}

renderer_create_texture_set :: (r: *Renderer, textures: [] Gpu_Texture) {
	count := textures.count.(u32);

	desc_variable_flag := Vk.DescriptorBindingFlags.VARIABLE_DESCRIPTOR_COUNT_BIT;
	desc_binding_flags: Vk.DescriptorSetLayoutBindingFlagsCreateInfo;
	desc_binding_flags.bindingCount = 1;
	desc_binding_flags.pBindingFlags = *desc_variable_flag;
	desc_layout_binding_tex: Vk.DescriptorSetLayoutBinding;
	desc_layout_binding_tex.descriptorType = .COMBINED_IMAGE_SAMPLER;
	desc_layout_binding_tex.descriptorCount = count;
	desc_layout_binding_tex.stageFlags = .FRAGMENT_BIT;
	desc_layout_tex_ci: Vk.DescriptorSetLayoutCreateInfo;
	desc_layout_tex_ci.pNext = *desc_binding_flags;
	desc_layout_tex_ci.bindingCount = 1;
	desc_layout_tex_ci.pBindings = *desc_layout_binding_tex;
	chk(Vk.CreateDescriptorSetLayout(r.device, *desc_layout_tex_ci, null, *r.descriptor_set_layout_tex));

	pool_size: Vk.DescriptorPoolSize;
	pool_size.type = .COMBINED_IMAGE_SAMPLER;
	pool_size.descriptorCount = count;
	desc_pool_ci: Vk.DescriptorPoolCreateInfo;
	desc_pool_ci.maxSets = 1;
	desc_pool_ci.poolSizeCount = 1;
	desc_pool_ci.pPoolSizes = *pool_size;
	chk(Vk.CreateDescriptorPool(r.device, *desc_pool_ci, null, *r.descriptor_pool));

	variable_desc_count_ai: Vk.DescriptorSetVariableDescriptorCountAllocateInfo;
	variable_desc_count_ai.descriptorSetCount = 1;
	variable_desc_count_ai.pDescriptorCounts = *count;
	tex_desc_set_alloc: Vk.DescriptorSetAllocateInfo;
	tex_desc_set_alloc.pNext = *variable_desc_count_ai;
	tex_desc_set_alloc.descriptorPool = r.descriptor_pool;
	tex_desc_set_alloc.descriptorSetCount = 1;
	tex_desc_set_alloc.pSetLayouts = *r.descriptor_set_layout_tex;
	chk(Vk.AllocateDescriptorSets(r.device, *tex_desc_set_alloc, *r.descriptor_set_tex));

	texture_descriptors := make_temp_dyn_array(Vk.DescriptorImageInfo);
	for textures {
		array_add(*texture_descriptors, texture_get_descriptor(it));
	}

	write_desc_set: Vk.WriteDescriptorSet;
	write_desc_set.dstSet = r.descriptor_set_tex;
	write_desc_set.dstBinding = 0;
	write_desc_set.descriptorType = .COMBINED_IMAGE_SAMPLER;
	write_desc_set.descriptorCount = count;
	write_desc_set.pImageInfo = texture_descriptors.data;
	Vk.UpdateDescriptorSets(r.device, 1, *write_desc_set, 0, null);
}

renderer_create_pipeline :: (r: *Renderer, spirv: string) -> bool {
	shader_module_ci: Vk.ShaderModuleCreateInfo;
	shader_module_ci.codeSize = xx spirv.count;
	shader_module_ci.pCode = spirv.data.(*u32);
	chk(Vk.CreateShaderModule(r.device, *shader_module_ci, null, *r.shader_module));

	push_constant_range: Vk.PushConstantRange;
	push_constant_range.stageFlags = .VERTEX_BIT;
	push_constant_range.size = size_of(Vk.DeviceAddress);
	pipeline_layout_ci: Vk.PipelineLayoutCreateInfo;
	pipeline_layout_ci.setLayoutCount = 1;
	pipeline_layout_ci.pSetLayouts = *r.descriptor_set_layout_tex;
	pipeline_layout_ci.pushConstantRangeCount = 1;
	pipeline_layout_ci.pPushConstantRanges = *push_constant_range;
	chk(Vk.CreatePipelineLayout(r.device, *pipeline_layout_ci, null, *r.pipeline_layout));

	vertex_binding: Vk.VertexInputBindingDescription;
	vertex_binding.stride = size_of(Vertex);
	vertex_binding.inputRate = .VERTEX;
	// TODO Try to generate this automatically
	vertex_attributes := Vk.VertexInputAttributeDescription.[
		{location=0, binding=0, format=.R32G32B32_SFLOAT},
		{location=1, binding=0, format=.R32G32B32_SFLOAT, offset=xx offset_of(Vertex, #code normal)},
		{location=2, binding=0, format=.R32G32_SFLOAT, offset=xx offset_of(Vertex, #code tex_coords)},
	];

	vertex_input_state: Vk.PipelineVertexInputStateCreateInfo;
	vertex_input_state.vertexBindingDescriptionCount = 1;
	vertex_input_state.pVertexBindingDescriptions = *vertex_binding;
	vertex_input_state.vertexAttributeDescriptionCount = vertex_attributes.count;
	vertex_input_state.pVertexAttributeDescriptions = vertex_attributes.data;

	input_assembly_state: Vk.PipelineInputAssemblyStateCreateInfo;
	input_assembly_state.topology = .TRIANGLE_LIST;

	shader_stages := Vk.PipelineShaderStageCreateInfo.[
		{stage=.VERTEX_BIT, module=renderer.shader_module, pName="main"},
		{stage=.FRAGMENT_BIT, module=renderer.shader_module, pName="main"},
	];

	viewport_state: Vk.PipelineViewportStateCreateInfo;
	viewport_state.viewportCount = 1;
	viewport_state.scissorCount = 1;
	dynamic_states := Vk.DynamicState.[.VIEWPORT, .SCISSOR];
	dynamic_state: Vk.PipelineDynamicStateCreateInfo;
	dynamic_state.dynamicStateCount = dynamic_states.count;
	dynamic_state.pDynamicStates = dynamic_states.data;

	depth_stencil_state: Vk.PipelineDepthStencilStateCreateInfo;
	depth_stencil_state.depthTestEnable = Vk.TRUE;
	depth_stencil_state.depthWriteEnable = Vk.TRUE;
	depth_stencil_state.depthCompareOp = .LESS_OR_EQUAL;

	rendering_ci: Vk.PipelineRenderingCreateInfo;
	rendering_ci.colorAttachmentCount = 1;
	rendering_ci.pColorAttachmentFormats = *renderer.swapchain_image_format;
	rendering_ci.depthAttachmentFormat = renderer.depth_image_format;

	blend_attachment := Vk.PipelineColorBlendAttachmentState.{colorWriteMask=0xF};
	color_blend_state: Vk.PipelineColorBlendStateCreateInfo;
	color_blend_state.attachmentCount = 1;
	color_blend_state.pAttachments = *blend_attachment;
	rasterization_state: Vk.PipelineRasterizationStateCreateInfo;
	rasterization_state.lineWidth = 1.0;
	multisample_state: Vk.PipelineMultisampleStateCreateInfo;
	multisample_state.rasterizationSamples = ._1_BIT;

	pipeline_ci: Vk.GraphicsPipelineCreateInfo;
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
	pipeline_ci.layout = renderer.pipeline_layout;
	chk(Vk.CreateGraphicsPipelines(renderer.device, Vk.NULL_HANDLE, 1, *pipeline_ci, null, *renderer.pipeline));

	return true;
}

begin_frame :: (using r: *Renderer, clear_color := Vector4.{0, 0, 0, 1}) -> bool {
	if update_swapchain {
		update_swapchain = false;
		ok := vulkan_create_swapchain(r, window_size.width, window_size.height);
		if ok vulkan_create_depth(r);
	}

	if window_size.width == 0 || window_size.height == 0 then return false;

	chk(Vk.WaitForFences(device, 1, *fences[frame_index], Vk.TRUE, U64_MAX));
	chk(Vk.ResetFences(device, 1, *fences[frame_index]));

	result := Vk.AcquireNextImageKHR(device, swapchain, U64_MAX, image_acquired_semaphores[frame_index], Vk.NULL_HANDLE, *image_index);
	if result == .ERROR_OUT_OF_DATE_KHR {
		update_swapchain = true;
		return false;
	} else if result == .SUBOPTIMAL_KHR {
		update_swapchain = true;
	} else {
		chk(result);
	}

	current_cb = command_buffers[frame_index];
	chk(Vk.ResetCommandBuffer(current_cb, 0));

	cb_bi: Vk.CommandBufferBeginInfo;
	cb_bi.flags = .ONE_TIME_SUBMIT_BIT;
	chk(Vk.BeginCommandBuffer(current_cb, *cb_bi));

	output_barriers := Vk.ImageMemoryBarrier2.[
		{
			srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT,
			dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT,
			dstAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT,
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = swapchain_images[image_index],
			subresourceRange = {aspectMask=.COLOR_BIT, levelCount=1, layerCount=1},
		},
		{
			srcStageMask = .LATE_FRAGMENT_TESTS_BIT,
			srcAccessMask = .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			dstStageMask = .EARLY_FRAGMENT_TESTS_BIT,
			dstAccessMask = .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = depth_image,
			subresourceRange = {aspectMask=.DEPTH_BIT | .STENCIL_BIT, levelCount=1, layerCount=1},
		}
	];

	barrier_dependency_info: Vk.DependencyInfo;
	barrier_dependency_info.imageMemoryBarrierCount = output_barriers.count;
	barrier_dependency_info.pImageMemoryBarriers = output_barriers.data;
	Vk.CmdPipelineBarrier2(current_cb, *barrier_dependency_info);

	color_attachment_info: Vk.RenderingAttachmentInfo;
	color_attachment_info.imageView = swapchain_image_views[image_index];
	color_attachment_info.imageLayout = .COLOR_ATTACHMENT_OPTIMAL;
	color_attachment_info.loadOp = .CLEAR;
	color_attachment_info.storeOp = .STORE;
	color_attachment_info.clearValue.color.float32_ = .[0, 0, 0.2, 1.0];
	depth_attachment_info: Vk.RenderingAttachmentInfo;
	depth_attachment_info.imageView = depth_image_view;
	depth_attachment_info.imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
	depth_attachment_info.loadOp = .CLEAR;
	depth_attachment_info.storeOp = .DONT_CARE;
	depth_attachment_info.clearValue.depthStencil = {1.0, 0};

	rendering_info: Vk.RenderingInfo;
	rendering_info.renderArea = {extent=window_size};
	rendering_info.layerCount = 1;
	rendering_info.colorAttachmentCount = 1;
	rendering_info.pColorAttachments = *color_attachment_info;
	rendering_info.pDepthAttachment = *depth_attachment_info;
	Vk.CmdBeginRendering(current_cb, *rendering_info);

	vp := Vk.Viewport.{
		width = window_size.width.(float),
		height = window_size.height.(float),
		minDepth = 0,
		maxDepth = 1,
	};
	Vk.CmdSetViewport(current_cb, 0, 1, *vp);
	scissor := Vk.Rect2D.{extent=window_size};
	Vk.CmdSetScissor(current_cb, 0, 1, *scissor);

	Vk.CmdBindPipeline(current_cb, .GRAPHICS, pipeline);
	Vk.CmdBindDescriptorSets(current_cb, .GRAPHICS, pipeline_layout, 0, 1, *descriptor_set_tex, 0, null);

	Vk.CmdPushConstants(
		current_cb,
		pipeline_layout,
		.VERTEX_BIT,
		0,
		size_of(Vk.DeviceAddress),
		*shader_data_buffers[frame_index].device_address
	);
	return true;
}

draw_mesh :: (r: *Renderer, mesh: Gpu_Mesh, instance_count: u32 = 1) {
	v_offset: Vk.DeviceSize;
	Vk.CmdBindVertexBuffers(r.current_cb, 0, 1, *mesh.buffer, *v_offset);
	Vk.CmdBindIndexBuffer(r.current_cb, mesh.buffer, mesh.index_offset, .UINT32);
	Vk.CmdDrawIndexed(r.current_cb, mesh.index_count, instance_count, 0, 0, 0);
}

end_frame :: (using r: *Renderer) {
	Vk.CmdEndRendering(current_cb);

	barrier_present: Vk.ImageMemoryBarrier2;
	barrier_present.srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
	barrier_present.srcAccessMask = .COLOR_ATTACHMENT_WRITE_BIT;
	barrier_present.dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
	barrier_present.oldLayout = .ATTACHMENT_OPTIMAL;
	barrier_present.newLayout = .PRESENT_SRC_KHR;
	barrier_present.image = swapchain_images[image_index];
	barrier_present.subresourceRange = {aspectMask=.COLOR_BIT, levelCount=1, layerCount = 1};
	barrier_present_dependency_info: Vk.DependencyInfo;
	barrier_present_dependency_info.imageMemoryBarrierCount = 1;
	barrier_present_dependency_info.pImageMemoryBarriers = *barrier_present;
	Vk.CmdPipelineBarrier2(current_cb, *barrier_present_dependency_info);

	Vk.EndCommandBuffer(current_cb);

	wait_semaphore_info: Vk.SemaphoreSubmitInfo;
	wait_semaphore_info.semaphore = image_acquired_semaphores[frame_index];
	wait_semaphore_info.stageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
	command_buffer_submit_info: Vk.CommandBufferSubmitInfo;
	command_buffer_submit_info.commandBuffer = current_cb;
	signal_semaphore_info: Vk.SemaphoreSubmitInfo;
	signal_semaphore_info.semaphore = render_complete_semaphores[image_index];
	signal_semaphore_info.stageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
	submit_info: Vk.SubmitInfo2;
	submit_info.waitSemaphoreInfoCount = 1;
	submit_info.pWaitSemaphoreInfos = *wait_semaphore_info;
	submit_info.commandBufferInfoCount = 1;
	submit_info.pCommandBufferInfos = *command_buffer_submit_info;
	submit_info.signalSemaphoreInfoCount = 1;
	submit_info.pSignalSemaphoreInfos = *signal_semaphore_info;
	chk(Vk.QueueSubmit2(queue, 1, *submit_info, fences[frame_index]));

	frame_index = (frame_index + 1) % MAX_FRAMES_IN_FLIGHT;

	present_info: Vk.PresentInfoKHR;
	present_info.waitSemaphoreCount = 1;
	present_info.pWaitSemaphores = *render_complete_semaphores[image_index];
	present_info.swapchainCount = 1;
	present_info.pSwapchains = *swapchain;
	present_info.pImageIndices = *image_index;
	result := Vk.QueuePresentKHR(queue, *present_info);
	if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
		update_swapchain = true;
	} else {
		chk(result);
	}
}

set_shader_data :: (r: *Renderer, data: *Shader_Data) {
	memcpy(r.shader_data_buffers[r.frame_index].allocation_info.pMappedData, data, size_of(type_of(data.*)));
}

// #scope_file

begin_one_time_commands :: (r: *Renderer) {
	chk(Vk.ResetFences(r.device, 1, *r.immediate_fence));
	chk(Vk.ResetCommandBuffer(r.immediate_command_buffer, 0));
	begin_info := command_buffer_begin_info(.ONE_TIME_SUBMIT_BIT);
	chk(Vk.BeginCommandBuffer(r.immediate_command_buffer, *begin_info));
}

end_one_time_commands :: (r: *Renderer) {
	chk(Vk.EndCommandBuffer(r.immediate_command_buffer));
	cmd_submit_info := command_buffer_submit_info(r.immediate_command_buffer);
	submit_info := submit_info_2(*cmd_submit_info);
	chk(Vk.QueueSubmit2(r.queue, 1, *submit_info, r.immediate_fence));
	chk(Vk.WaitForFences(r.device, 1, *r.immediate_fence, Vk.TRUE, U64_MAX));
}

vulkan_create_swapchain :: (r: *Renderer, width: int = -1, height: int = -1) -> bool {
	chk(Vk.DeviceWaitIdle(r.device));
	surface_capabilities: Vk.SurfaceCapabilitiesKHR;
	chk(Vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.physical_device, r.surface, *surface_capabilities));

	if surface_capabilities.maxImageExtent.width == 0 || surface_capabilities.maxImageExtent.height == 0 {
		return false;
	}

	r.window_size = surface_capabilities.currentExtent;
	if width != -1 || height != -1 {
		r.window_size = {xx width, xx height};
	} else if r.window_size.width == 0xFFFFFFFF {
		x, y, win_width, win_height, ok := get_dimensions(r.window, right_handed=false);
		assert(ok);
		r.window_size = {xx win_width, xx win_height};
	}

	r.swapchain_image_format = .B8G8R8A8_SRGB;
	swapchain_info: Vk.SwapchainCreateInfoKHR;
	swapchain_info.surface = r.surface;
	swapchain_info.minImageCount = surface_capabilities.minImageCount;
	swapchain_info.imageFormat = r.swapchain_image_format;
	swapchain_info.imageColorSpace = .SRGB_NONLINEAR_KHR;
	swapchain_info.imageExtent = r.window_size;
	swapchain_info.imageArrayLayers = 1;
	swapchain_info.imageUsage = .COLOR_ATTACHMENT_BIT;
	swapchain_info.preTransform = .IDENTITY_BIT_KHR;
	swapchain_info.compositeAlpha = .OPAQUE_BIT_KHR;
	swapchain_info.presentMode = .FIFO_KHR;
	swapchain_info.oldSwapchain = r.swapchain;
	chk(Vk.CreateSwapchainKHR(r.device, *swapchain_info, null, *r.swapchain));

	if swapchain_info.oldSwapchain then Vk.DestroySwapchainKHR(r.device, swapchain_info.oldSwapchain, null);

	images := vulkan_fill_array(Vk.Image, Vk.GetSwapchainImagesKHR, r.device, r.swapchain);
	if r.swapchain_images.count == 0 {
		r.swapchain_images = alloc_and_copy_array(images);
	} else if r.swapchain_images.count == images.count {
		copy_array_dst_src(r.swapchain_images, images);
	} else {
		assert(false, "Missmatch between old and new swapchain image count");
	}

	for r.swapchain_image_views Vk.DestroyImageView(r.device, it, null);

	new_image_views := make_temp_dyn_array(Vk.ImageView);
	for r.swapchain_images {
		view_info: Vk.ImageViewCreateInfo;
		view_info.image = it;
		view_info.viewType = ._2D;
		view_info.format = r.swapchain_image_format;
		view_info.subresourceRange = {aspectMask=.COLOR_BIT, levelCount=1, layerCount=1};
		image_view: Vk.ImageView;
		chk(Vk.CreateImageView(r.device, *view_info, null, *image_view));
		array_add(*new_image_views, image_view);
	}

	if r.swapchain_image_views.count == 0 {
		r.swapchain_image_views = alloc_and_copy_array(new_image_views);
	} else if r.swapchain_image_views.count == images.count {
		copy_array_dst_src(r.swapchain_image_views, new_image_views);
	} else {
		assert(false, "Missmatch between old and new swapchain image views count");
	}

	for 0..MAX_FRAMES_IN_FLIGHT - 1 {
		if !r.fences[it]
			r.fences[it] = vulkan_create_fence(r.device, signaled=true);
		if !r.image_acquired_semaphores[it]
			r.image_acquired_semaphores[it] = vulkan_create_semaphore(r.device);
	}

	new_render_complete_semaphores := make_temp_dyn_array(Vk.Semaphore);
	for 0..r.swapchain_images.count - 1 {
		array_add(*new_render_complete_semaphores, vulkan_create_semaphore(r.device));
	}

	for * r.render_complete_semaphores {
		vulkan_destroy_semaphore(r.device, it);
	}

	if r.render_complete_semaphores.count == 0 {
		r.render_complete_semaphores = alloc_and_copy_array(new_render_complete_semaphores);
	} else if r.render_complete_semaphores.count == r.swapchain_images.count {
		copy_array_dst_src(r.render_complete_semaphores, new_render_complete_semaphores);
	} else {
		assert(false, "Missmatch between old and new render_complete_semaphores count");
	}

	return true;
}

vulkan_create_depth :: (r: *Renderer) {
	if r.depth_image && r.depth_image_allocation {
		Vma.DestroyImage(r.allocator, r.depth_image, r.depth_image_allocation);
		Vk.DestroyImageView(r.device, r.depth_image_view, null);
	}

	depth_format_list :: Vk.Format.[
		.D32_SFLOAT_S8_UINT,
		.D24_UNORM_S8_UINT
	];

	for depth_format_list {
		format_properties: Vk.FormatProperties2;
		Vk.GetPhysicalDeviceFormatProperties2(r.physical_device, it, *format_properties);
		if format_properties.formatProperties.optimalTilingFeatures & .DEPTH_STENCIL_ATTACHMENT_BIT {
			r.depth_image_format = it;
			break;
		}
	}

	assert(r.depth_image_format != .UNDEFINED);

	depth_image_info: Vk.ImageCreateInfo;
	depth_image_info.imageType = ._2D;
	depth_image_info.format = r.depth_image_format;
	depth_image_info.extent = {r.window_size.width, r.window_size.height, 1};
	depth_image_info.mipLevels = 1;
	depth_image_info.arrayLayers = 1;
	depth_image_info.samples = ._1_BIT;
	depth_image_info.tiling = .OPTIMAL;
	depth_image_info.usage = .DEPTH_STENCIL_ATTACHMENT_BIT;
	depth_image_info.initialLayout = .UNDEFINED;

	alloc_info := Vma.AllocationCreateInfo.{
		flags = .DEDICATED_MEMORY_BIT,
		usage = .AUTO,
	};
	chk(Vma.CreateImage(
		r.allocator,
		*depth_image_info,
		*alloc_info,
		*r.depth_image,
		*r.depth_image_allocation,
		null
	));

	depth_view_info: Vk.ImageViewCreateInfo;
	depth_view_info.image = r.depth_image;
	depth_view_info.viewType = ._2D;
	depth_view_info.format = r.depth_image_format;
	depth_view_info.subresourceRange = {aspectMask=.DEPTH_BIT, levelCount=1, layerCount=1};
	chk(Vk.CreateImageView(r.device, *depth_view_info, null, *r.depth_image_view));
}

vulkan_create_semaphore :: (device: Vk.Device) -> Vk.Semaphore {
	create_info : Vk.SemaphoreCreateInfo;
	semaphore : Vk.Semaphore;
	chk(Vk.CreateSemaphore(device, *create_info, null, *semaphore));
	return semaphore;
}

vulkan_destroy_semaphore :: (device: Vk.Device, semaphore : *Vk.Semaphore) {
	Vk.DestroySemaphore(device, semaphore.*, null);
	semaphore.* = null;
}

vulkan_create_fence :: (device: Vk.Device, signaled : bool) -> Vk.Fence {
	create_info : Vk.FenceCreateInfo;
	if signaled create_info.flags = .SIGNALED_BIT;
	fence : Vk.Fence;
	chk(Vk.CreateFence(device, *create_info, null, *fence));
	return fence;
}

vulkan_destroy_fence :: (device: Vk.Device, fence : *Vk.Fence) {
	Vk.DestroyFence(device, fence.*, null);
	fence.* = null;
}

vulkan_create_buffer :: (
	allocator: Vma.Allocator,
	size: Vk.DeviceSize,
	usage: Vk.BufferUsageFlags,
	alloc_flags: Vma.AllocationCreateFlags
) -> Vk.Buffer, Vma.Allocation, Vma.AllocationInfo {
	buffer_info: Vk.BufferCreateInfo;
	buffer_info.size = size;
	buffer_info.usage = usage;
	buffer_alloc_create_info: Vma.AllocationCreateInfo;
	buffer_alloc_create_info.flags = alloc_flags;
	buffer_alloc_create_info.usage = .AUTO;
	buffer_alloc_info: Vma.AllocationInfo;

	buffer: Vk.Buffer;
	alloc: Vma.Allocation;
	chk(Vma.CreateBuffer(
		allocator,
		*buffer_info,
		*buffer_alloc_create_info,
		*buffer,
		*alloc,
		*buffer_alloc_info
	));

	return buffer, alloc, buffer_alloc_info;
}

Layout_Usage :: struct {
	access: Vk.AccessFlags2;
	stage: Vk.PipelineStageFlags2;
}

layout_usage :: (layout: Vk.ImageLayout) -> Layout_Usage {
	if layout == {
	case .UNDEFINED; #through;
	case .PRESENT_SRC_KHR;
		return {0, .NONE};
	case .TRANSFER_SRC_OPTIMAL;
		return {.TRANSFER_READ_BIT, .TRANSFER_BIT};
	case .TRANSFER_DST_OPTIMAL;
		return {.TRANSFER_WRITE_BIT, .TRANSFER_BIT};
	case .COLOR_ATTACHMENT_OPTIMAL;
		return {.COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT, .COLOR_ATTACHMENT_OUTPUT_BIT};
	case .READ_ONLY_OPTIMAL; #through;
	case .DEPTH_ATTACHMENT_OPTIMAL; #through;
	case .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
		return {
			.DEPTH_STENCIL_ATTACHMENT_READ_BIT | .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			.EARLY_FRAGMENT_TESTS_BIT | .LATE_FRAGMENT_TESTS_BIT,
		};
	case .SHADER_READ_ONLY_OPTIMAL;
		return {.SHADER_SAMPLED_READ_BIT, .FRAGMENT_SHADER_BIT};
	case .GENERAL;
		return {.SHADER_STORAGE_READ_BIT |. SHADER_STORAGE_WRITE_BIT, .COMPUTE_SHADER_BIT};
	case;
		log_error("Transition image, unhandled layout: %", layout);
		return {0, .ALL_COMMANDS_BIT};
	}
}

transition_image :: (cmd: Vk.CommandBuffer, image: Vk.Image, old_layout: Vk.ImageLayout, new_layout: Vk.ImageLayout) {
	src := layout_usage(old_layout);
	dst := layout_usage(new_layout);

	aspect := Vk.ImageAspectFlags.COLOR_BIT;
	if new_layout == .DEPTH_ATTACHMENT_OPTIMAL {
		aspect = .DEPTH_BIT;
	} else if new_layout == .DEPTH_STENCIL_ATTACHMENT_OPTIMAL {
		aspect = .DEPTH_BIT | .STENCIL_BIT;
	}

	barrier: Vk.ImageMemoryBarrier2;
	barrier.srcStageMask = src.stage;
	barrier.srcAccessMask = src.access;
	barrier.dstStageMask = dst.stage;
	barrier.dstAccessMask = dst.access;
	barrier.oldLayout = old_layout;
	barrier.newLayout = new_layout;
	barrier.srcQueueFamilyIndex = Vk.QUEUE_FAMILY_IGNORED;
	barrier.dstQueueFamilyIndex = Vk.QUEUE_FAMILY_IGNORED;
	barrier.image = image;
	barrier.subresourceRange = {
		aspectMask = aspect,
		levelCount = Vk.REMAINING_MIP_LEVELS,
		layerCount = Vk.REMAINING_ARRAY_LAYERS,
	};

	info: Vk.DependencyInfo;
	info.imageMemoryBarrierCount = 1;
	info.pImageMemoryBarriers = *barrier;

	Vk.CmdPipelineBarrier2(cmd, *info);
}

texture_get_descriptor :: (texture: Gpu_Texture) -> Vk.DescriptorImageInfo {
	return {
		sampler = texture.sampler,
		imageView = texture.view,
		imageLayout = .READ_ONLY_OPTIMAL
	};
}

// From modules/osor_vulkan/examples/src/main.jai
vulkan_fill_array :: ($type : Type, procedure : $Procedure, $arguments : ..Code) -> [] type #expand {
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
