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

Shader_Data :: struct {
	projection: Matrix4;
	view: Matrix4;
	model: [3] Matrix4;
	light_pos: Vector4 = {0, -10, 10, 0};
	selected: u32 = 1;
}

FOV_VERTICAL :: 60 * PI / 180.0;

window_handle: Window_Type;
renderer: Renderer;
mesh: Mesh;
shader_data: Shader_Data;
cam_pos := Vector3.{0, 0, 6};

main :: () {
	window_handle = create_window(1920, 1080, "Vulkan 2026");

	is_release :: BUILD_TYPE == .RELEASE;
	rederer_init(*renderer, window_handle, !is_release);
	defer renderer_deinit(*renderer);

	{
		start := current_time_monotonic();
		ok:, mesh = load_model_obj("data/suzanne.obj");
		delta_ms := to_float64_seconds(current_time_monotonic() - start) * 1000;
		log("Loaded model in %ms", delta_ms);
	}

	object_rotations: [3] Vector3;

	gpu_mesh := renderer_upload_mesh(*renderer, mesh);
	defer renderer_destroy_mesh(*renderer, *gpu_mesh);

	texture_descriptors: [renderer.textures.count] Vk.DescriptorImageInfo;
	for * renderer.textures {
		ktx_data := read_entire_file(tprint("data/suzanne%.ktx2", it_index));
		ok, ktx_image := ktx_load(ktx_data);
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
		chk(Vma.CreateImage(renderer.allocator, *texture_info, *texture_alloc_info, *it.image, *it.allocation, null));

		texture_view_info: Vk.ImageViewCreateInfo;
		texture_view_info.image = it.image;
		texture_view_info.viewType = ._2D;
		texture_view_info.format = texture_info.format;
		texture_view_info.subresourceRange = {
			aspectMask = .COLOR_BIT,
			levelCount = ktx_image.level_count,
			layerCount = 1
		};
		chk(Vk.CreateImageView(renderer.device, *texture_view_info, null, *it.view));

		image_source_buffer, image_source_allocation, image_source_allocation_info := vulkan_create_buffer(
			renderer.allocator,
			xx ktx_image.image_data.count,
			.TRANSFER_SRC_BIT,
			.HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .MAPPED_BIT
		);

		memcpy(image_source_allocation_info.pMappedData, ktx_image.image_data.data, ktx_image.image_data.count);

		begin_one_time_commands(*renderer);

		transition_image(renderer.immediate_command_buffer, it.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL);

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
			renderer.immediate_command_buffer,
			image_source_buffer,
			it.image,
			.TRANSFER_DST_OPTIMAL,
			xx copy_regions.count,
			copy_regions.data
		);

		transition_image(renderer.immediate_command_buffer, it.image, .TRANSFER_DST_OPTIMAL, .READ_ONLY_OPTIMAL);

		end_one_time_commands(*renderer);
		Vma.DestroyBuffer(renderer.allocator, image_source_buffer, image_source_allocation);

		sampler_info: Vk.SamplerCreateInfo;
		sampler_info.magFilter = .LINEAR;
		sampler_info.minFilter = .LINEAR;
		sampler_info.mipmapMode = .LINEAR;
		sampler_info.anisotropyEnable = Vk.TRUE;
		sampler_info.maxAnisotropy = 8.0;
		sampler_info.maxLod = ktx_image.level_count.(float);
		chk(Vk.CreateSampler(renderer.device, *sampler_info, null, *it.sampler));

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
	desc_layout_binding_tex.descriptorCount = xx renderer.textures.count;
	desc_layout_binding_tex.stageFlags = .FRAGMENT_BIT;
	desc_layout_tex_ci: Vk.DescriptorSetLayoutCreateInfo;
	desc_layout_tex_ci.pNext = *desc_binding_flags;
	desc_layout_tex_ci.bindingCount = 1;
	desc_layout_tex_ci.pBindings = *desc_layout_binding_tex;
	chk(Vk.CreateDescriptorSetLayout(renderer.device, *desc_layout_tex_ci, null, *renderer.descriptor_set_layout_tex));

	pool_size: Vk.DescriptorPoolSize;
	pool_size.type = .COMBINED_IMAGE_SAMPLER;
	pool_size.descriptorCount = xx renderer.textures.count;
	desc_pool_ci: Vk.DescriptorPoolCreateInfo;
	desc_pool_ci.maxSets = 1;
	desc_pool_ci.poolSizeCount = 1;
	desc_pool_ci.pPoolSizes = *pool_size;
	chk(Vk.CreateDescriptorPool(renderer.device, *desc_pool_ci, null, *renderer.descriptor_pool));

	variable_desc_count := renderer.textures.count.(u32);
	variable_desc_count_ai: Vk.DescriptorSetVariableDescriptorCountAllocateInfo;
	variable_desc_count_ai.descriptorSetCount = 1;
	variable_desc_count_ai.pDescriptorCounts = *variable_desc_count;
	tex_desc_set_alloc: Vk.DescriptorSetAllocateInfo;
	tex_desc_set_alloc.pNext = *variable_desc_count_ai;
	tex_desc_set_alloc.descriptorPool = renderer.descriptor_pool;
	tex_desc_set_alloc.descriptorSetCount = 1;
	tex_desc_set_alloc.pSetLayouts = *renderer.descriptor_set_layout_tex;
	chk(Vk.AllocateDescriptorSets(renderer.device, *tex_desc_set_alloc, *renderer.descriptor_set_tex));

	write_desc_set: Vk.WriteDescriptorSet;
	write_desc_set.dstSet = renderer.descriptor_set_tex;
	write_desc_set.dstBinding = 0;
	write_desc_set.descriptorType = .COMBINED_IMAGE_SAMPLER;
	write_desc_set.descriptorCount = xx texture_descriptors.count;
	write_desc_set.pImageInfo = texture_descriptors.data;
	Vk.UpdateDescriptorSets(renderer.device, 1, *write_desc_set, 0, null);

	shader_blob := read_entire_file("data/shader.spriv");
	shader_module_ci: Vk.ShaderModuleCreateInfo;
	shader_module_ci.codeSize = xx shader_blob.count;
	shader_module_ci.pCode = shader_blob.data.(*u32);
	chk(Vk.CreateShaderModule(renderer.device, *shader_module_ci, null, *renderer.shader_module));

	push_constant_range: Vk.PushConstantRange;
	push_constant_range.stageFlags = .VERTEX_BIT;
	push_constant_range.size = size_of(Vk.DeviceAddress);
	pipeline_layout_ci: Vk.PipelineLayoutCreateInfo;
	pipeline_layout_ci.setLayoutCount = 1;
	pipeline_layout_ci.pSetLayouts = *renderer.descriptor_set_layout_tex;
	pipeline_layout_ci.pushConstantRangeCount = 1;
	pipeline_layout_ci.pPushConstantRanges = *push_constant_range;
	chk(Vk.CreatePipelineLayout(renderer.device, *pipeline_layout_ci, null, *renderer.pipeline_layout));

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

	last_time := current_time_monotonic();
	left_click := false;
	quit := false;
	while !quit {
		if begin_frame(*renderer, clear_color={0,0,0.2,1}) {
			aspect_ratio := renderer.window_size.width.(float) / renderer.window_size.height.(float);
			shader_data.projection = make_projection_matrix(FOV_VERTICAL, aspect_ratio, 0.1, 32, depth_range_01=true);
			shader_data.projection._22 *= -1;
			shader_data.view = make_look_at_matrix(cam_pos, {0,0,0}, {0, 1, 0}, x_is_forward=false);
			for 0..2 {
				instance_pos := Vector3.{(it - 1).(float) * 3, 0, 0};
				rotation := rotation_matrix(Matrix4, euler_to_quaternion(object_rotations[it]));
				shader_data.model[it] = make_translation_matrix4(instance_pos) * rotation;
			}
			set_shader_data(*renderer, *shader_data);
			draw_mesh(*renderer, gpu_mesh, 3);
			end_frame(*renderer);
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
					shader_data.selected = ifx shader_data.selected < 2 then shader_data.selected + 1 else 0;
				case .ARROW_LEFT;
					shader_data.selected = ifx shader_data.selected > 0 then shader_data.selected - 1 else 2;
				}
			case .MOUSE_WHEEL;
				cam_pos.z -= it.wheel_delta.(float) * delta_time * 10;
			}
		}

		if left_click {
			object_rotations[shader_data.selected].x += mouse_delta_y.(float) * delta_time;
			object_rotations[shader_data.selected].y += mouse_delta_x.(float) * delta_time;
		}

		resizes := get_window_resizes();
		for record: resizes {
			if record.window == window_handle {
				renderer_resize(*renderer, xx record.width, xx record.height);
			}
		}
	}
}
