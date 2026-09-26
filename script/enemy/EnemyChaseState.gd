class_name EnemyChaseState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 寻路，Client 只表现
## 职责：追击状态：AStarGrid2D 寻路 + 视线简化（string pulling）+ 卡墙恢复 + 同伴软避让与分离推力。
## 依赖：enemy 实体、StateMachine、TileMapLayer（可行走性来源）、CornerAssist（蹭墙侧移）、Global.debug_visuals（调试绘制）

## Host 维护 A* 路径和敌人避让缓存；Client 不寻路，只表现 Host 给出的移动结果。
## 追击玩家 — A* 寻路（Godot 内置 AStarGrid2D）+ 调试输出 + 路径可视化
##
## 网格分辨率：32×32 像素（原生图块分辨率）
##
## 【地形事实（改判定前先确认）】本工程图块碰撞多边形一律是**整格矩形**
## （`tres/*_tileset.tres` 里全部是 `(-16,-16, 16,-16, 16,16, -16,16)`，以格心为原点），
## 且 `physics_layer_0/collision_layer = 1`（＝ `CornerAssist.WORLD_LAYER_BIT`）。
## 因此「某格有碰撞图块」等价于「整格不可通过」，而格心是格内离墙最远的点。
##
## 【可行走性判定（2026-09-10 二次修订）】
## 旧规则是「该格任一图块带碰撞多边形 → 整格不可行走」。它在两类地形上必然误判：
##   ① 一格宽的窄通道：VX Ace 自动图块的边缘变体会把一条薄碰撞条带漏进通道格，
##      于是「敌人身体明明过得去」的通道被整格判死 → 寻路找不到路 → 降级冲撞 → 挤墙；
##   ② 墙体画在 Ground 层的地图（如第二关学校内部）：旧豁免只挂在 decor 碰撞上，
##      且方向判定只扫描 upper/decor 层，于是豁免永远不可能触发。
## 现改为以「敌人碰撞体能否站得下」为唯一判据：
##   · 把碰撞体（收缩 BODY_CLEARANCE 留余量）放到格心，与**所有图层**的碰撞多边形
##     求交；相交即该处站不下（不区分图层、不整格判死）；
##   · 格心站不下时，在格内（允许略微越格）做一圈候选偏移搜索 `_stand_center()`，
##     找到能站的位置就仍判为可行走，并把该位置作为航点 —— 这才是窄通道能走通的关键；
##   · 一格都找不到可站位置 → 判为不可行走；
##   · wall 层仍是整格硬阻挡（该层按约定表示实体墙）；无 ground 图块的空区同样不可行走。
##
## 【路径生成的三段式与一条硬性质（2026-09-10 三次修订）】
##   · 共线简化 → 视线简化（string pulling）→ 立足点重插 → **逐段硬校验**；
##   · 硬性质：**路径的每一段都必须"碰撞体全程可通过"**。简化与重插都用同一个判据，
##     最后再来一次全段复核，任何一段不通过就整条退回 A* 原始格心序列（按构造必然可跟随）。
##   · 已删除「推墙」步骤：它假设图块可能是半格薄碰撞，把航点从格心推开 half+6 作为"离墙更远"。
##     但本工程两套 tileset 的碰撞多边形**全是整格矩形**（见 tres/*_tileset.tres），
##     格心本来就是离墙最远的位置；推开只会让航点贴到墙上。实测第二关学校内部：
##     一格宽通道里航点被横推 14px 出通道 → 路径线穿墙 + 敌人沿墙前后各 2.67px 振荡、
##     永远过不去（单帧位移恒为 2.67px，连"卡住检测"都骗过了）。
##
## 【同伴避让策略（2026-09-10 修订）】
## 原先把每一只其他敌人 set_point_solid(true) 写成硬障碍。AStarGrid2D 用 4 邻域
## （DIAGONAL_MODE_NEVER），只要玩家四周的正交格被同伴占住，目标格就彻底不可达
## → get_id_path() 返回空 → 连续失败后切「直接冲撞」降级模式，表现为一群丧尸挤在
## 门口互相卡死。现改为两级：
##   ① 软代价：同伴占用的格子用 set_point_weight_scale 提高寻路代价 → 倾向绕行但不封死；
##   ② 玩家豁免：玩家 ENEMY_IGNORE_RADIUS 内的敌人完全不参与标记，保证终段必定可达，
##      贴身围拢交给 _push_apart_from_other_enemies 的软推力解决。
## 软代价用完即在同一次 _find_path() 内还原，不留残余状态。

# ── 路径跟踪 ──
var _path: Array[Vector2] = []
var _path_idx: int = 0
var _repath_timer: float = 0.0
var _first_path: bool = true  ## 首次寻路打印详细信息
var _no_path_count: int = 0    ## 连续无路径次数
var _last_failed: bool = false  ## 上次寻路是否失败
var _last_player_pos: Vector2 = Vector2.ZERO  ## 上次寻路时玩家位置
var _fallback_mode: bool = false  ## 降级模式：连续失败后切到直接追击，避免卡顿
var _stuck_frames: int = 0        ## 连续"没能更靠近当前航点"的帧数（进度式，见 _update_stuck_state）
var _wp_best_dist: float = 1e30   ## 到当前航点的历史最近距离 —— 判断"有没有在靠近"
var _wp_tracked_idx: int = -1     ## _wp_best_dist 对应的航点下标（换航点即重置）

# ── A* 网格缓存（静态：所有敌人共享，只查一次）──
static var _tile_walk_cache: Dictionary = {}  ## Vector2i → bool — 地图格子缓存（32×32 分辨率）
static var _stand_cache: Dictionary = {}      ## Vector2i → Vector2 — 该格「站得下」的中心偏移（相对格心）
static var _cell_rect_cache: Dictionary = {}   ## Vector2i → Array[Rect2] — 该格的碰撞盒（热路径用，见 _scan_cell）
static var _body_half: Vector2 = Vector2(10.0, 14.0)  ## 敌人碰撞体半尺寸（由 enter() 从实体读入，静态供 _is_walkable 使用）
static var _cell_size: float = 32.0  ## 网格分辨率（原生图块大小）
static var _tilemaps: Array[TileMapLayer] = []  ## 缓存所有 TileMapLayer（所有敌人共享）
static var _tilemap_roles: Array[int] = []  ## 与 _tilemaps 平行：图层角色（名字判定只做一次）
static var _astar_grid: AStarGrid2D = null  ## Godot 内置 A* 网格（静态，全图共享）
static var _grid_building: bool = false   ## 是否正在分帧构建网格
static var _grid_build_y: int = 0         ## 当前构建到的行
static var _grid_build_x: int = 0         ## 当前构建到的列（行内游标，避免分帧时重扫整行）
static var _grid_build_bounds: Rect2i = Rect2i()  ## 构建区域
static var _grid_build_frame: int = -1    ## 当前帧已处理过（防同帧重复）
static var _grid_build_solids: int = 0     ## 累计障碍物计数
static var _grid_build_start_usec: int = 0  ## 构建起始时刻（用于报告累计 CPU 耗时）
var _collision_half: Vector2 = Vector2(12, 14)  ## 碰撞体半尺寸，用于推墙距离

# ── 敌人列表分帧缓存 ──
# 分离推力与软代价标记都是「每敌人 × 每帧」调用 get_nodes_in_group()，
# 不缓存会变成 N 次数组分配 + N 次全量遍历。同帧内共享一次查询结果即可。
static var _enemy_group_cache: Array[Node] = []
static var _enemy_group_frame: int = -1

const BUILD_CHUNK: int = 1200  ## 每帧最多处理的格子数
const BUILD_TIME_BUDGET_USEC: int = 6000  ## 每帧构建的时间预算（微秒）——两者先到者停

const REPATH_INTERVAL: float = 0.5          ## 正常重算间隔
const REPATH_FAIL_INTERVAL: float = 3.0     ## 寻路失败后重试间隔（避免卡顿）
const REPATH_FAIL_MOVE_DIST: float = 48.0   ## 失败后玩家移动多远才重试
const WAYPOINT_RADIUS: float = 10.0
const NO_CELL: Vector2i = Vector2i(-999999, -999999)  ## _find_nearest_walkable 的"无解"返回值
const FALLBACK_THRESHOLD: int = 2  ## 连续失败多少次切到直接追击模式
## 让位方向配比（2026-09-26）：**横向为主**，前向只留一点点用于从缓行者身侧挤过。
## 旧实现是 `move×0.75 + side×0.25` —— 前向为主等于把挡路者往**前方**推：
## 队列里后面的人一路把前面的人推快（用户实测"被后面的敌人推会加速"），
## 而且永远排成一列纵队。改横向为主后，挡路者往侧面让位，自然形成**肩并肩**横排。
const PUSH_SIDE_WEIGHT: float = 0.85
const PUSH_FORWARD_WEIGHT: float = 0.15
## 身后多少以内不算"挡路"（radial·move_dir 的下限）。身后的人不该把我往侧面挤 ——
## 让路是**后面那个**自己的事（它会把我看成前方障碍），否则队列里前后互相抖。
const PUSH_BEHIND_IGNORE: float = -0.35
## 几乎正对/正背（横向分量过小）时，按 instance_id 定侧，保证同队两侧分开且不左右抖。
const PUSH_ALIGN_EPS: float = 0.15

