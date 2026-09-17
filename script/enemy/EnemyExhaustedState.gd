class_name EnemyExhaustedState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 决定时长；Client 经快照 visual_char_index 同步趴下帧（死亡帧索引），
##       无需专用网络字段。
## 职责：力竭倒地（クリムゾンヘッド 专属）：狂暴态累计奔跑约 10 秒后累趴，
##       倒地期间不能行动（受击只掉血+闪色，不被击退/硬直打断 —— 见 enemy.take_damage
##       的 blocked_states），时长走完后变回普通形态并回 Chase。
## 依赖：State、enemy 实体（variant_rage_exhaust_down_seconds / death_char_index / set_rage）
##
## 原作依据（E:/15.L3D readme/enemy.html クリムゾンヘッド条）：
##   「中身はエキストラ（一般人）であるためこの状態で１０秒ほど走り回されると
##     倒れてしまうこともあるとかないとか。」
## 设计定稿（2026-09-12）：倒下改为确定机制（总纲：逼玩家占位、边打边走），
##   起身时变回普通形态 —— 「累垮的是普通人」的语义自洽，也给玩家喘息窗口；
##   下次尸潮再次狂暴时重新计时。

var _down_timer: float = 0.0
var _linger_timer: float = 0.0
## 趴姿保持期（2026-09-17 用户改版）：倒地时长走完后**保持趴姿原地不动**一小段
## （中间无任何动画），然后直接切回普通图恢复行动。
const LINGER_SECONDS: float = 1.2


func enter() -> void:
	var enemy: Node2D = character
	enemy.velocity = Vector2.ZERO
	enemy.update_moving(false)
	_down_timer = maxf(0.5, enemy.variant_rage_exhaust_down_seconds)
	_linger_timer = 0.0
	# 趴下表现：复用普通死亡帧（本项目所有角色图同布局，帧索引一致）。
	# _current_char_index 会随快照的 visual_char_index 同步到 Client，零网络改动。
	enemy._refresh_sprite_with_index(enemy.death_char_index)


func exit() -> void:
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		return
	_down_timer -= delta
	## 下次尸潮 set_rage(true) 重新狂暴 → 立刻起身扑人（此帧 Chase 会切狂暴图与追击）
	if character._rage:
		transition_requested.emit("Chase")
		return
	if _down_timer > 0.0:
		return
	## 趴姿保持期：原地不动、无任何动画，趴够 LINGER_SECONDS 再直接切回普通图
	## （2026-09-17 用户改版：趴一会→咔切普通图，中间无过渡动画）。
	_linger_timer += delta
	if _linger_timer < LINGER_SECONDS:
		return
	var enemy: Node2D = character
	enemy._exhausted = false
	enemy.set_rage(false)  ## 切回普通图
	## 直接落普通站立帧（不残留趴姿索引、不播过渡动画），Chase 接步行动画
	enemy._refresh_sprite_with_index(0)
	transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	# 力竭期间完全不移动
	pass
