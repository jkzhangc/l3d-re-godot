class_name StatusCatalogData extends RefCounted

## ── 架构定位 ──
## 系统：状态图鉴 ｜ 层：数据（常量表）
## 联机：不涉及（纯本地查看）
## 职责：全游戏「正面状态 / 负面状态 / 被动」的图鉴条目：名称、效果、获得方式、备注。
## 依赖：被收藏馆「状态」页签读取；HUD 上真正显示的短名仍以 `Player.BUFF_LABELS` 为唯一真源。
##
## 【为什么单独一份表】HUD 只需要一个短名（血条右边一行），而图鉴要「效果 + 怎么来的」，
## 两者信息量差一个数量级；把长文案塞进 player.gd 会让那份常量表变成半个说明书。
## 字段含义：
##   id     —— 与 `Player.BUFF_LABELS` 的键一致（便于对照）；非 HUD 状态用机制名
##   name   —— 图鉴显示名（★中文；原作日文/英文名写在 remark 里备查）
##   kind   —— 分类标签：正面状态 / 负面状态 / 被动
##   debuff —— 是否负面（决定图鉴配色，与 HUD 红/青一致）
##   hud    —— 是否出现在血条右侧状态栏
##   effect —— 效果
##   obtain —— 获得方式（怎么触发/怎么拿到）
##   remark —— 补充说明（可空）
## `{觉醒键}` 是键名占位符：界面层按平台替换（手机没有这颗键时退化为「觉醒键」三个字）。

const ENTRIES: Array[Dictionary] = [
	{
		"id": "yasuo_soul",
		"name": "安雄魂",
		"kind": "正面状态",
		"debuff": false,
		"hud": true,
		"effect": "5 秒内每一次受到的伤害都固定为 1（受伤不会提前结束）；期间可重复发动，每次 +5 秒并叠一层。",
		"obtain": "安雄举枪（構え）中按{觉醒键}，消耗 TP10 发动；生效中再按一次即续期。",
		"remark": "状态挂在玩家身上：发动后换人、换座位都不会丢。过热、武器损耗、推击等副作用照常生效。",
	},
	{
		"id": "awaken",
		"name": "觉醒·集中射击",
		"kind": "正面状态",
		"debuff": false,
		"hud": true,
		"effect": "射击威力 ×1.5，子弹附带即死与胆怯；对 Boss 只保留 ×1.5 与胆怯。发动中每秒消耗 5 TP。",
		"obtain": "大雄举枪（構え）中按{觉醒键}发动，TP 必须大于 0。",
		"remark": "原作是「構え中 Z+X」，本作改成单独一颗觉醒键。",
	},
	{
		"id": "painkiller",
		"name": "镇痛剂",
		"kind": "正面状态",
		"debuff": false,
		"hud": true,
		"effect": "15 秒内受到的伤害归零。",
		"obtain": "使用辅助品「镇痛剂」。",
		"remark": "只免疫伤害数字：过热、武器损耗、推击与属性负效果照常生效。",
	},
	{
		"id": "adrenaline",
		"name": "肾上腺素",
		"kind": "正面状态",
		"debuff": false,
		"hud": true,
		"effect": "15 秒内攻击力 ×2，远程与近战都生效。",
		"obtain": "使用辅助品「肾上腺素」。",
		"remark": "即死类攻击不会因此变得更痛，只是基础伤害翻倍。",
	},
	{
		"id": "burning",
		"name": "燃烧",
		"kind": "负面状态",
		"debuff": true,
		"hud": true,
		"effect": "4 秒内持续掉血，每 0.5 秒结算一次。",
		"obtain": "被火属性攻击命中，或站进火焰范围。",
		"remark": "重复点燃会重置持续时间；普通难度每秒约 8 点，难度越高越痛。",
	},
	{
		"id": "heat",
		"name": "过热",
		"kind": "负面状态",
		"debuff": true,
		"hud": true,
		"effect": "6 秒内不能换人、禁止见切与反击、TP 停止回复、毅力（保命）失效。",
		"obtain": "被特殊敌人的过热攻击命中，或被爆炸波及。",
		"remark": "原作「ヒート（Heat）」：说明书写的是「キャラチェンジ不可」。\n中招时身体闪红光，血条右侧有倒计时；换人锁只挡手动切换，角色被打死仍会自动换人。",
	},
	{
		"id": "attrition",
		"name": "武器损耗",
		"kind": "负面状态",
		"debuff": true,
		"hud": false,
		"effect": "远程武器弹夹 -2 发；近战武器耐久 -8，耐久归零则武器直接损坏。",
		"obtain": "被酸属性攻击或过热攻击命中。",
		"remark": "原作「削り」；不占用状态栏，直接体现在弹夹与耐久上。",
	},
	{
		"id": "guts",
		"name": "毅力",
		"kind": "被动",
		"debuff": false,
		"hud": false,
		"effect": "HP ≥ 2 时受到致命伤害，会保留 1 HP 不倒。",
		"obtain": "所有角色天生具备，不需要获得。",
		"remark": "原作「ガッツ」；处于过热状态时失效。",
	},
]


## 图鉴总条目（顺序即页签内顺序：先正面、再负面、最后被动）。
static func all_entries() -> Array[Dictionary]:
	return ENTRIES.duplicate(true)
