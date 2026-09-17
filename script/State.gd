class_name State extends Node

## ── 架构定位 ──
## 系统：状态机框架 ｜ 层：框架
## 联机：不涉及（纯逻辑基类）
## 职责：所有玩家/敌人状态的抽象基类，只声明 enter/exit/process_update/physics_update 生命周期与 transition_requested 信号。
## 依赖：PlayerState（经 Players 反查），不依赖任何具体实体

## 状态基类 — 所有玩家/敌人状态的父类
##
## 状态只描述一段可替换行为，不保存跨场景进度。玩家状态通过 get_player_state() 访问对应座位；
## 联机 Client 不应在这些状态里自行结算权威伤害或库存。
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
