class_name MeshMerge
extends RefCounted
## Bakes static decoration (many small MeshInstance3D with a few materials)
## into one mesh per material: same picture, a handful of draw calls instead of
## hundreds (each caster is drawn again in every shadow split).


## Merges the MeshInstance3D under root into one child per material.
## shader: only meshes whose ShaderMaterial uses it (null: any material);
## recursive: false = direct children only (sub-nodes that move stay apart);
## by_look: plain StandardMaterial3D that look the same share a batch (only for
## materials nobody changes later).
static func merge(root: Node3D, shader: Shader = null, recursive := true, by_look := false) -> void:
	var groups := {}   # key -> {mat, shadow, parts: [[mesh, xform]]}
	var victims: Array[MeshInstance3D] = []
	for n in root.find_children("*", "MeshInstance3D", recursive, false):
		var mi := n as MeshInstance3D
		var mat := mi.material_override
		if mi.mesh == null or mat == null or not mi.visible or mi.get_script() != null or mi.get_child_count() > 0:
			continue
		if shader != null and not (mat is ShaderMaterial and (mat as ShaderMaterial).shader == shader):
			continue
		var key := _key(mat, mi.cast_shadow, by_look)
		if not groups.has(key):
			groups[key] = {"mat": mat, "shadow": mi.cast_shadow, "parts": []}
		var xf := _local_xform(root, mi)
		groups[key].parts.append([mi.mesh, xf])
		victims.append(mi)
	for key in groups:
		var g: Dictionary = groups[key]
		if g.parts.size() < 2:
			continue
		var out := MeshInstance3D.new()
		out.mesh = _bake(g.parts)
		out.material_override = g.mat
		out.cast_shadow = g.shadow
		root.add_child(out)
	for mi in victims:
		if groups[_key(mi.material_override, mi.cast_shadow, by_look)].parts.size() >= 2:
			mi.get_parent().remove_child(mi)
			mi.queue_free()


## Materials that look the same share a batch even if they are separate objects.
static func _key(mat: Material, shadow: int, by_look: bool) -> String:
	if by_look and mat is StandardMaterial3D:
		var m := mat as StandardMaterial3D
		if m.albedo_texture == null and m.normal_texture == null:
			return "std %s %s %s %s %d" % [m.albedo_color, m.roughness, m.metallic, m.metallic_specular, shadow]
	return "%d %d" % [mat.get_instance_id(), shadow]


static func _local_xform(root: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var p: Node = n
	while p != null and p != root:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


static func _bake(parts: Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for part in parts:
		var mesh: Mesh = part[0]
		var xf: Transform3D = part[1]
		var nb := xf.basis.inverse().transposed()
		for s in mesh.get_surface_count():
			var a := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var nrm = a[Mesh.ARRAY_NORMAL]
			var tan = a[Mesh.ARRAY_TANGENT]
			var uv = a[Mesh.ARRAY_TEX_UV]
			var ix = a[Mesh.ARRAY_INDEX]
			var base := verts.size()
			for i in v.size():
				verts.append(xf * v[i])
				normals.append((nb * (nrm[i] as Vector3)).normalized() if nrm != null and nrm.size() > i else Vector3.UP)
				if tan != null and tan.size() >= (i + 1) * 4:
					var t := (xf.basis * Vector3(tan[i * 4], tan[i * 4 + 1], tan[i * 4 + 2])).normalized()
					tangents.append_array([t.x, t.y, t.z, tan[i * 4 + 3]])
				else:
					tangents.append_array([1.0, 0.0, 0.0, 1.0])
				uvs.append(uv[i] if uv != null and uv.size() > i else Vector2.ZERO)
			if ix != null and ix.size() > 0:
				for k in ix:
					idx.append(base + k)
			else:
				for k in v.size():
					idx.append(base + k)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TANGENT] = tangents
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
