extends Node2D
## 选择界面文字样式回归 —— headless 验证。
##
## 【为什么存在】三张选择界面的文字都走 GradientLabel（像素字体+固定色+阴影），
## 历史上出现过两类「样式静默失效」：
##  ① 纯 Label 节点（描述 / 提示文字）没有字体覆盖，落到 Godot 默认字体与纯白，
##     和周围的像素字完全割裂；
##  ② .tscn 里给 GradientLabel 显式写的 bold / color_index 被 Global 默认值覆盖
##     （场景属性先写入、_enter_tree() 后才读 Global，无脑覆盖就抹掉了场景意图）；
##  ③ 渐变渲染在途被取消后不重排，标签永久停在占位状态（平色 + 旧文本）。
##
## 本测试在 headless 下钉住 ①② 的结构性后果：直接断言每个文字节点都有字体覆盖。
## ③ 必须真实渲染器才能复现，见 tools/ui_text_probe.tscn（需窗口运行）。
##
## 用法："$GD" --headless --path <项目> res://tools/ui_text_style_test.tscn

const CASES: Array[Dictionary] = [
	{
		"label": "战役选择",
		"scene": "res://scene/campaign_select.tscn",
		## 多行描述文字：用不了 GradientLabel，但必须补上字体与固定色
		"styled": ["MenuWindow/DescPanel/DescLabel"],
		## .tscn 里显式写了 bold = true / color_index = 1，必须不被 Global 覆盖
		"explicit": ["MenuWindow/TitleLabel", "MenuWindow/HintLabel"],
	},
	{
		"label": "难度选择",
		"scene": "res://scene/difficulty_select.tscn",
		"styled": ["MenuWindow/DescPanel/DescLabel"],
		"explicit": ["MenuWindow/TitleLabel", "MenuWindow/Item0"],
	},
	{
		"label": "角色选择",
		"scene": "res://scene/character_select.tscn",
		"styled": [],
		"explicit": [],
	},
]

var _checks: int = 0
var _fails: int = 0
var _root: Node = null


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("[PASS] %s" % label)
	else:
		_fails += 1
		print("[FAIL] %s" % label)


func _ready() -> void:
	for case: Dictionary in CASES:
		await _check_case(case)
	print("=== UI_TEXT_STYLE_TEST: %d/%d checks passed ===" % [_checks - _fails, _checks])
	get_tree().quit(0 if _fails == 0 else 1)


func _check_case(case: Dictionary) -> void:
	var label: String = case["label"]
	var packed: PackedScene = load(case["scene"]) as PackedScene
	if packed == null:
		_check(false, "%s：场景加载失败 %s" % [label, case["scene"]])
		return
	var root: Control = packed.instantiate() as Control
	if root == null:
		_check(false, "%s：根节点不是 Control" % label)
		return
	add_child(root)
	_root = root
	await get_tree().process_frame

	# ① 任何 Label 都不该留在「默认字体」状态
	var bare: Array[String] = []
	_collect_bare_labels(root, bare)
	_check(bare.is_empty(),
		"%s：所有 Label 都套了像素字体%s" % [label, "" if bare.is_empty() else "（漏掉：%s）" % ", ".join(bare)])

	# GradientLabel 必须真的套上像素字体（字体覆盖在 LabelMain 上）
	var no_font: Array[String] = []
	_collect_unstyled_gradients(root, no_font)
	_check(no_font.is_empty(),
		"%s：所有文字标签都套了像素字体%s" % [label, "" if no_font.is_empty() else "（漏掉：%s）" % ", ".join(no_font)])

	# 多行描述文字：字体覆盖要有
	for path: String in case["styled"]:
		var node: Label = root.get_node_or_null(NodePath(path)) as Label
		if node == null:
			_check(false, "%s：找不到 %s" % [label, path])
			continue
		_check(node.has_theme_font_override("font"),
			"%s：%s 已套像素字体" % [label, path])

	# ② 场景里显式写的样式必须存活
	for path: String in case["explicit"]:
		var node: GradientLabel = root.get_node_or_null(NodePath(path)) as GradientLabel
		if node == null:
			_check(false, "%s：找不到 %s" % [label, path])
			continue
		_check(node.color_index == 1 and node.shadow,
			"%s：%s 保留了场景显式样式（色=%d 阴影=%s）" % [label, path, node.color_index, str(node.shadow)])

	root.queue_free()
	_root = null
	await get_tree().process_frame


## 收集「没有字体覆盖」的 Label（GradientLabel 的内部 Label 另算）
func _collect_bare_labels(node: Node, out: Array[String]) -> void:
	if node is GradientLabel:
		return  ## 内部实现由 _collect_unstyled_gradients 负责
	if node is Label and node.material == null and not node.has_theme_font_override("font"):
		out.append(str(_root.get_path_to(node)))
	for c in node.get_children():
		_collect_bare_labels(c, out)


## 收集没套字体的 GradientLabel
func _collect_unstyled_gradients(node: Node, out: Array[String]) -> void:
	if node is GradientLabel:
		var main: Control = node.get_node_or_null("LabelMain")
		if main == null or not main.has_theme_font_override("font"):
			out.append(str(_root.get_path_to(node)))
	for c in node.get_children():
		_collect_unstyled_gradients(c, out)
