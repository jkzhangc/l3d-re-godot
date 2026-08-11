extends SceneTree
## 无头冒烟测试（net_proto）：
##   godot --headless --script res://tests/test_sync_config.gd
##
## 验证 Godot 4.6 下 SceneReplicationConfig 方法式 API 与 spawn_function 可用性。
## 这两处是本原型的同步基石，先用最小代码锁死 API 行为。

var _failures := 0


func _initialize() -> void:
	print("== net_proto 同步配置冒烟测试 ==")
	_test_replication_config()
	_test_spawn_function_registration()
	print("== 测试结束：%d 个失败 ==" % _failures)
	quit(_failures)


func _test_replication_config() -> void:
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath("^position"))
	cfg.property_set_replication_mode(
		NodePath("^position"),
		SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ALWAYS
	)
	cfg.property_set_spawn(NodePath("^position"), true)
	cfg.add_property(NodePath("^hp"))
	cfg.property_set_replication_mode(
		NodePath("^hp"),
		SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ON_CHANGE
	)
	cfg.property_set_spawn(NodePath("^hp"), true)
	_check(
		cfg.property_get_replication_mode(NodePath("^position"))
			== SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ALWAYS,
		"position 同步模式 = ALWAYS"
	)
	_check(cfg.property_get_spawn(NodePath("^hp")), "hp 生成时携带 = true")
	_check(
		cfg.property_get_replication_mode(NodePath("^hp"))
			== SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ON_CHANGE,
		"hp 同步模式 = ON_CHANGE"
	)


func _test_spawn_function_registration() -> void:
	var spawner := MultiplayerSpawner.new()
	spawner.spawn_function = _dummy_spawn
	_check(spawner.spawn_function != null, "spawn_function 可注册为 Callable")
	spawner.free()


func _dummy_spawn(_data: Variant) -> Node:
	return Node.new()


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  PASS  " + what)
	else:
		_failures += 1
		printerr("  FAIL  " + what)
