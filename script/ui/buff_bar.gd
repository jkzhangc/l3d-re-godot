extends VBoxContainer

## 玩家 buff / 状态列表（HUD 血条右侧）。
##
## 【为什么做成场景节点】榜单外观（字号、描边、间距、图标位）全部写在
## `buff_bar.tscn` / `buff_entry.tscn` 里，本脚本**只负责复制模板与填字** ——
## 不在代码里 new Label / set_offset，改样式不用改代码（2026-11-09 用户口径）。
##
## 用法：`refresh(player.get_active_buffs())`，每帧或变化时调用都行；
## 行数不增不减时只更新文字，不重建节点。

## 行模板（场景里放一个隐藏的 BuffEntry 实例）。
@onready var _template: Control = get_node_or_null("Template") as Control

var _rows: Array[Control] = []


func refresh(entries: Array) -> void:
	if _template == null:
		return
	_ensure_rows(entries.size())
	for i: int in range(_rows.size()):
		var row: Control = _rows[i]
		if i >= entries.size():
			row.visible = false
			continue
		row.visible = true
		var e: Dictionary = entries[i]
		if row.has_method("setup"):
			row.call("setup",
				String(e.get("label", "")),
				float(e.get("remain", -1.0)),
				int(e.get("stacks", 1)),
				bool(e.get("debuff", false)),
				e.get("icon", null))


## 复制模板补足行数（模板必须 visible=false，否则空列表也多占一行）。
func _ensure_rows(count: int) -> void:
	while _rows.size() < count:
		var row := _template.duplicate() as Control
		if row == null:
			return
		row.name = "Buff%d" % _rows.size()
		row.visible = true
		add_child(row)
		_rows.append(row)