const PUSH_APART_RADIUS: float = 36.0   ## 敌人推开检测半径
const PUSH_APART_FORCE: float = 220.0   ## 推开速度（像素/秒，强力分离）
## 推挤的空间分桶边长。必须 > PUSH_APART_RADIUS，保证"自身格 + 相邻 8 格"能覆盖所有
## 可能互相推挤的同伴（否则会漏推）。
const PUSH_BUCKET_SIZE: float = 48.0
## 推挤的施加节流：每 N 个物理帧推一次，位移按 delta × N 补偿（总冲量不变）。
## 2026-09-26 性能优化：软分离不需要 60Hz —— 密集尸群时它是 physics 时间里的大头。
const PUSH_APART_STEP: int = 2

# ── 航点推进失败 → 跳过并重算（避免"死死按着不可达航点撞墙、拐不了弯"）──
## 【判据必须是"进度"而不是"位移"】顶在墙上时敌人会被沿墙滑行带着来回蹭，
## 每帧位移恒为 move_speed/60（实测 2.67px）—— 用"单帧位移 < 0.3px"判卡住永远不触发，
## 敌人于是无限振荡（报告里 stuck=0 却有敌人 220 帧原地不动，就是这么来的）。
## 改成看「到当前航点的距离有没有变小」：振荡时距离不变，立刻识别。
const STUCK_SKIP_FRAMES: int = 15       ## 连续多少物理帧没能更靠近航点就放弃它（约 0.25s）
const STUCK_PROGRESS_EPS: float = 0.5   ## 比历史最近距离至少近这么多像素才算"有进展"

# ── 同伴避让（软代价，替代硬障碍）──
const ENEMY_SOFT_COST: float = 8.0        ## 同伴占用格的寻路代价倍率（>1 倾向绕行，但不封死）
const DEFAULT_POINT_COST: float = 1.0     ## AStarGrid2D 点位默认代价，用于还原
const ENEMY_IGNORE_RADIUS: float = 96.0   ## 玩家周围此半径内的敌人完全不标记 → 保证终段可达
const ENEMY_MARK_RADIUS: float = 288.0    ## 只标记此半径内的同伴（更远的对避让无意义，少写少算）

# ── 视线简化（string pulling）──
const LOS_SAMPLE_STEP: float = 8.0        ## 碰撞体采样步长（像素），越小越保守
const LOS_SAMPLE_MAX: int = 128           ## 单段最多采样点数（与步长相乘即为覆盖上限 1024px）

# ── 可行走性：以「敌人碰撞体能否站得下」为判据 ──
const BODY_CLEARANCE: float = 1.0         ## 判定时把碰撞体收缩的量（像素），给"刚好卡住"留余量
const STAND_SEARCH_STEP: float = 4.0      ## 站不下时在格内试探偏移的步长
const STAND_SEARCH_RINGS: int = 3         ## 兜底环搜索圈数（3 圈 × 4px = 最远 12px）
const STAND_HUG_EPS: float = 1.0          ## 判定「阻挡贴格边」的容差（像素）
const _cell_half: float = 16.0            ## 半格（图块碰撞多边形以格心为原点，换算用）
const STAND_REINJECT_THRESHOLD: float = 2.0  ## 立足点偏离格心超过此值（像素）的格，必须在路径里保留航点

# 图层角色（按名字子串判定；未知层按"只阻挡、不提供地面"处理，宁可挡住也不当空气）
const ROLE_WALL: int = 0
const ROLE_GROUND: int = 1
const ROLE_SOLID_HINT: int = 2   ## upper / decor / 未知名：参与碰撞判定，不提供地面

const SCAN_GROUND: int = 1        ## _scan_cell 位掩码：本格有 ground/floor 图块
const SCAN_WALL: int = 2          ## _scan_cell 位掩码：本格有 wall 层图块（整格阻挡）

const NO_STAND: Vector2 = Vector2(-1e9, -1e9)  ## _stand_center 的"该格站不下"返回值

## 整格碰撞盒（局部坐标 0..32）。本工程绝大多数阻挡图块都是这一种，
## 共用同一个常量数组可以省掉几万次数组分配（学校内部图有 6 万格带碰撞）。
const FULL_CELL_RECTS: Array[Rect2] = [Rect2(0.0, 0.0, 32.0, 32.0)]
const EMPTY_RECTS: Array[Rect2] = []


func enter() -> void:
	character.update_moving(true)
# 注：enemy 使用 MOTION_MODE_FLOATING，up_direction 无需设置
	# 获取碰撞体半尺寸用于推墙计算
	var col_shape: CollisionShape2D = character.get_node_or_null("CollisionShape2D")
	if col_shape and col_shape.shape is RectangleShape2D:
		_collision_half = (col_shape.shape as RectangleShape2D).size * 0.5
	else:
		_collision_half = Vector2(12, 14)  # 默认 24×28
	_body_half = _collision_half  ## 同步给静态判定（_is_walkable 是静态方法，读不到实例字段）
	_path = []
	_path_idx = 0
	# 首次重算由「路径为空」立即触发；这里给每个敌人一个确定性的相位偏移，
	# 让后续 0.5s 周期的重算错峰，避免整批敌人同帧一起 A* 造成周期性卡顿。
	_repath_timer = float(character.get_instance_id() % 1000) / 1000.0 * REPATH_INTERVAL
	_no_path_count = 0
	_last_failed = false
	_last_player_pos = Vector2.ZERO
	_fallback_mode = false
	_stuck_frames = 0
	_wp_best_dist = 1e30
	_wp_tracked_idx = -1
	_first_path = true
	# 找到所有 TileMapLayer（static 缓存，只在首次进入时搜索并打印）
	if _tilemaps.is_empty() or not is_instance_valid(_tilemaps[0]):
		_tilemaps.clear()
		_tile_walk_cache.clear()
		_stand_cache.clear()
		_cell_rect_cache.clear()
		_astar_grid = null  ## 失效 AStarGrid2D，触发重建
		_grid_building = false  ## 中断分帧构建
		_find_all_tilemaps()
		var names: String = ""
		for tm in _tilemaps:
			if not is_instance_valid(tm):
				continue
			names += tm.name + " "
		print("[A*] 找到 TileMapLayer (%d 个): [%s]" % [_tilemaps.size(), names.strip_edges()])
	# 注册调试绘制字段
	character._debug_path = []
	character._debug_path_idx = 0
	character._debug_path_found = false
	character._debug_start_grid = Vector2i.ZERO
	character._debug_end_grid = Vector2i.ZERO
	character._debug_start_walkable = false
	character._debug_end_walkable = false
	character._debug_astar_iters = 0
	character._debug_walk_cache = {}
	character._debug_cell_size = _cell_size


