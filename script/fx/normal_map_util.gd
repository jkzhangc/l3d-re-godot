class_name NormalMaps extends RefCounted

## ── 架构定位 ──
## 系统：夜间视界 · 2D 灯光的法线支持 ｜ 层：表现（工具类）
## 联机：纯本地表现，不涉及同步
## 职责：把「漫反射贴图」按命名约定换成 CanvasTexture（附带 normal_texture），
##       让 PointLight2D 能做出表面起伏。找不到法线图时原样返回，零开销。
##
## 命名约定（与 tools/gen_normal_maps.py 一致）
##   res://art/Characters/<名字>.png      →  res://art/Characters/n/<名字>_n.png
##
## 【为什么要包在"贴图变量"而不是"每个 sprite.texture = ... 处"】
##   敌人每帧刷新都会 `sprite.texture = walk_texture`，直接改 sprite.texture 会被覆盖；
##   把 walk_texture 本身换成 CanvasTexture，所有赋值点天然带上法线。
##
## ⚠ 灯光侧还需要 `PointLight2D.height > 0`，否则法线贴图完全不参与（默认就是 0）。
##   见 NightOverlay.LIGHT_HEIGHT / LightEmitter.light_height。

const CHAR_DIR := "res://art/Characters/"
const NORMAL_SUBDIR := "n"

## 漫反射纹理 → CanvasTexture（或 null 表示没有法线图）
static var _cache: Dictionary = {}


## 取某张漫反射贴图对应的法线贴图路径；没有则返回空串。
static func normal_path_for(tex: Texture2D) -> String:
	if tex == null:
		return ""
	var path: String = tex.resource_path
	if path.is_empty() or not path.begins_with(CHAR_DIR):
		return ""
	if path.get_base_dir() == CHAR_DIR + NORMAL_SUBDIR:   # 法线图自己不要再套一层
		return ""
	var name := path.get_file().get_basename()
	var candidate := CHAR_DIR + NORMAL_SUBDIR + "/" + name + "_n.png"
	return candidate if ResourceLoader.exists(candidate) else ""


## 把漫反射贴图包成 CanvasTexture（带法线）。没有法线图 / 传 null → 原样返回。
## 同一张漫反射贴图只构造一次，之后命中缓存。
static func canvas(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	if tex is CanvasTexture:
		return tex
	var key: int = tex.get_instance_id()
	if _cache.has(key):
		var hit: Variant = _cache[key]
		return hit if hit != null and is_instance_valid(hit) else tex
	var npath := normal_path_for(tex)
	if npath.is_empty():
		_cache[key] = null
		return tex
	var ntex := load(npath) as Texture2D
	if ntex == null:
		_cache[key] = null
		return tex
	var ct := CanvasTexture.new()
	ct.diffuse_texture = tex
	ct.normal_texture = ntex
	_cache[key] = ct
	return ct
