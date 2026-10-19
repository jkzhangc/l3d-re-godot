extends RefCounted

## ── 架构定位 ──
## 系统：战斗判定工具 ｜ 层：工具类（RefCounted，无 class_name）
## 联机：Host 与单机共用同一套判据常量（两端行为必须一致）
## 职责：收敛玩家近战/推击与联机 Host 近战/推击四处「命中结算」里**真正共享**的部分：
##       碰撞层掩码、生死/玩家判据、溅射衰减、collider→敌人实体归属解析。
## 依赖：无（纯静态工具）
##
## 【为什么无 class_name】本项目约定：新建脚本的 class_name 要等编辑器重扫才会写进
## global_script_class_cache，headless 跑用例时那份缓存是旧的，按类名引用会直接 Parse Error。
## 因此统一用 `preload("res://script/hit_resolver.gd")` 常量调用（与 SpawnSpotResolver 同款）。
##
## 【为什么只抽共享部分，不合并整个命中流程（2026-10-08 决策）】
## 四处"重复"经逐行核对后**并非真正重复**，差异是本质性的：
##   · 单机走 Area2D `get_overlapping_bodies/areas`；Host 走 `intersect_shape` 物理直查；
##   · 单机近战有背刺/即死成就/章节统计/命中特效音效，Host 近战没有（走表现广播）；
##   · 单机推击遍历 `enemy` 组做溅射，Host 推击遍历 `_enemies` 表；
##   · Host 近战有 4 帧命中窗口重试，单机没有；
##   · `take_damage` 参数个数不同（Host 多传 source_id）。
## 强行合并控制流等于改写战斗行为 —— 因此本工具只收敛「常量 + 判据 + 几何」，
## 四处各自的控制流保持原样，把各自差异显式留在调用点。

## 敌人受击判定掩码：层 4（敌人物理体 bit=8）+ 层 5（受击碰撞体 bit=16）= 24。
## 与 player.tscn / enemy.tscn 的层定义同口径（见 project.godot [layer_names] 与 README）。
## ⚠ 这四处曾各自硬编码裸数字 24；集中到常量后改层定义只需动这里。
const ENEMY_HIT_MASK: int = (1 << 3) | (1 << 4)  ## = 24
## 玩家本体层（layer 3 = 4）。players 没有独立受击盒，子弹靠 body_entered 命中本体。
const PLAYER_HIT_MASK: int = 1 << 2  ## = 4
const FRIENDLY_FIRE_MIN_DAMAGE: float = 1.0
const FRIENDLY_FIRE_MAX_DAMAGE: float = 2.0


## 返回当前是否为联机房间。单机不启用友伤规则，保持原有伤害语义。
static func is_online_session() -> bool:
	var net: Node = Engine.get_main_loop().get_root().get_node_or_null("Net") \
		if Engine.get_main_loop() else null
	return net != null and net.has_method("is_online_session") and bool(net.call("is_online_session"))


## 读取 Host 下发/维护的房间开关。缺失或非联机时一律关闭。
static func friendly_fire_enabled() -> bool:
	var net: Node = Engine.get_main_loop().get_root().get_node_or_null("Net") \
		if Engine.get_main_loop() else null
	return is_online_session() and net != null and bool(net.get("friendly_fire_enabled"))


## 仅单机或 Host 可以结算伤害；客户端只能消费权威快照与表现。
static func is_damage_authority() -> bool:
	if not is_online_session():
		return true
	var net: Node = Engine.get_main_loop().get_root().get_node_or_null("Net")
	return is_instance_valid(net) and bool(net.get("is_host"))


## 来源释放后仍用生成时保存的阵营标记，不能对失效节点调用方法。
static func is_friendly_player_hit(source: Node, target: Node,
		source_is_player_origin: bool = false) -> bool:
	if not is_player(target) or source == target:
		return false
	return is_player(source) if is_instance_valid(source) else source_is_player_origin


## 是否允许一次玩家来源命中进入友伤结算。不会随机，调用方可先用它决定是否计为有效命中。
static func is_player_damage_allowed(source: Node, target: Node, online: bool,
		enabled: bool, source_is_player_origin: bool = false) -> bool:
	return not is_friendly_player_hit(source, target, source_is_player_origin) or not online or enabled


## 统一玩家来源伤害解析：返回负数表示整次命中无效；有效友伤只在此处随机一次。
## source_is_player_origin 用于爆炸/火海等来源节点暂时缺失时，防止在线无来源绕过开关。
## 可注入模式的纯判定入口，供 tools 行为测试复用。
static func resolve_player_damage_for_mode(raw_damage: float, source: Node, target: Node,
		online: bool, enabled: bool, source_is_player_origin: bool = false) -> float:
	if not is_friendly_player_hit(source, target, source_is_player_origin):
		return raw_damage
	if not is_player_damage_allowed(source, target, online, enabled, source_is_player_origin):
		return -1.0
	if not online or raw_damage <= 0.0:
		return raw_damage
	return float(randi_range(int(FRIENDLY_FIRE_MIN_DAMAGE), int(FRIENDLY_FIRE_MAX_DAMAGE)))


## 目标是否已死亡（`_is_dead`）。所有实体（玩家/敌人）都有该字段。
static func is_dead(node: Node) -> bool:
	return node != null and node.get("_is_dead") == true


## 目标是否处于移除/倒地路径（`_is_dead` 或 `_is_dying`）。
## 单机近战/推击用这个；Host 侧（只认 `_is_dead`）**不要**改用它，见文件头说明。
static func is_removed(node: Node) -> bool:
	if node == null:
		return true
	return node.get("_is_dead") == true or node.get("_is_dying") == true


## 是否为玩家实体（近战/推击必须排除玩家，只打敌人）。
static func is_player(node: Node) -> bool:
	return is_instance_valid(node) and node.is_in_group("player")


## 溅射击退的力度衰减：边缘 = 50%、中心 = 100%。
## 单机推击（PlayerShoveState）与 Host 推击（NetworkWorld）共用同一条曲线，
## 保证两端手感一致。`radius <= 0` 时返回 1.0（调用方本应在此之前闸掉）。
static func splash_falloff(distance: float, radius: float) -> float:
	if radius <= 0.0:
		return 1.0
	return 1.0 - (distance / radius) * 0.5


## 把物理查询返回的 collider 解析为受管敌人实体。
##
## Host 的 `intersect_shape` 可能命中的是敌人的**子碰撞体**（HurtArea 的子节点）而非敌人本体，
## 因此不能只做 `collider == enemy`，还要接受「collider 是 enemy 的后代」。
##
## `resolve` 是把 `_enemies` 表项还原为实体的回调（如 NetworkWorld._resolve_enemy_entry）；
## 传入 `entried_enemies`（表项数组）与 `resolve`，返回首个匹配的敌人（无匹配返回 null）。
static func find_owning_enemy(collider: Node, entries: Array, resolve: Callable,
		require_alive: bool = true) -> Node2D:
	if not is_instance_valid(collider):
		return null
	for entry: Variant in entries:
		var enemy: Node2D = resolve.call(entry) as Node2D
		if not is_instance_valid(enemy):
			continue
		if require_alive and is_dead(enemy):
			continue
		if collider == enemy or enemy.is_ancestor_of(collider):
			return enemy
	return null
