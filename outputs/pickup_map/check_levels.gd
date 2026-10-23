extends SceneTree

## 校验「多人房间章节列表」是否已剔除测试地图，以及「调试跳转」是否仍包含它们。
## 用法：godot --headless --path . --script res://outputs/pickup_map/check_levels.gd

func _init() -> void:
	var cd: GDScript = load("res://script/campaign_data.gd")
	print("=== 多人房间（过滤测试图）===")
	var pub: Array = cd.collect_all_level_entries()
	for e: Dictionary in pub:
		print("  ", e.get("label", "?"), "  <", e.get("scene", ""))
	print("=== 调试跳转（含测试图）===")
	var dev: Array = cd.collect_all_level_entries("res://scene/maps", true)
	for e: Dictionary in dev:
		var sp: String = str(e.get("scene", ""))
		print("  ", "[DEV]" if cd.is_dev_map(sp) else "     ", e.get("label", "?"))
	print("public=", pub.size(), " all=", dev.size())
	quit()
