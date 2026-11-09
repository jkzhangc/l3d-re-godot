extends HBoxContainer

## 单条 buff/状态（HUD 右侧列表的一行）。
## 结构完全来自 `buff_entry.tscn`：Icon（图标接口，默认隐藏）+ Label（文字）。
## 只负责把一条数据渲染成文字/颜色，不持有任何状态。

## 正面状态文字色（偏青白）。
const BUFF_COLOR: Color = Color(0.82, 0.94, 1.0, 1.0)
## 负面状态文字色（偏红）。
const DEBUFF_COLOR: Color = Color(1.0, 0.55, 0.5, 1.0)

@onready var _icon: TextureRect = get_node_or_null("Icon") as TextureRect
@onready var _label: Label = get_node_or_null("Label") as Label


## 填一条。`remain` < 0 = 无倒计时（常驻/待触发）；`stacks` <= 1 时不显示层数。
## `icon` 非空时显示图标（图标接口，目前所有 buff 都传 null 走文字）。
func setup(label_text: String, remain: float, stacks: int, debuff: bool, icon: Texture2D) -> void:
	if _label == null:
		return
	var text: String = label_text
	if remain > 0.0:
		text += " %.1fs" % remain
	if stacks > 1:
		text += " ×%d" % stacks
	_label.text = text
	_label.add_theme_color_override("font_color", DEBUFF_COLOR if debuff else BUFF_COLOR)
	if _icon != null:
		if icon != null:
			_icon.texture = icon
			_icon.visible = true
		else:
			_icon.visible = false
