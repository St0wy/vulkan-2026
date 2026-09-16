//
// device_info -- the smallest useful Jolk program.
//
// Opens the Vulkan library, creates an instance, and prints what the machine has. It goes
// as far as creating a Device so that it exercises all three loading levels, which makes
// it a decent smoke test for the module as well as an example.
//
// Build:
//     jai main.jai -import_dir ../../..
//

#import "Basic";
Vk :: #import "Jolk";

main :: () {
    // 1. Open the Vulkan library and pick up CreateInstance and friends.
    if Vk.initialize() != .SUCCESS {
        print("No Vulkan loader on this machine.\n");
        return;
    }
    defer Vk.finalize();

    version := Vk.get_instance_version();
    print("Loader supports Vulkan %.%.%\n\n",
          Vk.API_VERSION_MAJOR(version), Vk.API_VERSION_MINOR(version), Vk.API_VERSION_PATCH(version));

    // 2. Create an instance. sType is already filled in for us, and enum values are
    //    written short (.SUCCESS) wherever the type is known.
    application: Vk.ApplicationInfo;
    application.pApplicationName = "device_info".data;
    application.apiVersion       = Vk.API_VERSION_1_0;

    create_info: Vk.InstanceCreateInfo;
    create_info.pApplicationInfo = *application;

    instance: Vk.Instance;
    result := Vk.CreateInstance(*create_info, null, *instance);
    if result != .SUCCESS {
        print("CreateInstance failed: %\n", result);
        return;
    }

    // 3. Now that there is an instance, every entry point can be resolved.
    Vk.load_instance(instance);
    defer Vk.DestroyInstance(instance, null);

    count: u32;
    Vk.EnumeratePhysicalDevices(instance, *count, null);
    if !count {
        print("No physical devices.\n");
        return;
    }

    devices := NewArray(count, Vk.PhysicalDevice);
    defer array_free(devices);
    Vk.EnumeratePhysicalDevices(instance, *count, devices.data);

    print("% physical device(s):\n", count);
    for device: devices {
        properties: Vk.PhysicalDeviceProperties;
        Vk.GetPhysicalDeviceProperties(device, *properties);

        api := properties.apiVersion;
        print("\n  [%] %\n", it_index, to_string(properties.deviceName));
        print("      type       : %\n", properties.deviceType);
        print("      api        : %.%.%\n", Vk.API_VERSION_MAJOR(api), Vk.API_VERSION_MINOR(api), Vk.API_VERSION_PATCH(api));
        print("      max 2D dim : %\n", properties.limits.maxImageDimension2D);

        // Queue families, so we can ask for a graphics queue below.
        family_count: u32;
        Vk.GetPhysicalDeviceQueueFamilyProperties(device, *family_count, null);
        families := NewArray(family_count, Vk.QueueFamilyProperties);
        defer array_free(families);
        Vk.GetPhysicalDeviceQueueFamilyProperties(device, *family_count, families.data);

        graphics_family := -1;
        for family: families {
            // QueueFlags is the flag enum itself, so this needs no casting.
            if family.queueFlags & .GRAPHICS_BIT {
                graphics_family = it_index;
                break;
            }
        }
        print("      queues     : % families, graphics on %\n",
              family_count, ifx graphics_family >= 0 then tprint("family %", graphics_family) else "none");

        if graphics_family < 0  continue;

        // 4. Create a device and re-load the device entry points from it. After this,
        //    Vk.CmdDraw and the rest go straight to the driver.
        priority := 1.0;
        queue_info: Vk.DeviceQueueCreateInfo;
        queue_info.queueFamilyIndex = xx graphics_family;
        queue_info.queueCount       = 1;
        queue_info.pQueuePriorities = *priority;

        device_info: Vk.DeviceCreateInfo;
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos    = *queue_info;

        logical: Vk.Device;
        if Vk.CreateDevice(device, *device_info, null, *logical) != .SUCCESS {
            print("      device     : could not be created\n");
            continue;
        }

        Vk.load_device(logical);
        defer Vk.DestroyDevice(logical, null);

        queue: Vk.Queue;
        Vk.GetDeviceQueue(logical, xx graphics_family, 0, *queue);
        print("      device     : created, graphics queue %\n", ifx queue then "obtained" else "missing");

        // A per-device table, for when one set of globals is not enough.
        table: Vk.Device_Table;
        Vk.load_device_table(*table, logical);
        print("      table      : CmdDraw %\n", ifx table.CmdDraw then "resolved" else "missing");
    }
}
