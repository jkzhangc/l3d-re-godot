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

## 旧版写死的两条路径 —— 现在只作**导出包兜底**（打包后 DirAccess 可能列不出目录）。
## ★2026-10-31 用户需求「战役选择能够识别到目前有的战役」：
## 真正的主清单改成运行时扫描 `res://object/campaign_*.tres`，
## 新增战役只要放一个资源文件就能被认出来，不用改代码。
const CAMPAIGN_RESOURCE_PATHS: Array[String] = [
	"res://object/campaign_assault.tres",
	"res://object/campaign_night_hunter.tres",
]

static var _cached_campaign_paths: Array[String] = []
static var _cached_campaign_order: Array[String] = []


## 战役资源清单 = 扫描目录发现 ∪ 写死兜底（去重、只保留真实存在的）。
static func campaign_resource_paths() -> Array[String]:
	if not _cached_campaign_paths.is_empty():
		return _cached_campaign_paths
	var out: Array[String] = []
	for preset: String in CAMPAIGN_RESOURCE_PATHS:
		if not preset.is_empty() and ResourceLoader.exists(preset) and preset not in out:
			out.append(preset)
	var dir: DirAccess = DirAccess.open("res://object")
	if dir != null:
		dir.list_dir_begin()
		var f: String = dir.get_next()
		while f != "":
			if not dir.current_is_dir():
				var name: String = f.trim_suffix(".remap")
				if name.begins_with("campaign_") and name.ends_with(".tres"):
					var p: String = "res://object/" + name
					if p not in out and ResourceLoader.exists(p):
						out.append(p)
			f = dir.get_next()
		dir.list_dir_end()
	out.sort()
	_cached_campaign_paths = out
	return out


## 战役前缀顺序（= 地图文件名第一段，如 "突袭" / "夜行猎手"）。
## 由**战役资源的 `campaign_name`** 决定顺序，不再写死表 —— 新增战役自动接在后面。
static func campaign_order() -> Array[String]:
	if not _cached_campaign_order.is_empty():
		return _cached_campaign_order
	var out: Array[String] = []
	for p: String in campaign_resource_paths():
		var res: Resource = load(p)
		if res is CampaignData:
			var nm: String = str((res as CampaignData).campaign_name)
			if not nm.is_empty() and nm not in out:
				out.append(nm)
	if out.is_empty():
		var fallback: Array[String] = ["突袭", "夜行猎手"]
		out = fallback
	_cached_campaign_order = out
	return out


## 场景路径 → 所属战役 id（"assault" / "night_hunter"）。找不到 = 空。
## 终章结算用：多人「选章节」/ 调试跳关不经过 campaign_select，
## `Global.selected_campaign` 可能是空的或上一局的，不能作为唯一依据。
static func campaign_id_for_scene(scene_path: String) -> String:
	if scene_path.is_empty():
		return ""
	var file_name: String = scene_path.get_file()
	for p: String in campaign_resource_paths():
		if not ResourceLoader.exists(p):
			continue
		var res: Resource = load(p)
		if not (res is CampaignData):
			continue
		var cd: CampaignData = res as CampaignData
		if scene_path in cd.level_scenes:
			return cd.campaign_id
	## 第二道：按文件名前缀认（本工程地图命名约定「战役名-第N关-…」）。
	## 第一战役的 level_scenes 只登记到学校内部，矿洞 / 实验室 / 列车台不在表里 ——
	## 终章在列车台，只靠 level_scenes 会认不出来。
	for p: String in campaign_resource_paths():
		if not ResourceLoader.exists(p):
			continue
		var res2: Resource = load(p)
		if not (res2 is CampaignData):
			continue
		var cd2: CampaignData = res2 as CampaignData
		if not cd2.campaign_name.is_empty() and file_name.begins_with(cd2.campaign_name + "-"):
			return cd2.campaign_id
	return ""


