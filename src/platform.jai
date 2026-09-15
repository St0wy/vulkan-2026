#if OS == .WINDOWS {

#import "Windows";
#import "Windows_Utf8";

load_vulkan :: (shared_library_path: string) {
	wide_path, ok := utf8_to_wide(shared_library_path,, temp);
	assert(ok, "Could not convert path to UTF-16");
	vulkan_library := LoadLibraryW(wide_path);
	load_vulkan_loader_procedures(vulkan_library, GetProcAddress);
}

get_desired_surface_extensions :: () -> [..] string {
	desired_surface_extensions := make_temp_dyn_array(string);
	array_add(*desired_surface_extensions, VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME);
	return desired_surface_extensions;
}

supports_presentation :: (physical_device: VkPhysicalDevice, queue_family_index: u32) -> bool {
	return vkGetPhysicalDeviceWin32PresentationSupportKHR(physical_device, queue_family_index).(bool);
}

create_surface :: (instance: VkInstance, window_handle: Window_Type) -> VkSurfaceKHR {
	surface: VkSurfaceKHR;
	surface_create_info: VkWin32SurfaceCreateInfoKHR;
	surface_create_info.hinstance = GetModuleHandleW(null);
	surface_create_info.hwnd = window_handle;
	chk(vkCreateWin32SurfaceKHR(instance, *surface_create_info, null, *surface));

	return surface;
}

} else {
#assert(false);

load_vulkan :: (shared_library_path: string) {}
get_desired_surface_extensions :: () -> [..] string {}
supports_presentation :: (physical_device: VkPhysicalDevice, queue_family_index: u32) -> bool {}
create_surface :: (instance: VkInstance, window_handle: Window_Type) -> VkSurfaceKHR {}

}
