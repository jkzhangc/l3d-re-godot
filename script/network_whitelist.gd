extends RefCounted

## ── 架构定位 ──
## 系统：联机资源白名单 ｜ 层：网络（纯数据 + 纯查询，无状态、无副作用）
## 联机：Host/Client 两端共用；**唯一的资源合法性来源**
## 职责：集中定义联机可用的武器 / 投掷物 / 特感 / 僵尸变体 / 治疗品白名单，
##       并提供按 id 查表的静态方法。
## 依赖：无（只依赖项目内 .tres 资源；不引用 Net / Players / Global）
##
## 【为什么从 network_world.gd 抽出（2026-10-08）】原文件 5313 行里，本块约 175 行
## 是**唯一「纯数据 + 零副作用」**的部分：5 张常量表 + 25 个单资源常量 + 5 个按 id
## 查表方法。抽出后 network_world.gd 保留**同名常量转发别名 + 同名方法转发**，
## 因此 net_regression_harness.gd 子类对这些常量的直接引用零改动。
##
## 【铁律（原文件注释原样保留）】联机武器/投掷物/特感/变体**必须从本表的固定白名单
## 解析，绝不根据客户端输入动态 `load()` 资源**。客户端 RPC 只传 id，资源只从本表取。
##
## 【为什么是 RefCounted 而非静态类】Godot GDScript 无真正的静态字段；本表的所有
## 成员都是 `const`，`RefCounted` 只作命名空间用（配合 network_world.gd 的 preload 常量）。
## 实际全部查询走 `static func` / `const`，无需实例化。


# ═══════════════════════════════════════
# 治疗品白名单
# ═══════════════════════════════════════

## 治疗品白名单（D2 实测修复）：喷雾/药品此前不在联机同步范围——动态刷出的治疗品
## Client 看不见、预摆的 Client 本地私拿（Host 权威域无感知）→ 倒地时无喷雾可用。
const NETWORK_SPRAY: ItemData = preload("res://object/item_first_aid_spray.tres")
const NETWORK_PILLS: ItemData = preload("res://object/item_pills.tres")
const NETWORK_HEALINGS: Dictionary = {
	"first_aid_spray": NETWORK_SPRAY,
	"pills_01": NETWORK_PILLS,
}


# ═══════════════════════════════════════
# 武器白名单
# ═══════════════════════════════════════

const NETWORK_PISTOL: WeaponData = preload("res://object/weapon_pistol.tres")
const NETWORK_KNIFE: WeaponData = preload("res://object/weapon_knife.tres")
const NETWORK_RIFLE: WeaponData = preload("res://object/weapon_rifle.tres")
const NETWORK_SMG: WeaponData = preload("res://object/weapon_smg.tres")
const NETWORK_SHOTGUN: WeaponData = preload("res://object/weapon_shotgun.tres")
const NETWORK_SNIPER: WeaponData = preload("res://object/weapon_sniper.tres")
const NETWORK_MAGNUM: WeaponData = preload("res://object/weapon_magnum.tres")
const NETWORK_LAUNCHER: WeaponData = preload("res://object/weapon_grenade_launcher.tres")
const NETWORK_ROCKET: WeaponData = preload("res://object/weapon_rocket_launcher.tres")
const NETWORK_BOWGUN: WeaponData = preload("res://object/weapon_bowgun.tres")
const NETWORK_LAUNCHER_ACID: WeaponData = preload("res://object/weapon_launcher_acid.tres")
const NETWORK_LAUNCHER_ICE: WeaponData = preload("res://object/weapon_launcher_ice.tres")
const NETWORK_LAUNCHER_THUNDER: WeaponData = preload("res://object/weapon_launcher_thunder.tres")
const NETWORK_FRYSPAN: WeaponData = preload("res://object/weapon_frypan.tres")
const NETWORK_BAT: WeaponData = preload("res://object/weapon_metal_bat.tres")

## 联机武器必须从 Host 固定白名单解析，绝不根据客户端输入动态 load() 资源。
const NETWORK_WEAPONS: Dictionary = {
	"pistol_01": NETWORK_PISTOL,
	"knife_01": NETWORK_KNIFE,
	"rifle_01": NETWORK_RIFLE,
	"smg_01": NETWORK_SMG,
	"shotgun_01": NETWORK_SHOTGUN,
	"sniper_01": NETWORK_SNIPER,
	"magnum_01": NETWORK_MAGNUM,
	"launcher_01": NETWORK_LAUNCHER,
	"rocket_01": NETWORK_ROCKET,
	"bowgun_01": NETWORK_BOWGUN,
	"launcher_acid_01": NETWORK_LAUNCHER_ACID,
	"launcher_ice_01": NETWORK_LAUNCHER_ICE,
	"launcher_thunder_01": NETWORK_LAUNCHER_THUNDER,
	"frypan_01": NETWORK_FRYSPAN,
	"bat_01": NETWORK_BAT,
}


# ═══════════════════════════════════════
# 投掷物白名单
# ═══════════════════════════════════════

const NETWORK_GRENADE: ThrowableData = preload("res://object/item_grenade.tres")
const NETWORK_MOLOTOV: ThrowableData = preload("res://object/item_molotov.tres")
const NETWORK_FLASH: ThrowableData = preload("res://object/throwable_flash.tres")

## 投掷物同样必须由 Host 的固定白名单解析；客户端 RPC 绝不能指定资源或伤害。
const NETWORK_THROWABLES: Dictionary = {
	"grenade_01": NETWORK_GRENADE,
	"molotov_01": NETWORK_MOLOTOV,
	"flash_01": NETWORK_FLASH,
}


# ═══════════════════════════════════════
# 特感白名单
# ═══════════════════════════════════════