## 返回 [{campaign, chapter, label, scene}, ...]（按战役→关卡顺序）。
static func collect_chapter_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: String in campaign_resource_paths():
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
##
## ★★ 2026-09-27 打包后为空的事故（务必保留这条注释）★★
## 用户打包后发现「房间里显示不了章节、跳转章节也是空的」。根因：**导出包里靠 DirAccess
## 枚举 `res://scene/maps` 拿不到 `.tscn`** —— 导出预设开了资源加密
##（`export_presets.cfg: encryption_include_filters="*.gd,*.tscn,*.tres"`），被加密/转换过的
## 场景在目录里是 **`xxx.tscn.remap`** 形态，`file_name.ends_with(".tscn")` 全部落空 → 列表空。
## 修法：**显式清单为主（导出包唯一可靠来源）+ 目录发现为辅（编辑器里自动带上新地图）**，
## 与 `campaign_select` / `character_catalog` 同一套做法。**新增地图请把路径补进 MAP_SCENE_PATHS。**
const MAP_SCENE_PATHS: Array[String] = [
	"res://scene/maps/突袭-第一关-开头安全屋-户外.tscn",
	"res://scene/maps/突袭-第一关-街道.tscn",
	"res://scene/maps/突袭-第一关-结尾安全屋-室内.tscn",
	"res://scene/maps/突袭-第二关-学校门口.tscn",
	"res://scene/maps/突袭-第二关-学校内部.tscn",
	"res://scene/maps/突袭-第二关-结尾安全屋.tscn",
	"res://scene/maps/突袭-第三关-矿洞.tscn",
	"res://scene/maps/突袭-第三关-结尾安全屋.tscn",
	"res://scene/maps/突袭-第四关-实验室走廊.tscn",
	"res://scene/maps/突袭-第四关-列车台（最终场景）.tscn",
	## ── 夜行猎手（第二战役，2026-10-25 补登记）──
	## ⚠ 第三关（电视台外 / 电视台内）**暂不登记**：电视台内只有 GroundLayer/DecorLayer/Player
	## 七个节点，缺 GameInit / Menu / CombatHUD / 传送点，进去就是死图；电视台外有 GameInit
	## 但没有出口传送点。等它们做完再补进本表与 `campaign_night_hunter.tres`。
	"res://scene/maps/夜行猎手-第一关-开头安全屋.tscn",
	"res://scene/maps/夜行猎手-第一关-R市.tscn",
	"res://scene/maps/夜行猎手-第一关-结束安全屋.tscn",
	"res://scene/maps/夜行猎手-第二关-公园入口.tscn",
	"res://scene/maps/夜行猎手-第二关-公园.tscn",
	"res://scene/maps/夜行猎手-第二关-结束安全屋.tscn",
]

## 战役顺序（2026-10-25）：`_describe_level` 用它给多战役条目排序 + 决定标签是否带战役名。
## 新增战役必须同时进本表，否则会被归到「其它」。
## [已停用] 旧版写死的战役前缀顺序。2026-10-31 起由 `campaign_order()`（读战役资源的
## `campaign_name`）动态生成；保留常量只为兼容可能存在的旧引用，代码里不再读取。
const CAMPAIGN_ORDER: Array[String] = ["突袭", "夜行猎手"]

const _CN_NUMBERS: Dictionary = {
	"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
}
## 关内先后顺序（按"包含"匹配，取最先命中的一条）。安全屋永远在最前/最后。
const _SUB_ORDER_KEYWORDS: Array[String] = [
	"开头安全屋", "街道", "门口", "内部", "R市", "公园入口", "公园",
	"矿洞", "实验室走廊", "电视台外", "电视台内", "列车台", "结尾安全屋", "结束安全屋",
]


## ── 开发用地图（2026-10-23）──
## 目录发现会把 `scene/maps/` 下的测试图一起带进来（`test.tscn`、`测试-敌人试验场.tscn`）。
## 多人房间的「选择章节」是给玩家看的，不该出现调试地图 → 默认过滤掉；
## 调试「跳转关卡」要跳测试图，调用时传 `include_dev_maps = true`。
const DEV_MAP_KEYWORDS: Array[String] = ["测试", "试验场", "test"]


## 是否开发/调试用地图（按文件名关键字判定，不看目录）。
static func is_dev_map(scene_path: String) -> bool:
	var base: String = scene_path.get_file().get_basename().to_lower()
	for kw: String in DEV_MAP_KEYWORDS:
		if base.contains(kw):
			return true
	return false


