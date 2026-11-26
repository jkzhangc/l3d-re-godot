extends RefCounted

## ── 架构定位 ──
## 系统：自定义剧情 ｜ 层：数据（RefCounted，纯静态）
## 职责：存「可触发剧情」的台词表 —— 与安全屋台词同构（固定 NPC 页 + 按角色分支）。
## 依赖：无
## 被调用：script/story/story_sequence.gd
##
## 【数据结构】
## ```
## "key": {
##     "npc_name": "多啦A梦",              # 固定角色名（显示用）
##     "common":  [页面, ...],             # 开场固定页（所有人一样）
##     "by_character": { "<日文角色名>": [页面, ...] },   # 该角色的分支页
##     "fallback": [页面, ...],            # 角色没有专属分支时用（可空）
##     "closing": [页面, ...],             # 收尾固定页
## }
## 页面 = { "speaker": "说话人", "lines": ["第一句", "第二句"], "portrait": null }
## ```
## 角色名用 **日文原名**（`CharacterData.character_name`，如 `のび太` / `ジャイアン`），
## 与 `Global.CHARACTER_NAME_ZH` 的键一致 —— 这样数据表不依赖角色 id / 资源路径。
##
## 【本表内容来源】
## `map0030_doraemon_*` 来自原作 Map0030「扉」事件（死亡岛第三关 · 多啦A梦剧情），
## 由 `tools/rm2k3_map_restore/export_orig_dialogue.py` 导出、人工整理成两段：
## 初次见面（开关 500 为 OFF）与铜锣烧委托（开关 500 为 ON）。

