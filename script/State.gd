class_name State extends Node
## 状态基类 — 所有玩家/敌人状态的父类
##
## 子类覆写:
##   enter()           — 进入状态时调用一次
##   exit()            — 离开状态时调用一次
##   process_update()  — 每帧调用（输入检测、状态转换判断放这里）
##   physics_update()  — 物理帧调用（移动、碰撞放这里）

var character  ## CharacterBody2D (宽松类型以支持 _player_input)
var last_state: State

signal transition_requested(nxt_state: String)


func enter() -> void:
	pass


func exit() -> void:
	pass


func process_update(_delta: float) -> void:
	pass


func physics_update(_delta: float) -> void:
	pass
