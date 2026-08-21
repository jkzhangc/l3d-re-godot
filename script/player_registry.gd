extends Node
## 玩家座位与实体注册表（autoload 名：Players）
##
## 两层概念：
##   · 座位（seat）—— 数据层，一份 PlayerState。单人模式下每个队伍成员一个座位；
##                     联机模式下每个 peer 一个座位（座位表语义，见 owner_peer_id）。
##   · 实体（entity）—— 节点层，场景里的 Player 节点。
##                     单人模式全场只有 1 个实体，绑定在 active_seat_index 那个座位上；
##                     联机模式下每个座位各有 1 个实体。
##
## 存在意义：替代散落在 7 个文件里的 _find_player()（各自遍历 group 或递归场景树取
## 第一个 CharacterBody2D），并把「当前玩家状态」从 Global 的顶层单值里解放出来。

const DEFAULT_CHARACTER_PATH: String = "res://object/character_nobita.tres"

# ═══════════════════════════════════════
# 座位（数据层）
# ═══════════════════════════════════════
var seats: Array[PlayerState] = []
## 单人：当前操控的座位；联机：本地玩家的座位
var active_seat_index: int = 0
## 座位表是否由「角色选择菜单 / 磁盘存档 / checkpoint」正式填充过。
## 懒创建的默认座位不算。Global.try_load_or_init() 用它判断是否要初始化新游戏 ——
## 不能用 seat_count()==0，因为其他游戏流程调用 get_active_state() 时也可能触发懒创建。
var seats_authored: bool = false

# ═══════════════════════════════════════
# 实体（节点层）
# ═══════════════════════════════════════
var _entities: Array[Node2D] = []          ## 所有已注册的玩家实体节点
var _local_entity: Node2D = null           ## 本客户端操控的实体（单人 = 唯一那个）
var _seat_of_entity: Dictionary = {}       ## 实体 instance_id → seat_index


func _ready() -> void:
	# 显式初始化容器（防 Godot 4 类级默认值跨实例共享，沿用项目既有约定）
	seats = []
	_entities = []
	_seat_of_entity = {}


# ═══════════════════════════════════════
# 座位查询
# ═══════════════════════════════════════

func seat_count() -> int:
	return seats.size()


func get_seat(i: int) -> PlayerState:
	if i < 0 or i >= seats.size():
		return null
	return seats[i]


## 取当前激活座位的状态。**保证非 null** —— 座位表为空时懒创建座位 0。
## 单角色回退模式（未走角色选择菜单直接进图）依赖这个兜底。
func get_active_state() -> PlayerState:
	if seats.is_empty():
		_create_default_seat()
	if active_seat_index < 0 or active_seat_index >= seats.size():
		active_seat_index = 0
	return seats[active_seat_index]


func living_seat_count() -> int:
	var n: int = 0
	for s: PlayerState in seats:
		if s and s.is_alive():
			n += 1
	return n


## 从 from 座位往后找下一个存活座位（不含 from 自己）。找不到返回 -1。
## 替代 character_switch_manager.gd 的 _find_next_living_member()。
func next_living_seat(from: int) -> int:
	var size: int = seats.size()
	if size <= 1:
		return -1
	for offset: int in range(1, size):
		var idx: int = (from + offset) % size
		var s: PlayerState = seats[idx]
		if s and s.is_alive():
			return idx
	return -1


# ═══════════════════════════════════════
# 座位维护
# ═══════════════════════════════════════

func clear_seats() -> void:
	seats.clear()
	active_seat_index = 0
	seats_authored = false
	clear_entity_bindings()


## 场景切换时只清除已释放的玩家节点绑定；保留座位和跨图 PlayerState。
func clear_entity_bindings() -> void:
	_entities.clear()
	_seat_of_entity.clear()
	_local_entity = null


## 追加一个座位，返回其索引。会同步写入 state.seat_index。
func add_seat(state: PlayerState) -> int:
	if not state:
		return -1
	var idx: int = seats.size()
	state.seat_index = idx
	seats.append(state)
	return idx


## 切换激活座位。单人模式下本地实体随之换绑到新座位。
func set_active_seat(i: int) -> void:
	if i < 0 or i >= seats.size():
		return
	active_seat_index = i
	# 单人模式：全场只有一个实体节点，它现在代表新座位
	if _local_entity and is_instance_valid(_local_entity):
		_seat_of_entity[_local_entity.get_instance_id()] = i


func _create_default_seat() -> void:
	var cd: CharacterData = null
	if ResourceLoader.exists(DEFAULT_CHARACTER_PATH):
		var res: Resource = load(DEFAULT_CHARACTER_PATH)
		if res is CharacterData:
			# duplicate() 保证座位独占实例，不污染资源缓存里的 .tres 母本
			cd = (res as CharacterData).duplicate() as CharacterData
	var st: PlayerState = PlayerState.new()
	st.init_from_character(cd, DEFAULT_CHARACTER_PATH)
	add_seat(st)
	active_seat_index = 0
	print("[Players] 座位表为空，已懒创建默认座位 0: %s" % st.describe())


