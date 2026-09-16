// To make the generation work on linux, I had to add stddef.h and __stddef_max_align_t.h by hand.
// For MacOS, it is "stdint.h".
// There is probably a better way to fix the issue, but I don't know how
// -- Stowy

// config
COMPILE_TIME                         :: true;
vulkan_memory_allocator_h_location   :: "source/vk_mem_alloc.h";
vulkan_memory_allocator_cpp_location :: "source/vk_mem_alloc.cpp";

#if OS == .WINDOWS {
	vulkan_memory_allocator_lib_path :: "windows/";
} else #if OS == .LINUX {
	vulkan_memory_allocator_lib_path :: "linux/";
} else #if OS == .MACOS {
	vulkan_memory_allocator_lib_path :: "macos/";
} else {
	assert(false);
}

#if COMPILE_TIME {
	#run,stallable {
		#if OS == .WINDOWS {
			Windows :: #import "Windows";
			vulkan_sdk_path := to_string(Windows.getenv("VULKAN_SDK"));
			if !vulkan_sdk_path then sdk_error_and_quit();

			vulkan_headers_include := tprint("-I%\\Include", vulkan_sdk_path);

			build_cpp_dynamic_lib(
				"windows/VMA",
				vulkan_memory_allocator_cpp_location,
				extra=.[vulkan_headers_include, "/std:c++20", "/DVMA_CALL_PRE=__declspec(dllexport)"],
				library_files=.[tprint("%/Lib/vulkan-1.lib", vulkan_sdk_path)]
			);
		} else if OS == .LINUX {
			POSIX :: #import "POSIX";
			vulkan_sdk_path := to_string(POSIX.getenv("VULKAN_SDK"));
			if !vulkan_sdk_path then sdk_error_and_quit();

			build_cpp_dynamic_lib("linux/VMA", vulkan_memory_allocator_cpp_location, extra=.["-std=c++20", "-Wno-nullability-completeness"], library_files=.[tprint("%/lib/libvulkan.so.1", vulkan_sdk_path)]);
		} else if OS == .MACOS {
			POSIX :: #import "POSIX";
			vulkan_sdk_path := to_string(POSIX.getenv("VULKAN_SDK"));
			if !vulkan_sdk_path then sdk_error_and_quit();

			vulkan_headers_include := tprint("-I%/include", vulkan_sdk_path);

			// TODO: maybe compile for x86 and arm separately
			build_cpp_dynamic_lib(
				"macos/VMA",
				vulkan_memory_allocator_cpp_location,
				extra=.[vulkan_headers_include, "-std=c++20", "-Wno-nullability-completeness"],
				library_files=.[tprint("%/lib/libvulkan.1.dylib", vulkan_sdk_path)]
			);
		}

		set_build_options_dc(.{do_output = false});
		if !generate_bindings() {
			compiler_set_workspace_status(.FAILED);
		}
	}
} else {
	#import "System";

	main :: () {
		set_working_directory(path_strip_filename(get_path_of_running_executable()));
		if !generate_bindings() {
			exit(1);
		}
	}
}

sdk_error_and_quit :: () {
	write_string("Vulkan SDK not found. Please ensure that it's installed on your system!\n", true);
	exit(1);
}

// -----------------------------------------------------

OMIT_LIST :: string.[];

