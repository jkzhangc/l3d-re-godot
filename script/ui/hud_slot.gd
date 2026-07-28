extends Panel
## HUD 槽位 — 竖排武器/物品快捷槽。包含热键、名称、弹药/数量全部信息。
##
## 由 hud.gd 动态创建。slot_type: "weapon" | "heal" | "support" | "throwable"


# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════

var slot_index: int = 0           ## 0-4, 对应按键 1-5
var slot_type: String = "weapon"
var slot_key: String = ""         ## Global.equipment 的 key


# ═══════════════════════════════════════
# 子节点
# ═══════════════════════════════════════

var _hotkey_label: Label = null
var _icon_rect: TextureRect = null
var _name_label: Label = null
var _count_label: Label = null
var _reserve_label: Label = null


# ═══════════════════════════════════════
# 样式
# ═══════════════════════════════════════

const COLOR_ACTIVE := Color(1.0, 0.85, 0.2, 0.9)
const COLOR_NORMAL := Color(0.7, 0.7, 0.7, 0.5)
const COLOR_EMPTY  := Color(0.35, 0.35, 0.35, 0.3)
const COLOR_AMMO   := Color(0.9, 0.85, 0.5, 0.9)
const COLOR_RESERVE := Color(0.7, 0.7, 0.7, 0.8)

const SLOT_SIZE := Vector2(104, 52)


# ═══════════════════════════════════════
# 构建
# ═══════════════════════════════════════

func _ready() -> void:
	custom_minimum_size = SLOT_SIZE
	size = SLOT_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_update_style(false)


func _build_ui() -> void:
	# 内容容器
	var hbox := HBoxContainer.new()
	hbox.name = "SlotContent"
	hbox.position = Vector2(3, 2)
	hbox.size = Vector2(SLOT_SIZE.x - 6, SLOT_SIZE.y - 4)
	hbox.add_theme_constant_override("separation", 3)
	add_child(hbox)

	# 左侧：热键
	_hotkey_label = Label.new()
	_hotkey_label.name = "Hotkey"
	_hotkey_label.text = str(slot_index + 1)
	_hotkey_label.add_theme_font_size_override("font_size", 13)
	_hotkey_label.custom_minimum_size = Vector2(14, 0)
	_hotkey_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(_hotkey_label)

	# 左侧：图标
	_icon_rect = TextureRect.new()
	_icon_rect.name = "Icon"
	_icon_rect.custom_minimum_size = Vector2(16, 16)
	_icon_rect.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hbox.add_child(_icon_rect)

	# 右侧：名称 + 弹药行 + 备弹行
	var right_vbox := VBoxContainer.new()
	right_vbox.name = "RightInfo"
	right_vbox.add_theme_constant_override("separation", 0)
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(right_vbox)

	_name_label = Label.new()
	_name_label.name = "Name"
	_name_label.text = "—"
	_name_label.add_theme_font_size_override("font_size", 10)
	_name_label.clip_text = true
	right_vbox.add_child(_name_label)

	_count_label = Label.new()
	_count_label.name = "Count"
	_count_label.text = ""
	_count_label.add_theme_font_size_override("font_size", 9)
	right_vbox.add_child(_count_label)

	_reserve_label = Label.new()
	_reserve_label.name = "Reserve"
	_reserve_label.text = ""
	_reserve_label.add_theme_font_size_override("font_size", 8)
	right_vbox.add_child(_reserve_label)


# ═══════════════════════════════════════
# 每帧刷新
# ═══════════════════════════════════════

func refresh(is_active: bool) -> void:
	var item: Resource = null
	var name_str: String = "—"
	var count_str: String = ""
	var reserve_str: String = ""
	var name_color := COLOR_EMPTY
	var count_color := COLOR_AMMO

	match slot_type:
		"weapon":
			item = Global.equipment.get(slot_key) as WeaponData
			if item:
				var wd: WeaponData = item as WeaponData
				name_str = wd.item_name
				name_color = Color(0.9, 0.9, 0.9, 0.9)
				if wd.is_ranged and wd.magazine_capacity > 0:
					var mag: int = Global.weapon_magazines.get(wd.item_id, 0)
					count_str = "%d/%d" % [mag, wd.magazine_capacity]
					var reserve: int = Global.count_ammo_item(wd.ammo_item_id)
					reserve_str = "备弹 %d" % reserve
				elif not wd.is_ranged:
					count_str = "近战"
					count_color = Color(0.7, 0.7, 0.7, 0.7)

		"heal":
			item = Global.healing_item
			if item:
				name_str = item.item_name
				name_color = Color(0.9, 0.9, 0.9, 0.9)
				var c := _count_in_inventory(item)
				count_str = "x%d" % c if c > 0 else ""

		"support":
			item = Global.support_item
			if item:
				name_str = item.item_name
				name_color = Color(0.9, 0.9, 0.9, 0.9)
				var c := _count_in_inventory(item)
				count_str = "x%d" % c if c > 0 else ""

		"throwable":
			pass  # 预留

	# 更新显示
	_name_label.text = name_str
	_name_label.add_theme_color_override("font_color", name_color)
	_icon_rect.texture = item.icon if item and item.icon else null
	_count_label.text = count_str
	_count_label.add_theme_color_override("font_color", count_color)
	_reserve_label.text = reserve_str
	_reserve_label.add_theme_color_override("font_color", COLOR_RESERVE)

	_update_style(is_active)


func _count_in_inventory(target: Resource) -> int:
	if not target:
		return 0
	var c: int = 0
	for it: Resource in Global.inventory:
		if it and it.item_id == target.item_id:
			c += 1
	return c


func _update_style(is_active: bool) -> void:
	var bg := StyleBoxFlat.new()
	bg.set_corner_radius_all(3)
	bg.border_width_left = 2
	bg.border_width_right = 2
	bg.border_width_top = 2
	bg.border_width_bottom = 2

	if is_active:
		bg.bg_color = Color(0.12, 0.10, 0.04, 0.9)
		bg.border_color = COLOR_ACTIVE
		_hotkey_label.add_theme_color_override("font_color", Color(1, 0.9, 0.2, 1.0))
	else:
		bg.bg_color = Color(0.06, 0.06, 0.10, 0.85)
		bg.border_color = COLOR_NORMAL
		_hotkey_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3, 0.6))

	add_theme_stylebox_override("panel", bg)
