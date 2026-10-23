extends SceneTree

## 校验「武器单体动作图」的数据层：攻击序列步号 → 列号映射 + 图集切格。
## 不依赖 autoload（只 load weapon_data.gd），可以在 --script 模式跑。
##   godot --headless --path . --script res://outputs/pickup_map/check_melee_sprite.gd

const WD_PATH := "res://script/weapon_data.gd"
const SHEET := "res://art/WeaponAttack/木刀/木刀_attack1.png"

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _init() -> void:
	var cls: GDScript = load(WD_PATH)
	var wd: Resource = cls.new()
	var tex: Texture2D = load(SHEET)

	print("=== 1) 未配动作图 → 永远 -1（旧行为） ===")
	_check("has_melee_weapon_sprite", wd.call("has_melee_weapon_sprite"), false)
	_check("col(1)", wd.call("get_melee_weapon_sprite_col", 1), -1)

	wd.set("melee_weapon_sprite", tex)
	wd.set("melee_attack_char_sequence", [3, 4, 5, 2] as Array[int])
	print("=== 2) 空绑定表 → 按步序自动推（4 步序列） ===")
	_check("has_melee_weapon_sprite", wd.call("has_melee_weapon_sprite"), true)
	_check("第1步=前摇(0)", wd.call("get_melee_weapon_sprite_col", 0), 0)
	_check("第2步=挥动(1)", wd.call("get_melee_weapon_sprite_col", 1), 1)
	_check("第3步=挥动(1)", wd.call("get_melee_weapon_sprite_col", 2), 1)
	_check("第4步=后摇(2)", wd.call("get_melee_weapon_sprite_col", 3), 2)
	_check("越界(4)=-1", wd.call("get_melee_weapon_sprite_col", 4), -1)
	_check("非攻击(-1)=-1", wd.call("get_melee_weapon_sprite_col", -1), -1)

	print("=== 3) 用户示例：动作图第1帧落在攻击第2帧 → {1:0,2:1,3:2} ===")
	wd.set("melee_weapon_sprite_seq_cols", {1: 0, 2: 1, 3: 2})
	_check("第1步 未列出=-1", wd.call("get_melee_weapon_sprite_col", 0), -1)
	_check("第2步=动作图第1帧(0)", wd.call("get_melee_weapon_sprite_col", 1), 0)
	_check("第3步=动作图第2帧(1)", wd.call("get_melee_weapon_sprite_col", 2), 1)
	_check("第4步=动作图第3帧(2)", wd.call("get_melee_weapon_sprite_col", 3), 2)

	print("=== 4) 3 步序列 + 越界列号被夹到 0..2 ===")
	wd.set("melee_attack_char_sequence", [3, 4, 2] as Array[int])
	wd.set("melee_weapon_sprite_seq_cols", {0: 0, 1: 9, 2: 2})
	_check("第2步 9→2", wd.call("get_melee_weapon_sprite_col", 1), 2)

	print("=== 5) 图集切格 ===")
	var w: int = tex.get_width()
	var h: int = tex.get_height()
	_check("图集尺寸", Vector2i(w, h), Vector2i(636, 592))
	_check("格尺寸", Vector2i(w / 3, h / 4), Vector2i(212, 148))

	print("=== 6) 偏移表空 → ZERO ===")
	_check("offset(null)", wd.call("get_melee_weapon_sprite_offset", null, 0), Vector2.ZERO)

	print("\n失败 %d 项" % _fail)
	quit(1 if _fail > 0 else 0)
