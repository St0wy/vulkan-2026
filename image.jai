Pixel :: struct {
	r, g, b: u8;
}

PixelRgba :: struct {
	r, g, b, a: u8;
}

Image :: struct ($T: Type = Pixel) {
	width, height: s32;
	pixels: [] T;
	loaded_from_stbi: bool = false;
}

load_image :: (path: string, $T: Type = Pixel, desired_channels: s32 = 0) -> bool, Image(T) {
	image: Image(T) = ---;
	channels_in_file: s32;
	data := stbi_load(to_c_string(path,, temp), *image.width, *image.height, *channels_in_file, desired_channels);
	if !data {
		failure_reason := to_string(stbi_failure_reason());
		log_error("Could not load image, reason: %", failure_reason);
		return false, image;
	}

	channels_in_type: s32;
	#if T == Pixel {
		channels_in_type = 3;
	} else #if T == PixelRgba {
		channels_in_type = 4;
	}else #if T == u8 || T == float {
		channels_in_type = 1;
	}
	if channels_in_type != channels_in_file {
		log_error("Missmatching number of channels between provided type and loaded file (wanted % recieved %, %).", channels_in_type, channels_in_file, path);
		stbi_image_free(data);
		return false, image;
	}

	image.pixels.count = image.width * image.height;
	image.pixels.data = cast(*T, data);
	image.loaded_from_stbi = true;

	return true, image;
}

create_image :: inline (width: s32, height: s32, $T: Type = Pixel) -> Image(T) {
	image: Image(T) = ---;
	image.width = width;
	image.height = height;
	image.pixels = NewArray(width * height, T);

	return image;
}

delete_image :: inline (image: Image) {
	if image.loaded_from_stbi {
		stbi_image_free(image.pixels.data);
	} else {
		array_free(image.pixels);
	}
}
