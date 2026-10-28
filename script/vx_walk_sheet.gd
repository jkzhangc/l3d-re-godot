extends RefCounted

## ── 架构定位 ──
## 系统：素材格式 / 行走图渲染 ｜ 层：工具类（RefCounted，纯静态）
## 联机：不涉及
## 职责：解析 VX Ace **行走图文件名**里的特殊前缀，并统一给出取帧矩形。
## 依赖：无（只读 Texture2D 的 resource_path / get_size）
## 被调用：所有渲染行走图的地方（玩家 / 敌人 / 拾取物 / 地图互动物 / 编辑器预览）

## ── VX Ace 文件名约定（RPG Maker VX Ace 素材规格）──
##   `$` 前缀 = **单角色文件**：整张图只有 1 个角色格（3 列帧 × 4 行方向），
##      单帧尺寸 = 图宽 / 3 × 图高 / 4。角色索引恒为 0。
##   `!` 前缀 = 取消「角色上移 4px」+ 草丛半透明（门 / 宝箱等物件）。
##      本项目不做那 4px 上移，`!` 对布局无影响 —— 这里只提供识别，不影响取帧。
##   其余 = 标准 8 角色表（4 列 × 2 行角色格；单帧 = 图宽 / 12 × 图高 / 8，通常 48×64）。
##
## ★为什么要统一到这里：`$` 素材（如变色龙 Boss、t002 之外的零散单角色表）如果按
##   4 列算，帧宽会被算成 图宽/12（只有真实值的 1/4），整张表取帧全错位。
##   各渲染点必须走同一份判据，否则会出现"这个物件对了、那个物件错位"。

## 标准帧尺寸（非 `$` 表未显式指定时的兜底）。
const DEFAULT_FRAME_W: int = 48
const DEFAULT_FRAME_H: int = 64
## 单角色表：3 列帧 × 4 行方向。
const SINGLE_FRAME_COLS: int = 3
const SINGLE_DIR_ROWS: int = 4
## 标准表：4 列角色格 × 2 行角色格。
const CHARS_PER_ROW: int = 4
const CHAR_ROWS: int = 2
const DIRECTIONS: int = 4


## 文件名是否以 `$` 开头（单角色表）。
## ★必须容忍 `!` 在前的组合写法：项目里就存在 `!$T-002タイラント01.png`
##   （`!` = 无 4px 上移，`$` = 单角色表，两个前缀可以叠加）。
static func is_single_char(texture: Texture2D) -> bool:
	if texture == null:
		return false
	return _prefix_flags(_file_name(texture)).contains("$")

## 文件名是否以 `!` 开头（无 4px 上移 / 草丛半透明）。
## 本项目不渲染那 4px 偏移，所以取帧结果不受影响，仅作语义识别与将来备用。
static func has_bang(texture: Texture2D) -> bool:
	if texture == null:
		return false
	return _prefix_flags(_file_name(texture)).contains("!")


## 一行有几个角色格：`$` 单角色表 = 1，标准表 = 4。
static func chars_per_row(texture: Texture2D) -> int:
	return 1 if is_single_char(texture) else CHARS_PER_ROW


## 角色格有几行：`$` = 1，标准表 = 2。
static func char_rows(texture: Texture2D) -> int:
	return 1 if is_single_char(texture) else CHAR_ROWS


## 一维帧尺寸。
## `$` 表由贴图尺寸推导（这就是它存在的意义：帧尺寸不再固定 48×64）；
## 标准表一律用调用方给的兜底值（不少物件刻意用非 48×64 的手工配置，
## 比如 `HintMarker.frame_size`，不能拿贴图尺寸反推）。
static func frame_size(texture: Texture2D, fallback: Vector2i = Vector2i(DEFAULT_FRAME_W, DEFAULT_FRAME_H)) -> Vector2i:
	if texture == null or not is_single_char(texture):
		return fallback
	var size: Vector2 = source(texture).get_size()
	return Vector2i(
		maxi(1, int(size.x) / SINGLE_FRAME_COLS),
		maxi(1, int(size.y) / SINGLE_DIR_ROWS))


static func frame_width(texture: Texture2D, fallback: int = DEFAULT_FRAME_W) -> int:
	return frame_size(texture, Vector2i(fallback, DEFAULT_FRAME_H)).x


static func frame_height(texture: Texture2D, fallback: int = DEFAULT_FRAME_H) -> int:
	return frame_size(texture, Vector2i(DEFAULT_FRAME_W, fallback)).y


## 角色格索引归一：`$` 表只有 1 格 → 恒为 0；标准表 clamp 到 0~7。
## （作者在 `$` 素材上填了 6 也不会取到空白格。）
static func normalized_char_index(texture: Texture2D, char_index: int) -> int:
	if is_single_char(texture):
		return 0
	return clampi(char_index, 0, CHARS_PER_ROW * CHAR_ROWS - 1)


## 取帧矩形：角色格索引 + 朝向（0=下 1=左 2=右 3=上）+ 踏步帧（0~2）。
## `fallback_size` = 非 `$` 表用的兜底帧尺寸（手工配置走这里；`$` 表始终按贴图推导，
## 因为 `$` 的语义就是"这张表的帧尺寸由图本身决定"）。
static func region_rect(texture: Texture2D, char_index: int, direction: int, frame: int,
		fallback_size: Vector2i = Vector2i(DEFAULT_FRAME_W, DEFAULT_FRAME_H)) -> Rect2:
	var fs: Vector2i = frame_size(texture, fallback_size)
	if texture == null:
		return Rect2(Vector2.ZERO, Vector2(fs))
	var cols: int = chars_per_row(texture)
	var ci: int = normalized_char_index(texture, char_index)
	var col: int = ci % cols
	var row: int = ci / cols
	var x: int = (col * SINGLE_FRAME_COLS + clampi(frame, 0, 2)) * fs.x
	var y: int = (row * SINGLE_DIR_ROWS + clampi(direction, 0, 3)) * fs.y
	return Rect2(x, y, fs.x, fs.y)


## 剥掉包装层拿到底图。
## ★`NormalMaps.canvas()`（敌人 / 队友精灵都套了它）返回的是 `CanvasTexture`，
##   它的 `resource_path` 是空的 —— 直接读外层会把 `$` 素材当普通表处理。
static func source(texture: Texture2D) -> Texture2D:
	var node: Texture2D = texture
	var guard: int = 0
	while node is CanvasTexture and guard < 8:
		var inner: Texture2D = (node as CanvasTexture).diffuse_texture
		if inner == null:
			break
		node = inner
		guard += 1
	return node


static func _file_name(texture: Texture2D) -> String:
	if texture == null:
		return ""
	var path: String = source(texture).resource_path
	if path.is_empty():
		return ""
	return path.get_file()


## 取出文件名开头的特殊前缀集合（`$` / `!` 可以叠加，如 `!$T-002…`）。
static func _prefix_flags(file_name: String) -> String:
	var flags: String = ""
	var i: int = 0
	while i < file_name.length():
		var ch: String = file_name[i]
		if ch != "$" and ch != "!":
			break
		flags += ch
		i += 1
	return flags
