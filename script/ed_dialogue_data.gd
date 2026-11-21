extends RefCounted

## ── 架构定位 ──
## 系统：ED 台词数据 ｜ 层：数据（纯静态，无节点）
## 联机：各端本地读取，不需要同步。
## 职责：内置默认（原作 `Map0021` 突袭 / `Map0023` 夜行猎手，逐字文本）
##       + 外部覆盖文件 + 运行时注册（创意工坊 / 模组预留接口）。
## 依赖：无（仅 FileAccess / JSON / print）。
##
## 【可编辑性 · 创意工坊（2026-11-21 用户要求）】
##   查找顺序（后者覆盖前者，按「战役 → 角色 → 批次」合并，不会整表替换）：
##     ① DEFAULT_A / DEFAULT_B —— 内置默认，保证任何情况下 ED 都能播
##     ② user://ed_dialogue.json —— 玩家 / 模组可直接编辑的覆盖文件
##     ③ register_campaign() —— 将来创意工坊在运行时注入
##   隔离原则：
##     - 覆盖文件读取/解析失败 → 只打 warning，整层忽略，内置默认照常；
##     - 单个战役格式不对 → 只跳过该战役；
##     - 单个角色 / 单批台词格式不对 → 只跳过该条，其余照常；
##     - 本文件不持有节点、不 emit 信号，任何失败都不会打断 ED 流程。
##
## 【覆盖文件格式（user://ed_dialogue.json）】
## {
##   "version": 1,
##   "campaigns": {
##     "assault": {
##       "order": ["のび太", "ジャイアン", "静香"],   // 可选，省略用内置 ED 顺序
##       "characters": {
##         "のび太": {"a": ["结局第一行", "结局第二行"], "b": ["登车第一行"]}
##       }
##     }
##   }
## }
##   - 键 = CharacterData.character_name（日文名，`ジャイ` 会自动归一到 `ジャイアン`）；
##   - `a` = 角色结局感想，`b` = 登车 / 起飞 / 启动；
##   - 可只写想改的角色/批次，未写的继续用内置默认；
##   - 新增角色（模组）只要写进 `characters` 且列入 `order`，就会参与 ED 排序。

## 外部覆盖文件：放 user:// 下，导出包/创意工坊内容都能写，不污染工程资源。
const OVERRIDE_PATH := "user://ed_dialogue.json"

## 原作 ED 顺序（说话人在地图文本里写死，按 `Map0021` 的出现顺序）。
const ORDER: Array[String] = ["のび太", "ジャイアン", "静香", "聖奈", "スネ夫", "健治", "出木杉", "安雄", "サーシャ", "咲夜"]

## A 批 · 角色结局感想 —— 三张 ED 图（Map0021/0023/0034）完全一致，共用一份。
const DEFAULT_A: Dictionary = {
	"のび太": ["我并没有依赖多啦A梦、", "我一个人的力量也是能做到的！"],
	"ジャイアン": ["干的漂亮！", "终于逃出来了！"],
	"静香": ["太棒了！　逃出来了！"],
	"聖奈": ["神是真的存在啊。"],
	"スネ夫": ["看来我还是非常强啊！", "哈哈哈哈。"],
	"健治": ["哎呦喂！", "一定要活下去！　为了明天！！"],
	"出木杉": ["原来我有这么高的生存能力啊，", "我自己都不知道呢。"],
	"安雄": ["我是榴弹炮安雄！", "还记得我吧！"],
	"サーシャ": ["这次差点死了、", "我的厄运还真是不简单啊。"],
	"咲夜": ["呼。", "差点以为今天会死在这里呢！"],
}

## B 批 · 登车 / 起飞 / 启动 —— 按战役不同。
## 死亡岛（`Map0034` 气垫船）台词已导出到 docs，等战役地图做完再补 "dead_island"。
const DEFAULT_B: Dictionary = {
	"assault": {
		"のび太": ["大家做好了！", "请早点启动列车吧！"],
		"ジャイアン": ["赶快给我启动啊！", "一定要找到妈妈和技子", "你们一定不能死啊！"],
		"静香": ["大家都做好了啊！", "请离开这里吧！"],
		"聖奈": ["现在已经没事了、启动列车吧。"],
		"スネ夫": ["来晚了！", "在干什么！"],
		"健治": ["好、全员都在！", "启动列车吧！"],
		"出木杉": ["全体人员！", "请赶紧启动列车离开这里！"],
		"安雄": ["终于来了！　操作任务交给我！", "……啊、我还是不行？"],
		"サーシャ": ["全员确认上车。启动列车。"],
		"咲夜": ["现在是好时机啊！", "现在、快从这里离开吧！"],
	},
	"night_hunter": {
		"のび太": ["大家做好了！", "请早点飞行吧！"],
		"ジャイアン": ["赶快给我飞起来！", "一定要找到妈妈和技子", "你们一定不能死啊！"],
		"静香": ["大家都做好了啊！", "请离开这里吧！"],
		"聖奈": ["谢谢救出我们。", "现在已经没事了、起飞吧。"],
		"スネ夫": ["来晚了！", "在干什么！"],
		"健治": ["好、全员都在！", "起飞吧！"],
		"出木杉": ["全体人员！", "请赶紧起飞！"],
		"安雄": ["终于来了！　操作任务交给我！", "……啊、我还是不行？"],
		"サーシャ": ["迎接我们辛苦了。", "全员确认登机。起飞吧。"],
		"咲夜": ["现在是好时机啊！", "现在、快从这里离开吧！"],
	},
}

