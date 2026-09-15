
Ktx_Offsets :: struct {
	byte_offset: u64;
	byte_length: u64;
}

Ktx_Image :: struct {
	vulkan_format: VkFormat;
	width, height: u32;
	level_count: u32;
	mipmap_offsets: [] Ktx_Offsets;
	image_data: [] u8;
	file_data: string;
}

// The returned Ktx_Image owns the data passed, so it must not be freed as long as the Ktx_Image is needed
ktx_load :: (data: string) -> bool, Ktx_Image {
	cursor := data;
	image: Ktx_Image;
	image.file_data = data;

	header := cursor.data.(*Ktx_Header);
	for KTX_FILE_IDENTIFIER {
		if it != header.identifier[it_index] {
			log_error("Wrong KTX file identifier. Should be % but found %. (This loader only supports .ktx2 files)", KTX_FILE_IDENTIFIER.(string), header.identifier.(string));
			return false, image;
		}
	}
	advance(*cursor, size_of(Ktx_Header));

	if header.vk_format == VkFormat.VK_FORMAT_UNDEFINED {
		log_error("Unsuported vk_format: %", header.vk_format);
		return false, image;
	}

	if header.supercompression_scheme != 0 {
		log_error("Supercompression is not supported.");
		return false, image;
	}

	if header.type_size != 1 {
		log_error("Only type_size of 1 is supported.");
		return false, image;
	}

	if header.pixel_depth != 0 {
		log_error("Only 2D images are supported.");
		return false, image;
	}

	if header.layer_count != 0 {
		log_error("Only one layer is supported.");
		return false, image;
	}

	if header.face_count != 1 {
		log_error("Only one face is supported.");
		return false, image;
	}

	image.vulkan_format = header.vk_format;
	image.width = header.pixel_width;
	image.height = header.pixel_height;
	image.level_count = header.level_count;

	index := cursor.data.(*Ktx_Index);
	advance(*cursor, size_of(Ktx_Index));

	levels: [] Ktx_Level;
	levels.count = header.level_count;
	levels.data = xx cursor.data;

	image_data_start := levels[levels.count - 1].byte_offset;
	image.mipmap_offsets = NewArray(levels.count, Ktx_Offsets);
	image.image_data = advance(data, xx image_data_start).([] u8);
	for levels {
		image.mipmap_offsets[it_index].byte_offset = it.byte_offset - image_data_start;
		image.mipmap_offsets[it_index].byte_length = it.byte_length;
	}

	if levels[0].byte_length != levels[0].uncompressed_byte_length {
		log_error(
			"Compression is not supported. Missmatch between byte_length (%) and uncompressed_byte_length (%). Header: %",
			levels[0].byte_length,
			levels[0].uncompressed_byte_length,
			header.*
		);
		return false, image;
	}

	return true, image;
}

free :: (image: *Ktx_Image) {
	free(image.file_data);
	array_free(image.mipmap_offsets);
	image.* = {};
}

#scope_file

KTX_FILE_IDENTIFIER :: u8.[0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A];

Ktx_Supercompression_Scheme :: enum u32 #specified {
	None      :: 0;
	BasisLZ   :: 1; // ETC1S Slice Decoding https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#etc1s_slice
	Zstandard :: 2; // https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#RFC8478
	ZLIB      :: 3; // https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#RFC1950
}

Ktx_Header :: struct {
	identifier: [12] u8;
	vk_format: VkFormat;
	type_size: u32;
	pixel_width: u32;
	pixel_height: u32;
	pixel_depth: u32;
	layer_count: u32;
	face_count: u32;
	level_count: u32;
	supercompression_scheme: Ktx_Supercompression_Scheme;
}

Ktx_Index :: struct {
	dfd_byte_offset: u32;
	dfd_byte_length: u32;
	kvd_byte_offset: u32;
	kvd_byte_length: u32;
	sgd_byte_offset: u64;
	sgd_byte_length: u64;
}

Ktx_Level :: struct {
	byte_offset: u64;
	byte_length: u64;
	uncompressed_byte_length: u64;
}
