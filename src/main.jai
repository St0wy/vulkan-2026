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
#load "renderer.jai";

main :: () {
	window_handle := create_window(1920, 1080, "Vulkan 2026");

	vk_context: Vulkan_Context;
	is_release :: BUILD_TYPE == .RELEASE;
	vulkan_init(*vk_context, window_handle, !is_release, !is_release);
	defer vulkan_deinit(*vk_context);

	ok := vulkan_create_swapchain(*vk_context);
	assert(ok, "Could not create the first swapchain");
	vulkan_create_depth(*vk_context);

	mesh: Mesh;
	{
		start := current_time_monotonic();
		ok, mesh = load_model_obj("data/suzanne.obj");
		delta_ms := to_float64_seconds(current_time_monotonic() - start) * 1000;
		log("Loaded model in %ms", delta_ms);
	}

	object_rotations: [3] Vector3;

	vulkan_mesh := vulkan_upload_mesh(vk_context.allocator, mesh);
	defer vulkan_destroy_mesh(vk_context.allocator, *vulkan_mesh);
	vulkan_allocate_shader_data_buffer(*vk_context);
	defer vulkan_free_shader_data_buffers(*vk_context);
	vulkan_allocate_command_buffers(*vk_context);

	texture_descriptors: [vk_context.textures.count] VkDescriptorImageInfo;
	for * vk_context.textures {
		ktx_data := read_entire_file(tprint("data/suzanne%.ktx2", it_index));
		ok=, ktx_image := ktx_load(ktx_data);
		defer free(*ktx_image);
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

	cam_pos := Vector3.{0, 0, 6};
	last_time := current_time_monotonic();
	left_click := false;
	quit := false;
	while !quit {
		chk(vkWaitForFences(vk_context.device, 1, *vk_context.fences[vk_context.frame_index], VK_TRUE, U64_MAX));
		chk(vkResetFences(vk_context.device, 1, *vk_context.fences[vk_context.frame_index]));

		result := vkAcquireNextImageKHR(vk_context.device, vk_context.swapchain, U64_MAX, vk_context.image_acquired_semaphores[vk_context.frame_index], VK_NULL_HANDLE, *vk_context.image_index);
		if result == .VK_ERROR_OUT_OF_DATE_KHR || result == .VK_SUBOPTIMAL_KHR {
			vk_context.update_swapchain = true;
		} else {
			chk(result);
		}

		if vk_context.window_size.width == 0 && vk_context.window_size.height == 0 then continue;

		aspect_ratio := vk_context.window_size.width.(float) / vk_context.window_size.height.(float);
		FOV_VERTICAL :: 45.0 * PI / 180.0;
		vk_context.shader_data.projection = make_projection_matrix(FOV_VERTICAL, aspect_ratio, 0.1, 32, depth_range_01=true);
		vk_context.shader_data.projection._22 *= -1;
		vk_context.shader_data.view = make_look_at_matrix(cam_pos, {0,0,0}, {0, 1, 0}, x_is_forward=false);
		for 0..2 {
			instance_pos := Vector3.{(it - 1).(float) * 3, 0, 0};
			rotation := rotation_matrix(Matrix4, euler_to_quaternion(object_rotations[it]));
			vk_context.shader_data.model[it] = make_translation_matrix4(instance_pos) * rotation;
		}

		memcpy(vk_context.shader_data_buffers[vk_context.frame_index].allocation_info.pMappedData, *vk_context.shader_data, size_of(Vulkan_Shader_Data));

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
		vkCmdBindVertexBuffers(cb, 0, 1, *vulkan_mesh.mesh_buffer, *v_offset);
		v_buf_size := cast(VkDeviceSize, size_of(type_of(mesh.vertices[0])) * mesh.vertices.count);
		vkCmdBindIndexBuffer(cb, vulkan_mesh.mesh_buffer, v_buf_size, .VK_INDEX_TYPE_UINT32);

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
		if result == .VK_ERROR_OUT_OF_DATE_KHR || result == .VK_SUBOPTIMAL_KHR {
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
				if it.key_code == .MOUSE_BUTTON_LEFT {
					left_click = it.key_pressed != 0;
				}

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
				cam_pos.z -= it.wheel_delta.(float) * delta_time * 10;
			}
		}

		if left_click {
			object_rotations[vk_context.shader_data.selected].x += mouse_delta_y.(float) * delta_time;
			object_rotations[vk_context.shader_data.selected].y += mouse_delta_x.(float) * delta_time;
		}

		resizes := get_window_resizes();
		for record: resizes {
			if record.window == window_handle {
				vk_context.window_size = {xx record.width, xx record.height};
				vk_context.update_swapchain = true;
			}
		}

		if vk_context.update_swapchain {
			vk_context.update_swapchain = false;
			ok = vulkan_create_swapchain(*vk_context, vk_context.window_size.width, vk_context.window_size.height);
			if ok vulkan_create_depth(*vk_context);
		}
	}

	chk(vkDeviceWaitIdle(vk_context.device));
}
