class_name PlayerInput extends Resource
## 玩家输入抽象层 —— 封装所有输入读取，支持本地和网络两种输入源。
##
## 使用方式：
##   1. player._input = LocalPlayerInput.new()
##   2. 在 _physics_process 开头调用 player._input.read()
##   3. 所有状态中用 player._input.xxx() 替代 Input.xxx()
##
## 网络场景：
##   本地玩家：LocalPlayerInput.read() → 序列化 → RPC 发给 Host
##   远程玩家：NetworkPlayerInput.apply_network_state(data) → 状态机读取

## 当前帧的移动向量（已归一化）
var move_vector: Vector2 = Vector2.ZERO

## 当前帧的按键状态（action_name → bool，true=按住中）
var actions: Dictionary = {}

## 上一帧的按键状态（用于 is_action_just_pressed 边缘检测）
var actions_prev: Dictionary = {}


## 帧切换：把当前帧状态移到上一帧，清空当前帧。
## 必须在每帧读取新输入之前调用。
func tick() -> void:
	actions_prev = actions.duplicate()
	actions.clear()
	move_vector = Vector2.ZERO


## 返回归一化后的移动方向向量
func get_move_vector() -> Vector2:
	return move_vector


## 当前帧是否按住指定按键（等效于 Input.is_action_pressed）
func is_action_pressed(action: String) -> bool:
	return actions.get(action, false)


## 当前帧是否刚按下指定按键（等效于 Input.is_action_just_pressed）
## 通过与上一帧比较实现边缘检测
func is_action_just_pressed(action: String) -> bool:
	return actions.get(action, false) and not actions_prev.get(action, false)


## 序列化当前输入状态（用于网络传输）
func serialize() -> Dictionary:
	var d: Dictionary = {"mx": move_vector.x, "my": move_vector.y}
	for key in actions:
		d[key] = actions[key]
	return d


## 从网络数据恢复输入状态（用于远程玩家）
func apply_network_state(data: Dictionary) -> void:
	tick()
	move_vector = Vector2(data.get("mx", 0.0), data.get("my", 0.0))
	for key in data:
		if key != "mx" and key != "my":
			actions[key] = data[key]
