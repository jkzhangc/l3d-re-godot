extends Node

## ── 架构定位 ──
## 系统：调试工具 ｜ 层：单例挂载（由 Global 在 _ready 里动态创建，不落场景文件）
## 联机：**仅 Host / 单机**触发；Client 按键只打印提示，不产生任何权威变更
## 职责：主机调试热键 —— Ctrl+R 把其他玩家瞬移到主机身边；Ctrl+H 全体满血 + 复活倒地/死亡玩家。
## 依赖：NetworkWorld（权威结算）、Players（单机兜底）、Net（会话状态）
##
## 【用法】游戏运行中（仅主机 / 单机）：
##   Ctrl+R → 其他玩家全部瞬移到我身边（绕我排开，自动避开物理层碰撞）
##   Ctrl+H → 全体玩家满血 + 复活倒地与真死亡的玩家
##
## 【为什么权威结算放在 NetworkWorld】玩家坐标与生死是 Host 权威数据，
## 调试键只是"触发口"。Client 侧不自己改 —— 位置与 HP 都由 Host 的常规快照回灌
## （玩家 60Hz），所以除了瞬移需要一次"硬吸附"外，不需要额外的表现广播。

const GATHER_KEY: int = KEY_R
const HEAL_KEY: int = KEY_H


func _ready() -> void:
	set_process(false)
	print("[DebugHotkey] 就绪 —— Ctrl+R 集结队友 / Ctrl+H 全体满血+复活（仅主机 / 单机）")


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo or not key.ctrl_pressed:
		return
	var code: int = key.physical_keycode
	if code == 0:
		code = key.keycode
	if code == GATHER_KEY:
		_gather()
	elif code == HEAL_KEY:
		_heal_all()


# ═══════════════════════════════════════
# 取环境
# ═══════════════════════════════════════

func _net() -> Node:
	return get_node_or_null("/root/Net")


func _world() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.get_node_or_null("NetworkWorld")


## 只在地图里生效：标题/菜单/结算页没有玩家实体，直接忽略，避免误触。
func _in_game() -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	for node: Node in tree.get_nodes_in_group("player"):
		if node is Node2D and (node as Node2D).is_inside_tree():
			return true
	return false


func _online() -> bool:
	var net: Node = _net()
	return net != null and bool(net.call("is_online_session"))


func _is_host() -> bool:
	var net: Node = _net()
	if net == null:
		return false
	return bool(net.get("is_host"))


## 非主机（联机客户端）一律不执行 —— 打印提示便于现场确认按键被收到了。
func _rejected_offline_host(tag: String) -> bool:
	if _online() and not _is_host():
		print("[DebugHotkey] %s 仅主机可用（客户端不改权威状态）" % tag)
		return true
	return false


# ═══════════════════════════════════════
# Ctrl+R：把其他玩家瞬移到主机身边
# ═══════════════════════════════════════

func _gather() -> void:
	if not _in_game() or _rejected_offline_host("Ctrl+R 集结"):
		return
	var world: Node = _world()
	if world == null:
		print("[DebugHotkey] Ctrl+R：单机模式没有其他玩家，忽略")
		return
	var moved: int = int(world.call("debug_gather_players_to_host"))
	if moved <= 0:
		print("[DebugHotkey] Ctrl+R：没有可瞬移的队友")


# ═══════════════════════════════════════
# Ctrl+H：全体满血 + 复活
# ═══════════════════════════════════════

func _heal_all() -> void:
	if not _in_game() or _rejected_offline_host("Ctrl+H 全体治疗"):
		return
	if _online():
		var world: Node = _world()
		if world != null:
			world.call("debug_heal_all_players")
			return
	_heal_all_solo()


## 单机：全队座位回满（与医疗箱单机口径一致）。
## 单机的"倒地/真死"走的是黑屏重载流程，这里**不介入**那条链（只把 HP 填满），
## 避免调试键与正式死亡流程互相打架。
func _heal_all_solo() -> void:
	var players: Node = get_node_or_null("/root/Players")
	if players == null:
		return
	for state: PlayerState in players.get("seats"):
		if state != null:
			state.current_hp = state.get_max_hp()
	var healed: int = 0
	for entity: Node2D in players.call("all_entities", false):
		if not is_instance_valid(entity):
			continue
		var state: PlayerState = players.call("get_state_for_entity", entity) as PlayerState
		if state != null and entity.get("_is_dying") != true:
			entity.set("current_hp", state.current_hp)
			healed += 1
	print("[DebugHotkey] Ctrl+H 单机：%d 名角色回满 HP" % healed)
