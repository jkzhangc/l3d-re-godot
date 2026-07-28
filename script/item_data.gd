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
