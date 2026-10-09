extends RefCounted

## ── 架构定位 ──
## 系统：触摸布局服务 ｜ 层：服务类（RefCounted，由 Global 持有）
## 联机：纯本机设置，与联机无关
## 职责：手机端「自由拖动按键/摇杆位置」与「隐藏元素」的存取、序列化与持久化触发。
## 依赖：宿主节点（Global，提供 save_config）
##
## 【为什么从 global.gd 抽出（2026-10-08）】触摸布局约 80 行、与字体/音频/checkpoint 无关，
## 且外部（menu_controller / title_screen / touch_controls）一律经 `Global.` 访问。
## 抽出后 Global 只保留同名转发门面 + 属性代理 → 外部调用点零改动。
##
## 【数据形态】layout 存「元素名 → Vector2(dx,dy)」，单位是**相对逻辑画布的偏移比例**
## （不是像素）—— 换设备分辨率 / 逻辑画布尺寸变化时像素值会整体跑偏，比例不会。
## 元素名 = 触摸层里的节点名（`Joystick` / `BtnAttack` / `BtnFunc` …）。
## 空字典 = 从未自定义过（用 tscn 里的默认位置）。

## 宿主节点（Global），用于回调 save_config。
var _host: Node = null

## 元素名 → 相对偏移比例（见文件头说明）。
var layout: Dictionary = {}
## 被玩家隐藏的元素名（隐藏只影响显示：动作映射还在，只是按钮不画出来、也不吃触摸）。
var hidden: Array = []


func _init(host: Node) -> void:
	_host = host


func _save() -> void:
	if _host != null and _host.has_method("save_config"):
		_host.call("save_config")


# ═══════════════════════════════════════
# 隐藏列表
# ═══════════════════════════════════════

## 该元素是否被玩家隐藏。
func hidden_is(elem_name: String) -> bool:
	return hidden.has(elem_name)


## 设置某元素的隐藏状态。`persist=false` 用于编辑过程中的临时切换（保存时才落盘）。
func set_hidden(elem_name: String, is_hidden: bool, persist: bool = true) -> void:
	if is_hidden == hidden.has(elem_name):
		return
	if is_hidden:
		hidden.append(elem_name)
	else:
		hidden.erase(elem_name)
	if persist:
		_save()


## 从 config 读隐藏列表。⚠ 缺字段时**保留原值**（与其它设置字段一致）。
func apply_hidden(raw: Variant) -> void:
	if not (raw is Array):
		return
	var out: Array = []
	for v: Variant in (raw as Array):
		out.append(String(v))
	hidden = out


# ═══════════════════════════════════════
# 布局偏移
# ═══════════════════════════════════════

## 取某元素的布局偏移（比例）。未自定义过 → (0, 0)。
func layout_offset(elem_name: String) -> Vector2:
	var raw: Variant = layout.get(elem_name, null)
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() == 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO


## 写入某元素的布局偏移（比例）。传 (0,0) 等价于清除该项（回到 tscn 默认位置）。
## `persist=false` 用于拖动过程中的高频写入（先攒着，松手/保存时再落盘）。
func set_layout_offset(elem_name: String, ratio: Vector2, persist: bool = true) -> void:
	if ratio.length() < 0.0001:
		layout.erase(elem_name)
	else:
		layout[elem_name] = ratio
	if persist:
		_save()


## 是否自定义过布局（设置页显示「默认 / 自定义」用）。隐藏按钮也算自定义。
func has_custom() -> bool:
	return not layout.is_empty() or not hidden.is_empty()


## 恢复默认布局（清空全部偏移 + 隐藏列表 + 落盘）。返回是否真的有改动。
func reset() -> bool:
	if layout.is_empty() and hidden.is_empty():
		return false
	layout.clear()
	hidden.clear()
	_save()
	return true


## 从 config 读布局。⚠ 缺字段 / 类型不对时**保留原值**（与其它设置字段一致的行为）。
func apply_layout(raw: Variant) -> void:
	if not (raw is Dictionary):
		return
	var out: Dictionary = {}
	for k: Variant in (raw as Dictionary).keys():
		var v: Variant = (raw as Dictionary)[k]
		if v is Array and (v as Array).size() == 2:
			out[String(k)] = Vector2(float((v as Array)[0]), float((v as Array)[1]))
	layout = out


## 序列化成 JSON 友好形式（Vector2 不能直接进 JSON）。
func layout_to_json() -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in layout.keys():
		var v: Vector2 = layout[k]
		out[String(k)] = [v.x, v.y]
	return out