generate_bindings :: () -> bool {
    log("Generating bindings...");
	output_filename: string;
	opts: Generate_Bindings_Options;

	{
		using opts;

		#if OS == .WINDOWS {
			Windows :: #import "Windows";
			vulkan_sdk_path := to_string(Windows.getenv("VULKAN_SDK"));
			if !vulkan_sdk_path then sdk_error_and_quit();

			vulkan_headers_path := tprint("%\\Include", vulkan_sdk_path);

			array_add(*system_include_paths, vulkan_headers_path);
			array_add(*extra_clang_arguments, "-x", "c", "-DWIN32_LEAN_AND_MEAN");

			output_filename = "windows.jai";
		} else #if OS == .LINUX {
			POSIX :: #import "POSIX";
			vulkan_sdk_path := to_string(POSIX.getenv("VULKAN_SDK"));
			if !vulkan_sdk_path then sdk_error_and_quit();

			vulkan_headers_path := tprint("%\\Include", vulkan_sdk_path);

			array_add(*system_include_paths, vulkan_headers_path);

			output_filename = "linux.jai";
		} else #if OS == .MACOS {
			output_filename = "macos.jai";
		} else {
			assert(false);
		}

		array_add(*libraries, .{filename="VMA"});
		array_add(*library_search_paths, vulkan_memory_allocator_lib_path);

		array_add(*source_files, vulkan_memory_allocator_h_location);
		array_add(*system_include_paths, ".");
		array_add(*strip_prefixes, "vma");
		array_add(*strip_prefixes, "Vma");

		generate_library_declarations = false;

		will_print_bindings = () {
			// Change the library name to be the same on all platforms
			// so that we don't have to generate identical bindings for every platform just because the library name is different.
			context.generator.libraries[0].identifier = "libvma";
		};
		footer = VMA_FOOTER;

		visitor = vulkan_memory_allocator_visitor;
		log_stripped_declarations = false;
		generate_compile_time_struct_checks = false;
	}

	return generate_bindings(opts, output_filename);
}

available_flag_bits: Table(string, *Enum);

vulkan_memory_allocator_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
	// Omit header definitions (ex: VULKAN_H_)
	if decl.kind == .MACRO_DEFINITION && ends_with(decl.name, "_H_") {
		decl.decl_flags |= .OMIT_FROM_OUTPUT;
		return .STOP;
	}

	if !parent_decl && array_find(OMIT_LIST, decl.name) {
		decl.decl_flags |= .OMIT_FROM_OUTPUT;
		return .STOP;
	}

	if decl.kind == .ENUM {
		en := cast(*Enum)decl;

		if en.type {
			if en.type.size == {
				case 1;
					en.type = context.generator.type_def_u8;
				case 2;
					en.type = context.generator.type_def_u16;
				case 4;
					en.type = context.generator.type_def_u32;
				case 8;
					en.type = context.generator.type_def_u64;
			}
		}

		if contains(decl.name, "FlagBits") {
			en.flags |= .IS_ENUM_FLAGS;
			en.flags |= .VALUES_IN_HEX;

			table_add(*available_flag_bits, decl.name, en);
		}
	}

	// Replace typedef which has "VkFlags" as value. :VkFlags
	// VkAccessFlags :: VkFlags   ->   VkAccessFlags :: VkAccessFlagBits;
	// We don't change the name of the FlagBits enum directly because both the ...FlagBits and the ...Flags aliases are used in declarations.
	if decl.kind == .TYPEDEF && decl.type.type_of_typedef &&  decl.type.type_of_typedef.name == "VkFlags" {
		//print("TYPEDEF(VkFlags):%\n", << decl.name);
		flags_name := replace(decl.name, "Flags", "FlagBits");
		found, enum_decl := table_find(*available_flag_bits, flags_name);
		if found {
			type := New(CType);
			type.type_of_enum = enum_decl;
			type.size = enum_decl.type.size;
			decl.type = type;
		}
	}

	return .RECURSE;
}

#scope_file

#import "Basic";
#import "Compiler";
#import "Bindings_Generator";
#import "String";
#import "File";
#import "Check";
#import "Hash_Table";
#import "BuildCpp";

VMA_FOOTER :: #string DONE
C_Names :: #import "Jolk/C_Names";
using,map(C_Names.to_c_names) Vk :: #import "Jolk";

#if OS == .WINDOWS {
	libvma :: #library "windows/VMA";
} else #if OS == .LINUX {
	libvma :: #library "linux/VMA";
} else #if OS == .MACOS {
	libvma :: #library "macos/VMA";
} else {
	#assert(false);
}
DONE
