extends SceneTree

## @trace FLOW-003
## 真实渲染截图，不写存档/配置。需要非headless运行。
const SESSION = preload("res://script/flow/game_session.gd")
var _paths: Array[String] = [
	"res://scene/maps/突袭-第一关-街道.tscn",
	"res://scene/maps/夜行猎手-第三关-结束安全屋.tscn",
	"res://scene/maps/突袭-第二关-学校内部.tscn",
]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var out := "res://.workbuddy/tmp/session-visual-20261121"
	DirAccess.make_dir_recursive_absolute(out)
	var global: Node = root.get_node("Global")
	# 关闭玩家输入不改作者参数，截图后当前进程结束。
	for index: int in range(_paths.size()):
		if SESSION.request_map(self, _paths[index]) != OK:
			quit(2)
			return
		for _frame: int in range(80):
			await process_frame
		var map: Node = (load("res://script/map/map_locator.gd") as Script).get_map_root(self)
		var summary: Node = map.find_child("ChapterSummary", true, false)
		if summary != null and summary.visible:
			summary.call("_finish_summary")
		global.call("hide_loading_screen")
		for _frame: int in range(45):
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = root.get_texture().get_image()
		var path: String = out + "/map_%d.png" % index
		if image.save_png(path) != OK:
			quit(3)
			return
		print("SESSION_VISUAL_SAVED " + path)
	var director: Node = root.get_node("Director")
	director.call("_reset_live_combat_state")
	director.set_process(false)
	SESSION.end_session(self)
	current_scene = null
	await process_frame
	await process_frame
	print("SESSION_VISUAL_CHECK: PASS images=3")
	quit(0)
