class_name CharacterProfileData extends RefCounted

## ── 架构定位 ──
## 系统：角色图鉴 ｜ 层：数据（常量表）
## 联机：不涉及（纯本地查看）
## 职责：角色选择的「人物介绍」文案：一句话定位 + 简介正文（数值/武器/特性/技能不写在这里，
##       全部从 `CharacterData` 实时算，避免手抄数字与 .tres 漂移）。
## 依赖：被收藏馆「角色」页签读取；键 = `CharacterData.get_character_key()`。
##
## 【口径】只写「资料」，不写玩法提示 —— 键位、消耗、冷却都由技能行/状态图鉴负责。
## 【长度】定位 ≤ 4 字（右栏只有 156px 宽，再长会折成半截），
##        正文 ≤ 3 行（详情区 360px 宽、24px 字号约 14 字/行）：
##        超出会顶出收藏馆的详情区，长设定请写进安全屋台词或开发日志。
## 未登记的角色不报错：界面回退到「（暂无介绍）」，新增角色可以先上线再补文案。

const PROFILES: Dictionary = {
	"nobita": {
		"tagline": "万能型",
		"bio": "本作主角。主副武器都能上手；觉醒「集中射击」让子弹附带即死。",
	},
	"bigg": {
		"tagline": "重火力",
		"bio": "体格最壮的一档。机枪、霰弹、马格南和小刀打完都不僵直，SA 能把周围敌人唱退。",
	},
	"suneo": {
		"tagline": "双背包",
		"bio": "天生带两个背包，两套武器按 SA 互换；喷雾携带上限还多一瓶。",
	},
	"shizuka": {
		"tagline": "续航位",
		"bio": "续航核心。SA「しゃがみ回避」蹲下即无敌；自己用治疗品时全队回血。",
	},
	"yasuo": {
		"tagline": "爆破手",
		"bio": "原作 §6 的「グレネード安雄」。攻击最高、防御最薄，自己的爆炸伤不到自己。",
	},
}


## 取某角色的介绍文案；未登记返回空字典（界面自行兜底）。
static func profile_for(character_key: String) -> Dictionary:
	return PROFILES.get(character_key, {})
