Vertex :: struct {
	position: Vector3;
	normal: Vector3;
	tex_coords: Vector2;
	// tangent: Vector4;
}

Mesh :: struct {
	name: string;
	vertices: [] Vertex;
	indices: [] u32;
	material_index: u16; // 0 = nil
}

Material :: struct {
	name: string;
	ambient: Vector3;
	diffuse: Vector3;
	specular: Vector3;
	specular_exponent: float;
	emissive: Vector3;
	index_of_refraction: float;
	dissolve: float;
}

// Based on https://github.com/thisistherk/fast_obj
load_model_obj :: (obj_path: string) -> bool, Mesh, [] Material {
	mesh: Mesh;
	materials: [] Material;
	obj_content, success := read_entire_file(obj_path);
	if !success then return false, mesh, materials;
	defer free(obj_content);

	positions := make_temp_dyn_array(Vector3);
	normals := make_temp_dyn_array(Vector3);
	tex_coords := make_temp_dyn_array(Vector2);
	added_indices := make_temp_dyn_array(ObjIndexInfo);

	vertices: [..] Vertex;
	indices: [..] u32;

	line := 1;
	content := obj_content;
	while content.count > 0 {
		skip_whitespace(*content);

		if content[0] == {
		case "v";
			advance(*content);
			c := content[0];
			advance(*content);
			if is_whitespace(c) {
				pos := parse_vertex(*content);
				array_add(*positions, pos);
			} else if c == {
			case "t";
				tex_coord := parse_tex_coord(*content);
				array_add(*tex_coords, tex_coord);
			case "n";
				normal := parse_normal(*content);
				array_add(*normals, normal);
			case;
				go_back(*content);
			}
		case "f";
			advance(*content);
			c := content[0];
			advance(*content);

			if is_whitespace(c) {
				faces_index_infos := parse_faces(*content);
				// For now doing it while parsing, but if the face data is before positions etc it
				// wont work, so might have to move it out later
				for index_infos: faces_index_infos {
					for index_info: index_infos {
						// Already got and index with the same infos
						could_find, index_index := array_find(added_indices, index_info);
						if could_find {
							assert(index_index < vertices.count);
							array_add(*indices, xx index_index);
						} else {
							vertex: Vertex;
							vertex.position = positions[index_info.vertex - 1];
							// TODO Handle the case where there's no texture coordinates, normal etc
							vertex.tex_coords = tex_coords[index_info.tex_coords - 1];
							vertex.normal = normals[index_info.normal - 1];

							array_add(*vertices, vertex);
							array_add(*added_indices, index_info);
							array_add(*indices, cast(u32, added_indices.count - 1));
							assert(vertices.count == added_indices.count);
						}
					}
				}
			} else {
				go_back(*content);
			}
		case "o";
			advance(*content);
			c := content[0];
			advance(*content);
			if is_whitespace(c) {
				// TODO handle multiple meshes
				assert(mesh.name == "");
				skip_whitespace(*content);
				start := content;
				skip_name(*content);
				end := content;

				count := start.count - end.count;
				name := start;
				name.count = count;

				mesh.name = copy_string(name);
			} else {
				go_back(*content);
			}
		case "m";
			advance(*content);
			if content[0] == "t" &&
			content[1] == "l" &&
			content[2] == "l" &&
			content[3] == "i" &&
			content[4] == "b" &&
			is_whitespace(content[5]) {
				advance(*content, 5);
				skip_whitespace(*content);

				start := content;
				skip_name(*content);
				end := content;
				count := start.count - end.count;
				mtl_name := start;
				mtl_name.count = count;

				mtl_path := parse_path(obj_path,, temp);
				mtl_path.words[mtl_path.words.count - 1] = mtl_name;
				mtl_path_string := path_to_string(mtl_path,, temp);

				ok:, materials = read_mtllib(mtl_path_string);
				if !ok return false, mesh, materials;
			}
		case "u";
			advance(*content);
			if content[0] == "s" &&
			content[1] == "e" &&
			content[2] == "m" &&
			content[3] == "t" &&
			content[4] == "l" &&
			is_whitespace(content[5]) {
				advance(*content, 5);
				skip_whitespace(*content);

				start := content;
				skip_name(*content);
				end := content;
				count := start.count - end.count;
				mtl_name := start;
				mtl_name.count = count;

				for materials {
					if it.name == mtl_name {
						mesh.material_index = xx it_index;
						break;
					}
				}

				if mesh.material_index == 0 {
					log("Did not find material %", mtl_name);
				}
			}
		}

		skip_line(*content);
		line += 1;
	}

	mesh.vertices = vertices;
	mesh.indices = indices;

	return true, mesh, materials;
}

