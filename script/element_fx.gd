extends RefCounted

## ── 架构定位 ──
## 系统：属性表现（音效）｜ 层：工具类（RefCounted，纯静态）
## 联机：纯本地表现；两端各自从本地数据解析，资源不过网络
## 职责：按 `WeaponData.Element` 给出**爆炸音 / 击中音**的默认值。子弹与投掷物
##       自己在数据里配了音效时以数据为准；没配才回退到这张表。
## 依赖：sound/ 下的具体音效文件
##
## 【为什么集中在一张表】用户 2026-11-01 要求「每个属性有各自的爆炸音与击中音」：
## 逐个武器/投掷物去配容易漏，表里给出默认值后，新加一把属性武器自动有声音。
## 想改某个属性的音色：改这里的 preload；只想改某件道具：改它的 tres 字段。
##
## 【属性语义（原作 §4.5，改行为前先读）】
##   炎 = 大伤害 + 持续燃烧掉血（燃烧中仍会攻击）
##   雷 = 大伤害 + 感电（**攻击不能**，直到解除）
##   氷 = 大伤害 + 冻结（可被一击粉碎=即死；碎不了受 1.5 倍伤）
##   酸 = 仅大伤害，无附加效果（抗性持有者最少的泛用属性）
## 上述 debuff 的实际结算在 `enemy.gd::take_damage()` 的「属性结算」段，
## 爆炸与直击走的是**同一个入口** —— 所以爆炸物天然带属性效果。

## 爆炸音（元素 → AudioStream）。NONE 不在表内 → 返回 null（沿用数据自己的爆炸音）。
const EXPLOSION_SOUNDS: Dictionary = {
	WeaponData.Element.FIRE: preload("res://sound/爆発3.ogg"),
	WeaponData.Element.LIGHTNING: preload("res://sound/しびれ3.ogg"),
	WeaponData.Element.ICE: preload("res://sound/ピキーン.ogg"),
	WeaponData.Element.ACID: preload("res://sound/酸着弾.ogg"),
}

## 击中音（元素 → AudioStream）。NONE 不在表内 → 返回 null。
const HIT_SOUNDS: Dictionary = {
	WeaponData.Element.FIRE: preload("res://sound/炎2.ogg"),
	WeaponData.Element.LIGHTNING: preload("res://sound/しびれ1.ogg"),
	WeaponData.Element.ICE: preload("res://sound/ガシャン.ogg"),
	WeaponData.Element.ACID: preload("res://sound/酸発射.ogg"),
}


## 该属性的默认爆炸音（NONE / 表外 → null）。
static func explosion_sound(element: int) -> AudioStream:
	return EXPLOSION_SOUNDS.get(element, null)


## 该属性的默认击中音（NONE / 表外 → null）。
static func hit_sound(element: int) -> AudioStream:
	return HIT_SOUNDS.get(element, null)


## 数据优先、属性兜底：给子弹/投掷物选爆炸音用。
static func resolve_explosion(explicit: AudioStream, element: int) -> AudioStream:
	return explicit if explicit != null else explosion_sound(element)


## 数据优先、属性兜底：给子弹选击中音用。
static func resolve_hit(explicit: AudioStream, element: int) -> AudioStream:
	return explicit if explicit != null else hit_sound(element)
