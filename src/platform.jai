#if OS == .WINDOWS {

#import "Windows";
#import "Windows_Utf8";

get_desired_surface_extensions :: () -> [..] string {
	desired_surface_extensions := make_temp_dyn_array(string);
	array_add(*desired_surface_extensions, Vk.KHR_SURFACE_EXTENSION_NAME, Vk.KHR_WIN32_SURFACE_EXTENSION_NAME);
	return desired_surface_extensions;
}

supports_presentation :: (physical_device: Vk.PhysicalDevice, queue_family_index: u32) -> bool {
	return Vk.GetPhysicalDeviceWin32PresentationSupportKHR(physical_device, queue_family_index).(bool);
}

create_surface :: (instance: Vk.Instance, window_handle: Window_Type) -> Vk.SurfaceKHR {
	surface: Vk.SurfaceKHR;
	surface_create_info: Vk.Win32SurfaceCreateInfoKHR;
	surface_create_info.hinstance = GetModuleHandleW(null);
	surface_create_info.hwnd = window_handle;
	chk(Vk.CreateWin32SurfaceKHR(instance, *surface_create_info, null, *surface));

	return surface;
}

} else {
#assert(false);

get_desired_surface_extensions :: () -> [..] string {}
supports_presentation :: (physical_device: VkPhysicalDevice, queue_family_index: u32) -> bool {}
create_surface :: (instance: VkInstance, window_handle: Window_Type) -> VkSurfaceKHR {}

}
