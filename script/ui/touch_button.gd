extends Button

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（Control）
## 联机：不涉及 —— 只把触摸转成既有 InputMap 动作，动作本身的权威判定完全不变
## 职责：**一个触摸按钮 = 一个 InputMap 动作的按下/松开来源**。
## 依赖：`Global.dispatch_virtual_action()`（改动作状态 + 补发 InputEventAction，唯一入口）

## 该按钮映射到的 InputMap 动作名（在编辑器里逐个节点设置）。
## 可用值见 project.godot 的 [input] 段：确定键 / 装填键 / SA键 / 推击键 / 功能键 /
## 治疗品键 / 辅助品键 / 投掷物键 / 主武器键 / 副武器键 / 菜单键 / 取消键 /
## 丢弃武器键 / 切换角色键 / 举起放下武器键 / 行走键 …
@export var action: StringName = &"确定键"

## 松手时是否立即松开该动作。持枪/行走类需要"按住持续"，保持 true 即可；
## 单次触发的动作（如丢弃武器）也无需改 —— 松开本来就该结束。
@export var release_on_up: bool = true

## ── 可见性规则（2026-09-29）──
## 前端菜单（标题 / 角色选择 / 难度 / 章节选择 / 结算页）是 RM2K3 光标式，只认
## `确定键` / `上` / `下` / `取消键`。菜单里显示整套战斗按钮会盖住菜单 →
## 只让「确定 / 取消」留下。由 TouchControls 按当前场景自动调用 set_menu_mode()。
##
## 三种常用组合：
##   ① 两模式都要（攻击=确定、取消、摇杆）→ `show_in_menu = true`
##   ② **只在菜单里**（如「开始游戏」）      → `show_in_menu = true` + `hide_in_gameplay = true`
##   ③ 只在关卡里（装填 / 物品 / 切人…）    → 两个都用默认 false
@export var show_in_menu: bool = false
## 关卡模式下隐藏（配合 `show_in_menu` 得到「只在菜单里出现」的按钮）。
@export var hide_in_gameplay: bool = false
## 菜单模式下替换的文字（留空 = 不改）。例：攻击键（=确定键）在菜单里显示「确定」。
@export var menu_text: String = ""
## 菜单模式下**只在这些场景**显示（按场景脚本文件名匹配，**不含**扩展名）。
## 留空 = 所有菜单场景都显示。例：「开始游戏」只在角色选择界面有意义 →
## `["character_select_menu"]`（全项目只有它读 `开始游戏键`，其余菜单显示它纯属干扰）。
@export var menu_scene_filter: PackedStringArray = PackedStringArray()

var _held: bool = false
var _base_text: String = ""
var _global: Node = null


func _ready() -> void:
	_base_text = text
	focus_mode = Control.FOCUS_NONE
	_global = get_node_or_null("/root/Global")
	button_down.connect(_on_down)
	button_up.connect(_on_up)
	## 手指滑出按钮范围时 Button 不一定发 button_up → 用 mouse_exited 兜底，
	## 否则会出现"动作一直按着"（角色一直走 / 一直开枪）。
	mouse_exited.connect(_on_up)


## ★一律走 Global.dispatch_virtual_action()（2026-09-29 手机实测）：
## `Input.action_press()` **只改状态、不派发事件** → 只认 `_input` 的菜单收不到 → 按了没反应。
func _forward(act: StringName, pressed: bool) -> void:
	if _global != null and _global.has_method("dispatch_virtual_action"):
		_global.call("dispatch_virtual_action", act, pressed)
	else:
		push_warning("[TouchButton] 找不到 /root/Global，虚拟按键未派发（act=%s）" % act)


## 由 TouchControls 调用：按模式（+ 当前菜单场景）决定显隐，并可选替换文字。
## `scene_key` = 当前场景脚本的文件名（不含扩展名），供 `menu_scene_filter` 过滤。
func set_menu_mode(menu_mode: bool, scene_key: String = "") -> void:
	if menu_mode:
		visible = show_in_menu and (menu_scene_filter.is_empty() or menu_scene_filter.has(scene_key))
	else:
		visible = not hide_in_gameplay
	if not visible:
		## ★隐藏时必须先松开：按钮被隐藏后收不到 button_up → 动作会永远保持按下
		##（角色一直走 / 一直开枪）。切场景那一帧正好会走到这里。
		_on_up()
	text = menu_text if (menu_mode and not menu_text.is_empty()) else _base_text


func _on_down() -> void:
	if action == &"" or _held:
		return
	_held = true
	_forward(action, true)


func _on_up() -> void:
	if action == &"" or not _held:
		return
	_held = false
	if release_on_up:
		_forward(action, false)


## 节点被移除 / 换场景时兜底松开 —— 否则动作会一直保持按下状态。
func _exit_tree() -> void:
	if _held:
		_held = false
		if action != &"":
			_forward(action, false)