const SCRIPTS: Dictionary = {
	"map0030_doraemon_meet": {
		"npc_name": "多啦A梦",
		"common": [
			{"speaker": "多啦A梦", "lines": ["啊、你好。", "我是多啦A梦。"]},
		],
		"by_character": {
			"のび太": [
				{"speaker": "大雄", "lines": ["多啦A梦！？", "终于找到你了！"]},
				{"speaker": "多啦A梦", "lines": ["嗯？　其他的机体么？", "我们是量产型的、所以脸的类型很少。"]},
				{"speaker": "大雄", "lines": ["是这样啊……。"]},
			],
			"ジャイアン": [
				{"speaker": "胖虎", "lines": ["哎、是多啦A梦啊！"]},
				{"speaker": "多啦A梦", "lines": ["嗯？　其他的机体么？", "我们是量产型的、所以脸的类型很少。"]},
				{"speaker": "胖虎", "lines": ["啊、可恶。原来是亲戚啊。"]},
			],
			"スネ夫": [
				{"speaker": "小夫", "lines": ["多啦A梦！？", "终于找到你了！"]},
				{"speaker": "多啦A梦", "lines": ["嗯？　其他的机体么？", "我们是量产型的、所以脸的类型很少。"]},
				{"speaker": "小夫", "lines": ["啊啊、说起来多啦A梦", "还真的是量产型的么……？"]},
			],
			"しずか": [
				{"speaker": "静香", "lines": ["多啦A梦！", "原来你平安无事啊！"]},
				{"speaker": "多啦A梦", "lines": ["嗯？　其他的机体么？", "我们是量产型的、所以脸的类型很少。"]},
				{"speaker": "静香", "lines": ["啊……对不起。"]},
			],
			"出木杉": [
				{"speaker": "出木杉", "lines": ["是多啦A梦啊！", "原来你平安无事啊！"]},
				{"speaker": "多啦A梦", "lines": ["嗯？　其他的机体么？", "我们是量产型的、所以脸的类型很少。"]},
				{"speaker": "出木杉", "lines": ["别的多啦A梦么。", "对不起。"]},
			],
			"安雄": [
				{"speaker": "安雄", "lines": ["是多啦A梦啊！", "原来你平安无事啊！"]},
				{"speaker": "多啦A梦", "lines": ["嗯？　其他的机体么？", "我们是量产型的、所以脸的类型很少。"]},
				{"speaker": "安雄", "lines": ["啊、是这样啊。不好意思。"]},
			],
			"聖奈": [
				{"speaker": "圣奈", "lines": ["??? 啊、狸猫化生的妖怪…"]},
				{"speaker": "多啦A梦", "lines": ["我可不是狸猫啊。"]},
				{"speaker": "圣奈", "lines": ["…………。"]},
			],
		},
		"fallback": [
			{"speaker": "多啦A梦", "lines": ["嗯？　其他的机体么？", "我们是量产型的、所以脸的类型很少。"]},
		],
		"closing": [],
	},

	"map0030_doraemon_quest": {
		"npc_name": "多啦A梦",
		"common": [
			{"speaker": "多啦A梦", "lines": ["我现在、在一个很安全的设施里", "有足够的食物。"]},
			{"speaker": "多啦A梦", "lines": ["只是、在躲进设施的时候很慌张", "忘记去拿铜锣烧了。"]},
			{"speaker": "多啦A梦", "lines": ["于是，我的提议是这样的。", "你们如果把铜锣烧给我带来的话", "我就帮你们把通向港口的门给打开。"]},
		],
		"by_character": {
			"のび太": [{"speaker": "大雄", "lines": ["真的？"]}],
			"ジャイアン": [{"speaker": "胖虎", "lines": ["真的么？", "欺骗我的话、就在这里了结你。"]}],
			"スネ夫": [{"speaker": "小夫", "lines": ["难道说、是因为你在", "这里工作的原因？"]}],
			"しずか": [{"speaker": "静香", "lines": ["可以相信你么？"]}],
			"出木杉": [{"speaker": "出木杉", "lines": ["听起来让人很高兴啊、", "但是，真的可以相信么？"]}],
			"咲夜": [{"speaker": "咲夜", "lines": ["相当慷慨大方啊。", "不是在骗我们？"]}],
			"健治": [{"speaker": "健治", "lines": ["铜锣烧给你之后就给我开启逃生的门", "真的么？　真的么？"]}],
			"安雄": [{"speaker": "安雄", "lines": ["咱们现在就去、立刻帮你哪来。", "所以这句话不要忘了啊。"]}],
			"聖奈": [{"speaker": "圣奈", "lines": ["这样看起来很方便啊、", "不是在说谎吧？"]}],
			"サーシャ": [{"speaker": "萨夏", "lines": ["开玩笑的要去。", "记住你说的报酬啊。"]}],
		},
		"fallback": [{"speaker": "多啦A梦", "lines": ["……那么、就拜托了。"]}],
		"closing": [
			{"speaker": "多啦A梦", "lines": ["脱出手段失去的话会很辛苦啊、", "但是关于你们的生存竞争。", "想逃出这个岛就好好合作。"]},
			{"speaker": "多啦A梦", "lines": ["…………。"]},
			{"speaker": "多啦A梦", "lines": ["（这……到底是个怎样的人呢）"]},
		],
	},
}


## 该 key 是否存在。
static func has_script(key: String) -> bool:
	return SCRIPTS.has(key)


## 拼出一轮完整页面：common → 角色分支（或 fallback）→ closing。
## `character_name` 用 **日文原名**（`CharacterData.character_name`）。
## 取不到专属分支时用 fallback；fallback 也为空就只出 common + closing。
static func pages_for(key: String, character_name: String) -> Array:
	if not has_script(key):
		return []
	var data: Dictionary = SCRIPTS[key]
	var out: Array = []
	for page: Variant in data.get("common", []):
		out.append(page)
	var by_char: Dictionary = data.get("by_character", {})
	var branch: Array = by_char.get(character_name, [])
	if branch.is_empty():
		branch = data.get("fallback", [])
	for page: Variant in branch:
		out.append(page)
	for page: Variant in data.get("closing", []):
		out.append(page)
	return out


## 固定 NPC 名（仅用于调试日志；页面里的 speaker 已逐条写好）。
static func npc_name(key: String) -> String:
	if not has_script(key):
		return ""
	return str(SCRIPTS[key].get("npc_name", ""))


## 该 key 覆盖了哪些角色的专属分支（供 UI / 文档展示）。
static func character_names(key: String) -> Array[String]:
	var out: Array[String] = []
	if not has_script(key):
		return out
	var by_char: Dictionary = SCRIPTS[key].get("by_character", {})
	for name: Variant in by_char.keys():
		out.append(str(name))
	out.sort()
	return out
