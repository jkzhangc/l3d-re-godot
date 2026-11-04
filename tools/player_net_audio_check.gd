extends Node

## 联机玩家音效回归（2026-11-04）。
## 用法：godot --headless --path . res://tools/player_net_audio_check.tscn
##
## 覆盖三类「客户端/主机都听不到」的缺口：
##  1. 联机死亡/倒地音效 —— `network_controlled` 实体的 `_die()` 在单机那条
##     `_play_sound(death_sound)` 之前就 return，Client 又走快照直接进
##     `_apply_network_death_state()` → 两端都没有死亡音。
##  2. 客户端用消耗品的使用音效/闪光 —— Host 代结算时 `_play_item_use_feedback`
##     按「只对本机操控玩家播」早退，Client 端完全静音。
##  3. 拾取音效 —— 联机拾取是 Host 权威事务，Client 不跑 `_do_pickup`；
##     武器/投掷物连 Host 也没有声音。
## 1、2 走运行时（真节点 + 真播放器），3 走源码闸门（链路分散在 network_world 的三个分支）。

const PLAYER_SCENE := preload("res://object/player.tscn")
const WORLD_SCRIPT := "res://script/network_world.gd"
const SAMPLE_SFX := "res://sound/チャキッ.ogg"
const SPRAY := preload("res://object/item_first_aid_spray.tres")

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _check_true(label: String, cond: bool) -> void:
	_check(label, cond, true)


## 该节点下是否有一个正在播 `stream` 的一次性播放器（Global.play_sfx_managed 的产物）。
func _has_player_for(root: Node, stream: AudioStream) -> bool:
	for child: Node in root.get_children():
		if child is AudioStreamPlayer and (child as AudioStreamPlayer).stream == stream:
			return true
		if child is AudioStreamPlayer2D and (child as AudioStreamPlayer2D).stream == stream:
			return true
	return false


func _ready() -> void:
	## 本用例只关心玩家节点的音效出口：关掉导演自动刷怪，避免 headless 下真的生成尸潮
	## （刷怪日志会淹没断言输出，且敌人攻击会改动 HP）。
	var director: Node = get_node_or_null("/root/Director")
	if director != null:
		director.set("auto_spawn_enabled", false)
	await get_tree().process_frame
	var sfx: AudioStream = load(SAMPLE_SFX) as AudioStream
	_check_true("取样音效存在", sfx != null)

	print("=== 1) 联机死亡/倒地：death_sound 必须播 ===")
	var p: Node2D = PLAYER_SCENE.instantiate()
	add_child(p)
	await get_tree().process_frame
	p.death_sound = sfx
	_check_true("死亡前无残留播放器", not _has_player_for(p, sfx))
	p.call("_apply_network_death_state")
	_check_true("_apply_network_death_state 后出现 death_sound 播放器", _has_player_for(p, sfx))
	_check("躺地标志", bool(p.get("_is_dying")), true)
	## 幂等：再进一次不应叠出第二个（调用点本就带 not _is_dying 闸门，这里只验现象）。
	var before := p.get_child_count()
	p.call("_apply_network_death_state")
	print("  · 二次进入子节点数 %d（一次进入前 %d）" % [p.get_child_count(), before])
	p.queue_free()
	await get_tree().process_frame

	print("=== 2) 客户端消耗品使用表现：play_network_item_use_feedback ===")
	var p2: Node2D = PLAYER_SCENE.instantiate()
	add_child(p2)
	await get_tree().process_frame
	var item: ItemData = (SPRAY as ItemData).duplicate()
	item.use_sound = sfx
	item.use_flash_duration = 0.0   ## 不触发全屏闪光（headless 下没有意义）
	_check_true("使用前无残留播放器", not _has_player_for(p2, sfx))
	p2.call("play_network_item_use_feedback", item)
	_check_true("play_network_item_use_feedback 后出现 use_sound 播放器", _has_player_for(p2, sfx))
	p2.queue_free()
	await get_tree().process_frame

	print("=== 3) 拾取音效链路（源码闸门） ===")
	var src := _read(WORLD_SCRIPT)
	_check_true("存在 pickup_sfx_presentation RPC", src.contains("func pickup_sfx_presentation("))
	_check_true("存在 _play_pickup_sfx 本地播放", src.contains("func _play_pickup_sfx("))
	_check_true("存在 _announce_pickup_sfx 广播", src.contains("func _announce_pickup_sfx("))
	## 三个拾取分支（治疗品 / 投掷物 / 武器）都必须广播
	var announce_count := src.count("_announce_pickup_sfx(pickup_id, pickup_position)")
	_check("_announce_pickup_sfx 调用点数量", announce_count, 3)
	## 武器与投掷物分支还必须在 Host 本地播（治疗品由 healing_pickup 自己播）
	var local_play_count := src.count("_play_pickup_sfx(throwable, pickup_position)") \
			+ src.count("_play_pickup_sfx(weapon, pickup_position)")
	_check("Host 本地拾取音调用点数量", local_play_count, 2)

	print("=== 4) 消耗品使用表现链路（源码闸门） ===")
	_check_true("存在 item_use_presentation RPC", src.contains("func item_use_presentation("))
	_check("_announce_item_use 调用点数量", src.count("_announce_item_use(peer_id, used,"), 2)
	var player_src := _read("res://script/player.gd")
	_check_true("player 有 play_network_item_use_feedback",
			player_src.contains("func play_network_item_use_feedback("))
	_check_true("联机攻击表现透传步号",
			player_src.contains("set_attack_char_index(sequence[index], index)"))

	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()
