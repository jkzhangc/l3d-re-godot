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

## 通用默认击中音（2026-11-04 用户指定）：数据没配、属性也没有专属音时用它 ——
## 典型场景就是**普通远程武器**（element = NONE）。音调 1.5 见 `resolve_hit_pitch()`。
## 放在这里而不是 `WeaponData.hit_sound` 的导出默认值上，是因为后者一旦非空就会
## 抢在属性表前面（`resolve_hit` 是「数据优先」），火/雷/冰/酸的专属击中音会被整体覆盖。
const DEFAULT_HIT_SOUND: AudioStream = preload("res://sound/殴る.ogg")
const DEFAULT_HIT_SOUND_PITCH: float = 1.5


## 该属性的默认爆炸音（NONE / 表外 → null）。
static func explosion_sound(element: int) -> AudioStream:
	return EXPLOSION_SOUNDS.get(element, null)


## 该属性的默认击中音（NONE / 表外 → null）。
static func hit_sound(element: int) -> AudioStream:
	return HIT_SOUNDS.get(element, null)


## 数据优先、属性兜底：给子弹/投掷物选爆炸音用。
static func resolve_explosion(explicit: AudioStream, element: int) -> AudioStream:
	return explicit if explicit != null else explosion_sound(element)


## 数据优先、属性其次、最后通用默认（2026-11-04 起**恒非 null**）。
## 想「这把武器命中不出声」请把 `hit_sound` 配成静音资源 —— 空值现在等于「用默认打击音」。
static func resolve_hit(explicit: AudioStream, element: int) -> AudioStream:
	if explicit != null:
		return explicit
	var by_element: AudioStream = hit_sound(element)
	return by_element if by_element != null else DEFAULT_HIT_SOUND


## 与 `resolve_hit` 配套的音调：只有落到**通用默认**那一层才是 1.5，
## 武器自定义音效 / 属性专属音效一律保持原调（1.0）。
static func resolve_hit_pitch(explicit: AudioStream, element: int) -> float:
	if explicit != null or hit_sound(element) != null:
		return 1.0
	return DEFAULT_HIT_SOUND_PITCH
