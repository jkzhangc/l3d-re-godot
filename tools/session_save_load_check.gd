extends SceneTree

## @trace FLOW-002, FLOW-003
## 仅测试槽18；存在原测试文件时逐字节备份恢复，不触碰0..14玩家存档。
const SESSION = preload("res://script/flow/game_session.gd")
const LOCATOR = preload("res://script/map/map_locator.gd")
const SLOT: int = 18
var _checks: int = 0
var _fails: int = 0
var _backup: Dictionary = {}


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])


func _wait_map() -> void:
	for _i: int in range(70):
		await physics_frame


func _run() -> void:
	await process_frame
	var sm: Script = load("res://script/save_manager.gd") as Script
	for path: String in [sm.slot_path(SLOT), sm.bak_path(SLOT)]:
		_backup[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	var global: Node = root.get_node("Global")
	var target := "res://scene/maps/突袭-第一关-街道.tscn"
	_check(SESSION.request_map(self, target) == OK, "进入待存档地图")
	await _wait_map()
	var map: Node = LOCATOR.get_map_root(self)
	var player: Node2D = LOCATOR.find_preplaced_player(map)
	var position: Vector2 = player.global_position
	var hud: Node = SESSION.find(self).get("hud")
	var hud_id: int = hud.get_instance_id()
	global.call("apply_quest_flag", "session_test_roundtrip", true)
	_check(sm.save_to_slot(SLOT, position, position), "写入保留测试槽18")
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(sm.slot_path(SLOT)))
	_check(data is Dictionary and data.get("scene_path") == target, "存档保存源地图路径而非Session")
	global.call("capture_checkpoint")
	_check(global.get("checkpoint").get("scene_path") == target, "内存checkpoint保存源地图路径")
	SESSION.request_map(self, "res://scene/maps/突袭-第二关-学校内部.tscn")
	await _wait_map()
	_check(global.call("load_from_slot", SLOT), "通过生产读档入口加载")
	await _wait_map()
	var restored: Node = LOCATOR.get_map_root(self)
	var restored_player: Node2D = LOCATOR.find_preplaced_player(restored)
	_check(restored.scene_file_path == target, "读档回到源地图")
	_check(restored_player.global_position.distance_to(position) < 1.0, "读档恢复真实玩家站位")
	_check(SESSION.find(self).get("hud").get_instance_id() == hud_id, "读档不重复创建HUD")
	_check(global.call("get_quest_flag", "session_test_roundtrip"), "任务状态随读档保留")
	root.get_node("Director").call("_reset_live_combat_state")
	root.get_node("Director").set_process(false)
	SESSION.end_session(self)
	current_scene = null
	await process_frame
	await process_frame
	_restore_slot()
	print("SESSION_SAVE_LOAD_CHECK: %d checks / %d failed" % [_checks, _fails])
	quit(0 if _fails == 0 else 1)


func _restore_slot() -> void:
	for path: String in _backup:
		var bytes: Variant = _backup[path]
		if bytes is PackedByteArray:
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_buffer(bytes)
		else:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
	_backup.clear()