## 特感（SpecialEnemyData）白名单：键 = tres 的 id 字段（StringName 转字符串）。
## Host 在 spawn_special_enemy 注入 enemy.special_data 后，spawn 快照携带
## special_id 下发；Client 命中白名单才在本地重建表现节点（外观/帧表/受击盒）。
## 与武器/投掷物同铁律：Client RPC 永远只传 id，资源只从本表解析。
const NETWORK_SPECIAL_GREEN: SpecialEnemyData = preload("res://tres/specials/グリーンソルジャー.tres")
const NETWORK_SPECIAL_TYRANT: SpecialEnemyData = preload("res://tres/specials/タイラントT002.tres")
const NETWORK_SPECIAL_HUNTER: SpecialEnemyData = preload("res://tres/specials/ハンター.tres")
const NETWORK_SPECIAL_HUNTER_BETA: SpecialEnemyData = preload("res://tres/specials/ハンターβ.tres")
const NETWORK_SPECIAL_HUNTER_GAMMA: SpecialEnemyData = preload("res://tres/specials/ハンターγ.tres")
const NETWORK_SPECIAL_WITCH: SpecialEnemyData = preload("res://tres/specials/ブレアウィッチ.tres")
const NETWORK_SPECIALDEMOS: SpecialEnemyData = preload("res://tres/specials/ブレインディモス.tres")
const NETWORK_SPECIALS: Dictionary = {
	"green_soldier": NETWORK_SPECIAL_GREEN,
	"tyrant_t002": NETWORK_SPECIAL_TYRANT,
	"hunter": NETWORK_SPECIAL_HUNTER,
	"hunter_beta": NETWORK_SPECIAL_HUNTER_BETA,
	"hunter_gamma": NETWORK_SPECIAL_HUNTER_GAMMA,
	"blare_witch": NETWORK_SPECIAL_WITCH,
	"brain_demos": NETWORK_SPECIALDEMOS,
}


# ═══════════════════════════════════════
# 僵尸变体白名单
# ═══════════════════════════════════════

## 僵尸变体白名单（A5）：键 = tres 的 id 字段。Host 在 spawn_enemy 按 zombie_pool
## 选种后登记 enemy.variant_data，spawn 快照携带 variant_id；Client 命中白名单
## 才在本地重建差异化行走图。狂暴换皮不走本表 —— 随快照 element_state bit3 实时同步。
const NETWORK_VARIANT_MALE: ZombieVariant = preload("res://tres/zombies/男性ゾンビ.tres")
const NETWORK_VARIANT_FEMALE: ZombieVariant = preload("res://tres/zombies/女性ゾンビ.tres")
const NETWORK_VARIANT_STUDENT: ZombieVariant = preload("res://tres/zombies/学生ゾンビ.tres")
const NETWORK_VARIANT_CHUNEN: ZombieVariant = preload("res://tres/zombies/中年ゾンビ.tres")
const NETWORK_VARIANT_SHIKAN: ZombieVariant = preload("res://tres/zombies/士官ゾンビ.tres")
const NETWORK_VARIANT_JOSHI: ZombieVariant = preload("res://tres/zombies/女子学生ゾンビ.tres")
const NETWORK_VARIANT_JIKKENTAI: ZombieVariant = preload("res://tres/zombies/実験体ゾンビ.tres")
const NETWORK_VARIANT_KENKYUIN: ZombieVariant = preload("res://tres/zombies/研究員ゾンビ.tres")
const NETWORK_VARIANT_SHOKUIN: ZombieVariant = preload("res://tres/zombies/職員ゾンビ.tres")
const NETWORK_VARIANT_KUNRENSEI: ZombieVariant = preload("res://tres/zombies/訓練生ゾンビ.tres")
const NETWORK_VARIANT_RUNNER: ZombieVariant = preload("res://enemys/疾走体.tres")
const NETWORK_VARIANT_TANK: ZombieVariant = preload("res://enemys/重装体.tres")
const NETWORK_VARIANTS: Dictionary = {
	"male": NETWORK_VARIANT_MALE,
	"female": NETWORK_VARIANT_FEMALE,
	"student": NETWORK_VARIANT_STUDENT,
	"chunen": NETWORK_VARIANT_CHUNEN,
	"shikan": NETWORK_VARIANT_SHIKAN,
	"joshi_gakusei": NETWORK_VARIANT_JOSHI,
	"jikkentai": NETWORK_VARIANT_JIKKENTAI,
	"kenkyuin": NETWORK_VARIANT_KENKYUIN,
	"shokuin": NETWORK_VARIANT_SHOKUIN,
	"kunrensei": NETWORK_VARIANT_KUNRENSEI,
	"runner": NETWORK_VARIANT_RUNNER,
	"tank": NETWORK_VARIANT_TANK,
}


# ═══════════════════════════════════════
# 按 id 查表（唯一合法性入口）
# ═══════════════════════════════════════

## 按 weapon_id 取武器资源；不在白名单返回 null。
static func weapon_by_id(weapon_id: String) -> WeaponData:
	return NETWORK_WEAPONS.get(weapon_id) as WeaponData


## 按 item_id 取投掷物资源；不在白名单返回 null。
static func throwable_by_id(item_id: String) -> ThrowableData:
	return NETWORK_THROWABLES.get(item_id) as ThrowableData


## 按 special_id 取特感资源；空 id / 不在白名单返回 null。
static func special_by_id(special_id: String) -> SpecialEnemyData:
	if special_id.is_empty():
		return null
	return NETWORK_SPECIALS.get(special_id) as SpecialEnemyData


## 按 variant_id 取僵尸变体资源；空 id / 不在白名单返回 null。
static func variant_by_id(variant_id: String) -> ZombieVariant:
	if variant_id.is_empty():
		return null
	return NETWORK_VARIANTS.get(variant_id) as ZombieVariant
