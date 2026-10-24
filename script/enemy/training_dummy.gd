extends CharacterBody2D

## ── 架构定位 ──
## 系统：测试工具 ｜ 层：开发者工具（只在调试地图里用）
## 联机：不参与（不注册网络实体；联机请用真敌人）
## 职责：不会移动、不会还手、**血量无限**的训练木偶，用来测武器伤害 / 暴击率；
##       被「即死」或「背刺」命中时会死亡，`revive_delay` 后自动复活并保留累计统计；
##       一段时间没被打就自动清零计数，方便连续测不同武器。
## 依赖：DamageNumber（飘字）、Global（像素字体）

## ── 接口契约 ──
## 受击入口与 `Enemy.take_damage()` 前 11 个参数**签名一致**：
##   子弹直击（9 参）、近战（9 参）、爆炸（9 参）、火海（11 参）都能直接调用。
## 另外必须提供 `_is_dead` / `instant_kill_immune` / `is_backstab_hit()` / `apply_backstab()`：
##   · `Bullet` 会读 `instant_kill_immune` 判断即死是否生效（**字段缺了会 null 崩**）；
##   · 近战/子弹会先问 `is_backstab_hit()` 再决定是否走 `apply_backstab()`。
## 因为血量不下降，`hp_before == hp_after`，章节伤害统计 / 成就不会被木偶污染。

signal dummy_died()
signal dummy_revived()

## 即死哨兵值：`Bullet` 的覚醒「集中射撃」把伤害拉成 max(99999)（bullet.gd:377/499）。
## 木偶血量是无限的，只能靠这个哨兵值识别「这一击是即死」，然后走死亡 → 复活。
const INSTANT_KILL_DAMAGE: float = 99999.0
## 背刺判据与 `Enemy.BACKSTAB_FACING_DOT` 一致：攻击方向与木偶朝向同向 = 从背后打到。
const BACKSTAB_FACING_DOT: float = 0.7
const DIR_VECTORS: Array[Vector2] = [Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT, Vector2.UP]

@export var dummy_title: String = "训练木偶"
## 显示用的行走图（4 列 × 3 帧 × 4 行朝向，与角色/敌人同一套图集布局）。
## 默认 = 男丧尸行走图；想区分不同木偶就在实例上换图。
@export var body_texture: Texture2D = null
## 用图集第几格（4 格一行）、第几帧（0/1/2）、朝哪个方向（0下 1左 2右 3上）。
## `body_direction` 同时是**背刺判定用的朝向**：从它背后打才触发背刺即死。
@export var body_char_index: int = 0
@export var body_frame: int = 1
@export var body_direction: int = 0
## 血量上限（只用来显示 / 兜底；实际永远保持满血）。
@export var max_hp: float = 999999.0
## 命中特效 / 飘字的基准偏移。默认 (0,0) = 与真敌人一致（敌人默认值也是零）。
@export var hurt_effect_offset: Vector2 = Vector2.ZERO
## 被即死 / 背刺打死之后多久复活（秒）。
@export var revive_delay: float = 1.5
## 多久没被攻击就自动清零计数（秒；0 = 不自动清零）。
@export var stats_idle_reset_sec: float = 5.0
## 头顶标签显示累计统计。
@export var show_stats: bool = true
## 每次受击打一条日志（批量刷伤害时可关掉）。
@export var log_each_hit: bool = true
## 受击闪红。
@export var hit_flash: bool = true

## 敌人 / 子弹 / 近战都按这个字段判「已死亡」，木偶必须提供，否则会一直被打。
var _is_dead: bool = false
var _is_dying: bool = false
## 即死免疫：木偶**不免疫**（false）→ 覚醒即死弹能把它打死再复活。
## ⚠ 这个字段不能删：`Bullet._hit()` 读它时用 `bool(get(...))`，字段不存在会 null 崩。
var instant_kill_immune: bool = false
## 血量（保持满值，永远不减）。
var current_hp: float = 0.0

var _hits: int = 0
var _crits: int = 0
var _total: float = 0.0
var _best: float = 0.0
var _best_crit: bool = false
var _instant_kills: int = 0
var _backstabs: int = 0
var _revives: int = 0
## 本次命中由 `apply_backstab()` 改写 → take_damage 里据此走背刺死亡。
var _backstab_this_hit: bool = false

var _flash_tween: Tween = null
var _idle_timer: Timer = null

const DamageNumber := preload("res://script/damage_number.gd")

## 与 PlayerSpriteRenderer / Enemy 一致的图集布局常量。
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRS: int = 4

@onready var _label: Label = get_node_or_null("StatsLabel")
@onready var _sprite: Sprite2D = get_node_or_null("Sprite2D")


