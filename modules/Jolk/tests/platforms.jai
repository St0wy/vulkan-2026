//
// Compiles the module with every platform parameter turned on, and again with all of them
// off, which is what catches a guard that lets a declaration reference something only
// available under a different guard.
//
//     jai platforms.jai -import_dir ../..
//

#import "Basic";

All :: #import "Jolk"(
    VK_ENABLE_BETA_EXTENSIONS       = true,
    VK_USE_PLATFORM_ANDROID_KHR     = true,
    VK_USE_PLATFORM_DIRECTFB_EXT    = true,
    VK_USE_PLATFORM_FUCHSIA         = true,
    VK_USE_PLATFORM_GGP             = true,
    VK_USE_PLATFORM_IOS_MVK         = true,
    VK_USE_PLATFORM_MACOS_MVK       = true,
    VK_USE_PLATFORM_METAL_EXT       = true,
    VK_USE_PLATFORM_OHOS            = true,
    VK_USE_PLATFORM_SCREEN_QNX      = true,
    VK_USE_PLATFORM_UBM_SEC         = true,
    VK_USE_PLATFORM_VI_NN           = true,
    VK_USE_PLATFORM_WAYLAND_KHR     = true,
    VK_USE_PLATFORM_WIN32_KHR       = true,
    VK_USE_PLATFORM_XCB_KHR         = true,
    VK_USE_PLATFORM_XLIB_KHR        = true,
    VK_USE_PLATFORM_XLIB_XRANDR_EXT = true
);

None :: #import "Jolk"(
    VK_ENABLE_BETA_EXTENSIONS       = false,
    VK_USE_PLATFORM_ANDROID_KHR     = false,
    VK_USE_PLATFORM_DIRECTFB_EXT    = false,
    VK_USE_PLATFORM_FUCHSIA         = false,
    VK_USE_PLATFORM_GGP             = false,
    VK_USE_PLATFORM_IOS_MVK         = false,
    VK_USE_PLATFORM_MACOS_MVK       = false,
    VK_USE_PLATFORM_METAL_EXT       = false,
    VK_USE_PLATFORM_OHOS            = false,
    VK_USE_PLATFORM_SCREEN_QNX      = false,
    VK_USE_PLATFORM_UBM_SEC         = false,
    VK_USE_PLATFORM_VI_NN           = false,
    VK_USE_PLATFORM_WAYLAND_KHR     = false,
    VK_USE_PLATFORM_WIN32_KHR       = false,
    VK_USE_PLATFORM_XCB_KHR         = false,
    VK_USE_PLATFORM_XLIB_KHR        = false,
    VK_USE_PLATFORM_XLIB_XRANDR_EXT = false
);

main :: () {
    // Reach into a struct from each window system so the declarations are really used and
    // not just parsed.
    win32   : All.Win32SurfaceCreateInfoKHR;
    xlib    : All.XlibSurfaceCreateInfoKHR;
    xcb     : All.XcbSurfaceCreateInfoKHR;
    wayland : All.WaylandSurfaceCreateInfoKHR;
    android : All.AndroidSurfaceCreateInfoKHR;
    metal   : All.MetalSurfaceCreateInfoEXT;
    screen  : All.ScreenSurfaceCreateInfoQNX;

    print("every platform on : % % % % % % %\n",
          win32.sType, xlib.sType, xcb.sType, wayland.sType, android.sType, metal.sType, screen.sType);

    // The core API must be complete with everything off.
    core: None.InstanceCreateInfo;
    print("every platform off: % (CreateInstance is a %)\n", core.sType, type_of(None.CreateInstance));

    // A video-codec type, to prove video.xml came through as well.
    sps: All.StdVideoH264SequenceParameterSet;
    All.set_constraint_set0_flag(*sps.flags, true);
    print("video codec types  : constraint_set0_flag round-trips as %\n", All.get_constraint_set0_flag(sps.flags));

    // A multi-bit field keeps its integer type rather than collapsing to a bool, and two
    // fields sharing one storage integer must not disturb each other.
    ray: All.AccelerationStructureInstanceKHR;
    All.set_mask(*ray, 0xAB);
    All.set_instanceCustomIndex(*ray, 0x123456);
    print("bit-field packing  : mask=% customIndex=% packed=%\n",
          formatInt(All.get_mask(ray), base = 16),
          formatInt(All.get_instanceCustomIndex(ray), base = 16),
          formatInt(ray.__bitfield, base = 16));
}