read_mtllib :: (path: string) -> bool, [] Material {
	materials: [..] Material;
	current_material: *Material;

	mtl_contents, ok := read_entire_file(path);
	defer free(mtl_contents);
	if !ok then return false, materials;

	// Add empty one because index 0 means no material in the mesh
	array_add(*materials, Material.{});
	contents := mtl_contents;
	while contents.count > 0 {
		skip_whitespace(*contents);

		if contents[0] == {
		case "n";
			advance(*contents);
			if contents[0] == "e" &&
			contents[1] == "w" &&
			contents[2] == "m" &&
			contents[3] == "t" &&
			contents[4] == "l" &&
			is_whitespace(contents[5]) {
				array_add(*materials, Material.{});
				current_material = *materials[materials.count - 1];
				advance(*contents, 5);
				skip_whitespace(*contents);

				start := contents;
				skip_name(*contents);
				end := contents;
				count := start.count - end.count;
				name := start;
				name.count = count;

				current_material.name = copy_string(name);
			}
		case "K";
			if contents[1] == "a" {
				advance(*contents, 2);
				current_material.ambient = parse_mtl_triple(*contents);
			} else if contents[1] == "d" {
				advance(*contents, 2);
				current_material.diffuse = parse_mtl_triple(*contents);
			} else if contents[1] == "s" {
				advance(*contents, 2);
				current_material.specular = parse_mtl_triple(*contents);
			} else if contents[1] == "e" {
				advance(*contents, 2);
				current_material.emissive = parse_mtl_triple(*contents);
			}
		case "N";
			if contents[1] == "s" {
				advance(*contents, 2);
				current_material.specular_exponent = parse_float(*contents);
			} else if contents[1] == "i" {
				advance(*contents, 2);
				current_material.index_of_refraction = parse_float(*contents);
			}
		case "d";
			if is_whitespace(contents[1]) {
				advance(*contents);
				current_material.dissolve = parse_float(*contents);
			}
		}

		skip_line(*contents);
	}

	return true, materials;
}

delete_mesh :: (mesh: Mesh) {
	array_free(mesh.vertices);
	array_free(mesh.indices);
	free(mesh.name);
}

delete_materials :: (materials: *[] Material) {
	for materials.* {
		free(it.name);
	}
	array_free(materials.*);
	materials.data = null;
	materials.count = 0;
}

// generate_tangents :: (mesh: Mesh) {
// 	for face_index: 0..(mesh.indices.count / 3) - 1 {
// 		vertex_a := *mesh.vertices[mesh.indices[face_index * 3]];
// 		vertex_b := *mesh.vertices[mesh.indices[face_index * 3 + 1]];
// 		vertex_c := *mesh.vertices[mesh.indices[face_index * 3 + 2]];

// 		edge_1 := vertex_b.position - vertex_a.position;
// 		edge_2 := vertex_c.position - vertex_a.position;
// 		delta_uv_1 := vertex_b.tex_coords - vertex_a.tex_coords;
// 		delta_uv_2 := vertex_c.tex_coords - vertex_a.tex_coords;

// 		f := 1.0 / (delta_uv_1.x * delta_uv_2.y - delta_uv_2.x * delta_uv_1.y);

// 		tangent := f * (delta_uv_2.y * edge_1 - delta_uv_1.y * edge_2);
// 		vertex_a.tangent.xyz = normalize(tangent - dot(vertex_a.normal, tangent) * vertex_a.normal);
// 		vertex_b.tangent.xyz = normalize(tangent - dot(vertex_b.normal, tangent) * vertex_b.normal);
// 		vertex_c.tangent.xyz = normalize(tangent - dot(vertex_c.normal, tangent) * vertex_c.normal);

// 		bitangent := f * (-delta_uv_2.x * edge_1 + delta_uv_1.x * edge_2);

// 		vertex_a.tangent.w = 1.0;
// 		vertex_b.tangent.w = 1.0;
// 		vertex_c.tangent.w = 1.0;
// 	}
// }

#scope_file

ObjIndexInfo :: struct {
	vertex: int;
	tex_coords: int;
	normal: int;
}

#poke_name Basic operator==;
operator == :: inline (a: ObjIndexInfo, b: ObjIndexInfo) -> bool {
	return a.vertex == b.vertex && a.tex_coords == b.tex_coords && a.normal == b.normal;
}

skip_whitespace :: inline (str: *string) {
	while is_whitespace(str.*[0]) advance(str);
}

peek_previous :: inline (str: string) -> u8 {
	data := str.data;
	return (data - 1).*;
}

skip_name :: inline (str: *string) {
	start := str.data;
	while !is_newline(str.*[0]) advance(str);
	while str.data > start && is_whitespace(peek_previous(str.*)) go_back(str);
}

is_whitespace :: inline (c: u8) -> bool {
	return c == " " || c == "\t" || c == "\r";
}

is_newline :: inline (c: u8) -> bool {
	return c == "\n";
}

is_exponent :: inline (c: u8) -> bool {
	return c == "e" || c == "E";
}

go_back :: inline (s: *string, amount: s64 = 1) {
	assert(amount >= 0);
	s.count += amount;
	s.data  -= amount;
}