## 全部可跳转关卡。`include_dev_maps = false` 时剔除测试图（多人房间用）。
static func collect_all_level_entries(map_dir: String = "res://scene/maps",
		include_dev_maps: bool = false) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for scene_path: String in _list_scene_paths(map_dir, include_dev_maps):
		rows.append(_describe_level(scene_path))
	## 排序键统一成字符串（"组-关-关内序-文件名"），避免混合类型比较报错。
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("sort_key", "")) < str(b.get("sort_key", "")))
	var out: Array[Dictionary] = []
	for row: Dictionary in rows:
		row.erase("sort_key")
		out.append(row)
	return out


## 目录项名 → 场景路径（返回空 = 不是场景）。
## 导出包里被加密/转换过的资源是 `xxx.tscn.remap`（见上方事故注释），必须一并认。
static func scene_path_from_dir_entry(map_dir: String, file_name: String) -> String:
	if file_name.ends_with(".tscn"):
		return map_dir + "/" + file_name
	if file_name.ends_with(".tscn.remap"):
		return map_dir + "/" + file_name.trim_suffix(".remap")
	return ""


## 关卡场景清单 = 显式清单 ∪ 目录发现（各自去重，并过滤掉真正不存在的路径）。
static func _list_scene_paths(map_dir: String, include_dev_maps: bool = false) -> Array[String]:
	var paths: Array[String] = []
	for preset: String in MAP_SCENE_PATHS:
		if not preset.is_empty() and ResourceLoader.exists(preset) and preset not in paths:
			paths.append(preset)

	var dir: DirAccess = DirAccess.open(map_dir)
	if dir == null:
		return paths
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		var found: String = scene_path_from_dir_entry(map_dir, file_name)
		if not found.is_empty() and ResourceLoader.exists(found) and found not in paths \
				and (include_dev_maps or not is_dev_map(found)):
			paths.append(found)
		file_name = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths


## 场景 → 章节号（1 = 第一关；**不是** level_scenes 下标）。
## 为什么需要单独一个函数：第一关在 level_scenes 里占了三张图
## （开头安全屋 / 街道 / 结尾安全屋），按下标判断会把"街道"当成第二张图。
## 认不出（文件名不含「第X关」）返回 -1。
static func chapter_number_for_scene(scene_path: String) -> int:
	if scene_path.is_empty():
		return -1
	var base: String = scene_path.get_file().get_basename()
	var parts: PackedStringArray = base.split("-")
	if parts.size() < 3:
		return -1
	return int(_CN_NUMBERS.get(parts[1].replace("第", "").replace("关", ""), -1))


## 把一个地图场景描述成一条跳转条目（含排序键）。
static func _describe_level(scene_path: String) -> Dictionary:
	var base: String = scene_path.get_file().get_basename()
	var parts: PackedStringArray = base.split("-")
	## 战役前缀识别改为查表（2026-10-25）：原来写死 `parts[0] == "突袭"`，
	## 夜行猎手的地图因此全被归成「[其它]」，房间里选章节无法区分两个战役。
	var prefix: String = parts[0] if parts.size() >= 3 else ""
	var order: int = campaign_order().find(prefix)
	if order < 0:
		return {
			"campaign": "其它",
			"chapter": 0,
			"label": "[其它] %s" % base,
			"scene": scene_path,
			"sort_key": "1-0-00-00-%s" % base,
		}
	var chapter: int = int(_CN_NUMBERS.get(parts[1].replace("第", "").replace("关", ""), 99))
	var rest: String = base.substr((prefix + "-" + parts[1] + "-").length())
	var sub: int = _sub_order_of(rest)
	var label: String = "%s · %s" % [parts[1], rest.replace("-", " · ")]
	if order > 0:
		## 第一个战役沿用旧标签（"第一关 · 街道"）以免改变既有观感；
		## 从第二个战役起必须带战役名，否则「第二关 · 结束安全屋」会重名。
		label = "%s · %s" % [prefix, label]
	return {
		"campaign": prefix,
		"chapter": chapter,
		"label": label,
		"scene": scene_path,
		"sort_key": "0-%d-%02d-%02d-%s" % [order, chapter, sub, base],
	}


static func _sub_order_of(rest: String) -> int:
	for i: int in range(_SUB_ORDER_KEYWORDS.size()):
		if rest.contains(_SUB_ORDER_KEYWORDS[i]):
			return i
	return 50
