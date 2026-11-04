extends Node

## 武器默认音效 / 推击逐帧时长 校验（2026-11-04）。
## 用法：godot --headless --path . res://tools/weapon_defaults_check.tscn
##
## 覆盖四件事：
##  1. `WeaponData.shove_sound` 默认「打撃3」——推击不再静音；
##  2. `shove_frame_durations` 默认 [0.1, 0.05, 0.2]，逐帧取值与兜底；
##  3. 推击总时长 / 命中帧延迟按**逐帧求和**（Host 战斗忙窗口与命中判定都用它）；
##  4. 远程命中音三级回退：数据 → 属性专属 → 通用默认「殴る」（1.5 调）。
## 最后三条源码闸门保证状态机 / 联机表现真的用了逐帧接口，而不是各写一份常数。

const PISTOL := preload("res://object/weapon_pistol.tres")
const ELEMENT_FX := preload("res://script/element_fx.gd")
const DEFAULT_SHOVE := "res://sound/回避2.ogg"
const DEFAULT_SHOVE_HIT := "res://sound/(効果音)打撃3.ogg"
const DEFAULT_HIT := "res://sound/切り裂く.ogg"

var _fail := 0


func _check(label: String, got, want) -> void:
	if typeof(got) == typeof(want) and is_same(got, want):
		print("  OK   %s = %s" % [label, str(got)])
		return
	## 浮点单独按容差比（避免 is_same 对 0.35 这类累加结果过于严格）
	if (got is float or got is int) and (want is float or want is int) \
			and absf(float(got) - float(want)) <= 0.0001:
		print("  OK   %s = %s" % [label, str(got)])
		return
	_fail += 1
	print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _path_of(stream: AudioStream) -> String:
	return stream.resource_path if stream != null else "<null>"


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _ready() -> void:
	await get_tree().process_frame
	var wd: WeaponData = PISTOL
	_check("测试武器存在", wd != null, true)

	print("=== 1) 推击音效默认值（动作音 / 命中音分开） ===")
	_check("shove_sound（起手动作音）", _path_of(wd.shove_sound), DEFAULT_SHOVE)
	_check("shove_hit_sound（推中敌人）", _path_of(wd.shove_hit_sound), DEFAULT_SHOVE_HIT)

	print("=== 2) 推击逐帧时长 ===")
	_check("shove_frame_durations 条目数", wd.shove_frame_durations.size(), 3)
	_check("第 1 帧（前摇）", wd.get_shove_frame_duration(0), 0.1)
	_check("第 2 帧（推出）", wd.get_shove_frame_duration(1), 0.05)
	_check("第 3 帧（收势）", wd.get_shove_frame_duration(2), 0.2)
	_check("越界下标回退统一时长", wd.get_shove_frame_duration(3), wd.shove_frame_duration)

	print("=== 3) 总时长 / 命中延迟按逐帧求和 ===")
	_check("总时长", wd.get_shove_total_duration(), 0.35)
	## 默认 shove_hit_at_sequence_idx = 1 → 命中前只走完第 1 帧
	_check("命中延迟", wd.get_shove_hit_delay(), 0.1)

	print("=== 4) 自定义逐帧时长即时生效（内存副本，不动磁盘 tres） ===")
	var custom: WeaponData = (PISTOL as WeaponData).duplicate()
	custom.shove_frame_durations = [0.3, 0.02, 0.05]
	custom.shove_hit_at_sequence_idx = 2
	_check("自定义第 1 帧", custom.get_shove_frame_duration(0), 0.3)
	_check("自定义总时长", custom.get_shove_total_duration(), 0.37)
	_check("自定义命中延迟（前两帧之和）", custom.get_shove_hit_delay(), 0.32)

	print("=== 5) 远程命中音三级回退 ===")
	_check("无数据 + 无属性 → 通用默认", _path_of(ELEMENT_FX.resolve_hit(null, 0)), DEFAULT_HIT)
	_check("无数据 + 无属性 → 音调 1.5", ELEMENT_FX.resolve_hit_pitch(null, 0), 1.5)
	_check("无数据 + 火属性 → 炎2", _path_of(ELEMENT_FX.resolve_hit(null, WeaponData.Element.FIRE)), "res://sound/炎2.ogg")
	_check("无数据 + 火属性 → 音调 1.0", ELEMENT_FX.resolve_hit_pitch(null, WeaponData.Element.FIRE), 1.0)
	var explicit: AudioStream = load("res://sound/チャキッ.ogg") as AudioStream
	_check("数据优先（显式）", ELEMENT_FX.resolve_hit(explicit, 0) == explicit, true)
	_check("数据优先 → 音调 1.0", ELEMENT_FX.resolve_hit_pitch(explicit, 0), 1.0)

	print("=== 6) 逐帧接口接线（源码闸门） ===")
	var shove_state := _read("res://script/player/PlayerShoveState.gd")
	_check("状态机用 get_shove_frame_duration", shove_state.contains("_wd.get_shove_frame_duration("), true)
	_check("状态机已无统一时长旧写法", shove_state.contains("_timer = _wd.shove_frame_duration"), false)
	_check("命中音在命中分支播（不是起手就响）",
			shove_state.contains("if _wd.shove_hit_sound:"), true)
	var player_src := _read("res://script/player.gd")
	_check("联机表现用 get_shove_frame_duration",
			player_src.contains("wd.get_shove_frame_duration(index)"), true)
	var world_src := _read("res://script/network_world.gd")
	_check("Host 忙窗口用 get_shove_total_duration",
			world_src.contains("wd.get_shove_total_duration()"), true)
	_check("Host 命中延迟用 get_shove_hit_delay", world_src.contains("wd.get_shove_hit_delay()"), true)
	_check("客户端命中音走 ELEMENT_FX", world_src.contains("ELEMENT_FX.resolve_hit("), true)
	_check("联机推击命中音有广播 RPC",
			world_src.contains("func shove_hit_sfx_presentation("), true)

	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
