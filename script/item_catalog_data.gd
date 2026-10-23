class_name ItemCatalogData extends RefCounted

## ── 架构定位 ──
## 系统：物品总表 ｜ 层：数据（常量表）
## 联机：不涉及
## 职责：全游戏「武器 / 医疗品 / 辅助品 / 投掷物 / 弹药」的静态清单。
## 依赖：被收藏馆界面与调试召唤菜单（Alt+W）读取
##
## ⚠ 本文件由 `tools/gen_item_catalog.py` 生成，**别手改** —— 改完 object/*.tres 重跑生成器。

const ENTRIES: Array[Dictionary] = [
	{"id": "at_rifle_01", "name": "巴雷特 M82", "group": "主武器（远程）", "path": "res://object/weapon_at_rifle_01.tres"},
	{"id": "bowgun_01", "name": "十字弩", "group": "主武器（远程）", "path": "res://object/weapon_bowgun.tres"},
	{"id": "launcher_01", "name": "榴弹发射器", "group": "主武器（远程）", "path": "res://object/weapon_grenade_launcher.tres"},
	{"id": "launcher_02", "name": "Denel-MGL", "group": "主武器（远程）", "path": "res://object/weapon_launcher_02.tres"},
	{"id": "launcher_acid_01", "name": "酸性榴弹发射器", "group": "主武器（远程）", "path": "res://object/weapon_launcher_acid.tres"},
	{"id": "launcher_ice_01", "name": "冰结榴弹发射器", "group": "主武器（远程）", "path": "res://object/weapon_launcher_ice.tres"},
	{"id": "launcher_thunder_01", "name": "电击榴弹发射器", "group": "主武器（远程）", "path": "res://object/weapon_launcher_thunder.tres"},
	{"id": "magnum_01", "name": "马格南", "group": "主武器（远程）", "path": "res://object/weapon_magnum.tres"},
	{"id": "magnum_02", "name": "沙漠之鹰", "group": "主武器（远程）", "path": "res://object/weapon_magnum_02.tres"},
	{"id": "magnum_03", "name": "Endfield", "group": "主武器（远程）", "path": "res://object/weapon_magnum_03.tres"},
	{"id": "mg_01", "name": "M249 轻机枪", "group": "主武器（远程）", "path": "res://object/weapon_mg_01.tres"},
	{"id": "pistol_01", "name": "贝雷塔 M92F", "group": "主武器（远程）", "path": "res://object/weapon_pistol.tres"},
	{"id": "pistol_02", "name": "S&W M36 左轮", "group": "主武器（远程）", "path": "res://object/weapon_pistol_02.tres"},
	{"id": "pistol_03", "name": "FN-57 手枪", "group": "主武器（远程）", "path": "res://object/weapon_pistol_03.tres"},
	{"id": "pistol_04", "name": "贝雷塔 M93R", "group": "主武器（远程）", "path": "res://object/weapon_pistol_04.tres"},
	{"id": "rifle_01", "name": "AK-47", "group": "主武器（远程）", "path": "res://object/weapon_rifle.tres"},
	{"id": "rifle_02", "name": "M4-A1", "group": "主武器（远程）", "path": "res://object/weapon_rifle_02.tres"},
	{"id": "rifle_03", "name": "FA-MAS", "group": "主武器（远程）", "path": "res://object/weapon_rifle_03.tres"},
	{"id": "rocket_01", "name": "火箭筒（RPG-7）", "group": "主武器（远程）", "path": "res://object/weapon_rocket_launcher.tres"},
	{"id": "rocket_02", "name": "M202 四联火箭", "group": "主武器（远程）", "path": "res://object/weapon_rocket_02.tres"},
	{"id": "rocket_03", "name": "便携式地对空导弹", "group": "主武器（远程）", "path": "res://object/weapon_rocket_03.tres"},
	{"id": "shotgun_01", "name": "M870 霰弹枪", "group": "主武器（远程）", "path": "res://object/weapon_shotgun.tres"},
	{"id": "shotgun_02", "name": "贝内利 M4", "group": "主武器（远程）", "path": "res://object/weapon_shotgun_02.tres"},
	{"id": "shotgun_03", "name": "Striker", "group": "主武器（远程）", "path": "res://object/weapon_shotgun_03.tres"},
	{"id": "smg_01", "name": "Vz61 蝎式", "group": "主武器（远程）", "path": "res://object/weapon_smg.tres"},
	{"id": "smg_02", "name": "Vz61 蝎式", "group": "主武器（远程）", "path": "res://object/weapon_smg_02.tres"},
	{"id": "smg_03", "name": "FN-P90", "group": "主武器（远程）", "path": "res://object/weapon_smg_03.tres"},
	{"id": "sniper_01", "name": "M700 狙击枪", "group": "主武器（远程）", "path": "res://object/weapon_sniper.tres"},
	{"id": "sniper_02", "name": "德拉贡诺夫", "group": "主武器（远程）", "path": "res://object/weapon_sniper_02.tres"},
	{"id": "sniper_03", "name": "H&K PSG1", "group": "主武器（远程）", "path": "res://object/weapon_sniper_03.tres"},
	{"id": "bat_01", "name": "金属球棒", "group": "副武器 / 近战", "path": "res://object/weapon_metal_bat.tres"},
	{"id": "combat_knife", "name": "战斗刀", "group": "副武器 / 近战", "path": "res://object/weapon_combat_knife.tres"},
	{"id": "fire_axe", "name": "防火斧", "group": "副武器 / 近战", "path": "res://object/weapon_fire_axe.tres"},
	{"id": "frypan_01", "name": "平底锅", "group": "副武器 / 近战", "path": "res://object/weapon_frypan.tres"},
	{"id": "knife_01", "name": "小刀", "group": "副武器 / 近战", "path": "res://object/weapon_knife.tres"},
	{"id": "knuckles", "name": "指虎", "group": "副武器 / 近战", "path": "res://object/weapon_knuckles.tres"},
	{"id": "pipe", "name": "铁管", "group": "副武器 / 近战", "path": "res://object/weapon_pipe.tres"},
	{"id": "shovel", "name": "铁锹", "group": "副武器 / 近战", "path": "res://object/weapon_shovel.tres"},
	{"id": "sledgehammer", "name": "大锤", "group": "副武器 / 近战", "path": "res://object/weapon_sledgehammer.tres"},
	{"id": "uchigatana", "name": "打刀", "group": "副武器 / 近战", "path": "res://object/weapon_uchigatana.tres"},
	{"id": "aid_box_01", "name": "救急箱", "group": "治疗品", "path": "res://object/item_aid_box.tres"},
	{"id": "first_aid_spray", "name": "急救喷雾", "group": "治疗品", "path": "res://object/item_first_aid_spray.tres"},
	{"id": "adrenaline_01", "name": "肾上腺素", "group": "辅助品", "path": "res://object/item_adrenaline.tres"},
	{"id": "painkiller_01", "name": "镇痛剂", "group": "辅助品", "path": "res://object/item_painkiller.tres"},
	{"id": "acid_bottle_01", "name": "ディモ酢瓶", "group": "投掷物", "path": "res://object/item_acid_bottle.tres"},
	{"id": "bolt_grenade_01", "name": "ボルトグレネード", "group": "投掷物", "path": "res://object/item_bolt_grenade.tres"},
	{"id": "dynamite_01", "name": "炸药", "group": "投掷物", "path": "res://object/throwable_dynamite.tres"},
	{"id": "flash_01", "name": "闪光弹", "group": "投掷物", "path": "res://object/throwable_flash.tres"},
	{"id": "grenade_01", "name": "手雷", "group": "投掷物", "path": "res://object/item_grenade.tres"},
	{"id": "molotov_01", "name": "燃烧瓶", "group": "投掷物", "path": "res://object/item_molotov.tres"},
	{"id": "nitrogen_01", "name": "液体窒素ボトル", "group": "投掷物", "path": "res://object/item_nitrogen.tres"},
	{"id": "throwing_knife_01", "name": "スローイングナイフ", "group": "投掷物", "path": "res://object/item_throwing_knife.tres"},
	{"id": "ammo_bowgun", "name": "弩箭", "group": "弹药", "path": "res://object/item_bowgun_ammo.tres"},
	{"id": "ammo_launcher", "name": "榴弹", "group": "弹药", "path": "res://object/item_launcher_ammo.tres"},
	{"id": "ammo_magnum", "name": "马格南子弹", "group": "弹药", "path": "res://object/item_magnum_ammo.tres"},
	{"id": "ammo_pistol", "name": "手枪子弹", "group": "弹药", "path": "res://object/item_pistol_ammo.tres"},
	{"id": "ammo_rifle", "name": "步枪子弹", "group": "弹药", "path": "res://object/item_rifle_ammo.tres"},
	{"id": "ammo_rocket", "name": "火箭弹", "group": "弹药", "path": "res://object/item_rocket_ammo.tres"},
	{"id": "ammo_shotgun", "name": "霰弹枪子弹", "group": "弹药", "path": "res://object/item_shotgun_ammo.tres"},
	{"id": "ammo_smg", "name": "冲锋枪子弹", "group": "弹药", "path": "res://object/item_smg_ammo.tres"},
	{"id": "ammo_sniper", "name": "狙击枪子弹", "group": "弹药", "path": "res://object/item_sniper_ammo.tres"}
]


## 收藏馆要展示的条目：**弹药不算收藏品**（2026-10-23 用户定），其余全给。
static func collection_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in ENTRIES:
		if str(e.get("group", "")) != "弹药":
			out.append(e)
	return out


## 按分组取条目（分组名见 catalog.json 的 groups）。
static func by_group(group: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in ENTRIES:
		if str(e.get("group", "")) == group:
			out.append(e)
	return out
