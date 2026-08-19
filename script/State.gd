class_name State extends Node
## 状态基类 — 所有玩家/敌人状态的父类
##
## 子类覆写:
##   enter()           — 进入状态时调用一次
##   exit()            — 离开状态时调用一次
##   process_update()  — 每帧调用（输入检测、状态转换判断放这里）
##   physics_update()  — 物理帧调用（移动、碰撞放这里）

var character: CharacterBody2D
var last_state: State


## 玩家状态机的 per-player 数据入口。敌人状态不会调用本方法。
## 通过实体反查座位，避免未来联机时误读本地 active state。
func get_player_state() -> PlayerState:
	return Players.get_state_for_entity(character)

signal transition_requested(nxt_state: String)


func enter() -> void:
	pass


func exit() -> void:
	pass


func process_update(_delta: float) -> void:
	pass


func physics_update(_delta: float) -> void:
	pass
