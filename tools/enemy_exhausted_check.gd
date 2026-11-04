extends Node

## 狂暴力竭「倒地帧只闪一瞬」回归（2026-11-04）。
## 用法：godot --headless --path . res://tools/enemy_exhausted_check.tscn
##
## 病象（用户实测）：狂暴丧尸力竭倒下时，趴下的行走图只显示约 0.12 秒，
## 之后整段倒地时间都站着，1 秒结束才恢复行动。
##
## 根因：`EnemyExhaustedState.enter()` 画好倒地帧后，**行走动画 Timer 仍在跑** →
## `_on_animation_timer_timeout()` → `_refresh_sprite()` 按 `walk_char_index`(0)
## 重画站立帧，把倒地帧覆盖掉。本用例直接调那个回调来复现/守住这条。
##
## 三个断言：
##  1. 进入力竭后 AnimationTimer 必须已停；
##  2. 倒地帧落在狂暴图的第 7 格（该格空白则第 4 格 —— 本用例用有图的变体，应为 7）；
##  3. 再手动触发一次 timer 回调，region_rect 必须**原封不动**。

const ENEMY_SCENE := preload("res://object/enemy.tscn")
## 与 enemys/疾走体.tres 的 rage_texture 同一张（第 7 格有内容）。
const RAGE_TEX := preload("res://art/Characters/学生クリムゾンヘッド1.png")

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _ready() -> void:
	## 只测玩家节点的敌人表现：关掉导演自动刷怪，避免额外敌人干扰。
	var director: Node = get_node_or_null("/root/Director")
	if director != null:
		director.set("auto_spawn_enabled", false)
	await get_tree().process_frame

	var enemy: Node2D = ENEMY_SCENE.instantiate()
	add_child(enemy)
	await get_tree().process_frame

	enemy.variant_rage_texture = RAGE_TEX
	## 倒地时长拉长到 30 秒：用例跑完之前不允许自动起身。
	enemy.variant_rage_exhaust_down_seconds = 30.0
	enemy.set_rage(true)
	await get_tree().process_frame
	_check("已进入狂暴形态", bool(enemy.get("_rage")), true)

	enemy.call("_enter_exhausted")
	await get_tree().process_frame
	await get_tree().process_frame

	print("=== 1) 倒地期间行走计时器必须停 ===")
	_check("AnimationTimer.is_stopped()", enemy.animation_timer.is_stopped(), true)
	_check("_moving 已复位", bool(enemy.get("_moving")), false)

	print("=== 2) 倒地帧落在狂暴图第 7 格 ===")
	## walk_texture 是 NormalMaps.canvas() 包过的 CanvasTexture → 要拆出漫反射图取尺寸/路径。
	var canvas: Texture2D = enemy.sprite.texture
	var tex: Texture2D = canvas.diffuse_texture if canvas is CanvasTexture else canvas
	var fw: int = int(tex.get_width() / 12)   ## 12 列 = 4 个角色格 × 3 帧
	var fh: int = int(tex.get_height() / 8)   ## 8 行 = 4 方向 × 2 行
	var rect: Rect2 = enemy.sprite.region_rect
	_check("使用的贴图是狂暴图", tex.resource_path, RAGE_TEX.resource_path)
	_check("region 尺寸 = 单帧", rect.size, Vector2(fw, fh))
	## 第 7 格 = 第 1 行（7/4）第 3 列（7%4），站立帧 = 块内第 1 帧 → 整表列 3*3+1
	_check("整表列号（块3 + 站立帧1）", int(rect.position.x / fw), 10)
	_check("整表行号（块行1 × 4）", int(rect.position.y / fh), 4)

	print("=== 3) 静置 0.5 秒，倒地帧不能被行走动画覆盖 ===")
	## 行走帧时长约 0.12s → 旧实现（timer 未停）在这里必然已经被重画成站立帧。
	await get_tree().create_timer(0.5).timeout
	await get_tree().process_frame
	_check("0.5 秒后仍是倒地帧", enemy.sprite.region_rect, rect)

	print("=== 4) 起身后行走计时器恢复（否则走路变平移） ===")
	## `_down_timer` 在**状态节点**上，不在 enemy 上 —— 直接把它压到 0 触发起身分支。
	var exhausted_state: Node = enemy.get_node_or_null("StateMachine/Exhausted")
	_check("找到 Exhausted 状态节点", exhausted_state != null, true)
	if exhausted_state != null:
		exhausted_state.set("_down_timer", 0.0)
	await get_tree().create_timer(0.15).timeout
	await get_tree().process_frame
	_check("离开力竭后 AnimationTimer 已重启", enemy.animation_timer.is_stopped(), false)
	_check("_exhausted 已复位", bool(enemy.get("_exhausted")), false)
	_check("已退出狂暴形态", bool(enemy.get("_rage")), false)

	enemy.queue_free()
	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
