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

Vulkan_Context :: struct {
	instance: VkInstance;
	debug_utils_messenger: VkDebugUtilsMessengerEXT;
	physical_device: VkPhysicalDevice;
	device: VkDevice;
	queue: VkQueue;
	allocator: VmaAllocator;
	surface: VkSurfaceKHR;
	window: Window_Type;
	swapchain: VkSwapchainKHR;
	swapchain_images: [] VkImage;
	swapchain_image_views: [] VkImageView;
	window_size: VkExtent2D;
	depth_image: VkImage;
	depth_image_allocation: VmaAllocation;
	depth_image_view: VkImageView;
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

	queue_family: u32;
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

vulkan_deinit :: (vk_context: *Vulkan_Context) {}

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

	image_format :: VkFormat.VK_FORMAT_B8G8R8A8_SRGB;
	swapchain_info: VkSwapchainCreateInfoKHR;
	swapchain_info.surface = vk_context.surface;
	swapchain_info.minImageCount = surface_capabilities.minImageCount;
	swapchain_info.imageFormat = image_format;
	swapchain_info.imageColorSpace = VK_COLORSPACE_SRGB_NONLINEAR_KHR;
	swapchain_info.imageExtent = vk_context.window_size;
	swapchain_info.imageArrayLayers = 1;
	swapchain_info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
	swapchain_info.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
	swapchain_info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
	swapchain_info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
	chk(vkCreateSwapchainKHR(vk_context.device, *swapchain_info, null, *vk_context.swapchain));

	images := vulkan_fill_array(VkImage, vkGetSwapchainImagesKHR, vk_context.device, vk_context.swapchain);
	if vk_context.swapchain_images.count == 0 {
		vk_context.swapchain_images = alloc_and_copy_array(images);
	} else if vk_context.swapchain_images.count == images.count {
		copy_array_dst_src(vk_context.swapchain_images, images);
	} else {
		assert(false, "Missmatch between old and new swapchain image count");
	}

	new_image_views := make_temp_dyn_array(VkImageView);
	for vk_context.swapchain_images {
		view_info: VkImageViewCreateInfo;
		view_info.image = it;
		view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
		view_info.format = image_format;
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

	return true;
}

vulkan_create_depth :: (vk_context: *Vulkan_Context) {
	depth_format_list :: VkFormat.[
		VK_FORMAT_D32_SFLOAT_S8_UINT,
		VK_FORMAT_D24_UNORM_S8_UINT
	];
	depth_format: VkFormat;
	for depth_format_list {
		format_properties: VkFormatProperties2;
		vkGetPhysicalDeviceFormatProperties2(vk_context.physical_device, it, *format_properties);
		if format_properties.formatProperties.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT {
			depth_format = it;
			break;
		}
	}

	assert(depth_format != VK_FORMAT_UNDEFINED);

	depth_image_info: VkImageCreateInfo;
	depth_image_info.imageType = VK_IMAGE_TYPE_2D;
	depth_image_info.format = depth_format;
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
	depth_view_info.format = depth_format;
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
	log("%", FormatStruct.{value=mesh, draw_type_name=true});

	quit := false;
	while !quit {
		update_window_events();

		for events_this_frame {
			if it.type == .QUIT then quit = true;

			if it.type == .KEYBOARD {
				if it.key_pressed == 0 continue;

				if it.key_code == .ESCAPE {
					quit = true;
				}
			}
		}
	}
}

// From modules/osor_vulkan/examples/src/main.jai
vulkan_fill_array :: ($type : Type, procedure : $Procedure, $arguments : ..Code) -> [] type #expand
{
    //
    // @@NOTE: I would like to be able to derive the return type from the procedure they pass in. This
    // would mean that we can get the type of the last argument and use it in the declaration of the procedure
    // which I can't find a way to do right now for it to work with polymorphism. Essentially I would like to do something
    // like the following:
    //
    // test :: ($procedure : $Procedure) -> #insert #run get_array_type(procedure)
    // {
    //     // . . .
    // }
    //
    // get_array_type :: ($procedure : Procedure) -> string
    // {
    //     info := type_info(procedure);
    //     argument := info.return_types[info.return_types-1];
    //     assert(argument.type == Type_Info_Tag.POINTER);
    //     argument_pointer := cast(*Type_Info_Pointer) argument;
    //     type_pointed_to := argument_pointer.pointer_to;
    //     assert(type_pointed_to.type == Type_Info_Tag.STRUCT);
    //     type_pointed_to_struct := cast(*Type_Info_Struct) type_pointed_to;
    //     return type_pointer_to_struct.name;
    // }
    //

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
