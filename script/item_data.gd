class_name ItemData extends Resource
## 物品数据 — 可在检查器中可视化编辑

enum ItemType {
	CONSUMABLE,   ## 消耗品（药水、食物）
	MATERIAL,     ## 材料
	KEY_ITEM,     ## 关键道具
	WEAPON,       ## 武器
	ARMOR,        ## 防具
	AMMO,         ## 弹药
	HEALING,      ## 治疗品（医疗包等，数字3键使用）
	SUPPORT,      ## 辅助品（药品等，数字4键使用）
}

@export var item_id: String = ""              ## 唯一标识
@export var item_name: String = "新物品"       ## 显示名称
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

@export_group("使用效果")
## 使用时回复的 HP 量（0=不回复）
@export var hp_restore: int = 0
## 使用时回复的 TP 量（0=不回复）
@export var tp_restore: int = 0


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
	return "未知"
