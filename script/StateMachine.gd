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
	if current_state:
		current_state.process_update(delta)


func _physics_process(delta: float) -> void:
	if current_state:
		current_state.physics_update(delta)


func _on_transition_requested(nxt_state: String) -> void:
	if not states.has(nxt_state) or (current_state and current_state.name == nxt_state):
		return

	if current_state:
		current_state.exit()
		last_state = current_state

	current_state = states[nxt_state]
	if current_state:
		current_state.last_state = last_state
		current_state.enter()
