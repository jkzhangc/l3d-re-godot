extends Button

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（Control）
## 联机：不涉及 —— 只把触摸转成既有 InputMap 动作，动作本身的权威判定完全不变
## 职责：**一个触摸按钮 = 一个 InputMap 动作的按下/松开来源**。
## 依赖：无（纯 Input 转发）

## 该按钮映射到的 InputMap 动作名（在编辑器里逐个节点设置）。
## 可用值见 project.godot 的 [input] 段：确定键 / 装填键 / SA键 / 推击键 / 功能键 /
## 治疗品键 / 辅助品键 / 投掷物键 / 主武器键 / 副武器键 / 菜单键 / 取消键 /
## 丢弃武器键 / 切换角色键 / 举起放下武器键 / 行走键 …
@export var action: StringName = &"确定键"

## 松手时是否立即松开该动作。持枪/行走类需要"按住持续"，保持 true 即可；
## 单次触发的动作（如丢弃武器）也无需改 —— 松开本来就该结束。
@export var release_on_up: bool = true

var _held: bool = false


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	button_down.connect(_on_down)
	button_up.connect(_on_up)
	## 手指滑出按钮范围时 Button 不一定发 button_up → 用 mouse_exited 兜底，
	## 否则会出现"动作一直按着"（角色一直走 / 一直开枪）。
	mouse_exited.connect(_on_up)


func _on_down() -> void:
	if action == &"" or _held:
		return
	_held = true
	Input.action_press(action)


func _on_up() -> void:
	if action == &"" or not _held:
		return
	_held = false
	if release_on_up:
		Input.action_release(action)


## 节点被移除 / 换场景时兜底松开 —— 否则动作会一直保持按下状态。
func _exit_tree() -> void:
	if _held:
		_held = false
		if action != &"":
			Input.action_release(action)