func _ready() -> void:
	current_hp = max_hp
	add_to_group("training_dummy")
	_apply_body()
	if _label != null:
		Global.apply_ui_font(_label, 12)
		_label.z_index = 2
	if stats_idle_reset_sec > 0.0:
		_idle_timer = Timer.new()
		_idle_timer.one_shot = true
		_idle_timer.timeout.connect(_on_idle_timeout)
		add_child(_idle_timer)
	_update_label()
	queue_redraw()


# ═══════════════════════════════════════
# 受击
# ═══════════════════════════════════════

## 与 Enemy.take_damage 前 11 参一致；击退/硬直/元素一律忽略（木偶不动）。
func take_damage(damage: float, _knockback_force: float = 0.0,
		_direction: Vector2 = Vector2.ZERO, is_headshot: bool = false,
		_knockback_stun: float = 0.0, _hitstun: float = 0.0,
		_source_id: int = 0, _element: int = 0, _source_is_explosive: bool = false,
		_shooter: Node = null, _source_is_player_origin: bool = false) -> void:
	if _is_dead:
		return
	## 血量无限：先回满再统计（不产生 hp 差，章节统计不会记到木偶头上）。
	current_hp = max_hp
	if damage <= 0.0:
		_backstab_this_hit = false
		return

	## 背刺（`apply_backstab()` 已把伤害改成 current_hp + 1）→ 直接即死级。
	if _backstab_this_hit:
		_backstab_this_hit = false
		_backstabs += 1
		_spawn_number("背刺", Color(0.85, 0.55, 1.0))
		_log_hit("背刺即死")
		_die("背刺")
		return
	_backstab_this_hit = false

	if damage >= INSTANT_KILL_DAMAGE:
		_instant_kills += 1
		_spawn_number("即死", Color(1.0, 0.3, 0.3))
		_log_hit("即死")
		_die("即死")
		return

	_hits += 1
	_crits += 1 if is_headshot else 0
	_total += damage
	if damage > _best:
		_best = damage
		_best_crit = is_headshot
	_spawn_number(str(int(round(damage))),
		Color(1.0, 0.85, 0.2) if is_headshot else Color.WHITE)
	_flash()
	if log_each_hit:
		_log_hit("%d%s" % [int(round(damage)), "（暴击）" if is_headshot else ""])
	_update_label()
	_restart_idle_timer()


## 背刺判定：与 `Enemy.is_backstab_hit()` 同一条判据 ——
## 攻击方向与木偶朝向同向（dot ≥ 0.7）说明是从背后打进来的。
## 木偶的「朝向」= `body_direction`（默认朝下），所以想测背刺就绕到它的上方、朝下砍。
func is_backstab_hit(direction: Vector2) -> bool:
	if _is_dead or direction == Vector2.ZERO:
		return false
	var facing: Vector2 = DIR_VECTORS[clampi(body_direction, 0, DIRS - 1)]
	return facing.dot(direction.normalized()) >= BACKSTAB_FACING_DOT


## 背刺结算：把伤害拉到「当前血量 + 1」——和敌人一样走即死路径（只是木偶会复活）。
func apply_backstab(damage: float) -> float:
	_backstab_this_hit = true
	return maxf(damage, current_hp + 1.0)


## 手动清零（调试 / 换武器时用；一段时间不被打也会自动清）。
func reset_stats() -> void:
	_clear_counters(false)
	if log_each_hit:
		print("[%s] 统计已清零" % dummy_title)


func get_stats() -> Dictionary:
	return {
		"hits": _hits,
		"crits": _crits,
		"total": _total,
		"best": _best,
		"best_crit": _best_crit,
		"instant_kills": _instant_kills,
		"backstabs": _backstabs,
		"revives": _revives,
		"crit_rate": float(_crits) / float(_hits) if _hits > 0 else 0.0,
		"average": _total / float(_hits) if _hits > 0 else 0.0,
	}


func _clear_counters(keep_revives: bool) -> void:
	_hits = 0
	_crits = 0
	_total = 0.0
	_best = 0.0
	_best_crit = false
	_instant_kills = 0
	_backstabs = 0
	if not keep_revives:
		_revives = 0
	_update_label()


func _restart_idle_timer() -> void:
	if _idle_timer != null and stats_idle_reset_sec > 0.0:
		_idle_timer.start(stats_idle_reset_sec)


func _on_idle_timeout() -> void:
	## 一段时间没被打 → 清零伤害计数（复活次数不重置，它不属于"伤害统计"）。
	if _hits == 0 and _instant_kills == 0 and _backstabs == 0:
		return
	print("[%s] %.0f 秒未被攻击 → 伤害计数已重置" % [dummy_title, stats_idle_reset_sec])
	_clear_counters(true)


# ═══════════════════════════════════════
# 死亡 / 复活
# ═══════════════════════════════════════

