extends SceneTree
## net_proto 静态/资源冒烟测试：
##   godot --headless --path net_proto --script res://tests/test_sync_config.gd
##
## 显式 RPC 方案不再依赖 MultiplayerSpawner / MultiplayerSynchronizer。
## 本测试负责尽早发现脚本解析失败、场景资源损坏和旧复制节点回流。

const REQUIRED_RESOURCES := [
	"res://script/net/net_connection.gd",
	"res://script/lobby.gd",
	"res://script/game.gd",
	"res://script/player.gd",
	"res://script/enemy.gd",
	"res://script/bullet.gd",
	"res://script/hud.gd",
	"res://scene/lobby.tscn",
	"res://scene/game.tscn",
	"res://object/player.tscn",
	"res://object/enemy.tscn",
	"res://object/bullet.tscn",
]

var _failures := 0


func _initialize() -> void:
	print("== net_proto explicit RPC 静态冒烟测试 ==")
	for path in REQUIRED_RESOURCES:
		_check(ResourceLoader.exists(path), "资源存在：" + path)
		var resource := load(path)
		_check(resource != null, "资源可加载：" + path)
	_test_game_scene()
	print("== 测试结束：%d 个失败 ==" % _failures)
	quit(_failures)


func _test_game_scene() -> void:
	var packed := load("res://scene/game.tscn") as PackedScene
	if packed == null:
		return
	var game := packed.instantiate()
	_check(game != null, "game.tscn 可实例化")
	if game == null:
		return
	_check(game.get_node_or_null("Players") != null, "存在 Players 容器")
	_check(game.get_node_or_null("Enemies") != null, "存在 Enemies 容器")
	_check(game.get_node_or_null("Bullets") != null, "存在 Bullets 容器")
	_check(not _contains_legacy_replication_node(game), "未包含旧 MultiplayerSpawner/Synchronizer")
	game.free()


func _contains_legacy_replication_node(node: Node) -> bool:
	if node is MultiplayerSpawner or node is MultiplayerSynchronizer:
		return true
	for child in node.get_children():
		if _contains_legacy_replication_node(child):
			return true
	return false


func _check(condition: bool, what: String) -> void:
	if condition:
		print("  PASS  " + what)
	else:
		_failures += 1
		printerr("  FAIL  " + what)
