class_name SafeDoor extends Area2D
## 安全门 — 放在地图上，玩家进入后回血+捕获内存 checkpoint
##
## 可放在安全屋入口或关卡末尾，作为存档检查点

# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
@export var heal_on_enter: bool = true             ## 进入时回满血
@export var save_on_enter: bool = true             ## 进入时捕获 checkpoint
@export var reset_pacing: bool = true              ## 进入时重置导演节奏（切到 Cooldown）
@export var one_shot: bool = true                  ## 只触发一次
@export var enter_message: String = "安全屋"        ## 进入提示文字

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _triggered: bool = false


func _ready() -> void:
	var cb: Callable = _on_body_entered
	body_entered.connect(cb)

	# 创建提示标签
	var label := Label.new()
	label.name = "HintLabel"
	label.text = enter_message
	label.add_theme_font_size_override("font_size", 14)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-40, -48)
	label.size = Vector2(80, 24)
	label.hide()
	add_child(label)


func _on_body_entered(body: Node2D) -> void:
	if _triggered and one_shot:
		return

	if not body is CharacterBody2D:
		return
	if not body.has_method("get_weapon_data"):
		return

	_triggered = true
	print("[SafeDoor] 玩家进入: %s" % body.name)

	# 先回血，再捕获 checkpoint（checkpoint 中保留满血状态）
	if heal_on_enter:
		var max_hp: float = body.get("max_hp") if body.get("max_hp") != null else 200.0
		body.set("current_hp", max_hp)
		Global.player_hp = max_hp
		print("[SafeDoor] 回血至: %.0f" % max_hp)

	if save_on_enter:
		Global.capture_checkpoint()

	if reset_pacing:
		var director: Node = get_node_or_null("/root/Director") if get_tree() else null
		if director:
			var pc: Node = director.get_node_or_null("PacingController")
			if pc and pc.has_method("force_cooldown"):
				pc.force_cooldown()
				print("[SafeDoor] 导演节奏已重置")

	# 进入提示
	var label: Label = get_node_or_null("HintLabel") as Label
	if label:
		label.show()
		var t: SceneTreeTimer = get_tree().create_timer(2.0)
		var hide_cb: Callable = func(): label.hide()
		t.timeout.connect(hide_cb)
