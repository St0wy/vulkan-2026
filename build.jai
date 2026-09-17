#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "Process";
#import "Metaprogram_Plugins";

BUILD_DEBUG_DIR :: "run/debug";
BUILD_OPTIMIZED_DIR :: "run/optimized";
BUILD_RELEASE_DIR :: "run/release";

plugins: [..] *Metaprogram_Plugin;

build :: () {
	w := compiler_create_workspace();
	if !w 	{
		write_string("Workspace creation failed.\n");
		return;
	}

	target_options := get_build_options(w);
	args := target_options.compile_time_command_line;

	build_optimized := false;
	build_release := false;
	autorun := false;

	for arg: args {
		if arg == {
			case "-o"; #through;
			case "-optimized";
				build_optimized = true;
			case "-release";
				build_release = true;
			case "-autorun";
				autorun = true;
		}
	}

	plugins_to_create: [..] Plugin_To_Create;
	array_add(*plugins_to_create, .{name="Check"});
	if autorun array_add(*plugins_to_create, .{name="Autorun"});
	success := init_plugins(plugins_to_create, *plugins, w);
	assert(success);

	target_options.output_executable_name = "vulkan_2026";

	// There are 3 target types in this program :
	// - Debug : Not optimized and has debug info
	// - Optimized : Optimized and has debug info
	// - Release : Very optimized and doesn't have debug info
	if build_release {
		setup_build_dir(BUILD_RELEASE_DIR);
		target_options.backend = .LLVM;
		target_options.output_path = BUILD_RELEASE_DIR;
		target_options.emit_debug_info = .NONE;
		target_options.enable_bytecode_inliner = true;
		target_options.llvm_options.enable_split_modules = false;
		target_options.array_bounds_check = .OFF;
		target_options.null_pointer_check = .OFF;
		target_options.arithmetic_overflow_check = .OFF;
		#if OS == .WINDOWS {
			target_options.additional_linker_arguments = .["/SUBSYSTEM:windows", "/ENTRY:mainCRTStartup"];
		}
		set_optimization(*target_options, Optimization_Type.VERY_OPTIMIZED);
	}
	else if build_optimized {
		setup_build_dir(BUILD_OPTIMIZED_DIR);
		target_options.backend = .LLVM;
		target_options.output_path = BUILD_OPTIMIZED_DIR;
		set_optimization(*target_options, Optimization_Type.OPTIMIZED, true);
	} else {
		setup_build_dir(BUILD_DEBUG_DIR);
		target_options.backend = #ifx CPU == .X64 then .X64 else .LLVM;
		target_options.output_path = BUILD_DEBUG_DIR;
		set_optimization(*target_options, Optimization_Type.DEBUG, true);
	}

	build_shader("data/shader.slang", "data/shader.spriv");

	set_build_options(target_options, w);

	intercept_flags: Intercept_Flags;
	for plugins if it.before_intercept it.before_intercept(it, *intercept_flags);
	compiler_begin_intercept(w, intercept_flags);

	for plugins if it.add_source it.add_source(it);

	add_build_string("BuildType :: enum u8 { DEBUG; OPTIMIZED; RELEASE; }", w);
	if build_release
		add_build_string("BUILD_TYPE :: BuildType.RELEASE;", w);
	else if build_optimized
		add_build_string("BUILD_TYPE :: BuildType.OPTIMIZED;", w);
	else
		add_build_string("BUILD_TYPE :: BuildType.DEBUG;", w);

	add_build_file("src/main.jai", w);

	message_loop(w);

	compiler_end_intercept(w);

	for plugins if it.finish it.finish(it);
	for plugins if it.shutdown it.shutdown(it);

	set_build_options_dc(.{do_output=false});
}

message_loop :: (w: Workspace) {
	while true {
		message := compiler_wait_for_message();
		if !message then continue;

		for plugins if it.message it.message(it, message);
		if message.workspace == w {
		}

		if message.kind == .COMPLETE break;
	}
}

setup_build_dir :: (path: string) {
	make_directory_if_it_does_not_exist(path, recursive=true);
	#if OS == .WINDOWS {
		vma_dll_path := tprint("%/VMA.dll", path);
		if !file_exists(vma_dll_path) then copy_file("modules/jai-vma/windows/VMA.dll", vma_dll_path);
	}
}

build_shader :: (in_path: string, out_path: string) {
	command := tprint("slangc % -target spirv -profile spirv_1_6 -emit-spirv-directly -matrix-layout-row-major -capability spirv_1_5+SPV_KHR_non_semantic_info+SPV_GOOGLE_user_type+spvDerivativeControl+spvImageQuery+spvImageGatherExtended+spvSparseResidency+spvMinLod+spvFragmentFullyCoveredEXT+spvShaderNonUniformEXT -o %", in_path, out_path);
	strings := break_command_into_strings(command);
	run_command(..strings);
}

main :: () {}

#run,stallable build();