func _die(reason: String = "即死") -> void:
	_is_dead = true
	_is_dying = true
	## 关掉受击体：死亡期间子弹/近战都打不到它（与真敌人的 `_is_dead` 门一致）。
	_deferred_set_collision(false)
	modulate = Color(1, 1, 1, 1)
	visible = false
	dummy_died.emit()
	print("[%s] 被%s命中 → 死亡，%.1fs 后复活" % [dummy_title, reason, revive_delay])
	await get_tree().create_timer(revive_delay, false).timeout
	if not is_inside_tree():
		return
	_revive()


func _revive() -> void:
	_revives += 1
	_is_dead = false
	_is_dying = false
	current_hp = max_hp
	_deferred_set_collision(true)
	visible = true
	modulate = Color(1, 1, 1, 1)
	queue_redraw()
	_update_label()
	dummy_revived.emit()
	print("[%s] 已复活（累计复活 %d 次）" % [dummy_title, _revives])


func _deferred_set_collision(enabled: bool) -> void:
	var shape: CollisionShape2D = get_node_or_null("CollisionShape2D")
	if shape != null:
		## 物理回调期间改碰撞会报错 → 统一延迟到帧末。
		shape.set_deferred("disabled", not enabled)


# ═══════════════════════════════════════
# 表现
# ═══════════════════════════════════════

func _spawn_number(text: String, color: Color) -> void:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	DamageNumber.spawn(global_position + hurt_effect_offset, 0.0,
		tree.current_scene, 0, color, text)


func _flash() -> void:
	if not hit_flash:
		return
	modulate = Color(2.2, 0.55, 0.55)
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_property(self, "modulate", Color.WHITE, 0.12)


func _log_hit(text: String) -> void:
	var st: Dictionary = get_stats()
	print("[%s] 命中 %s ｜ 累计 %d 次 ｜ 平均 %.1f ｜ 最高 %d%s ｜ 暴击 %d（%.1f%%）%s" % [
		dummy_title, text, st["hits"], st["average"], int(st["best"]),
		"（暴击）" if st["best_crit"] else "",
		st["crits"], float(st["crit_rate"]) * 100.0,
		("｜ 即死 %d 次 ｜ 背刺 %d 次" % [st["instant_kills"], st["backstabs"]])
			if int(st["instant_kills"]) > 0 or int(st["backstabs"]) > 0 else "",
	])


func _update_label() -> void:
	if _label == null:
		return
	if not show_stats:
		_label.visible = false
		return
	var st: Dictionary = get_stats()
	var lines: Array[String] = [dummy_title]
	lines.append("命中 %d · 暴击 %.1f%%" % [st["hits"], float(st["crit_rate"]) * 100.0])
	lines.append("总伤 %d · 均 %.1f" % [int(st["total"]), st["average"]])
	lines.append("最高 %d%s" % [int(st["best"]), "（暴击）" if st["best_crit"] else ""])
	if int(st["instant_kills"]) > 0 or int(st["backstabs"]) > 0 or int(st["revives"]) > 0:
		lines.append("即死 %d · 背刺 %d · 复活 %d" % [
			st["instant_kills"], st["backstabs"], st["revives"]])
	_label.text = "\n".join(lines)


## 把导出参数应用到 Sprite2D：图集裁格（4 列 × 3 帧 / 4 行朝向）。
## 与 PlayerSpriteRenderer 的取值口径一致，改导出参数后调本函数即可刷新。
func _apply_body() -> void:
	if _sprite == null:
		return
	if body_texture != null:
		_sprite.texture = body_texture
	if _sprite.texture == null:
		_sprite.visible = false
		return
	_sprite.visible = true
	_sprite.centered = true
	_sprite.region_enabled = true
	var tex_w: int = _sprite.texture.get_width()
	var tex_h: int = _sprite.texture.get_height()
	var col: int = clampi(body_char_index, 0, CHARS_PER_ROW - 1)
	var row: int = maxi(0, body_char_index / CHARS_PER_ROW)
	var frame: int = clampi(body_frame, 0, 2)
	var dir: int = clampi(body_direction, 0, DIRS - 1)
	var x: int = clampi(col * FRAME_W * 3 + frame * FRAME_W, 0, maxi(0, tex_w - FRAME_W))
	var y: int = clampi(row * FRAME_H * DIRS + dir * FRAME_H, 0, maxi(0, tex_h - FRAME_H))
	_sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
	queue_redraw()


## 只画脚下一小块影子（行走图由 Sprite2D 画）。
func _draw() -> void:
	draw_set_transform(Vector2(0, 3), 0.0, Vector2(1.0, 0.42))
	draw_circle(Vector2.ZERO, 13.0, Color(0, 0, 0, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
