class_name ItemData extends Resource

## ── 架构定位 ──
## 系统：物品数据 ｜ 层：数据（Resource）
## 联机：ID/路径白名单，禁止远端传 Resource
## 职责：物品基类：类型枚举、堆叠、图标、拾取外观等通用字段。
## 依赖：被 WeaponData / ThrowableData 继承

## 物品数据 — 可在检查器中可视化编辑

enum ItemType {
	CONSUMABLE,   ## 消耗品（药水、食物）
	MATERIAL,     ## 材料
	KEY_ITEM,     ## 关键道具
	WEAPON,       ## 武器
	ARMOR,        ## 防具
	AMMO,         ## 弹药
	HEALING,      ## 治疗品（急救喷雾等，数字3键使用）
	SUPPORT,      ## 辅助品（药品等，数字4键使用）
	THROWABLE,    ## 投掷物（手雷/燃烧瓶，数字5键使用）
}

@export var item_id: String = ""              ## 唯一标识
@export var item_name: String = "新物品"       ## 显示名称
## 物品类型（决定 HUD 槽位、拾取行为与收藏分类）
@export var item_type: int = ItemType.CONSUMABLE
@export_multiline var description: String = "" ## 描述
@export var icon: Texture2D                    ## 图标（可选）
@export_multiline var effect_text: String = "" ## 效果描述（如"回复 +50 HP"）
@export var sell_price: int = 0               ## 售价
@export var stackable: bool = false           ## 可否堆叠
@export var max_stack: int = 99               ## 最大堆叠数

@export_group("地面显示")
## 物品掉落在地面时的精灵表（VX Ace 行走图格式，用于生成拾取物）
@export var pickup_texture: Texture2D
## 精灵表中的角色索引
@export var pickup_char_idx: int = 0
## 朝向（0=下, 1=左, 2=右, 3=上）
@export var pickup_direction: int = 0
## 地面踏步帧序列（空=使用默认序列 [1, 0, 1, 2]）
@export var pickup_step_frames: Array[int] = []
## 地面踏步每帧持续时间，秒（0=使用默认 0.25s）
@export var pickup_step_duration: float = 0.0
## 地面是否启用踏步动画
@export var pickup_animated: bool = true
## ★拾取方式（2026-10-26 用户需求）：false = 走上去自动拾取（默认）；
## true = 靠近后**按住功能键(D)** 拾取（进度环 + 头顶 D 键帽提示，同武器替换的键帽）。
## 治疗品 / 辅助品 / **投掷物**默认开启，避免"路过顺手捡走"（投掷物 2026-10-27 补齐）。
## ⚠ 只对 `healing_pickup.tscn` 这一族掉落物（治疗品/辅助品/投掷物）生效；
##   武器掉落物走 `weapon_pickup.require_function_key`（它本身是长按替换）。
@export var pickup_requires_function_key: bool = false

@export_group("使用效果")
## ★拾取即用（2026-10-28 用户需求）：true = 捡到瞬间就把效果结算在拾取者身上，
## **不进入治疗品/辅助品槽位**（对应原作「不能携带」的グリーンハーブ / ミネラルウォーター）。
## 结算走 `player.apply_item_effects()` —— 与按键使用同一套 HP/TP/強化/闪烁/音效。
## 拾取者对应数值已满（HP 满 / TP 满）时视为无法使用 → **物品留在地上不消耗**。
## ⚠ 只对 `healing_pickup.tscn` 这一族掉落物生效（武器/投掷物忽略本开关）。
## ⚠ 建议与 `pickup_requires_function_key` 一起打开，否则触碰即自动吃掉。
@export var use_on_pickup: bool = false
## 使用时回复的 HP 量（0=不回复）
@export var hp_restore: int = 0
## 使用时回复的 TP 量（0=不回复）
@export var tp_restore: int = 0
## 鎮痛剤（原作 強化アイテム）：持续秒数内受到的伤害归零。0 = 无此效果。
## ⚠ 只免疫伤害数字，Heat/削り/Push 等状态照常生效（原作说明书明确）。
@export var painkiller_seconds: float = 0.0
## アドレナリン（原作 強化アイテム）：持续秒数内攻击力 ×2。0 = 无此效果。
@export var adrenaline_seconds: float = 0.0

@export_group("拾取音效")
## 拾取该物品（武器/治疗品/投掷物等，所有子类通用）时的音效。
## 留空 = 用 Global.default_pickup_sfx_path 的全局默认音（2026-09-15 用户定稿 bio1_アイテム入手２）。
@export var pickup_sound: AudioStream = null
## 拾取音效音调（<=0 = 按原调 1.0 播放，沿用项目 0=沿用惯例）。
@export_range(0.0, 4.0, 0.1) var pickup_sound_pitch: float = 1.0

@export_group("使用表现")
## 使用本物品时的**全屏闪烁颜色**（治疗品 / 辅助品共用这一套表现）。
## alpha 会再乘 `Global.item_use_flash_peak_alpha`（全局峰值上限），所以这里一般填 1。
## 例：急救喷雾=绿、鎮痛剤=冷白、アドレナリン=橙。
@export var use_flash_color: Color = Color(0.35, 1.0, 0.5, 1.0)
## 闪烁总时长（秒）；0 = 本次使用不闪。
@export_range(0.0, 2.0, 0.01) var use_flash_duration: float = 0.32
## 使用音效。留空 = `Global.default_item_use_sound`（默认 回復1.ogg）。
@export var use_sound: AudioStream = null
## 使用音效音调（<=0 = 原调 1.0）。
@export_range(0.0, 4.0, 0.1) var use_sound_pitch: float = 1.0


## 地面掉落物是否必须「按住功能键(D)」才能拾取（派生数据给 healing_pickup 用）。
## 治疗品 / 辅助品默认开启（见各自 .tres 的 pickup_requires_function_key）。
func needs_function_key_pickup() -> bool:
	return pickup_requires_function_key


## 是否「拾取即用」（捡到就结算效果、不进背包）。见 use_on_pickup。
func uses_on_pickup() -> bool:
	return use_on_pickup


func get_type_name() -> String:
	match item_type:
		ItemType.CONSUMABLE: return "消耗品"
		ItemType.MATERIAL:   return "材料"
		ItemType.KEY_ITEM:   return "关键道具"
		ItemType.WEAPON:     return "武器"
		ItemType.ARMOR:      return "防具"
		ItemType.AMMO:       return "弹药"
		ItemType.HEALING:    return "治疗品"
		ItemType.SUPPORT:    return "辅助品"
		ItemType.THROWABLE:  return "投掷物"
	return "未知"
