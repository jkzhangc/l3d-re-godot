class_name EnemyExhaustedState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 决定时长；Client 经快照 visual_char_index 同步倒地帧，无需专用网络字段。
## 职责：狂暴力竭（クリムゾンヘッド 专属）：狂暴累计约 10 秒后「力竭倒地」1 秒，
##       然后**直接换回普通形态**继续行动。
## 依赖：State、enemy 实体（variant_rage_texture / variant_rage_exhaust_down_seconds / set_rage）
##
## 原作依据（readme enemy.html クリムゾンヘッド条）：
##   「中身はエキストラ（一般人）であるためこの状態で１０秒ほど走り回されると
##     倒れてしまうこともあるとかないとか。」
## 即：**跑约 10 秒会倒**——不是变回普通丧尸，是累垮。本项目保留这个「累垮」机制。
##
## 设计定稿（2026-11-04 用户口径）：
##   · 倒地**只持续 1 秒**，不做任何过渡/动作动画；
##   · 倒地姿势直接用**狂暴图的第 7 格**（那张图里就是趴/倒的一格）；
##     ⚠ 有些角色的狂暴图第 7 格是空的 → 退回**第 4 格**（有内容的一格）；
##   · 起来时**直接切成普通形态的第 1 格**，不播起身动画。
##   比起旧实现（借用死亡帧躺 3.5s + 趴 1.2s），这条更接近"累了一下爬起来"的观感。

## 倒地时长兜底值（秒）。实际取 `enemy.variant_rage_exhaust_down_seconds`，
## 那是个 @export，策划可在 ZombieVariant 里逐种调；这里只在字段为 0 时兜底。
const DOWN_SECONDS: float = 1.0
## 狂暴图里的倒地格；该格为空时用的替身格（用户指认）。
const DOWN_CHAR_INDEX: int = 7
const DOWN_CHAR_INDEX_FALLBACK: int = 4
## 起身后普通形态站立用的格（用户指认）。
const STAND_CHAR_INDEX: int = 1

## 贴图 → 「第 7 格有没有内容」的缓存（一个变体的图只扫一次）。
static var _has_down_art_cache: Dictionary = {}

var _down_timer: float = 0.0
## 进入本状态那一刻是否已经在狂暴中。倒地**本来就发生在狂暴期间**，
## 旧实现的「再次狂暴就立刻起身」分支直接拿 `character._rage` 判，
## 结果每帧都命中 → 倒地只持续 1 帧（玩家根本看不到趴下），
## `_exhausted` 也就永远不复位 → 整局只可能触发一次。
var _rage_at_enter: bool = false


func enter() -> void:
	var enemy: Node2D = character
	enemy.velocity = Vector2.ZERO
	enemy.update_moving(false)
	var down: float = enemy.variant_rage_exhaust_down_seconds
	_down_timer = down if down > 0.0 else DOWN_SECONDS
	_rage_at_enter = enemy._rage
	enemy._refresh_sprite_with_index(_down_char_index(enemy))


func exit() -> void:
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		return
	_down_timer -= delta
	## 只有「倒地期间**又被新一波尸潮重新点燃**」（false → true）才提前起身扑人。
	## ⚠ 不能直接判 `character._rage`：倒地本来就发生在狂暴中，那样每帧都会命中，
	##   倒地只持续 1 帧、`_exhausted` 永远不复位（旧实现的实际表现）。
	if not _rage_at_enter and character._rage:
		transition_requested.emit("Chase")
		return
	if _down_timer > 0.0:
		return
	var enemy: Node2D = character
	enemy._exhausted = false
	enemy.set_rage(false)  ## 换回普通行走图
	## 直接落普通形态的 1 号格（用户指定索引 1），不播起身动画。
	## ⚠ 这里**同时改 `walk_char_index`**：否则下一帧 Chase 的 `update_moving(true)`
	##   会走 `_refresh_sprite()` 按原来的 `walk_char_index`(0) 重画，起身这一格等于没生效。
	##   若之后发现"累垮后走路姿势不对"，把下面这行删掉即可（只影响起身瞬间那一帧）。
	enemy.walk_char_index = STAND_CHAR_INDEX
	enemy._refresh_sprite_with_index(STAND_CHAR_INDEX)
	transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	# 倒地期间完全不移动
	pass


## 倒地该用哪一格：狂暴图第 7 格有内容就用 7，否则退回第 4 格。
func _down_char_index(enemy: Node2D) -> int:
	var tex: Texture2D = enemy.variant_rage_texture
	if tex == null:
		return DOWN_CHAR_INDEX_FALLBACK
	if _block_has_art(tex, DOWN_CHAR_INDEX):
		return DOWN_CHAR_INDEX
	return DOWN_CHAR_INDEX_FALLBACK


## 该贴图的第 idx 个角色格是否画了东西（只要有一个不透明像素就算有）。
## 布局与 VX Ace 一致：12 列 × 8 行帧，一个角色 = 3×4 帧。
static func _block_has_art(tex: Texture2D, idx: int) -> bool:
	var key: int = tex.get_instance_id()
	if _has_down_art_cache.has(key):
		return _has_down_art_cache[key]
	var has: bool = true   ## 取不到像素时默认"有"（宁可显示 7，也不要无谓退回 4）
	var img: Image = tex.get_image()
	if img != null:
		var cols: int = 4
		var fw: int = img.get_width() / (cols * 3)
		var fh: int = img.get_height() / 8
		if fw > 0 and fh > 0:
			var cb: int = idx % cols
			var rb: int = idx / cols
			has = false
			## 每 2 像素采一次即可：一整格 144×256，空白格全是透明，
			## 有内容的格子随便都能扫到（只跑一次，结果进缓存）。
			for y: int in range(rb * 4 * fh, rb * 4 * fh + 4 * fh, 2):
				for x: int in range(cb * 3 * fw, cb * 3 * fw + 3 * fw, 2):
					if img.get_pixel(x, y).a > 0.02:
						has = true
						break
				if has:
					break
	_has_down_art_cache[key] = has
	return has