# ═══════════════════════════════════════
# 实体注册
# ═══════════════════════════════════════

## 由 player.gd 的 _ready() 调用。seat_index 传 -1 表示绑定到当前激活座位。
func register_entity(node: Node2D, seat_index: int = -1) -> void:
	if not node or not is_instance_valid(node):
		return
	if seat_index < 0:
		seat_index = active_seat_index
	if not _entities.has(node):
		_entities.append(node)
	_seat_of_entity[node.get_instance_id()] = seat_index
	if not _local_entity or not is_instance_valid(_local_entity):
		_local_entity = node
	print("[Players] 实体注册: %s → 座位 %d" % [node.name, seat_index])


## 明确指定当前客户端的本地实体（联机由 NetworkWorld 在快照落地后调用）。
func set_local_entity(node: Node2D) -> void:
	_local_entity = node if node and is_instance_valid(node) else null


func unregister_entity(node: Node2D) -> void:
	if not node:
		return
	_entities.erase(node)
	_seat_of_entity.erase(node.get_instance_id())
	if _local_entity == node:
		_local_entity = null


# ═══════════════════════════════════════
# 实体查询
# ═══════════════════════════════════════

## 本客户端操控的玩家实体。替代全部 _find_player()。
## 未注册时回退到 group("player") 扫描（兼容 _ready() 时序竞争）。
func get_local_entity() -> Node2D:
	if _local_entity and is_instance_valid(_local_entity):
		return _local_entity
	_local_entity = null
	var found: Node2D = _scan_group_for_player()
	if found:
		register_entity(found)
	return found


func get_entity_for_seat(i: int) -> Node2D:
	_prune_invalid()
	for node: Node2D in _entities:
		if _seat_of_entity.get(node.get_instance_id(), -1) == i:
			return node
	return null


## 取得场景实体对应的座位状态。不要把「本地/激活座位」当作调用方实体的状态：
## 单人角色切换时实体会跟随 active_seat 重新绑定；未来联机时每个实体各自映射一个座位。
func get_state_for_entity(node: Node2D) -> PlayerState:
	if not node or not is_instance_valid(node):
		return null
	_prune_invalid()
	var seat_index: int = _seat_of_entity.get(node.get_instance_id(), -1)
	if seat_index < 0:
		# 兼容 _ready() / group 扫描的时序：首次查询时注册到当前激活座位。
		register_entity(node)
		seat_index = _seat_of_entity.get(node.get_instance_id(), active_seat_index)
	if seats.is_empty():
		_create_default_seat()
	return get_seat(seat_index)


## 全部在场玩家实体。exclude_dying=true 时跳过正在死亡的（对应旧 _find_player 里
## 的 `_is_dying` 跳过逻辑，见 director.gd）。
func all_entities(exclude_dying: bool = true) -> Array[Node2D]:
	_prune_invalid()
	# 兜底：一个都没注册时扫一次 group（兼容 _ready() 时序竞争）
	if _entities.is_empty():
		var found: Node2D = _scan_group_for_player()
		if found:
			register_entity(found)
	var out: Array[Node2D] = []
	for node: Node2D in _entities:
		if exclude_dying and node.get("_is_dying") == true:
			continue
		out.append(node)
	return out


## 距 pos 最近的玩家实体。多目标索敌 / 传送点 / Director 生成距离用。
func nearest_entity_to(pos: Vector2, exclude_dying: bool = true) -> Node2D:
	var best: Node2D = null
	var best_dist: float = INF
	for node: Node2D in all_entities(exclude_dying):
		var d: float = pos.distance_squared_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	return best


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

func _prune_invalid() -> void:
	var i: int = _entities.size() - 1
	while i >= 0:
		if not is_instance_valid(_entities[i]):
			_entities.remove_at(i)
		i -= 1


## 与旧 _find_player() 相同的鸭子类型判定：CharacterBody2D + has_method("get_weapon_data")
func _scan_group_for_player() -> Node2D:
	var tree: SceneTree = get_tree()
	if not tree:
		return null
	for n: Node in tree.get_nodes_in_group("player"):
		if n is CharacterBody2D and is_instance_valid(n):
			return n as Node2D
	return null


# ═══════════════════════════════════════
# 调试
# ═══════════════════════════════════════

func describe() -> String:
	var lines: Array[String] = []
	lines.append("[Players] 座位=%d 激活=%d 实体=%d" % [seats.size(), active_seat_index, _entities.size()])
	for i: int in range(seats.size()):
		var mark: String = "→" if i == active_seat_index else " "
		lines.append("  %s %s" % [mark, seats[i].describe()])
	return "\n".join(lines)
