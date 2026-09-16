//
// Exercises the loader API against the real Vulkan installed on this machine.
//
//     jai loader.jai -import_dir ../..
//
// Skips cleanly (rather than failing) when there is no Vulkan loader present, so it is
// safe to run on a machine without a driver.
//

#import "Basic";
Vk :: #import "Jolk";

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
    print("Jolk loader tests (Vulkan header %)\n\n", Vk.HEADER_VERSION);

    // Nothing is loaded before initialize.
    check(Vk.CreateInstance == null, "entry points start out null");

    if Vk.initialize() != .SUCCESS {
        print("\nNo Vulkan loader on this machine; skipping the rest.\n");
        return;
    }

    check(Vk.GetInstanceProcAddr != null, "initialize resolves GetInstanceProcAddr");
    check(Vk.CreateInstance      != null, "initialize resolves CreateInstance");
    check(Vk.EnumerateInstanceExtensionProperties != null, "initialize resolves the instance queries");
    check(Vk.DestroyInstance     == null, "instance-level entry points are still null");

    version := Vk.get_instance_version();
    check(Vk.API_VERSION_MAJOR(version) >= 1, "get_instance_version reports at least 1.x");

    // Extension names are Jai strings, so they compare directly against what the loader
    // reports, and `.data` gives the C string Vulkan wants.
    count: u32;
    Vk.EnumerateInstanceExtensionProperties(null, *count, null);
    check(count > 0, "the loader reports instance extensions");

    extensions := NewArray(count, Vk.ExtensionProperties);
    defer array_free(extensions);
    Vk.EnumerateInstanceExtensionProperties(null, *count, extensions.data);

    found_surface := false;
    for extensions  if to_string(it.extensionName) == Vk.KHR_SURFACE_EXTENSION_NAME  found_surface = true;
    check(found_surface, "KHR_SURFACE_EXTENSION_NAME matches a reported extension");

    application: Vk.ApplicationInfo;
    application.pApplicationName = "Jolk tests".data;
    application.apiVersion       = Vk.API_VERSION_1_0;
    check(application.sType == .APPLICATION_INFO, "sType defaults are filled in");

    // Enum values are short, and inferable wherever the type is known.
    check(Vk.Result.ERROR_OUT_OF_DATE_KHR == cast(Vk.Result) -1000001004, "extension values keep their numbers");
    image: Vk.ImageCreateInfo;
    image.imageType     = ._2D;
    image.initialLayout = .UNDEFINED;
    image.samples       = ._1_BIT;
    image.usage         = .COLOR_ATTACHMENT_BIT | .SAMPLED_BIT;
    check(image.initialLayout == Vk.ImageLayout.UNDEFINED, "inferred .UNDEFINED is ImageLayout.UNDEFINED");
    check(image.usage == Vk.ImageUsageFlags.COLOR_ATTACHMENT_BIT | .SAMPLED_BIT, "inferred flag bits or together");

    create_info: Vk.InstanceCreateInfo;
    create_info.pApplicationInfo = *application;

    instance: Vk.Instance;
    check(Vk.CreateInstance(*create_info, null, *instance) == .SUCCESS, "CreateInstance succeeds");

    Vk.load_instance_only(instance);
    check(Vk.DestroyInstance   != null, "load_instance_only resolves instance entry points");
    check(Vk.GetDeviceProcAddr != null, "load_instance_only resolves GetDeviceProcAddr");
    check(Vk.get_loaded_instance() == instance, "the loaded instance is remembered");

    Vk.load_instance(instance);
    check(Vk.CmdDraw != null, "load_instance also resolves device entry points");

    device_count: u32;
    Vk.EnumeratePhysicalDevices(instance, *device_count, null);
    if device_count {
        physical_devices := NewArray(device_count, Vk.PhysicalDevice);
        defer array_free(physical_devices);
        Vk.EnumeratePhysicalDevices(instance, *device_count, physical_devices.data);

        family_count: u32;
        Vk.GetPhysicalDeviceQueueFamilyProperties(physical_devices[0], *family_count, null);
        check(family_count > 0, "the first device reports queue families");

        priority := 1.0;
        queue_info: Vk.DeviceQueueCreateInfo;
        queue_info.queueCount       = 1;
        queue_info.pQueuePriorities = *priority;

        device_create: Vk.DeviceCreateInfo;
        device_create.queueCreateInfoCount = 1;
        device_create.pQueueCreateInfos    = *queue_info;

        device: Vk.Device;
        if Vk.CreateDevice(physical_devices[0], *device_create, null, *device) == .SUCCESS {
            defer Vk.DestroyDevice(device, null);

            Vk.load_device(device);
            check(Vk.get_loaded_device() == device, "the loaded device is remembered");
            check(Vk.CmdDraw != null, "load_device resolves device entry points");

            table: Vk.Device_Table;
            Vk.load_device_table(*table, device);
            check(table.CmdDraw       != null, "a device table resolves CmdDraw");
            check(table.QueueSubmit   != null, "a device table resolves QueueSubmit");
            check(table.DestroyDevice != null, "a device table resolves DestroyDevice");
        } else {
            print("  --   could not create a device; skipping the device-level checks\n");
        }
    } else {
        print("  --   no physical devices; skipping the device-level checks\n");
    }

    // initialize_custom must keep the handler it was given rather than replacing it with
    // the driver's own.
    handler := Vk.GetInstanceProcAddr;
    Vk.initialize_custom(handler);
    check(Vk.GetInstanceProcAddr == handler, "initialize_custom keeps the supplied handler");

    Vk.DestroyInstance(instance, null);

    Vk.finalize();
    check(Vk.CreateInstance == null, "finalize clears the entry points");
    check(Vk.CmdDraw        == null, "finalize clears the device entry points");

    print("\n%\n", ifx failures then tprint("% FAILED", failures) else "all tests passed");
    if failures  exit(1);
}
