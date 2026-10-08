extends State

## ── 架构定位 ──
## 系统：玩家状态机 ｜ 层：玩法（State 基类）
## 联机：Client 不走这些状态；Host 由 NetworkWorld 注入已验证输入，单机由本基类读本地键盘。
## 职责：地面移动三态（Idle / Walk / Run）的**共享输入入口**：武器举起/放下、主副武器、
##       治疗品、辅助品、投掷物的边沿消费，以及它们各自的转场助手。
## 依赖：State、Player 实体、PlayerState、PlayerInput
##
## 【为什么抽它（2026-10-08，P4 债务）】Idle / Walk / Run 三个 state 原本**逐字复制**同一段
## 「武器与消耗品输入轮询」和三个转场助手（_try_weapon_state / _try_raise_weapon /
## _try_throwable）。加一个热键要改三份、拼错只在运行时暴露。现收敛到本基类：
## 子类只在 process_update 里调用 `_consume_common_inputs()`，输入语义与优先级保持原样。
##
## 【保持的行为语义】原三态里这段逻辑的顺序即优先级：
##   主武器 → 副武器 → 治疗品 → 辅助品 → 投掷物 → 举起/放下武器；
## 任一被消费即 `return true`（子类随即返回，不再处理移动）。
##
## 【⚠ 仅"输入读取"共用，移动/外观分支仍留在各子类】——Idle 站立、Walk 慢走、Run 快走
##   的差异只在移动速度与外观，不属本基类职责。

const PlayerInput := preload("res://script/player_input.gd")


## 消费地面状态共有的武器/消耗品/投掷输入。
## 返回 true 表示已请求状态切换（调用方应立即 return，不再处理移动输入）。
func _consume_common_inputs() -> bool:
	# 直接举起武器
	if PlayerInput.pressed_item_key(PlayerInput.ACTION_PRIMARY_WEAPON):
		_try_raise_weapon("primary")
		return true
	if PlayerInput.pressed_item_key(PlayerInput.ACTION_SECONDARY_WEAPON):
		_try_raise_weapon("secondary")
		return true

	# 使用消耗品
	if PlayerInput.pressed_item_key(PlayerInput.ACTION_HEALING_ITEM):
		character.use_healing_item()
		return true
	if PlayerInput.pressed_item_key(PlayerInput.ACTION_SUPPORT_ITEM):
		character.use_support_item()
		return true

	# 投掷物
	if PlayerInput.pressed_item_key(PlayerInput.ACTION_THROWABLE):
		_try_throwable()
		return true

	if PlayerInput.pressed_raise_weapon():
		_try_weapon_state()
		return true

	return false


## 举起当前激活武器对应的状态（空手/无武器状态名则忽略）。
func _try_weapon_state() -> void:
	var wd: WeaponData = get_player_state().get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		transition_requested.emit(wd.weapon_state_name)


## 直接举起指定槽位的武器（槽位无武器/无状态名则忽略）。
func _try_raise_weapon(slot: String) -> void:
	var wd: WeaponData = get_player_state().get_equipped_weapon(slot)
	if not wd or wd.weapon_state_name.is_empty():
		return
	get_player_state().active_weapon_slot = slot
	transition_requested.emit(wd.weapon_state_name)


## 进入投掷物状态（未持有投掷物则忽略）。
func _try_throwable() -> void:
	if get_player_state().throwable:
		transition_requested.emit("Throwable")
