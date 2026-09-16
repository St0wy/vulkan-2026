//
// Imports Jolk through Jolk/C_Names and drives it with the C spellings, to check that the
// generated mapper covers every kind of name the module exports.
//
//     jai c_names.jai -import_dir ../..
//

#import "Basic";

C_Names :: #import "Jolk/C_Names";
using,map(C_Names.to_c_names) Vk :: #import "Jolk";

failures := 0;

check :: (condition: bool, message: string) {
    if condition {
        print("  ok   %\n", message);
    } else {
        print("  FAIL %\n", message);
        failures += 1;
    }
}

main :: () {
    print("Jolk C_Names tests (Vulkan header %)\n\n", VK_HEADER_VERSION);

    // Types, both spellings: the mapper renames declarations, it does not copy them.
    info: VkImageCreateInfo;
    same: Vk.ImageCreateInfo;
    check(type_of(info) == type_of(same), "VkImageCreateInfo is Vk.ImageCreateInfo");
    check(VkBuffer == Vk.Buffer && VkBuffer_T == Vk.Buffer_T, "handles and their opaque structs are renamed");
    check(VkImageUsageFlags == Vk.ImageUsageFlagBits, "flag types are renamed");
    check(PFN_vkDebugUtilsMessengerCallbackEXT == Vk.Proc_DebugUtilsMessengerCallbackEXT, "callback types are renamed");
    check(PFN_vkCreateInstance == Vk.Proc_CreateInstance, "entry-point types are renamed");

    // Constants.
    check(VK_UUID_SIZE == 16, "API constants are renamed");
    check(VK_KHR_SWAPCHAIN_EXTENSION_NAME == "VK_KHR_swapchain", "extension constants are renamed");
    check(VK_API_VERSION_MAJOR(VK_API_VERSION_1_3) == 1, "version macros are renamed");
    check(VK_NULL_HANDLE == null, "VK_NULL_HANDLE is renamed");
    check(VK_STD_VULKAN_VIDEO_CODEC_H264_DECODE_API_VERSION_1_0_0 == VK_MAKE_VIDEO_STD_VERSION(1, 0, 0),
          "video constants are renamed");

    // Enum values stay short: they live inside the enum, which the mapper does not reach.
    info.initialLayout = .UNDEFINED;
    check(info.initialLayout == VkImageLayout.UNDEFINED, "enum values keep their short names");

    // Entry points and the loader API.
    check(vkCreateInstance == null, "entry points are renamed");
    if vulkan_initialize() != .SUCCESS {
        print("\nNo Vulkan loader on this machine; skipping the rest.\n");
        return;
    }
    defer vulkan_finalize();

    check(vkCreateInstance != null, "vulkan_initialize loads vkCreateInstance");
    check(vulkan_get_instance_version() >= VK_API_VERSION_1_0, "vulkan_get_instance_version works");

    application: VkApplicationInfo;
    application.apiVersion = VK_API_VERSION_1_0;
    create_info: VkInstanceCreateInfo;
    create_info.pApplicationInfo = *application;

    instance: VkInstance;
    check(vkCreateInstance(*create_info, null, *instance) == .SUCCESS, "vkCreateInstance succeeds");
    vulkan_load_instance(instance);
    defer vkDestroyInstance(instance, null);
    check(vkCmdDraw != null, "vulkan_load_instance loads vkCmdDraw");

    // Table members are struct fields, so they keep the Jai spelling in both modes.
    table: Vulkan_Device_Table;
    check(type_of(table) == Vk.Device_Table, "Vulkan_Device_Table is Vk.Device_Table");

    print("\n%\n", ifx failures then tprint("% FAILED", failures) else "all tests passed");
    if failures  exit(1);
}
