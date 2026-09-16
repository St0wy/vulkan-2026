using Basic :: #import "Basic";
#import "Window_Creation";
#import "Input";
#import "Math";
#import "File";
#import "File_Utilities";
Debug :: #import "Debug";

Vma :: #import "jai-vma";
Vk :: #import "Jolk";

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

	texture_descriptors: [vk_context.textures.count] Vk.DescriptorImageInfo;
	for * vk_context.textures {
		ktx_data := read_entire_file(tprint("data/suzanne%.ktx2", it_index));
		ok=, ktx_image := ktx_load(ktx_data);
		defer free(*ktx_image);
		assert(ok, "Could not load texture");

		texture_info: Vk.ImageCreateInfo;
		texture_info.imageType = ._2D;
		texture_info.format = ktx_image.vulkan_format;
		texture_info.extent = {width=ktx_image.width, height=ktx_image.height, depth=1};
		texture_info.mipLevels = ktx_image.level_count;
		texture_info.arrayLayers = 1;
		texture_info.samples = ._1_BIT;
		texture_info.tiling = .OPTIMAL;
		texture_info.usage = .TRANSFER_DST_BIT | .SAMPLED_BIT;
		texture_info.initialLayout = .UNDEFINED;

		texture_alloc_info := Vma.AllocationCreateInfo.{usage=.AUTO};
		chk(Vma.CreateImage(vk_context.allocator, *texture_info, *texture_alloc_info, *it.image, *it.allocation, null));

		texture_view_info: Vk.ImageViewCreateInfo;
		texture_view_info.image = it.image;
		texture_view_info.viewType = ._2D;
		texture_view_info.format = texture_info.format;
		texture_view_info.subresourceRange = {
			aspectMask = .COLOR_BIT,
			levelCount = ktx_image.level_count,
			layerCount = 1
		};
		chk(Vk.CreateImageView(vk_context.device, *texture_view_info, null, *it.view));

		image_source_buffer, image_source_allocation, image_source_allocation_info := vulkan_create_buffer(
			vk_context.allocator,
			xx ktx_image.image_data.count,
			.TRANSFER_SRC_BIT,
			.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .MAPPED_BIT
		);

		memcpy(image_source_allocation_info.pMappedData, ktx_image.image_data.data, ktx_image.image_data.count);

		fence_one_time := vulkan_create_fence(vk_context.device, signaled=false);

		cb_one_time: Vk.CommandBuffer;
		cb_one_time_info: Vk.CommandBufferAllocateInfo;
		cb_one_time_info.commandPool = vk_context.command_pool;
		cb_one_time_info.commandBufferCount = 1;
		chk(Vk.AllocateCommandBuffers(vk_context.device, *cb_one_time_info, *cb_one_time));

		cb_one_time_bi: Vk.CommandBufferBeginInfo;
		cb_one_time_bi.flags = .ONE_TIME_SUBMIT_BIT;
		chk(Vk.BeginCommandBuffer(cb_one_time, *cb_one_time_bi));
		barrier_tex_image: Vk.ImageMemoryBarrier2;
		barrier_tex_image.srcStageMask = .NONE;
		barrier_tex_image.srcAccessMask = .NONE;
		barrier_tex_image.dstStageMask = .TRANSFER_BIT;
		barrier_tex_image.dstAccessMask = .TRANSFER_WRITE_BIT;
		barrier_tex_image.oldLayout = .UNDEFINED;
		barrier_tex_image.newLayout = .TRANSFER_DST_OPTIMAL;
		barrier_tex_image.image = it.image;
		barrier_tex_image.subresourceRange = {aspectMask=.COLOR_BIT, levelCount=ktx_image.level_count, layerCount = 1};
		barrier_tex_info: Vk.DependencyInfo;
		barrier_tex_info.imageMemoryBarrierCount = 1;
		barrier_tex_info.pImageMemoryBarriers = *barrier_tex_image;
		Vk.CmdPipelineBarrier2(cb_one_time, *barrier_tex_info);

		copy_regions := make_temp_dyn_array(Vk.BufferImageCopy);
		for ktx_image.mipmap_offsets {
			region_width := ktx_image.width >> it_index;
			region_height := ktx_image.height >> it_index;
			region := Vk.BufferImageCopy.{
				bufferOffset = it.byte_offset,
				imageSubresource = {aspectMask=.COLOR_BIT, mipLevel=xx it_index, layerCount=1},
				imageExtent = {width=region_width, height=region_height, depth=1},
			};
			array_add(*copy_regions, region);
		}

		Vk.CmdCopyBufferToImage(
			cb_one_time,
			image_source_buffer,
			it.image,
			.TRANSFER_DST_OPTIMAL,
			xx copy_regions.count,
			copy_regions.data
		);

		barrier_tex_read: Vk.ImageMemoryBarrier2;
		barrier_tex_read.srcStageMask = .TRANSFER_BIT;
		barrier_tex_read.srcAccessMask = .TRANSFER_WRITE_BIT;
		barrier_tex_read.dstStageMask = .FRAGMENT_SHADER_BIT;
		barrier_tex_read.dstAccessMask = .SHADER_READ_BIT;
		barrier_tex_read.oldLayout = .TRANSFER_DST_OPTIMAL;
		barrier_tex_read.newLayout = .READ_ONLY_OPTIMAL;
		barrier_tex_read.image = it.image;
		barrier_tex_read.subresourceRange = {aspectMask=.COLOR_BIT, levelCount=ktx_image.level_count, layerCount=1};
		barrier_tex_info.pImageMemoryBarriers = *barrier_tex_read;
		Vk.CmdPipelineBarrier2(cb_one_time, *barrier_tex_info);

		chk(Vk.EndCommandBuffer(cb_one_time));

		cb_one_time_submit_info: Vk.CommandBufferSubmitInfo;
		cb_one_time_submit_info.commandBuffer = cb_one_time;
		one_time_si: Vk.SubmitInfo2;
		one_time_si.commandBufferInfoCount = 1;
		one_time_si.pCommandBufferInfos = *cb_one_time_submit_info;
		chk(Vk.QueueSubmit2(vk_context.queue, 1, *one_time_si, fence_one_time));
		chk(Vk.WaitForFences(vk_context.device, 1, *fence_one_time, Vk.TRUE, U64_MAX));
		Vk.DestroyFence(vk_context.device, fence_one_time, null);
		Vma.DestroyBuffer(vk_context.allocator, image_source_buffer, image_source_allocation);

		sampler_info: Vk.SamplerCreateInfo;
		sampler_info.magFilter = .LINEAR;
		sampler_info.minFilter = .LINEAR;
		sampler_info.mipmapMode = .LINEAR;
		sampler_info.anisotropyEnable = Vk.TRUE;
		sampler_info.maxAnisotropy = 8.0;
		sampler_info.maxLod = ktx_image.level_count.(float);
		chk(Vk.CreateSampler(vk_context.device, *sampler_info, null, *it.sampler));

		texture_descriptors[it_index] = {
			sampler = it.sampler,
			imageView = it.view,
			imageLayout = .READ_ONLY_OPTIMAL
		};
	}

	desc_variable_flag := Vk.DescriptorBindingFlags.VARIABLE_DESCRIPTOR_COUNT_BIT;
	desc_binding_flags: Vk.DescriptorSetLayoutBindingFlagsCreateInfo;
	desc_binding_flags.bindingCount = 1;
	desc_binding_flags.pBindingFlags = *desc_variable_flag;
	desc_layout_binding_tex: Vk.DescriptorSetLayoutBinding;
	desc_layout_binding_tex.descriptorType = .COMBINED_IMAGE_SAMPLER;
	desc_layout_binding_tex.descriptorCount = xx vk_context.textures.count;
	desc_layout_binding_tex.stageFlags = .FRAGMENT_BIT;
	desc_layout_tex_ci: Vk.DescriptorSetLayoutCreateInfo;
	desc_layout_tex_ci.pNext = *desc_binding_flags;
	desc_layout_tex_ci.bindingCount = 1;
	desc_layout_tex_ci.pBindings = *desc_layout_binding_tex;
	chk(Vk.CreateDescriptorSetLayout(vk_context.device, *desc_layout_tex_ci, null, *vk_context.descriptor_set_layout_tex));

	pool_size: Vk.DescriptorPoolSize;
	pool_size.type = .COMBINED_IMAGE_SAMPLER;
	pool_size.descriptorCount = xx vk_context.textures.count;
	desc_pool_ci: Vk.DescriptorPoolCreateInfo;
	desc_pool_ci.maxSets = 1;
	desc_pool_ci.poolSizeCount = 1;
	desc_pool_ci.pPoolSizes = *pool_size;
	chk(Vk.CreateDescriptorPool(vk_context.device, *desc_pool_ci, null, *vk_context.descriptor_pool));

	variable_desc_count := vk_context.textures.count.(u32);
	variable_desc_count_ai: Vk.DescriptorSetVariableDescriptorCountAllocateInfo;
	variable_desc_count_ai.descriptorSetCount = 1;
	variable_desc_count_ai.pDescriptorCounts = *variable_desc_count;
	tex_desc_set_alloc: Vk.DescriptorSetAllocateInfo;
	tex_desc_set_alloc.pNext = *variable_desc_count_ai;
	tex_desc_set_alloc.descriptorPool = vk_context.descriptor_pool;
	tex_desc_set_alloc.descriptorSetCount = 1;
	tex_desc_set_alloc.pSetLayouts = *vk_context.descriptor_set_layout_tex;
	chk(Vk.AllocateDescriptorSets(vk_context.device, *tex_desc_set_alloc, *vk_context.descriptor_set_tex));

	write_desc_set: Vk.WriteDescriptorSet;
	write_desc_set.dstSet = vk_context.descriptor_set_tex;
	write_desc_set.dstBinding = 0;
	write_desc_set.descriptorType = .COMBINED_IMAGE_SAMPLER;
	write_desc_set.descriptorCount = xx texture_descriptors.count;
	write_desc_set.pImageInfo = texture_descriptors.data;
	Vk.UpdateDescriptorSets(vk_context.device, 1, *write_desc_set, 0, null);

	shader_data := read_entire_file("data/shader.spriv");
	shader_module_ci: Vk.ShaderModuleCreateInfo;
	shader_module_ci.codeSize = xx shader_data.count;
	shader_module_ci.pCode = shader_data.data.(*u32);
	chk(Vk.CreateShaderModule(vk_context.device, *shader_module_ci, null, *vk_context.shader_module));

	push_constant_range: Vk.PushConstantRange;
	push_constant_range.stageFlags = .VERTEX_BIT;
	push_constant_range.size = size_of(Vk.DeviceAddress);
	pipeline_layout_ci: Vk.PipelineLayoutCreateInfo;
	pipeline_layout_ci.setLayoutCount = 1;
	pipeline_layout_ci.pSetLayouts = *vk_context.descriptor_set_layout_tex;
	pipeline_layout_ci.pushConstantRangeCount = 1;
	pipeline_layout_ci.pPushConstantRanges = *push_constant_range;
	chk(Vk.CreatePipelineLayout(vk_context.device, *pipeline_layout_ci, null, *vk_context.pipeline_layout));

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
		{stage=.VERTEX_BIT, module=vk_context.shader_module, pName="main"},
		{stage=.FRAGMENT_BIT, module=vk_context.shader_module, pName="main"},
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
	rendering_ci.pColorAttachmentFormats = *vk_context.swapchain_image_format;
	rendering_ci.depthAttachmentFormat = vk_context.depth_image_format;

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
	pipeline_ci.layout = vk_context.pipeline_layout;
	chk(Vk.CreateGraphicsPipelines(vk_context.device, Vk.NULL_HANDLE, 1, *pipeline_ci, null, *vk_context.pipeline));

	cam_pos := Vector3.{0, 0, 6};
	last_time := current_time_monotonic();
	left_click := false;
	quit := false;
	while !quit {
		chk(Vk.WaitForFences(vk_context.device, 1, *vk_context.fences[vk_context.frame_index], Vk.TRUE, U64_MAX));
		chk(Vk.ResetFences(vk_context.device, 1, *vk_context.fences[vk_context.frame_index]));

		result := Vk.AcquireNextImageKHR(vk_context.device, vk_context.swapchain, U64_MAX, vk_context.image_acquired_semaphores[vk_context.frame_index], Vk.NULL_HANDLE, *vk_context.image_index);
		if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
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
		chk(Vk.ResetCommandBuffer(cb, 0));

		cb_bi: Vk.CommandBufferBeginInfo;
		cb_bi.flags = .ONE_TIME_SUBMIT_BIT;
		chk(Vk.BeginCommandBuffer(cb, *cb_bi));

		output_barriers := Vk.ImageMemoryBarrier2.[
			{
				srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT,
				dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT,
				dstAccessMask = .COLOR_ATTACHMENT_READ_BIT | .COLOR_ATTACHMENT_WRITE_BIT,
				oldLayout = .UNDEFINED,
				newLayout = .ATTACHMENT_OPTIMAL,
				image = vk_context.swapchain_images[vk_context.image_index],
				subresourceRange = {aspectMask=.COLOR_BIT, levelCount=1, layerCount=1},
			},
			{
				srcStageMask = .LATE_FRAGMENT_TESTS_BIT,
				srcAccessMask = .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
				dstStageMask = .EARLY_FRAGMENT_TESTS_BIT,
				dstAccessMask = .DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
				oldLayout = .UNDEFINED,
				newLayout = .ATTACHMENT_OPTIMAL,
				image = vk_context.depth_image,
				subresourceRange = {aspectMask=.DEPTH_BIT | .STENCIL_BIT, levelCount=1, layerCount=1},
			}
		];

		barrier_dependency_info: Vk.DependencyInfo;
		barrier_dependency_info.imageMemoryBarrierCount = output_barriers.count;
		barrier_dependency_info.pImageMemoryBarriers = output_barriers.data;
		Vk.CmdPipelineBarrier2(cb, *barrier_dependency_info);

		color_attachment_info: Vk.RenderingAttachmentInfo;
		color_attachment_info.imageView = vk_context.swapchain_image_views[vk_context.image_index];
		color_attachment_info.imageLayout = .COLOR_ATTACHMENT_OPTIMAL;
		color_attachment_info.loadOp = .CLEAR;
		color_attachment_info.storeOp = .STORE;
		color_attachment_info.clearValue.color.float32_ = .[0, 0, 0.2, 1.0];
		depth_attachment_info: Vk.RenderingAttachmentInfo;
		depth_attachment_info.imageView = vk_context.depth_image_view;
		depth_attachment_info.imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
		depth_attachment_info.loadOp = .CLEAR;
		depth_attachment_info.storeOp = .DONT_CARE;
		depth_attachment_info.clearValue.depthStencil = {1.0, 0};

		rendering_info: Vk.RenderingInfo;
		rendering_info.renderArea = {extent=vk_context.window_size};
		rendering_info.layerCount = 1;
		rendering_info.colorAttachmentCount = 1;
		rendering_info.pColorAttachments = *color_attachment_info;
		rendering_info.pDepthAttachment = *depth_attachment_info;
		Vk.CmdBeginRendering(cb, *rendering_info);

		vp := Vk.Viewport.{
			width = vk_context.window_size.width.(float),
			height = vk_context.window_size.height.(float),
			minDepth = 0,
			maxDepth = 1,
		};
		Vk.CmdSetViewport(cb, 0, 1, *vp);
		scissor := Vk.Rect2D.{extent=vk_context.window_size};
		Vk.CmdSetScissor(cb, 0, 1, *scissor);

		Vk.CmdBindPipeline(cb, .GRAPHICS, vk_context.pipeline);
		v_offset: Vk.DeviceSize;
		Vk.CmdBindDescriptorSets(cb, .GRAPHICS, vk_context.pipeline_layout, 0, 1, *vk_context.descriptor_set_tex, 0, null);
		Vk.CmdBindVertexBuffers(cb, 0, 1, *vulkan_mesh.mesh_buffer, *v_offset);
		v_buf_size := cast(Vk.DeviceSize, size_of(type_of(mesh.vertices[0])) * mesh.vertices.count);
		Vk.CmdBindIndexBuffer(cb, vulkan_mesh.mesh_buffer, v_buf_size, .UINT32);

		Vk.CmdPushConstants(
			cb,
			vk_context.pipeline_layout,
			.VERTEX_BIT,
			0,
			size_of(Vk.DeviceAddress),
			*vk_context.shader_data_buffers[vk_context.frame_index].device_address
		);

		index_count := mesh.indices.count.(u32);
		Vk.CmdDrawIndexed(cb, index_count, 3, 0, 0, 0);

		Vk.CmdEndRendering(cb);

		barrier_present: Vk.ImageMemoryBarrier2;
		barrier_present.srcStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
		barrier_present.srcAccessMask = .COLOR_ATTACHMENT_WRITE_BIT;
		barrier_present.dstStageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
		barrier_present.oldLayout = .ATTACHMENT_OPTIMAL;
		barrier_present.newLayout = .PRESENT_SRC_KHR;
		barrier_present.image = vk_context.swapchain_images[vk_context.image_index];
		barrier_present.subresourceRange = {aspectMask=.COLOR_BIT, levelCount=1, layerCount = 1};
		barrier_present_dependency_info: Vk.DependencyInfo;
		barrier_present_dependency_info.imageMemoryBarrierCount = 1;
		barrier_present_dependency_info.pImageMemoryBarriers = *barrier_present;
		Vk.CmdPipelineBarrier2(cb, *barrier_present_dependency_info);

		Vk.EndCommandBuffer(cb);

		wait_semaphore_info: Vk.SemaphoreSubmitInfo;
		wait_semaphore_info.semaphore = vk_context.image_acquired_semaphores[vk_context.frame_index];
		wait_semaphore_info.stageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
		command_buffer_submit_info: Vk.CommandBufferSubmitInfo;
		command_buffer_submit_info.commandBuffer = cb;
		signal_semaphore_info: Vk.SemaphoreSubmitInfo;
		signal_semaphore_info.semaphore = vk_context.render_complete_semaphores[vk_context.image_index];
		signal_semaphore_info.stageMask = .COLOR_ATTACHMENT_OUTPUT_BIT;
		submit_info: Vk.SubmitInfo2;
		submit_info.waitSemaphoreInfoCount = 1;
		submit_info.pWaitSemaphoreInfos = *wait_semaphore_info;
		submit_info.commandBufferInfoCount = 1;
		submit_info.pCommandBufferInfos = *command_buffer_submit_info;
		submit_info.signalSemaphoreInfoCount = 1;
		submit_info.pSignalSemaphoreInfos = *signal_semaphore_info;
		chk(Vk.QueueSubmit2(vk_context.queue, 1, *submit_info, vk_context.fences[vk_context.frame_index]));

		vk_context.frame_index = (vk_context.frame_index + 1) % MAX_FRAMES_IN_FLIGHT;

		present_info: Vk.PresentInfoKHR;
		present_info.waitSemaphoreCount = 1;
		present_info.pWaitSemaphores = *vk_context.render_complete_semaphores[vk_context.image_index];
		present_info.swapchainCount = 1;
		present_info.pSwapchains = *vk_context.swapchain;
		present_info.pImageIndices = *vk_context.image_index;
		result = Vk.QueuePresentKHR(vk_context.queue, *present_info);
		if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
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

	chk(Vk.DeviceWaitIdle(vk_context.device));
}