skip_line :: inline (str: *string) {
	c := str.*[0];
	advance(str);
	while !is_newline(c) {
		c = str.*[0];
		advance(str);
	}
}

parse_vertex :: inline (str: *string) -> Vector3 {
	vertex: Vector3 = ---;
	for * vertex.component {
		v := parse_float(str);
		it.* = v;
	}

	skip_whitespace(str);
	if !is_newline(str.*[0]) {
		assert(false, "w component or vertex colors not implemented");
	}

	return vertex;
}

parse_tex_coord :: inline (str: *string) -> Vector2 {
	tex_coord: Vector2 = ---;
	for * tex_coord.component {
		v := parse_float(str);
		it.* = v;
	}

	return tex_coord;
}

parse_normal :: inline (str: *string) -> Vector3 {
	normal: Vector3 = ---;
	for * normal.component {
		v := parse_float(str);
		it.* = v;
	}

	return normal;
}

parse_mtl_triple :: inline (str: *string) -> Vector3 {
	value: Vector3 = ---;
	for * value.component {
		v := parse_float(str);
		it.* = v;
	}

	return value;
}

parse_faces :: (str: *string) -> [..][3] ObjIndexInfo {
	index_info := make_temp_dyn_array(ObjIndexInfo);
	skip_whitespace(str);

	while !is_newline(str.*[0]) {
		v := parse_int(str);
		t, n: int;

		if str.*[0] == "/" {
			advance(str);
			if str.*[0] != "/" {
				t = parse_int(str);
			}

			if str.*[0] == "/" {
				advance(str);
				n = parse_int(str);
			}
		}

		array_add(*index_info, ObjIndexInfo.{
			vertex = v,
			tex_coords = t,
			normal = n,
		});
		skip_whitespace(str);
	}

	// TODO handle lines and polygons and stuff
	//
	assert(index_info.count == 4 || index_info.count == 3, "Count equal to 3 or 4, but it's %", index_info.count);

	triangles := make_temp_dyn_array([3] ObjIndexInfo);

	if index_info.count == 3 {
		triangle: [3] ObjIndexInfo;
		for index_info triangle[it_index] = it;
		array_add(*triangles, triangle);
	} else if index_info.count == 4 {
		triangle_1: [3] ObjIndexInfo;
		for 0..2 triangle_1[it] = index_info[it];
		array_add(*triangles, triangle_1);

		triangle_2: [3] ObjIndexInfo;
		triangle_2[0] = index_info[0];
		triangle_2[1] = index_info[2];
		triangle_2[2] = index_info[3];
		array_add(*triangles, triangle_2);
	}

	return triangles;
}

// Based on https://github.com/thisistherk/fast_obj/blob/d620667f10a548dee94dbc8c144bb22f79162176/fast_obj.h#L587
parse_float :: (str: *string) -> float {
	sign: float64 = 1.0;

	skip_whitespace(str);

	if str.*[0] == {
	case "+";
		advance(str);
	case "-";
		sign = -1.0;
		advance(str);
	}

	num: float64;
	while is_digit(str.*[0]) {
		num = 10.0 * num + (str.*[0] - #char "0");
		advance(str);
	}

	if str.*[0] == "." then advance(str);

	fra: float64;
	div: float64 = 1.0;
	while is_digit(str.*[0]) {
		fra = 10.0 * fra + (str.*[0] - #char "0");
		advance(str);
		div *= 10.0;
	}

	num += fra / div;

	if is_exponent(str.*[0]) {
		advance(str);

		POWER_10_POS :: float64.[
			1.0e0,  1.0e1,  1.0e2,  1.0e3,  1.0e4,  1.0e5,  1.0e6,  1.0e7,  1.0e8,  1.0e9,
			1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15, 1.0e16, 1.0e17, 1.0e18, 1.0e19,
		];
		POWER_10_NEG :: float64.[
			1.0e0, 1.0e-1,  1.0e-2,  1.0e-3,  1.0e-4,  1.0e-5,  1.0e-6,  1.0e-7,  1.0e-8,  1.0e-9,
			1.0e-10, 1.0e-11, 1.0e-12, 1.0e-13, 1.0e-14, 1.0e-15, 1.0e-16, 1.0e-17, 1.0e-18, 1.0e-19,
		];
		powers := POWER_10_POS;
		if str.*[0] == {
		case "+";
			advance(str);
		case "-";
			powers = POWER_10_NEG;
			advance(str);
		}

		eval: u32;
		while is_digit(str.*[0]) {
			eval = 10 * eval + (str.*[0] - #char "0");
			advance(str);
		}

		num *= ifx eval >= POWER_10_POS.count 0.0 else powers[eval];
	}

	val : float = (sign * num).(float);
	return val;
}

parse_int :: (str: *string) -> int {
	sign := 1;
	num: int;

	if str.*[0] == "-" {
		sign = -1;
		advance(str);
	}

	while is_digit(str.*[0]) {
		num = 10 * num + (str.*[0] - #char "0");
		advance(str);
	}

	return sign * num;
}
