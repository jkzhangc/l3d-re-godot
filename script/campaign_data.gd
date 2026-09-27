class_name CampaignData extends Resource

## ── 架构定位 ──
## 系统：战役数据 ｜ 层：数据（Resource）
## 联机：不涉及
## 职责：战役定义：ID/名称/描述/图标与按顺序排列的关卡场景路径。
## 依赖：被 campaign_select 读取

## 战役数据 — 定义一组连续关卡

@export var campaign_id: String = ""           ## 唯一标识，如 "assault"
@export var campaign_name: String = ""         ## 显示名称，如 "突袭"
@export_multiline var description: String = "" ## 战役描述
@export var level_scenes: Array[String] = []   ## 关卡场景路径列表，按顺序
@export var campaign_icon: Texture2D           ## 战役选择界面图标（可选）


## ── 关卡扁平表（2026-09-27）──
## 把各战役的关卡按顺序摊平，供两个地方共用：①调试「跳转章节」（多人主机）②多人房间的
## 「选择章节」。清单与 campaign_select 保持一致；章节骨架期 level_scenes 为空的战役跳过。
const CAMPAIGN_RESOURCE_PATHS: Array[String] = [
	"res://object/campaign_assault.tres",
	"res://object/campaign_night_hunter.tres",
]


## 返回 [{campaign, chapter, label, scene}, ...]（按战役→关卡顺序）。
static func collect_chapter_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: String in CAMPAIGN_RESOURCE_PATHS:
		if not ResourceLoader.exists(p):
			continue
		var res: Resource = load(p)
		if not (res is CampaignData):
			continue
		var cd: CampaignData = res as CampaignData
		for i: int in range(cd.level_scenes.size()):
			var scene_path: String = cd.level_scenes[i]
			if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
				continue
			out.append({
				"campaign": cd.campaign_name,
				"chapter": i + 1,
				"label": "%s · %d %s" % [
					cd.campaign_name, i + 1, _chapter_title_of(scene_path)],
				"scene": scene_path,
			})
	return out


## 章节短名：取场景文件名最后一个"-"之后的部分（"突袭-第一关-街道.tscn" → "街道"）。
static func _chapter_title_of(scene_path: String) -> String:
	var base: String = scene_path.get_file().get_basename()
	var parts: PackedStringArray = base.split("-")
	if parts.is_empty():
		return base
	return parts[parts.size() - 1]


## ── 全部可跳转关卡（2026-09-27 补）──
## 只取战役表的话只有 5 关（第一关 3 张 + 第二关 2 张），而 `scene/maps/` 下实际有 12 张 ——
## 矿洞 / 实验室走廊 / 列车台 / 各安全屋 / 测试图都没登记进 `level_scenes`。
## 调试「跳转关卡」与房间「选择章节」都需要"想跳哪张就跳哪张"，因此这里**直接扫地图目录**：
## ① 名字带「突袭」的按「关 → 关内顺序」排前面（标签 = "第一关 · 街道"）
## ② 其余地图（测试图等）排后面，标签加 `[其它]` 前缀。
const _CN_NUMBERS: Dictionary = {
	"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
}
## 关内先后顺序（按"包含"匹配，取最先命中的一条）。安全屋永远在最前/最后。
const _SUB_ORDER_KEYWORDS: Array[String] = [
	"开头安全屋", "街道", "门口", "内部", "矿洞", "实验室走廊", "列车台", "结尾安全屋",
]


static func collect_all_level_entries(map_dir: String = "res://scene/maps") -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for scene_path: String in _list_scene_paths(map_dir):
		rows.append(_describe_level(scene_path))
	## 排序键统一成字符串（"组-关-关内序-文件名"），避免混合类型比较报错。
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("sort_key", "")) < str(b.get("sort_key", "")))
	var out: Array[Dictionary] = []
	for row: Dictionary in rows:
		row.erase("sort_key")
		out.append(row)
	return out


static func _list_scene_paths(map_dir: String) -> Array[String]:
	var paths: Array[String] = []
	var dir: DirAccess = DirAccess.open(map_dir)
	if dir == null:
		return paths
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		if file_name.ends_with(".tscn"):
			paths.append(map_dir + "/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths


## 把一个地图场景描述成一条跳转条目（含排序键）。
static func _describe_level(scene_path: String) -> Dictionary:
	var base: String = scene_path.get_file().get_basename()
	var parts: PackedStringArray = base.split("-")
	var is_campaign: bool = parts.size() >= 3 and parts[0] == "突袭"
	if not is_campaign:
		return {
			"campaign": "其它",
			"chapter": 0,
			"label": "[其它] %s" % base,
			"scene": scene_path,
			"sort_key": "1-0-%02d-%s" % [0, base],
		}
	var chapter: int = int(_CN_NUMBERS.get(parts[1].replace("第", "").replace("关", ""), 99))
	var rest: String = base.substr(("突袭-" + parts[1] + "-").length())
	var sub: int = _sub_order_of(rest)
	return {
		"campaign": parts[0],
		"chapter": chapter,
		"label": "%s · %s" % [parts[1], rest.replace("-", " · ")],
		"scene": scene_path,
		"sort_key": "0-%02d-%02d-%s" % [chapter, sub, base],
	}


static func _sub_order_of(rest: String) -> int:
	for i: int in range(_SUB_ORDER_KEYWORDS.size()):
		if rest.contains(_SUB_ORDER_KEYWORDS[i]):
			return i
	return 50
