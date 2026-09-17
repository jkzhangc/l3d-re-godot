extends Node2D
## 选择界面窗口居中回归 —— headless 验证。
##
## 【为什么存在】战役/难度选择界面的窗口坐标是 640×400 时代的绝对位置，工程视口切到
## 1280×960 后窗口全部缩在左上角；角色选择的信息窗虽然看起来居中，但那是硬编码坐标的巧合，
## 一旦窗口尺寸变动就会偏心。本测试把「窗口在视口正中」钉成回归项。
##
## 【覆盖范围】MenuWindow（战役/难度，水平+垂直居中）、InfoWindow（角色，水平居中、
## 底边按设计贴底）。注意窗口是在 _ready() 里由脚本摆放的，所以必须实例化真实场景节点，
## 不能只读 .tscn 的 offset。
##
## 用法："$GD" --headless --path <项目> res://tools/ui_center_test.tscn

## 期望分辨率取工程设置（设计分辨率），与运行时窗口尺寸解耦
const DESIGN_W_NAME := "display/window/size/viewport_width"
const DESIGN_H_NAME := "display/window/size/viewport_height"

const TOL := 1.0
## 角色选择信息窗的设计底边距（贴底，不垂直居中）
const INFO_WINDOW_BOTTOM_GAP := 34.0

const CASES: Array[Dictionary] = [
	{
		"label": "战役选择 MenuWindow",
		"scene": "res://scene/campaign_select.tscn",
		"node": "MenuWindow",
		"size": Vector2(440, 280),
		"center_y": true,
	},
	{
		"label": "难度选择 MenuWindow",
		"scene": "res://scene/difficulty_select.tscn",
		"node": "MenuWindow",
		"size": Vector2(320, 280),
		"center_y": true,
	},
	{
		"label": "角色选择 InfoWindow",
		"scene": "res://scene/character_select.tscn",
		"node": "InfoWindow",
		"size": Vector2(1160, 210),
		"center_y": false,
	},
]

var _checks: int = 0
var _fails: int = 0


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("[PASS] %s" % label)
	else:
		_fails += 1
		print("[FAIL] %s" % label)


func _ready() -> void:
	var design := Vector2(
		float(ProjectSettings.get_setting(DESIGN_W_NAME)),
		float(ProjectSettings.get_setting(DESIGN_H_NAME))
	)
	print("[UI_CENTER] 设计分辨率 %s；运行时视口 %s" % [str(design), str(get_viewport().get_visible_rect().size)])
	_check(design.x > 0.0 and design.y > 0.0, "工程设置了有效设计分辨率")

	for case: Dictionary in CASES:
		await _check_case(case, design)

	print("=== UI_CENTER_TEST: %d/%d checks passed ===" % [_checks - _fails, _checks])
	get_tree().quit(0 if _fails == 0 else 1)


func _check_case(case: Dictionary, design: Vector2) -> void:
	var label: String = case["label"]
	var packed: PackedScene = load(case["scene"]) as PackedScene
	if packed == null:
		_check(false, "%s：场景加载失败 %s" % [label, case["scene"]])
		return
	var root: Control = packed.instantiate() as Control
	if root == null:
		_check(false, "%s：根节点不是 Control" % label)
		return

	# 节点必须在树内 _ready() 才会跑，窗口位置是那时由脚本摆的
	add_child(root)
	await get_tree().process_frame

	var win: Control = root.get_node_or_null(NodePath(case["node"])) as Control
	if win == null:
		_check(false, "%s：找不到窗口节点 %s" % [label, case["node"]])
		root.queue_free()
		return

	var expect_size: Vector2 = case["size"]
	_check(win.size.is_equal_approx(expect_size),
		"%s：尺寸 %s（应为 %s）" % [label, str(win.size), str(expect_size)])

	var pos: Vector2 = win.global_position
	var center := pos + win.size * 0.5
	_check(absf(center.x - design.x * 0.5) <= TOL,
		"%s：水平中心 %.1f（视口中心 %.1f）" % [label, center.x, design.x * 0.5])

	if bool(case["center_y"]):
		_check(absf(center.y - design.y * 0.5) <= TOL,
			"%s：垂直中心 %.1f（视口中心 %.1f）" % [label, center.y, design.y * 0.5])
	else:
		var bottom_gap: float = design.y - (pos.y + win.size.y)
		_check(absf(bottom_gap - INFO_WINDOW_BOTTOM_GAP) <= TOL,
			"%s：底边距 %.1f（设计 %.1f）" % [label, bottom_gap, INFO_WINDOW_BOTTOM_GAP])

	root.queue_free()