func process_update(_delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character
	if not enemy.has_valid_player_target():
		transition_requested.emit("Idle")
		return
	var player: Node2D = enemy._player_ref

	var fw: Vector2 = enemy.get_facing_vector()
	# ── 丸呑み（ハンターγ）：零距离必杀，优先于普通攻击判定 ──
	# 原作「零距離で「丸呑み」」，触发距离远小于攻击矩形，所以必须放在前面 ——
	# 否则玩家一贴近就先吃普通攻击，丸呑み永远轮不到。
	if _can_swallow(enemy, player):
		transition_requested.emit("Swallow")
		return

	var rect_center: Vector2 = enemy.global_position + fw * enemy.attack_range_forward_offset
	var rel: Vector2 = player.global_position - rect_center
	var rt: Vector2 = Vector2(fw.y, -fw.x)
	## melee_enabled = false（ブレインディモス 2026-09-17）→ 纯远程，贴脸也不近战，直接落空落到吐酸判定
	if enemy.melee_enabled \
			and abs(rel.dot(rt)) <= enemy.attack_range.x / 2.0 and abs(rel.dot(fw)) <= enemy.attack_range.y / 2.0:
		transition_requested.emit("Attack")
		return

	# ── 首狩り（ハンター 系）：中距离锁定 → 突进扑咬 ──
	# 判定放在普通攻击之后：能直接咬到就不必起跳（避免"近距离还做突进"的滑稽表现）。
	# 距离带由 pounce_trigger_min/max_dist 控制，冷却由 enemy._pounce_cooldown_left 控制。
	if _can_pounce(enemy, player):
		transition_requested.emit("Pounce")
		return

	# ── 远程吐酸（ブレインディモス）：中距离停步吐酸 ──
	# 放在最后：能咬到就咬（Attack）、够得着就扑（Pounce）、都不行且在射程带内才吐酸。
	if _can_spit(enemy, player):
		transition_requested.emit("Spit")


## 丸呑み（ハンターγ）触发条件：贴到零距离 + 冷却已过 + 状态机里有 Swallow 节点。
##
## 注意：这里不掷 swallow_chance —— 概率判定放在 Swallow 状态的「吞入帧」里，
## 因为那才是原作的「丸吞判定区」（帧 1）。放在这里会导致动画还没张嘴就已经决定结果，
## 表现与判定脱节（玩家看到张嘴却发现什么都没发生，或反之）。
func _can_swallow(enemy: Node2D, player: Node2D) -> bool:
	if not enemy.swallow_enabled:
		return false
	if enemy._swallow_cooldown_left > 0.0:
		return false
	var sm: Node = enemy.get_node_or_null("StateMachine")
	if sm == null or sm.get_node_or_null("Swallow") == null:
		return false
	var d: float = player.global_position.distance_to(enemy.global_position)
	return d <= maxf(1.0, enemy.swallow_trigger_range)


func _can_pounce(enemy: Node2D, player: Node2D) -> bool:
	if not enemy.pounce_enabled:
		return false
	if enemy._pounce_cooldown_left > 0.0:
		return false
	# 状态机里没有 Pounce 节点（旧场景/被裁剪）时不能切 —— 会静默卡死在 Chase
	var sm: Node = enemy.get_node_or_null("StateMachine")
	if sm == null or sm.get_node_or_null("Pounce") == null:
		return false
	var d: float = player.global_position.distance_to(enemy.global_position)
	return d >= enemy.pounce_trigger_min_dist and d <= enemy.pounce_trigger_max_dist


## 远程吐酸（ブレインディモス）触发条件：距离带内 + 冷却已过 + 状态机有 Spit 节点
## + 与玩家之间无墙（隔墙吐酸不成立——酸弹撞墙即碎，纯浪费演出与冷却）。
func _can_spit(enemy: Node2D, player: Node2D) -> bool:
	if not enemy.spit_enabled:
		return false
	if enemy._spit_cooldown_left > 0.0:
		return false
	var sm: Node = enemy.get_node_or_null("StateMachine")
	if sm == null or sm.get_node_or_null("Spit") == null:
		return false
	var d: float = player.global_position.distance_to(enemy.global_position)
	if d < enemy.spit_trigger_min_dist or d > enemy.spit_trigger_max_dist:
		return false
	# LOS：射线只查墙层（1=图块 | 32=子弹阻挡），打到墙 = 玩家在掩体后
	var space: PhysicsDirectSpaceState2D = enemy.get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(
		enemy.global_position, player.global_position, 1 | 32)
	query.exclude = [enemy.get_rid()]
	return space.intersect_ray(query).is_empty()


func physics_update(delta: float) -> void:
	_build_step()  ## 持续分帧构建 AStarGrid2D（如在构建中）

	var enemy: Node2D = character

	# ── 先结算「有没有在靠近当前航点」（进度式卡住检测，理由见 STUCK_SKIP_FRAMES 注释）──
	# 放在最前面是为了不被后面多处 return 打断。
	_update_stuck_state(enemy)

	# ── 卡住太久 → 放弃当前航点（跳到下一个 / 强制重算），而不是一直顶在同一面墙上。
	#    这是「航点不可达时敌人只会原地挤墙、拐不了弯」的兜底。
	if _stuck_frames >= STUCK_SKIP_FRAMES:
		_stuck_frames = 0
		_wp_best_dist = 1e30
		if _fallback_mode:
			_fallback_mode = false  ## 冲撞也撞不动 → 退出降级，重试寻路
			_repath_timer = 0.0
		elif _path_idx < _path.size():
			_path_idx += 1
			if _path_idx >= _path.size():
				_path.clear()  ## 末段也走不到 → 清空以触发下一帧重算
			enemy._debug_path_idx = _path_idx

	if not enemy.has_valid_player_target():
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return
	var player: Node2D = enemy._player_ref

	var to_player: Vector2 = player.global_position - enemy.global_position
	if to_player.length() < 1.0:
		return

	var speed: float = enemy.move_speed

	# ── 降级模式：连续失败2次 → 切到直接追击（避免A*卡顿）──
	if _fallback_mode:
		_repath_timer += delta
		if _repath_timer >= REPATH_FAIL_INTERVAL:
			_repath_timer = 0.0
			var player_moved: float = player.global_position.distance_to(_last_player_pos)
			if player_moved > REPATH_FAIL_MOVE_DIST:
				_fallback_mode = false
				_path = _find_path(enemy.global_position, player.global_position)
				_last_player_pos = player.global_position
				if not _path.is_empty():
					_path_idx = 1 if _path.size() > 1 else 0
					_last_failed = false
					enemy._debug_path = _path
					enemy._debug_path_idx = _path_idx
				else:
					_fallback_mode = true
		if _fallback_mode:
			_move_direct(enemy, to_player, speed, delta)
			return

	# 定期重算路径（失败后退避）
	_repath_timer += delta
	var should_repath: bool = _path.is_empty()
	if not should_repath and not _last_failed:
		if _repath_timer >= REPATH_INTERVAL:
			should_repath = true

	if should_repath:
		_repath_timer = 0.0
		_last_player_pos = player.global_position
		_path = _find_path(enemy.global_position, player.global_position)
		_path_idx = 1 if _path.size() > 1 else 0
		_last_failed = _path.is_empty()
		if _last_failed:
			_no_path_count += 1
			if _no_path_count >= FALLBACK_THRESHOLD:
				_fallback_mode = true
		else:
			_no_path_count = 0
		enemy._debug_path = _path
		enemy._debug_path_idx = _path_idx
		enemy._debug_walk_cache = _tile_walk_cache
		if Global.debug_visuals:
			enemy.queue_redraw()

	# ── 确定移动目标方向 ──
	if _path.is_empty():
		_move_direct(enemy, to_player, speed, delta)
		return

	_no_path_count = 0
	while _path_idx < _path.size():
		if enemy.global_position.distance_to(_path[_path_idx]) < 16.0:
			_path_idx += 1
		else:
			break

	var move_dir: Vector2
	if _path_idx >= _path.size():
		move_dir = to_player.normalized()
	else:
		move_dir = (_path[_path_idx] - enemy.global_position).normalized()


	character.update_facing_from_direction(move_dir)
	_move_with_stuck_recovery(character, move_dir, speed, delta)
	_push_apart_from_other_enemies(character, delta, move_dir)

# 移动工具
# ═══════════════════════════════════════

func _update_stuck_state(enemy: Node2D) -> void:
	## 进度式卡住检测：比较「到当前航点的距离」有没有变小，而不是单帧位移大小。
	if _path_idx >= _path.size():
		_wp_tracked_idx = -1
		_wp_best_dist = 1e30
		_stuck_frames = 0
		return
	if _wp_tracked_idx != _path_idx:
		_wp_tracked_idx = _path_idx
		_wp_best_dist = 1e30
		_stuck_frames = 0
	var d: float = enemy.global_position.distance_to(_path[_path_idx])
	if d < _wp_best_dist - STUCK_PROGRESS_EPS:
		_wp_best_dist = d
		_stuck_frames = 0  ## 只要还在靠近（哪怕很慢）就不算卡
		return
	## ⚠ 这里**不要**顺手把 best 更新成 d：best 是"已经到达过的最近距离"这个**标尺**，
	## 它每帧跟着 d 走的话，慢速接近（如被群挤着 0.3px/帧）会让"比 best 近 0.5px"
	## 这个条件永远攒不满 → 把正常缓慢推进误判成卡住。
	## 所以只累计计数，标尺留给"确实靠近了 0.5px"那一次来推进。
	_stuck_frames += 1


func _move_direct(enemy: Node2D, to_player: Vector2, speed: float, delta: float) -> void:
	var move_dir: Vector2 = to_player.normalized()
	character.update_facing_from_direction(move_dir)
	_move_with_stuck_recovery(character, move_dir, speed, delta)
	_push_apart_from_other_enemies(character, delta, move_dir)

const ENEMY_LAYER_BIT: int = 8  ## Layer 4 = 1<<3，敌人物理体所在层

func _move_with_stuck_recovery(body: CharacterBody2D, move_dir: Vector2, speed: float, delta: float) -> void:
	## 临时关闭敌人间硬碰撞 → 只撞墙不撞敌人，像以撒那样靠软推力分离
	var prev_pos := body.global_position
	# 移除敌人层碰撞 → move_and_collide 不会因敌人而停下
	var saved_mask := body.collision_mask
	body.collision_mask = saved_mask & ~ENEMY_LAYER_BIT

	var motion := move_dir * speed * delta
	for _i in range(6):
		var col := body.move_and_collide(motion)
		if not col:
			break
		## 沿墙滑行：取 slide 后的**真实长度**，不要重新归一化。
		## 旧写法 `.normalized() * speed * delta` 会把极小的切向分量放大回全速 ——
		## 正对墙面时切向分量本应≈0，被放大后变成每帧满速的横向位移，
		## 于是敌人贴着墙来回磨（实测 ±2.67px/帧振荡）且"位移永远不为 0"，
		## 连卡住检测都被骗过。保持真实长度后：正撞 → 位移≈0 → 下面的蹭墙侧移接手。
		## （这也与 `move_and_slide()` 的行为一致：它同样不做重新归一化。）
		motion = motion.slide(col.get_normal())
		if motion.length() < 0.5:
			break

	# 恢复碰撞掩码
	body.collision_mask = saved_mask

	# 卡住 → 用与玩家同一套「蹭墙」逻辑沿垂直方向侧移，
	# 而不是原地朝同一方向反复撞墙（原地重试在门框/墙角上永远撞不开）。
	if body.global_position.distance_to(prev_pos) < 1.5:
		var e = character
		e.apply_corner_nudge(move_dir, move_dir * speed * delta)


static func _cached_enemy_group(tree: SceneTree) -> Array[Node]:
	## 同一物理帧内所有敌人共享一次 group 查询结果。
	## 调用方只遍历、不修改返回数组，因此共享是安全的。
	var cf: int = Engine.get_physics_frames()
	if _enemy_group_frame != cf:
		_enemy_group_frame = cf
		_enemy_group_cache = tree.get_nodes_in_group("enemy")
	return _enemy_group_cache


## ── 推挤用的"每物理帧缓存"（2026-09-26 性能优化）──
## 旧实现的 `_push_apart_from_other_enemies` 是 O(N²)，且**每一对**都要做
## `other.get("_is_dead")` / `other.get_node_or_null("StateMachine")` / 状态名比较 ——
## 全是对 C++ 的字符串查表。实测 20 只敌人就把每帧 process 从 1.2ms 顶到 20ms、
## 40 只 37ms（headless 且不含渲染）。这里把"状态查询"下沉成每帧一次的 O(N) 预处理，
## 再把"和谁比距离"收窄到相邻粗格，推挤循环里只剩浮点运算。
static var _push_buckets: Dictionary = {}      ## Vector2i(粗格) → Array[Node]
static var _push_skip_ids: Dictionary = {}     ## 死亡 / 击退 / 硬直 的敌人 instance_id
static var _push_cache_frame: int = -1


static func _ensure_push_cache(tree: SceneTree) -> void:
	var cf: int = Engine.get_physics_frames()
	if _push_cache_frame == cf:
		return
	_push_cache_frame = cf
	_push_buckets.clear()
	_push_skip_ids.clear()
	for node: Node in _cached_enemy_group(tree):
		if not is_instance_valid(node):
			continue
		var oid: int = node.get_instance_id()
		if node.get("_is_dead") == true:
			_push_skip_ids[oid] = true
			continue
		var sm: Node = node.get_node_or_null("StateMachine")
		if sm != null and sm.current_state != null:
			var sname: StringName = sm.current_state.name
			if sname == &"Knockback" or sname == &"Hitstun":
				_push_skip_ids[oid] = true
				continue
		var pos: Vector2 = (node as Node2D).global_position
		var key := Vector2i(floori(pos.x / PUSH_BUCKET_SIZE), floori(pos.y / PUSH_BUCKET_SIZE))
		var bucket: Variant = _push_buckets.get(key)
		if bucket is Array:
			(bucket as Array).append(node)
		else:
			_push_buckets[key] = [node]


func _push_apart_from_other_enemies(enemy: Node2D, delta: float, move_dir: Vector2 = Vector2.ZERO) -> void:
	## 自然推开挡路敌人：沿移动方向推开，而非盲目径向挤
	var tree: SceneTree = enemy.get_tree()
	if not tree:
		return

	_ensure_push_cache(tree)
	var my_pos: Vector2 = enemy.global_position
	var has_move_dir: bool = move_dir.length() > 0.3
	var my_id: int = enemy.get_instance_id()
	var radius_sq: float = PUSH_APART_RADIUS * PUSH_APART_RADIUS
	## 限流：每 PUSH_APART_STEP 个物理帧处理一次（位移按倍数补偿，总冲量不变）。
	var physics_frame: int = Engine.get_physics_frames()
	if physics_frame % PUSH_APART_STEP != 0:
		return
	var step_delta: float = delta * float(PUSH_APART_STEP)
	## ★单步位移上限 = 一只敌人的满强度推力。推的人再多也不会超过它
	##（旧实现是逐个 move_and_collide 别人 → 位移线性叠加 = 排队推着加速 + 挤穿墙）。
	var max_step_push: float = PUSH_APART_FORCE * step_delta
	var key := Vector2i(floori(my_pos.x / PUSH_BUCKET_SIZE), floori(my_pos.y / PUSH_BUCKET_SIZE))
	var push_sum: Vector2 = Vector2.ZERO
	var contributors: int = 0
	var side: Vector2 = Vector2.UP if not has_move_dir else Vector2(-move_dir.y, move_dir.x)

	for dx: int in range(-1, 2):
		for dy: int in range(-1, 2):
			var bucket: Variant = _push_buckets.get(Vector2i(key.x + dx, key.y + dy))
			if not (bucket is Array):
				continue
			for other_value: Variant in (bucket as Array):
				var other: Node = other_value as Node
				if other == null or other.get_instance_id() == my_id:
					continue
				if _push_skip_ids.has(other.get_instance_id()):
					continue
				var other_pos: Vector2 = (other as Node2D).global_position
				var dist_sq: float = my_pos.distance_squared_to(other_pos)
				if dist_sq >= radius_sq or dist_sq <= 0.0001:
					continue
				var dist: float = sqrt(dist_sq)
				var radial: Vector2 = (other_pos - my_pos) / dist
				var push_dir: Vector2
				if has_move_dir:
					## 身后的人不算挡路（让路是后面那个自己的事），否则队列前后会互相抖。
					if radial.dot(move_dir) < PUSH_BEHIND_IGNORE:
						continue
					var side_dot: float = radial.dot(side)
					## ★符号：现在推的是**自己**，所以侧向必须**背离**挡路者
					##（radial 是我→对方；side_dot 大于 0 = 对方在我 +side 侧 → 我要往 -side 让）。
					## 旧实现推的是对方，方向恰好相反；改成推自己时漏取负 = 往对方身上挤（自检抓到）。
					var away_sign: float = -1.0 if side_dot >= 0.0 else 1.0
					if absf(side_dot) < PUSH_ALIGN_EPS:
						## 几乎正对/正背（排成一列）：按 instance_id 定侧 —— 同一对必然分向两侧、
						## 且不随帧抖动（旧实现用 side_dot 符号，正对时符号会在正负之间跳）。
						away_sign = 1.0 if my_id > other.get_instance_id() else -1.0
					push_dir = (side * away_sign * PUSH_SIDE_WEIGHT
						+ move_dir * PUSH_FORWARD_WEIGHT).normalized()
				else:
					push_dir = -radial  # 静止：纯径向分离
				var push_strength: float = (1.0 - dist / PUSH_APART_RADIUS) * PUSH_APART_FORCE
				push_sum += push_dir * push_strength * step_delta
				contributors += 1

	if push_sum == Vector2.ZERO:
		return
	## ★钳制：所有同伴的推力求和后**只施加一次**，且不超过单推力上限。
	if push_sum.length() > max_step_push:
		push_sum = push_sum.normalized() * max_step_push
	if enemy is CharacterBody2D:
		enemy.move_and_collide(push_sum)
	else:
		enemy.global_position += push_sum


# ═══════════════════════════════════════
# A* 寻路（Godot 内置 AStarGrid2D）
# ═══════════════════════════════════════

static func prebuild() -> void:
	## 场景加载后立即启动网格构建（由 GameInit 延迟调用）。
	## 避免首个敌人进入追击时才同步创建 AStarGrid2D（update() 为一次性同步开销，
	## 大图会卡一帧），把一次性成本前移到加载阶段。
	## _ensure_astar_grid 内部已处理：已就绪直接返回、场景切换后自动重新发现图块。
	_ensure_astar_grid()


static func tick_build() -> void:
	## 每物理帧驱动网格分帧构建（由 GameInit 调用）。
	## 敌人尚未追击时也能推进构建；闲置时仅一次布尔判断，开销可忽略。
	_build_step()


static func _ensure_astar_grid() -> bool:
	## 确保 AStarGrid2D 已构建。返回 true 表示就绪（立即可用）。
	## 如果尚未构建，启动分帧构建并返回 false（调用者应使用降级追击）。
	if _astar_grid and not _tilemaps.is_empty() and is_instance_valid(_tilemaps[0]):
		if _grid_building:
			return false  ## 构建中，尚未就绪
		return true

	# 正在构建中，不要重启
	if _grid_building:
		return false

	# 重新发现 tilemaps
	if _tilemaps.is_empty() or not is_instance_valid(_tilemaps[0]):
		_tilemaps.clear()
		_tile_walk_cache.clear()
		_stand_cache.clear()
		_cell_rect_cache.clear()
		_find_all_tilemaps()

	if _tilemaps.is_empty():
		return false

	# 计算所有 tilemap 的合并边界
	var bounds: Rect2i = Rect2i()
	var first: bool = true
	for tm in _tilemaps:
		if not is_instance_valid(tm):
			continue
		var rect: Rect2i = tm.get_used_rect()
		if first:
			bounds = rect
			first = false
		else:
			bounds = bounds.merge(rect)

	if first:
		return false

	var total_cells: int = bounds.size.x * bounds.size.y
	var est_frames: int = ceili(float(total_cells) / float(BUILD_CHUNK))
	print("[A*] 分帧构建 AStarGrid2D: region=%s cells=%d (约%d帧完成)" % [str(bounds), total_cells, est_frames])

	_astar_grid = AStarGrid2D.new()
	_astar_grid.region = bounds
	_astar_grid.cell_size = Vector2(_cell_size, _cell_size)
	_astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar_grid.update()

	# 启动分帧构建
	_grid_building = true
	_grid_build_y = bounds.position.y
	_grid_build_x = bounds.position.x
	_grid_build_bounds = bounds
	_grid_build_frame = -1
	_grid_build_solids = 0
	_grid_build_start_usec = Time.get_ticks_usec()

	return false  ## 构建中，稍后才就绪


static func _build_step() -> void:
	## 每帧处理 BUILD_CHUNK 个格子，分帧完成障碍物标记。
	## 可被多次调用，同帧内只执行一次。
	if not _grid_building or not _astar_grid:
		return

	var cf: int = Engine.get_physics_frames()
	if _grid_build_frame == cf:
		return  ## 本帧已处理过
	_grid_build_frame = cf

	var bounds: Rect2i = _grid_build_bounds
	var row_end: int = bounds.position.x + bounds.size.x
	var count: int = 0
	var t_start: int = Time.get_ticks_usec()

	## 注意：本帧用完配额要 return，所以**必须**把"行内已处理到哪一列"也记下来。
	## 早期只记行号，下帧会从这一行的行首重扫 —— 已处理的格子被重复计数，
	## 于是日志出现「障碍物数 > 总格数」这种不可能的百分比。
	while _grid_build_y < bounds.position.y + bounds.size.y:
		while _grid_build_x < row_end:
			var gp := Vector2i(_grid_build_x, _grid_build_y)
			var walkable: bool = _is_walkable(gp)
			## 场景切换（安全门/传送点）会在 _is_walkable 内部把缓存整体失效
			## （_astar_grid = null、_grid_building = false）。此时旧构建进度已无意义，
			## 必须立即中止本帧 —— 否则下一行就是对空引用 set_point_solid（学校门口实测崩溃）。
			if not _grid_building or not _astar_grid:
				return
			if not walkable:
				_astar_grid.set_point_solid(gp, true)
				_grid_build_solids += 1
			_grid_build_x += 1
			count += 1
			if count >= BUILD_CHUNK:
				return  ## 下帧从当前行列继续
			## 时间预算：格子耗时随地图复杂度浮动，只按数量限流会在复杂地图上掉帧。
			## 每 64 格查一次时钟（开销可忽略），先到者停。
			if (count & 63) == 0 and Time.get_ticks_usec() - t_start >= BUILD_TIME_BUDGET_USEC:
				return
		_grid_build_x = bounds.position.x
		_grid_build_y += 1

	# 构建完成
	_grid_building = false
	var total: int = bounds.size.x * bounds.size.y
	print("[A*] AStarGrid2D 构建完成: %d cells, 障碍物 %d (%.1f%%), 累计 CPU 耗时 %d ms" % [
		total, _grid_build_solids, float(_grid_build_solids) / float(total) * 100.0,
		int((Time.get_ticks_usec() - _grid_build_start_usec) / 1000)])


func _mark_enemy_soft_costs(player_pos: Vector2) -> Array[Vector2i]:
	## 给「挡在路上」的同伴占用格加软代价，返回被改动的格子以便还原。
	##
	## 相比原来的 set_point_solid(true) 有两处关键区别：
	## ① 软代价不封死格子 —— 即使同伴把路占满，A* 仍能穿过去，不会出现「无路径」；
	## ② 玩家 ENEMY_IGNORE_RADIUS 内的同伴完全不标记 —— 保证目标格与紧邻格永远可达；
	##    贴身围拢交给 _push_apart_from_other_enemies 的软推力处理（那才是它的职责）。
	## 只考虑 ENEMY_MARK_RADIUS 内的同伴：更远的同伴不会与本路径竞争同一段走廊。
	var touched: Array[Vector2i] = []
	if not _astar_grid:
		return touched

	var tree: SceneTree = character.get_tree()
	if not tree:
		return touched

	var my_grid: Vector2i = _world_to_grid(character.global_position)
	var my_pos: Vector2 = character.global_position
	var ignore_sq: float = ENEMY_IGNORE_RADIUS * ENEMY_IGNORE_RADIUS
	var mark_sq: float = ENEMY_MARK_RADIUS * ENEMY_MARK_RADIUS

	for other in _cached_enemy_group(tree):
		if other == character or not is_instance_valid(other):
			continue
		if other.get("_is_dead") == true:
			continue

		var other_pos: Vector2 = other.global_position
		if other_pos.distance_squared_to(player_pos) <= ignore_sq:
			continue
		if other_pos.distance_squared_to(my_pos) > mark_sq:
			continue

		var gp: Vector2i = _world_to_grid(other_pos)
		if gp == my_grid:
			continue
		if not _astar_grid.region.has_point(gp):
			continue
		if _astar_grid.is_point_solid(gp):
			continue  ## 静态墙不动，只处理可通行格
		if _astar_grid.get_point_weight_scale(gp) >= ENEMY_SOFT_COST:
			continue  ## 已被同伴（同格）标记过，避免重复记录
		_astar_grid.set_point_weight_scale(gp, ENEMY_SOFT_COST)
		touched.append(gp)

	return touched


func _clear_enemy_soft_costs(cells: Array[Vector2i]) -> void:
	if not _astar_grid:
		return
	for gp in cells:
		if _astar_grid.region.has_point(gp):
			_astar_grid.set_point_weight_scale(gp, DEFAULT_POINT_COST)


func _find_path(from: Vector2, to: Vector2) -> Array[Vector2]:
	var start: Vector2i = _world_to_grid(from)
	var end: Vector2i = _world_to_grid(to)
	var start_ok: bool = _is_walkable(start)
	var end_ok: bool = _is_walkable(end)

	character._debug_start_grid = start
	character._debug_end_grid = end
	character._debug_start_walkable = start_ok
	character._debug_end_walkable = end_ok

	if _first_path and Global.debug_visuals:
		print("[A*] ═══ 寻路开始（AStarGrid2D, %dpx 格子）═══" % int(_cell_size))
		print("[A*] 敌人世界: (%.0f, %.0f) → 格子: %s  可行走=%s" % [from.x, from.y, str(start), str(start_ok)])
		print("[A*] 玩家世界: (%.0f, %.0f) → 格子: %s  可行走=%s" % [to.x, to.y, str(end), str(end_ok)])

	if not end_ok:
		print("[A*] ⚠ 目标不可通行，搜索邻近格子...")
		end = _find_nearest_walkable(end)
		if end == NO_CELL:
			print("[A*] ❌ 找不到可通行的邻近格子！")
			character._debug_path_found = false
			character._debug_astar_iters = 0
			_first_path = false
			return []
		print("[A*]   邻近可通行格子: %s" % str(end))

	if not start_ok:
		## 敌人贴着墙站着时，自身所在格的格心可能站不下（身体压到墙上）。这不是"没有路"，
		## 只是取样点不好 —— 吸附到附近的可行走格即可。直接放弃会掉进降级冲撞 → 挤墙。
		var snapped_start: Vector2i = _find_nearest_walkable(start)
		if snapped_start == NO_CELL:
			print("[A*] ❌ 起点附近找不到可通行格子！")
			character._debug_path_found = false
			character._debug_astar_iters = 0
			_first_path = false
			return []
		if Global.debug_visuals:
			print("[A*] 起点不可通行 → 吸附到最近可行走格 %s" % str(snapped_start))
		start = snapped_start

	if start == end:
		print("[A*] 起点=终点，直走")
		character._debug_path_found = true
		character._debug_astar_iters = 0
		_first_path = false
		return [to]

	# ── 确保 AStarGrid2D 已构建 ──
	if not _ensure_astar_grid():
		print("[A*] ❌ 无法构建寻路网格！")
		character._debug_path_found = false
		character._debug_astar_iters = 0
		_first_path = false
		return []

	# ── 给附近同伴加「软代价」（让路但不封死），用完立即还原 ──
	var soft_cells: Array[Vector2i] = _mark_enemy_soft_costs(to)

	# ── 使用 Godot 内置 AStarGrid2D 寻路 ──
	var id_path: PackedVector2Array = _astar_grid.get_id_path(start, end)

	# ── 还原软代价 ──
	_clear_enemy_soft_costs(soft_cells)

	if id_path.is_empty():
		if Global.debug_visuals:
			print("[A*] ❌ 无路径！")
		character._debug_path_found = false
		character._debug_astar_iters = 0
		_first_path = false
		return []

	# 转换为 Array[Vector2i]（get_id_path 返回 PackedVector2Array，元素为浮点格子坐标）
	var grid_path: Array[Vector2i] = []
	for p: Vector2 in id_path:
		grid_path.append(Vector2i(int(p.x), int(p.y)))

	# 平滑路径（共线简化 + 碰撞体感知推墙）
	var smoothed: Array[Vector2] = _smooth_path(grid_path)

	if Global.debug_visuals:
		print("[A*] ✅ 找到路径！原始=%d 平滑后=%d" % [grid_path.size(), smoothed.size()])
		if smoothed.size() > 0:
			print("[A*]   起点: (%.0f, %.0f)  终点: (%.0f, %.0f)" % [smoothed[0].x, smoothed[0].y, smoothed[smoothed.size()-1].x, smoothed[smoothed.size()-1].y])

	character._debug_path_found = true
	character._debug_astar_iters = 0  ## AStarGrid2D 不暴露迭代数
	_first_path = false
	return smoothed


func _smooth_path(grid_path: Array[Vector2i]) -> Array[Vector2]:
	## 三段式路径优化：共线简化 → 视线简化 → 立足点重插，最后**逐段硬校验**。
	##
	## ① 共线简化：把「一直朝同一方向」的连续格子压成一个拐点；
	## ② 视线简化（string pulling）：两点之间只要碰撞体全程可通过，中间的拐点就全部丢弃。
	##    这是让敌人走斜直线、而不是沿格子边缘走锯齿「楼梯」的关键一步；
	## ③ 立足点重插：② 会把中间格全丢掉，可窄通道里的格「立足点」是偏离格心的，
	##    丢掉它就会让线段从格心直穿而过 —— 身体压到自动图块的漏边上。把这类格插回来。
	##
	## 【为什么不再有"推墙"这一步（2026-09-10 三次修订）】
	## 旧实现（第 ④ 步）把航点从格心推开最多 `half+6`，理由是"离开墙面、减少贴墙摩擦"。
	## 那个假设在本工程不成立：两套 tileset 的碰撞多边形**全是整格矩形**，
	## 格心就是格内离墙最远的点，把它推开只会让航点贴到墙上。实测后果（第二关学校内部）：
	## 一格宽通道里航点被横向推出通道 14px，路径线穿过墙体、敌人沿墙前后振荡永远过不去。
	## 真正的保障是"每一段都可跟随"，由下面的 `_verify_or_raw()` 兜底。
	var world := _to_world_array(grid_path)
	if grid_path.size() <= 2:
		return _verify_or_raw(world, grid_path)

	var keypoints: Array[Vector2i] = [grid_path[0]]
	for i in range(1, grid_path.size() - 1):
		var prev: Vector2i = grid_path[i - 1]
		var curr: Vector2i = grid_path[i]
		var next_: Vector2i = grid_path[i + 1]
		if (curr - prev) != (next_ - curr):
			keypoints.append(curr)
	keypoints.append(grid_path[grid_path.size() - 1])

	world = _pull_string(_to_world_array(keypoints))
	world = _reinject_offset_cells(world)
	return _verify_or_raw(world, grid_path)


func _verify_or_raw(points: Array[Vector2], grid_path: Array[Vector2i]) -> Array[Vector2]:
	## 最后一道闸：逐段复核「碰撞体全程可通过」。任何一段不通过就整条退回
	## **A* 原始格心序列** —— 相邻格（4 邻域）的中心连线只经过这两格，
	## 而这两格都可行走，所以按构造必然可跟随。
	## 简化与重插都是启发式，这一层保证「路径一定走得通」这个硬性质不会丢。
	if _path_followable(points):
		return points
	if Global.debug_visuals:
		print("[A*] ⚠ 平滑结果存在不可跟随的段 → 退回原始格心路径（%d 点）" % grid_path.size())
	return _to_world_array(grid_path)


static func _path_followable(points: Array[Vector2]) -> bool:
	for i in range(points.size() - 1):
		if not _segment_followable(points[i], points[i + 1]):
			return false
	return true


static func _segment_followable(a: Vector2, b: Vector2) -> bool:
	## 线段全程「碰撞体站得下」——两层判定：
	##   ① 格子级：经过的格子都可行走（不漏格）；
	##   ② 碰撞体级：沿线段等距采样，每点身体都不与任何碰撞盒相交。
	if not _segment_cells_walkable(a, b):
		return false
	var steps: int = clampi(ceili(a.distance_to(b) / LOS_SAMPLE_STEP), 1, LOS_SAMPLE_MAX)
	for i in range(steps + 1):
		if not _body_fits_at(a.lerp(b, float(i) / float(steps))):
			return false
	return true


func _reinject_offset_cells(points: Array[Vector2]) -> Array[Vector2]:
	## 把线段途经的「立足点明显偏离格心」的格重新插回路径（见 _smooth_path 第 ③ 步）。
	## 偏离量小于阈值的格不插 —— 开阔地形的立足点就是格心，插了只会白白增加航点数。
	if points.size() < 2:
		return points

	var mid: Vector2 = Vector2(_cell_size, _cell_size) * 0.5
	var out: Array[Vector2] = [points[0]]
	for i in range(points.size() - 1):
		var cells: Array[Vector2i] = _segment_cells(points[i], points[i + 1])
		## 跳过首尾两格：它们本身就是当前航点所在的格
		for ci in range(1, cells.size() - 1):
			var gp: Vector2i = cells[ci]
			var off: Vector2 = _stand_center(gp)
			if off == NO_STAND:
				continue
			if (off - mid).length() <= STAND_REINJECT_THRESHOLD:
				continue
			out.append(_grid_to_world(gp))
		out.append(points[i + 1])
	return out


func _pull_string(points: Array[Vector2]) -> Array[Vector2]:
	## 视线简化：维护一个锚点，向后试探最远的可直达点；
	## 一旦不可直达，就保留当前点的前一个点，并把它设为新锚点。
	if points.size() <= 2:
		return points
	var out: Array[Vector2] = [points[0]]
	var anchor: int = 0
	for i in range(2, points.size()):
		if not _has_line_of_sight(points[anchor], points[i]):
			out.append(points[i - 1])
			anchor = i - 1
	out.append(points[points.size() - 1])
	return out


func _has_line_of_sight(from_world: Vector2, to_world: Vector2) -> bool:
	## 通视 = 线段全程「碰撞体站得下」。判定实现在 `_segment_followable()`（两层：格 + 碰撞体），
	## 与路径复核用的是同一个判据 —— 视线简化认为通的段，路径复核也一定认为通。
	if from_world.distance_to(to_world) < 0.5:
		return true
	return _segment_followable(from_world, to_world)


static func _segment_cells_walkable(a: Vector2, b: Vector2) -> bool:
	## 线段经过的格子是否全部可行走。
	for gp in _segment_cells(a, b):
		if not _is_walkable(gp):
			return false
	return true


static func _segment_cells(a: Vector2, b: Vector2) -> Array[Vector2i]:
	## 线段经过的格子列表（含首尾格），Amanatides–Woo 网格步进，按行进顺序返回。
	## 与采样无关，因此不会漏格；迭代次数与格距成正比，长线段也只是几十次查表。
	var cells: Array[Vector2i] = []
	var delta: Vector2 = b - a
	var gx: int = floori(a.x / _cell_size)
	var gy: int = floori(a.y / _cell_size)
	var end_x: int = floori(b.x / _cell_size)
	var end_y: int = floori(b.y / _cell_size)
	cells.append(Vector2i(gx, gy))

	var step_x: int = 0
	var step_y: int = 0
	var t_max_x: float = INF
	var t_max_y: float = INF
	var t_delta_x: float = INF
	var t_delta_y: float = INF
	if not is_zero_approx(delta.x):
		step_x = 1 if delta.x > 0.0 else -1
		var next_x: float = float(gx + (1 if step_x > 0 else 0)) * _cell_size
		t_max_x = (next_x - a.x) / delta.x
		t_delta_x = _cell_size / absf(delta.x)
	if not is_zero_approx(delta.y):
		step_y = 1 if delta.y > 0.0 else -1
		var next_y: float = float(gy + (1 if step_y > 0 else 0)) * _cell_size
		t_max_y = (next_y - a.y) / delta.y
		t_delta_y = _cell_size / absf(delta.y)

	var guard: int = 0  ## 防御性上限（正常长线段远达不到）
	while (gx != end_x or gy != end_y) and guard < 8192:
		guard += 1
		if t_max_x < t_max_y:
			gx += step_x
			t_max_x += t_delta_x
		else:
			gy += step_y
			t_max_y += t_delta_y
		cells.append(Vector2i(gx, gy))
	return cells


static func _body_fits_at(center: Vector2) -> bool:
	## 敌人碰撞体以 center 为中心时，是否「站得下」。两层，取更严的那层：
	##
	##   ① **真实碰撞盒**（`_body_blocked_by`）：身体是否与任何图块碰撞盒相交。
	##      这是唯一能正确处理"半格碰撞"（自动图块边缘变体）的判据 ——
	##      真实地图上"身体压在薄边上"必须判为不可通行；
	##   ② **按格覆盖**：身体 AABB 覆盖到的每一格都必须是可行走格。
	##      ① 在碰撞盒数据缺失/不完整时会漏判：实测合成夹具上，一条恰好沿格线走的
	##      对角线能"从两格的夹缝里挤过去"（网格步进只经过 (9,10)、(10,10)，绕开了
	##      真正的墙格 (10,9)），而身体其实压住了它。② 用包围盒覆盖区间把它补回来。
	##
	## 两层都必要：只有 ① 会漏判缺数据的情形，只有 ② 会把半格碰撞判错。
	if _body_blocked_at(center):
		return false
	var hx: float = _body_half.x
	var hy: float = _body_half.y
	for gx in range(floori((center.x - hx) / _cell_size), floori((center.x + hx) / _cell_size) + 1):
		for gy in range(floori((center.y - hy) / _cell_size), floori((center.y + hy) / _cell_size) + 1):
			if not _is_walkable(Vector2i(gx, gy)):
				return false
	return true

# ═══════════════════════════════════════
# 网格工具
# ═══════════════════════════════════════

static func notify_map_changed() -> void:
	## 场景机关（可爆破墙 blast_wall 等）在运行期改动了图块/碰撞后调用：
	## 清空全部静态缓存并要求重建 A* 网格，下一次 _is_walkable/_ensure_astar_grid
	## 访问时按新地形重建（与场景重载失效走同一套保护，分帧构建会安全中止）。
	_tile_walk_cache.clear()
	_stand_cache.clear()
	_cell_rect_cache.clear()
	_astar_grid = null
	_grid_building = false


static func _find_all_tilemaps() -> void:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		_search_tilemaps((main_loop as SceneTree).root)
	_ensure_roles()


static func _ensure_roles() -> void:
	## 图层角色只在图层集合变化时算一次。**不要在热路径里直接 to_lower() + 子串搜索**：
	## 那会为每格每层分配两个临时字符串，6.5 万格 × 9 次 ≈ 60 万次分配，
	## 实测是旧实现里仅次于几何求交的第二大开销。
	if _tilemap_roles.size() == _tilemaps.size():
		return
	_tilemap_roles.clear()
	for tm in _tilemaps:
		_tilemap_roles.append(_layer_role(tm.name.to_lower()) if is_instance_valid(tm) else ROLE_SOLID_HINT)

static func _search_tilemaps(node: Node) -> void:
	if node is TileMapLayer:
		_tilemaps.append(node)
	for child in node.get_children():
		_search_tilemaps(child)


func _world_to_grid(world: Vector2) -> Vector2i:
	return Vector2i(floori(world.x / _cell_size), floori(world.y / _cell_size))


func _grid_to_world(gp: Vector2i) -> Vector2:
	## 航点取「该格的立足点」而非几何中心：窄通道里立足点会偏到能走的那一侧。
	## 若直接用格心，通道格的格心可能压在自动图块漏进来的碰撞边上 →
	## 航点落在墙里 → 敌人顶着那面墙不动（这正是"拐不了弯"的直接成因）。
	var off: Vector2 = _stand_center(gp)
	if off == NO_STAND:
		off = Vector2(_cell_size, _cell_size) * 0.5
	return Vector2(float(gp.x) * _cell_size, float(gp.y) * _cell_size) + off


func _to_world_array(grid_path: Array[Vector2i]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for gp in grid_path:
		result.append(_grid_to_world(gp))
	return result


func _find_nearest_walkable(pos: Vector2i) -> Vector2i:
	## 以 pos 为中心由近及远找第一个可行走格；找不到返回 NO_CELL。
	for r in range(1, 8):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n: Vector2i = Vector2i(pos.x + dx, pos.y + dy)
				if _is_walkable(n):
					return n
	return NO_CELL


# ═══════════════════════════════════════
# 可行走性检测（32×32 原生图块 + 碰撞多边形中心检测）
# ═══════════════════════════════════════

static func _is_walkable(gp: Vector2i) -> bool:
	## 以「敌人碰撞体能否站得下」为唯一判据：
	##   ① 该格必须有 ground/floor 图块 —— 否则是地图外的空洞，不该走；
	##   ② wall 层图块 → 整格硬阻挡（该层按约定表示实体墙）；
	##   ③ 其余情况把碰撞体放到 `_stand_center(gp)` 求出的立足点，与**所有图层**的
	##      碰撞多边形求交，不相交即可行走。
	##
	## 与旧规则（任一图块带碰撞 → 整格不可行走）的区别就在第 ③ 步：
	## 旧规则会把「自动图块漏进通道格的一条薄碰撞边带」当成整格墙，
	## 于是 32px 窄通道被误判为走不通 —— 那正是敌人绕不过窄道的原因。
	if _tile_walk_cache.has(gp):
		return _tile_walk_cache[gp]

	# 检测静态缓存是否失效（场景重载后）
	if not _tilemaps.is_empty() and not is_instance_valid(_tilemaps[0]):
		_tilemaps.clear()
		_tile_walk_cache.clear()
		_stand_cache.clear()
		_cell_rect_cache.clear()
		_astar_grid = null  ## 场景重载 → 失效网格
		_grid_building = false  ## 中断分帧构建
		_find_all_tilemaps()

	var blocks: Array[Rect2] = []
	var mask: int = _scan_cell(gp, blocks)
	var stand: Vector2 = NO_STAND
	if mask == SCAN_GROUND:
		stand = _solve_stand(gp, blocks)
		if stand != NO_STAND:
			_stand_cache[gp] = stand  ## 顺手缓存：运行期 _grid_to_world / 推墙 / 重插都要用
	var walkable: bool = stand != NO_STAND

	_tile_walk_cache[gp] = walkable

	## 诊断打印必须挂在 debug 开关下面。headless 下控制台 I/O 极慢 ——
	## 早期这里是「前 10 格无条件打印」，实测在基准里被记成了 140ms 的开销
	## （150ms 的判定里 9.5ms 是真正计算，其余全是这 10 行 print 的 I/O）。
	if Global.debug_visuals and _tile_walk_cache.size() < 10:
		print("[A* DEBUG] 图块 %s → walkable=%s mask=%d 立足点=%s" % [
			str(gp), str(walkable), mask, str(stand)])

	return walkable


# ── 图层角色 ──

static func _layer_role(name_lower: String) -> int:
	## 按节点名子串判定图层角色。**未知层名按「只阻挡、不提供地面」处理**：
	## 宁可把它当墙，也不要当空气 —— 否则新加的图层（如"铁门""MapLimit"）会被
	## 寻路完全忽略，敌人直接穿过去。
	if "wall" in name_lower:
		return ROLE_WALL
	if "ground" in name_lower or "floor" in name_lower:
		return ROLE_GROUND
	return ROLE_SOLID_HINT


static func _scan_cell(gp: Vector2i, blocks: Array[Rect2]) -> int:
	## 一次遍历拿齐「有地面 / 有 wall 层 / 自家碰撞盒」，返回位掩码 SCAN_GROUND|SCAN_WALL。
	##
	## 早期把这三件事拆成 _has_ground_at / _has_wall_at / _cell_block_rects 三个函数，
	## 同一格要做三遍图层查询（每遍每层一次 get_cell_tile_data）。6.5 万格下这是纯浪费，
	## 实测合并后整图判定再快约 25%。热路径统一走这里；单独查询保留下面两个薄封装。
	blocks.clear()
	var mask: int = 0
	_ensure_roles()
	for i in range(_tilemaps.size()):
		var tm: TileMapLayer = _tilemaps[i]
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		var td: TileData = tm.get_cell_tile_data(gp)
		if td == null:
			continue
		var role: int = _tilemap_roles[i]
		if role == ROLE_GROUND:
			mask |= SCAN_GROUND
		elif role == ROLE_WALL:
			mask |= SCAN_WALL
			blocks.append(Rect2(0.0, 0.0, _cell_size, _cell_size))
			continue
		## ⚠ TileSet 可能**没有任何 physics layer**（纯视觉图块集 / 生成器产出的地图）。
		## 此时 get_collision_polygons_count(0) 会每格报
		## "Index p_layer_id = 0 is out of bounds (physics.size() = 0)" —— headless 下
		## 实测每帧上百条、整图构建刷出数千条 ERROR（第四关 Map0146 实测 9200 条）。
		## 无物理层就是"该 tileset 不提供碰撞"，直接跳过即可。
		if tm.tile_set.get_physics_layers_count() == 0:
			continue
		for pi in range(td.get_collision_polygons_count(0)):
			var pts: PackedVector2Array = td.get_collision_polygon_points(0, pi)
			if pts.size() < 3:
				continue
			## ⚠ Godot 的图块碰撞多边形是**以格心为原点**存储的（整格矩形存成 -16..16），
			## 本文件内部统一用「格左上角为原点（0..32）」的格内局部坐标，所以必须补半格偏移。
			## 漏掉这一步，整片碰撞几何会向左上错半格：墙格自己的判定仍然“像墙”，
			## 但**紧邻墙的格子会被墙的碰撞误判为站不下**（实测少认约 20% 的可行走格）。
			var minx: float = 1e9
			var maxx: float = -1e9
			var miny: float = 1e9
			var maxy: float = -1e9
			for p in pts:
				minx = minf(minx, p.x)
				maxx = maxf(maxx, p.x)
				miny = minf(miny, p.y)
				maxy = maxf(maxy, p.y)
			blocks.append(Rect2(minx + _cell_half, miny + _cell_half,
				maxx - minx, maxy - miny))
	## 顺手写入缓存（**空也要缓存**，否则无阻挡的走廊格每次都要重扫三层图块）：
	## 通视 / 路径复核 / 立足点求解都会按坐标反复问同一批格子。整格矩形共用常量数组，
	## 避免为 6 万格各分配一份。
	if blocks.is_empty():
		_cell_rect_cache[gp] = EMPTY_RECTS
	else:
		_cell_rect_cache[gp] = FULL_CELL_RECTS if _is_full_cell_only(blocks) else blocks.duplicate()
	return mask


static func _is_full_cell_only(blocks: Array[Rect2]) -> bool:
	for r in blocks:
		if r.position != Vector2.ZERO or r.size != Vector2(_cell_size, _cell_size):
			return false
	return true


static func _has_ground_at(gp: Vector2i) -> bool:
	_ensure_roles()
	for i in range(_tilemaps.size()):
		if _tilemap_roles[i] != ROLE_GROUND:
			continue
		var tm: TileMapLayer = _tilemaps[i]
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		if tm.get_cell_tile_data(gp) != null:
			return true
	return false


static func _has_wall_at(gp: Vector2i) -> bool:
	_ensure_roles()
	for i in range(_tilemaps.size()):
		if _tilemap_roles[i] != ROLE_WALL:
			continue
		var tm: TileMapLayer = _tilemaps[i]
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		if tm.get_cell_tile_data(gp) != null:
			return true
	return false


# ── 「站得下」判定 ──

static func _cell_block_rects(gp: Vector2i) -> Array[Rect2]:
	## 收集该格「自家」的碰撞盒（格内局部坐标 0..32）。wall 层记作整格矩形。
	##
	## 只取碰撞多边形的 AABB，不做精确多边形求交 —— 本工程图块碰撞体是轴对齐矩形
	## （VX Ace 自动图块转换产物），矩形的 AABB 就是它本身；万一出现非矩形，AABB 偏保守
	## （更容易判阻挡）。这一条 + 下面的解析式立足点，是把整图判定从「35 秒」拉回
	## 「百毫秒级」的关键：旧实现每格要跑最多 49 个候选位置，每次都做
	## Geometry2D.intersect_polygons（要分配多边形数组），单格 0.54ms。
	if _cell_rect_cache.has(gp):
		return _cell_rect_cache[gp]
	var out: Array[Rect2] = []
	_scan_cell(gp, out)   ## _scan_cell 内部会写回缓存
	return out


static func _union_rects(rects: Array[Rect2]) -> Rect2:
	var u: Rect2 = rects[0]
	for i in range(1, rects.size()):
		u = u.merge(rects[i])
	return u


static func _rects_hit(rects: Array[Rect2], origin: Vector2, body: Rect2) -> bool:
	## 矩形相交判定。**严格不等号**：恰好相切不算撞 —— 窄通道里身体必须能贴着漏边站，
	## 例如上边漏进 16px 时，身体顶边正好压在 16px 处应判为"站得下"。
	for r in rects:
		if r.position.x + origin.x < body.end.x and r.end.x + origin.x > body.position.x \
				and r.position.y + origin.y < body.end.y and r.end.y + origin.y > body.position.y:
			return true
	return false


static func _body_blocked_by(gp: Vector2i, center: Vector2, own: Array[Rect2]) -> bool:
	## 碰撞体（收缩 BODY_CLEARANCE）放在 center 时，是否与本格（own）或相邻格的碰撞盒相交。
	## 身体允许越格 → 连带检查覆盖到的相邻格；窄通道贴边行走正是靠这个。
	var half: Vector2 = Vector2(maxf(_body_half.x - BODY_CLEARANCE, 1.0), maxf(_body_half.y - BODY_CLEARANCE, 1.0))
	var body := Rect2(center - half, half * 2.0)
	var origin := Vector2(float(gp.x) * _cell_size, float(gp.y) * _cell_size)
	if _rects_hit(own, origin, body):
		return true
	## 身体完全落在本格内 → 不可能碰到邻居，省掉最多 3 次邻居采样
	if body.position.x >= origin.x and body.end.x <= origin.x + _cell_size \
			and body.position.y >= origin.y and body.end.y <= origin.y + _cell_size:
		return false
	for gx in range(floori(body.position.x / _cell_size), floori(body.end.x / _cell_size) + 1):
		for gy in range(floori(body.position.y / _cell_size), floori(body.end.y / _cell_size) + 1):
			if gx == gp.x and gy == gp.y:
				continue
			var norigin := Vector2(float(gx) * _cell_size, float(gy) * _cell_size)
			if _rects_hit(_cell_block_rects(Vector2i(gx, gy)), norigin, body):
				return true
	return false


static func _body_blocked_at(center: Vector2) -> bool:
	## 便捷入口：从坐标反推格子现取碰撞盒判定（供推墙校验 / 测试 / 调试使用）。
	var gp := Vector2i(floori(center.x / _cell_size), floori(center.y / _cell_size))
	return _body_blocked_by(gp, center, _cell_block_rects(gp))


static func _stand_center(gp: Vector2i) -> Vector2:
	## 该格内「敌人碰撞体站得下」的位置（返回相对格原点的偏移；无解返回 NO_STAND）。
	##
	## 三级策略，越靠前越便宜（整图 6.5 万格，这里的常数因子直接决定加载时长与每帧卡顿）：
	##   ① 本格没有任何碰撞盒 → 身体在格心不可能越格 → 直接返回格心，**零校验**；
	##   ② 有碰撞盒 → 由「阻挡贴哪条边」直接解出让开量：上边漏进来 16px 就让开 16+半身高，
	##      一次校验定胜负；
	##   ③ ② 无解或校验失败 → 退回环搜索兜底（阻挡落在格子中间这类少见形状）。
	## 结果按格缓存；"无解"不缓存 —— 运行时只有可行走格会被反复查询，省下 5 万条无用记录。
	if _stand_cache.has(gp):
		return _stand_cache[gp]

	var blocks: Array[Rect2] = []
	_scan_cell(gp, blocks)
	var best: Vector2 = _solve_stand(gp, blocks)
	if best != NO_STAND:
		_stand_cache[gp] = best
	return best


static func _solve_stand(gp: Vector2i, own: Array[Rect2]) -> Vector2:
	## 立足点求解（纯计算，不查图层、不写缓存）。
	var origin := Vector2(float(gp.x) * _cell_size, float(gp.y) * _cell_size)
	var mid := Vector2(_cell_size, _cell_size) * 0.5
	var best: Vector2 = NO_STAND

	if own.is_empty():
		best = mid
	else:
		var u: Rect2 = _union_rects(own)
		var full_block: bool = false
		for r in own:
			## 必须是**单个**矩形铺满整格：多块拼成的 union 即使横跨整格，中间也可能留有空隙
			if r.size.x >= _cell_size - STAND_HUG_EPS and r.size.y >= _cell_size - STAND_HUG_EPS:
				full_block = true
				break
		if full_block:
			best = NO_STAND  ## 单块铺满整格 → 必站不下，连搜索都不用做
		else:
			var half: Vector2 = Vector2(maxf(_body_half.x - BODY_CLEARANCE, 1.0), maxf(_body_half.y - BODY_CLEARANCE, 1.0))
			var full_x: bool = u.size.x >= _cell_size - STAND_HUG_EPS  ## 横贯整宽 ⇒ 是上下某侧的横带
			var full_y: bool = u.size.y >= _cell_size - STAND_HUG_EPS  ## 纵贯整高 ⇒ 是左右某侧的竖带
			var candidate: Vector2 = mid
			## 让开量只有在「贴边 **且另一轴铺满**」时才能断言：否则阻挡可能只占该边的一部分，
			## 剩下的角落仍可能站得下 —— 那种情况交给下面的校验 + 环搜索处理。
			## （早期漏了这个前提，导致多块阻挡时 union 的 AABB 把整格判死，实测少认了约 20% 的可行走格。）
			if u.position.x <= STAND_HUG_EPS and full_y:
				candidate.x = u.end.x + half.x        ## 左侧竖带 → 往右让
			elif u.end.x >= _cell_size - STAND_HUG_EPS and full_y:
				candidate.x = u.position.x - half.x   ## 右侧竖带 → 往左让
			if u.position.y <= STAND_HUG_EPS and full_x:
				candidate.y = u.end.y + half.y        ## 上方横带 → 往下让
			elif u.end.y >= _cell_size - STAND_HUG_EPS and full_x:
				candidate.y = u.position.y - half.y   ## 下方横带 → 往上让

			var in_cell: bool = candidate.x >= 0.0 and candidate.x <= _cell_size \
				and candidate.y >= 0.0 and candidate.y <= _cell_size
			if in_cell and not _body_blocked_by(gp, origin + candidate, own):
				best = candidate
			else:
				## 解析解被否（让开量超格 / 阻挡落在格子中间 / union 与实际情况不符）
				## → 一律交给环搜索兜底。
				## **不要在这里判死**：union 只是各碰撞盒的并集 AABB，比实际阻挡大；
				## 只要它在某条边上"看起来贴边"，让开量就可能被高估到格内范围之外，
				## 而该边其实只挡住了格子的一部分（实测这样会少认约 20% 的可行走格）。
				best = _search_stand(gp, origin, mid, own)

	return best


static func _search_stand(gp: Vector2i, origin: Vector2, mid: Vector2, own: Array[Rect2]) -> Vector2:
	## 兜底环搜索：由近及远在格内试探（立足点留在格内，身体可以越格）。
	for ring in range(1, STAND_SEARCH_RINGS + 1):
		var r: float = STAND_SEARCH_STEP * float(ring)
		var offsets: Array[Vector2] = []
		for i in range(-ring, ring + 1):
			offsets.append(Vector2(float(i) * STAND_SEARCH_STEP, -r))
			offsets.append(Vector2(float(i) * STAND_SEARCH_STEP, r))
		for i in range(-ring + 1, ring):
			offsets.append(Vector2(-r, float(i) * STAND_SEARCH_STEP))
			offsets.append(Vector2(r, float(i) * STAND_SEARCH_STEP))
		for off in offsets:
			var candidate: Vector2 = mid + off
			if candidate.x < 0.0 or candidate.y < 0.0 or candidate.x > _cell_size or candidate.y > _cell_size:
				continue
			if not _body_blocked_by(gp, origin + candidate, own):
				return candidate
	## 最后补一轮"贴格边"的位置：4px 网格可能正好错过可行点
	## （如上边漏 16px 时需要恰好让开 16+半身高，而网格只落在 28 / 32）。
	for cy: float in [_cell_size, 0.0, mid.y]:
		for cx: float in [_cell_size, 0.0, mid.x]:
			var c := Vector2(cx, cy)
			if not _body_blocked_by(gp, origin + c, own):
				return c
	return NO_STAND