## 覆盖层缓存：{ campaign_id: {"table": Dictionary, "order": Array[String]} }
static var _override: Dictionary = {}
static var _override_loaded: bool = false
## 运行时注册层：{ campaign_id: Dictionary }（已 sanitize）
static var _registered: Dictionary = {}


## 所有可能出现在 ED 里的角色名（内置顺序 + 覆盖/注册新增，去重）。
static func order_for(campaign_id: String) -> Array[String]:
	_ensure_override()
	var out: Array[String] = []
	var custom: Variant = (_override.get(campaign_id, {}) as Dictionary).get("order", [])
	if custom is Array and not (custom as Array).is_empty():
		for name: Variant in (custom as Array):
			if name is String and not (name as String).is_empty() and not out.has(name):
				out.append(name)
	if out.is_empty():
		out = ORDER.duplicate()
	for name: String in lines_for(campaign_id).keys():
		if not out.has(name):
			out.append(name)
	return out


## 取某战役的合并结果：{ 角色名: {"a": Array[String], "b": Array[String]} }。
## 永不返回 null —— 最差也是内置默认。
static func lines_for(campaign_id: String) -> Dictionary:
	_ensure_override()
	var out: Dictionary = {}
	for name: String in DEFAULT_A:
		out[name] = {"a": (DEFAULT_A[name] as Array).duplicate()}
	for name: String in (DEFAULT_B.get(campaign_id, {}) as Dictionary):
		if not out.has(name):
			out[name] = {}
		out[name]["b"] = ((DEFAULT_B[campaign_id] as Dictionary)[name] as Array).duplicate()
	_apply(out, (_override.get(campaign_id, {}) as Dictionary).get("table", {}))
	_apply(out, _registered.get(campaign_id, {}))
	return out


## 创意工坊 / 模组运行时注入。返回 false = 数据格式不合法（已忽略，不影响内置默认）。
static func register_campaign(campaign_id: String, raw_table: Variant) -> bool:
	if campaign_id.strip_edges().is_empty():
		return false
	var table: Dictionary = _sanitize_table(raw_table)
	if table.is_empty():
		push_warning("[EDData] register_campaign(%s) 无有效条目，已忽略" % campaign_id)
		return false
	_registered[campaign_id] = table
	return true


## 清除运行时注册（调试 / 切换模组用）。
static func clear_registered() -> void:
	_registered.clear()


## 强制重新读覆盖文件（编辑 user://ed_dialogue.json 后不必重启）。
static func reload_override(path: String = OVERRIDE_PATH) -> void:
	_override_loaded = false
	_override.clear()
	if FileAccess.file_exists(path):
		_load_override(path)
	_override_loaded = true


static func _ensure_override() -> void:
	if _override_loaded:
		return
	_override_loaded = true
	_override.clear()
	if FileAccess.file_exists(OVERRIDE_PATH):
		_load_override(OVERRIDE_PATH)


static func _load_override(path: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[EDData] 覆盖文件打不开，已忽略：%s" % path)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("[EDData] 覆盖文件不是合法 JSON 对象，已忽略：%s" % path)
		return
	var camps: Variant = (parsed as Dictionary).get("campaigns", null)
	if not (camps is Dictionary):
		push_warning("[EDData] 覆盖文件缺少 campaigns 对象，已忽略：%s" % path)
		return
	for campaign_id: Variant in (camps as Dictionary).keys():
		if not (campaign_id is String):
			continue
		var raw_camp: Variant = (camps as Dictionary)[campaign_id]
		if not (raw_camp is Dictionary):
			continue
		## 允许 {"characters": {...}, "order": [...]}，也允许直接写角色表
		var chars: Variant = (raw_camp as Dictionary).get("characters", raw_camp)
		var table: Dictionary = _sanitize_table(chars)
		if table.is_empty():
			continue
		var order: Array[String] = []
		var raw_order: Variant = (raw_camp as Dictionary).get("order", null)
		if raw_order is Array:
			for name: Variant in (raw_order as Array):
				if name is String and not (name as String).is_empty():
					order.append(name)
		_override[campaign_id] = {"table": table, "order": order}


## 只保留「字符串 → {"a"/"b": 非空字符串数组}」的合法条目；其余静默丢弃。
static func _sanitize_table(raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not (raw is Dictionary):
		return out
	for name: Variant in (raw as Dictionary).keys():
		if not (name is String) or (name as String).strip_edges().is_empty():
			continue
		var entry: Variant = (raw as Dictionary)[name]
		if not (entry is Dictionary):
			continue
		var item: Dictionary = {}
		for batch: String in ["a", "b"]:
			var arr: Variant = (entry as Dictionary).get(batch, null)
			if not (arr is Array):
				continue
			var lines: Array[String] = []
			for ln: Variant in (arr as Array):
				if ln is String and not (ln as String).strip_edges().is_empty():
					lines.append(ln)
			if not lines.is_empty():
				item[batch] = lines
		if not item.is_empty():
			out[name] = item
	return out


## 合并一层：字段级覆盖，不清空未提及的批次。
static func _apply(dst: Dictionary, raw_table: Variant) -> void:
	var table: Dictionary = _sanitize_table(raw_table)
	for name: String in table:
		if not dst.has(name):
			dst[name] = {}
		for batch: String in (table[name] as Dictionary):
			dst[name][batch] = ((table[name] as Dictionary)[batch] as Array).duplicate()
