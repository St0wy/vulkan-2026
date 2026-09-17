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
textures: [3] Gpu_Texture;

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

	for * textures {
		ktx_data := read_entire_file(tprint("data/suzanne%.ktx2", it_index));
		ok, ktx_image := ktx_load(ktx_data);
		defer free(*ktx_image);
		assert(ok, "Could not load texture");

		it.* = renderer_create_texture(*renderer, ktx_image);
	}

	defer for * textures renderer_destroy_texture(*renderer, it);

	renderer_create_texture_set(*renderer, textures);

	shader_blob := read_entire_file("data/shader.spriv");
	renderer_create_pipeline(*renderer, shader_blob);

	last_time := current_time_monotonic();
	left_click := false;
	quit := false;
	while !quit {
		if begin_frame(*renderer, clear_color={0,0,0.2,1}) {
			aspect_ratio := renderer.window_size.width.(float) / renderer.window_size.height.(float);
			shader_data.projection = make_projection_matrix(FOV_VERTICAL, aspect_ratio, 0.1, 32, depth_range_01=true);
			shader_data.projection._22 *= -1; // To make it work with Vulkan conventions
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
