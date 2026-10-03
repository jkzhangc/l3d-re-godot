class_name StateMachine extends Node

## ── 架构定位 ──
## 系统：状态机框架 ｜ 层：框架
## 联机：不涉及（纯逻辑驱动）
## 职责：按 State 子节点名路由状态切换，保证 exit→enter 顺序并允许同名重入（换武器时重读资源）。
## 依赖：State 子节点；宿主为 CharacterBody2D

## 通用状态机 — 管理 State 子节点，路由生命周期和帧更新
##
## 用法：
##   1. 将 StateMachine 添加为 CharacterBody2D 的子节点
##   2. 将 State 子节点添加到 StateMachine 下
##   3. 设置 initial_state 指向初始状态
##
## 状态机本身不解释输入和规则，只保证生命周期顺序：exit(旧) → 记录 last_state → enter(新)。
## 同名重入被有意允许，以便切换武器后重新读取当前装备资源参数。
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
	if not states.has(nxt_state):
		return

	# 允许同名状态重入（武器切换时需重新 enter 读取新武器数据）
	if current_state:
		current_state.exit()
		last_state = current_state

	current_state = states[nxt_state]
	if current_state:
		current_state.last_state = last_state
		current_state.enter()


## 由**外部**（非 State 子节点）请求切换状态，与 State 内部 `transition_requested` 走同一条路径。
## 【为什么需要它】2026-10-03 推击改为「可打断任何武器状态」后，输入拦截收敛到 Player 层统一处理
## （它不属于任何一个 State，不能 emit State 的信号）—— 没有这个入口就只能去 call 私有方法
## `_on_transition_requested`，语义不清且容易被后续重构破坏。
## ⚠ 未知状态名会被忽略（与内部路径一致），调用方无需自行判断。
func request_state(state_name: String) -> void:
	_on_transition_requested(state_name)


## 当前状态名（供外部做「已在某状态就不重复请求」这类幂等判断）。
func current_state_name() -> String:
	return current_state.name if current_state != null else ""
