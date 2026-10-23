extends SceneTree

## 校验新生成的近战武器资源能被正常加载，并且「武器单体动作图」绑定正确。
##   godot --headless --path . --script res://outputs/pickup_map/check_melee_weapons.gd

const NEW_WEAPONS := [
	"res://object/weapon_fire_axe.tres",
	"res://object/weapon_sledgehammer.tres",
	"res://object/weapon_shovel.tres",
	"res://object/weapon_pipe.tres",
	"res://object/weapon_combat_knife.tres",
	"res://object/weapon_uchigatana.tres",
	"res://object/weapon_knuckles.tres",
]

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _init() -> void:
	for path: String in NEW_WEAPONS:
		var wd: WeaponData = load(path) as WeaponData
		if wd == null:
			_fail += 1
			print("  FAIL 载入失败 %s" % path)
			continue
		var seq: Array[int] = wd.get_melee_attack_char_sequence()
		var cols: String = ""
		for i: int in range(seq.size()):
			cols += "%d" % wd.get_melee_weapon_sprite_col(i)
		print("%-26s %-6s 攻%2d 速%.2f 近战=%s 序列=%s 列=%s 图集=%s 通用身体=%s" % [
			path.get_file(), wd.item_name, wd.attack_power, wd.attack_speed,
			str(not wd.is_ranged), str(seq), cols,
			"有" if wd.has_melee_weapon_sprite() else "无",
			str(wd.is_generic_melee_body(wd.weapon_walk_texture)),
		])
		_check("%s 有动作图" % wd.item_id, wd.has_melee_weapon_sprite(), true)
		_check("%s 是近战" % wd.item_id, wd.is_ranged, false)
		_check("%s 通用近战身体" % wd.item_id,
				wd.is_generic_melee_body(wd.weapon_walk_texture), true)
		_check("%s 首步有列" % wd.item_id, wd.get_melee_weapon_sprite_col(0) >= 0, true)
		_check("%s 末步有列" % wd.item_id,
				wd.get_melee_weapon_sprite_col(seq.size() - 1) >= 0, true)
		_check("%s 越界步=-1" % wd.item_id,
				wd.get_melee_weapon_sprite_col(seq.size()), -1)

	print("\n失败 %d 项" % _fail)
	quit(1 if _fail > 0 else 0)
