class_name StateMachine extends Node
## 通用状态机 — 管理 State 子节点，路由生命周期和帧更新
##
## 用法：
##   1. 将 StateMachine 添加为 CharacterBody2D 的子节点
##   2. 将 State 子节点添加到 StateMachine 下
##   3. 设置 initial_state 指向初始状态

@export var initial_state: State

var states: Dictionary = {}         ## name → State
var current_state: State = null
var last_state: State = null
var character: CharacterBody2D


func _ready() -> void:
	character = get_parent() as CharacterBody2D

	for child: Node in get_children():
		if child is State:
			states[child.name] = child
			child.transition_requested.connect(_on_transition_requested)
			child.character = character

	if initial_state:
		initial_state.enter()
		current_state = initial_state


func _process(delta: float) -> void:
	if current_state and current_state.has_method("process_update"):
		# 联机模式：仅 authority peer 运行状态机
		if character and is_instance_valid(character):
			if character.get_multiplayer_authority() != multiplayer.get_unique_id():
				return
		current_state.process_update(delta)


func _physics_process(delta: float) -> void:
	if current_state and current_state.has_method("physics_update"):
		# 联机模式：仅 authority peer 运行状态机
		if character and is_instance_valid(character):
			if character.get_multiplayer_authority() != multiplayer.get_unique_id():
				return
		current_state.physics_update(delta)


const STATE_ENUM_MAP: Dictionary = {
	"Idle": 0, "Walk": 1, "Run": 2,
	"Pistol": 3, "Knife": 3, "Shotgun": 3, "Rifle": 3,
	"PistolAttack": 4, "KnifeAttack": 4, "ShotgunAttack": 4, "RifleAttack": 4,
	"Reload": 5,
}

func _on_transition_requested(nxt_state: String) -> void:
	if not states.has(nxt_state):
		return

	# 允许同名状态重入（武器切换时需重新 enter 读取新武器数据）
	if current_state:
		current_state.exit()
		last_state = current_state

	current_state = states[nxt_state]
	if current_state:
		current_state.last_state = last_state
		# 更新 state_enum（供联机 puppet 推断动画）
		if STATE_ENUM_MAP.has(nxt_state):
			character.state_enum = STATE_ENUM_MAP[nxt_state]
		current_state.enter()
