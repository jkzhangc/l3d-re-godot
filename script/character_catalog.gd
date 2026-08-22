class_name CharacterCatalog
extends RefCounted
## 角色资源目录。
##
## 角色选择和联机白名单必须使用同一份目录：目录枚举在部分运行环境中可能
## 暂时不可用，而显式 preload 的正式角色既能稳定加载，也能被导出流程收集。

const DEFAULT_CHARACTER_PATH := "res://object/character_nobita.tres"
const BIGG_CHARACTER_PATH := "res://object/character_bigg.tres"

## 保持固定顺序：主角在前，随后是已正式接入的可选角色。
const _CORE_CHARACTER_RESOURCES := [
	preload("res://object/character_nobita.tres"),
	preload("res://object/character_bigg.tres"),
]


static func get_available_character_paths() -> Array[String]:
	var paths: Array[String] = []
	for resource: Resource in _CORE_CHARACTER_RESOURCES:
		if resource is CharacterData:
			_add_path_once(paths, resource.resource_path)
		else:
			push_warning("[角色目录] 正式角色资源不是 CharacterData: %s" % resource.resource_path)

	## 兼容以后新增的 character_*.tres。即使目录枚举失败，上面的正式角色仍可用。
	var dir := DirAccess.open("res://object")
	if dir:
		var discovered_paths: Array[String] = []
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while not file_name.is_empty():
			if file_name.begins_with("character_") and file_name.ends_with(".tres"):
				discovered_paths.append("res://object/" + file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
		discovered_paths.sort()
		for path: String in discovered_paths:
			var discovered: Resource = load(path)
			if discovered is CharacterData:
				_add_path_once(paths, path)
	else:
		push_warning("[角色目录] 无法枚举 res://object；继续使用预置角色清单")
	return paths


static func load_available_characters() -> Array[CharacterData]:
	var characters: Array[CharacterData] = []
	for path: String in get_available_character_paths():
		var resource: Resource = load(path)
		if resource is CharacterData:
			characters.append(resource as CharacterData)
		else:
			push_warning("[角色目录] 跳过无效角色资源: %s" % path)
	return characters


static func _add_path_once(paths: Array[String], path: String) -> void:
	if not path.is_empty() and path not in paths:
		paths.append(path)
