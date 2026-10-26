extends Control

## ── 架构定位 ──
## 系统：物品可视化编辑器 ｜ 层：工具（**独立运行场景**，按 F6 启动）
## 联机：不涉及
## 职责：扫描项目内 .tres（左侧列表，可按类型筛选），像 Godot 检查器一样分组编辑
##       物品 / 武器 / 投掷物字段；贴图字段直接显示缩略图，并可打开项目图像浏览器
##       （文件夹树 + 缩略图 + 大图缩放预览）选择图片。
## 依赖：asset_browser.gd（资源选择器）；无 autoload，可在编辑器外独立运行
##
## 【为什么是独立场景而不是 @tool】
## Godot 2D 编辑器视图不会把鼠标事件交给场景里的 Control，@tool 场景只能看不能点。
## 运行本场景（F6）即可获得完整交互；保存仍写回 res:// 下的 .tres，编辑器会自动检测变化。
##
## 【操作】
##   左键资源行 → 编辑   Ctrl+S → 保存   重新加载 → 丢弃未保存修改
##   贴图行「…」→ 打开图像浏览器（可筛选文件夹、搜索、滚轮/按钮缩放预览）
##   字典行「编辑…」→ 行式编辑器（对象 / 标量）；「预览」→ 偏移可视化（拖黄点/武器图）
##
## ★本文件是开发工具，使用系统 UI 字体（14/16/20），不受游戏内像素字体 12 倍数规则约束。

const BROWSER := preload("res://script/tools/asset_browser.gd")
const OFFSET_PREVIEW := preload("res://script/tools/offset_preview.gd")
const REGION_PREVIEW := preload("res://script/tools/region_preview.gd")

const MODE_TEXTURE: int = 0
const MODE_AUDIO: int = 1
const MODE_SCENE: int = 2
const MODE_RESOURCE: int = 3

const K_WR := "weapon_ranged"
const K_WM := "weapon_melee"
const K_HEAL := "healing"
const K_SUPPORT := "support"
const K_THROW := "throwable"
const K_AMMO := "ammo"
const K_ITEM := "item"
const K_PLAYER := "player"
const K_ENEMY_Z := "enemy_zombie"
const K_ENEMY_S := "enemy_special"
const K_OTHER := "other"

const KIND_ORDER: Array[String] = [
	K_WR, K_WM, K_HEAL, K_SUPPORT, K_THROW, K_AMMO, K_ITEM,
	K_PLAYER, K_ENEMY_Z, K_ENEMY_S, K_OTHER,
]
const KIND_LABELS := {
	K_WR: "武器（远程）",
	K_WM: "武器（近战）",
	K_HEAL: "治疗品",
	K_SUPPORT: "辅助品",
	K_THROW: "投掷物",
	K_AMMO: "弹药",
	K_ITEM: "其它物品",
	K_PLAYER: "玩家角色",
	K_ENEMY_Z: "敌人（丧尸）",
	K_ENEMY_S: "敌人（特感）",
	K_OTHER: "其它资源",
}
## 列表行右侧的类型短名（完整名在筛选弹窗里）
const KIND_SHORT := {
	K_WR: "远程", K_WM: "近战", K_HEAL: "治疗", K_SUPPORT: "辅助",
	K_THROW: "投掷", K_AMMO: "弹药", K_ITEM: "物品",
	K_PLAYER: "玩家", K_ENEMY_Z: "丧尸", K_ENEMY_S: "特感", K_OTHER: "其它",
}

const SKIP_DIRS: Array[String] = [
	".godot", "addons", "release", "android", "未使用素材", "未安装的插件",
	".workbuddy", "chm_extract", "tmpcheck_review", "outputs",
	"master-server", "net_proto", "doc", "engine-reference",
]

# ── Godot 编辑器风格配色 ──
const C_BG := Color("#1e1e1e")
const C_PANEL := Color("#252526")
const C_PANEL2 := Color("#2d2d30")
const C_BORDER := Color("#3f3f46")
const C_TEXT := Color("#d4d4d4")
const C_MUTED := Color("#9a9a9a")
const C_ACCENT := Color("#4a9eff")
const C_ACCENT_DIM := Color("#264f78")
const C_OK := Color("#89d185")
const C_WARN := Color("#e2b93d")
const C_ERR := Color("#f48771")

## 通用字典的值类型（用于「对象 / 标量」字典的可视化编辑）
const DV_JSON := "json"
const DV_INT := "int"
const DV_FLOAT := "float"
const DV_BOOL := "bool"
const DV_STRING := "string"
const DV_VECTOR2 := "vector2"
const DV_COLOR := "color"
const DV_TEXTURE := "texture"
const DV_RESOURCE := "resource"

var _font: SystemFont = null
var _entries: Array[Dictionary] = []
var _filter: Dictionary = {}
var _search: String = ""
var _selected_path: String = ""

var _res: Resource = null
var _entry: Dictionary = {}
var _dirty: bool = false

var _prop_info: Dictionary = {}
var _field_docs: Dictionary = {}
var _group_cache: Dictionary = {}
var _re_group: RegEx = null
var _re_var: RegEx = null

var _icon_cache: Dictionary = {}
var _thumb_cache: Dictionary = {}

# UI
var _path_label: Label = null
var _dirty_label: Label = null
var _save_btn: Button = null
var _left_count: Label = null
var _search_edit: LineEdit = null
var _list_scroll: ScrollContainer = null
var _list_box: VBoxContainer = null
var _row_bgs: Dictionary = {}
var _row_marks: Dictionary = {}
var _inspector_scroll: ScrollContainer = null
var _inspector_box: VBoxContainer = null
var _preview_title: Label = null
var _preview_clip: Control = null
var _preview_tex: TextureRect = null
var _preview_placeholder: Label = null
var _preview_info: Label = null
var _zoom_label: Label = null
var _zoom: float = 1.0
var _preview_texture: Texture2D = null
var _open_in_browser_btn: Button = null

var _browser: Control = null
var _filter_overlay: Control = null
var _json_overlay: Control = null
var _texture_dict_overlay: Control = null
var _generic_dict_overlay: Control = null
var _resource_overlay: Control = null
var _offset_overlay: Control = null
var _offset_preview_btn: Button = null
var _region_overlay: Control = null
var _region_preview_btn: Button = null
var _toast: Label = null
var _toast_tween: Tween = null

# 当前贴图/资源行（选择后只刷新这一行，避免整页重建导致滚动跳顶）
var _asset_rows: Dictionary = {}


func _ready() -> void:
	## 场景里预置的「按 F6 运行」提示只在编辑器预览里出现
	var hint: Node = get_node_or_null("EditorHint")
	if hint != null:
		hint.visible = false
		hint.queue_free()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	custom_minimum_size = Vector2(1200, 720)
	_build_theme()
	_init_regex()
	_build_ui()
	_scan_resources()
	_rebuild_list()
	_show_empty_inspector()
	resized.connect(_layout)
	_layout()


# ═══════════════════════════════════════
# 主题 / 布局
# ═══════════════════════════════════════

func _build_theme() -> void:
	_font = SystemFont.new()
	_font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI", "Noto Sans CJK SC", "sans-serif",
	])
	_font.font_weight = 400
	var th := Theme.new()
	th.default_font = _font
	th.default_font_size = 14
	theme = th


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 顶栏
	var top := Panel.new()
	top.name = "TopBar"
	top.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 0))
	add_child(top)

	var title := _label("物品可视化编辑器", 20, C_TEXT)
	title.position = Vector2(16, 12)
	title.size = Vector2(240, 32)
	top.add_child(title)

	_path_label = _label("", 12, C_MUTED)
	_path_label.position = Vector2(258, 18)
	_path_label.size = Vector2(400, 22)
	_path_label.clip_text = true
	top.add_child(_path_label)

	_dirty_label = _label("", 12, C_MUTED)
	_dirty_label.position = Vector2(258, 38)
	_dirty_label.size = Vector2(400, 18)
	top.add_child(_dirty_label)

	var reload := _button("重新加载", false)
	reload.name = "ReloadBtn"
	reload.pressed.connect(_reload_current)
	top.add_child(reload)

	_save_btn = _button("保存  Ctrl+S", true)
	_save_btn.name = "SaveBtn"
	_save_btn.pressed.connect(_save_current)
	top.add_child(_save_btn)

	# 左栏
	var left := Panel.new()
	left.name = "LeftPanel"
	left.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 4))
	add_child(left)

	var list_title := _label("资源列表", 16, C_TEXT)
	list_title.position = Vector2(14, 12)
	list_title.size = Vector2(160, 24)
	left.add_child(list_title)

	_left_count = _label("", 12, C_MUTED)
	_left_count.position = Vector2(140, 16)
	_left_count.size = Vector2(158, 20)
	_left_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	left.add_child(_left_count)

	_search_edit = LineEdit.new()
	_search_edit.position = Vector2(14, 46)
	_search_edit.size = Vector2(220, 30)
	_search_edit.placeholder_text = "搜索名称 / id / 路径…"
	_search_edit.clear_button_enabled = true
	_search_edit.text_changed.connect(_on_search_changed)
	left.add_child(_search_edit)

	var filter_btn := _button("筛选…", false)
	filter_btn.position = Vector2(244, 46)
	filter_btn.size = Vector2(96, 30)
	filter_btn.pressed.connect(_open_filter)
	left.add_child(filter_btn)

	var rescan := _button("↻", false)
	rescan.position = Vector2(312, 12)
	rescan.size = Vector2(28, 26)
	rescan.tooltip_text = "重新扫描项目里的 .tres"
	rescan.pressed.connect(func():
		_scan_resources()
		_rebuild_list()
		_toast_show("已重新扫描：%d 个资源" % _entries.size(), C_OK))
	left.add_child(rescan)

	_list_scroll = ScrollContainer.new()
	_list_scroll.position = Vector2(8, 86)
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(_list_scroll)

	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 1)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(_list_box)

	# 中栏：检查器
	var insp := Panel.new()
	insp.name = "InspectorPanel"
	insp.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 4))
	add_child(insp)

	_inspector_scroll = ScrollContainer.new()
	_inspector_scroll.position = Vector2(8, 8)
	_inspector_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	insp.add_child(_inspector_scroll)

	_inspector_box = VBoxContainer.new()
	_inspector_box.add_theme_constant_override("separation", 4)
	_inspector_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_scroll.add_child(_inspector_box)

	# 右栏：预览
	var right := Panel.new()
	right.name = "PreviewPanel"
	right.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 4))
	add_child(right)

	_preview_title = _label("预览", 16, C_TEXT)
	_preview_title.position = Vector2(14, 12)
	_preview_title.size = Vector2(360, 24)
	_preview_title.clip_text = true
	right.add_child(_preview_title)

	_preview_clip = Control.new()
	_preview_clip.position = Vector2(14, 44)
	_preview_clip.size = Vector2(360, 300)
	_preview_clip.clip_contents = true
	_preview_clip.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_clip.gui_input.connect(_on_preview_gui_input)
	right.add_child(_preview_clip)

	var checker := TextureRect.new()
	checker.texture = _checker_texture()
	checker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	checker.stretch_mode = TextureRect.STRETCH_TILE
	checker.size = _preview_clip.size
	checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_clip.add_child(checker)

	_preview_tex = TextureRect.new()
	_preview_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_clip.add_child(_preview_tex)

	_preview_placeholder = _label("选择资源后在这里预览图像", 13, C_MUTED)
	_preview_placeholder.position = Vector2(20, 130)
	_preview_placeholder.size = Vector2(320, 40)
	_preview_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_clip.add_child(_preview_placeholder)

	var zoom_out := _button("－", false)
	zoom_out.position = Vector2(14, 352)
	zoom_out.size = Vector2(34, 28)
	zoom_out.pressed.connect(func(): _zoom_by(0.8))
	right.add_child(zoom_out)

	_zoom_label = _label("100%", 12, C_MUTED)
	_zoom_label.position = Vector2(52, 356)
	_zoom_label.size = Vector2(56, 20)
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(_zoom_label)

	var zoom_in := _button("＋", false)
	zoom_in.position = Vector2(112, 352)
	zoom_in.size = Vector2(34, 28)
	zoom_in.pressed.connect(func(): _zoom_by(1.25))
	right.add_child(zoom_in)

	var fit := _button("适应", false)
	fit.position = Vector2(154, 352)
	fit.size = Vector2(52, 28)
	fit.pressed.connect(_fit_zoom)
	right.add_child(fit)

	_open_in_browser_btn = _button("在浏览器中打开", false)
	_open_in_browser_btn.position = Vector2(214, 352)
	_open_in_browser_btn.size = Vector2(150, 28)
	_open_in_browser_btn.pressed.connect(_open_current_texture_browser)
	right.add_child(_open_in_browser_btn)

	_offset_preview_btn = _button("偏移预览", false)
	_offset_preview_btn.position = Vector2(14, 384)
	_offset_preview_btn.size = Vector2(180, 28)
	_offset_preview_btn.tooltip_text = "可视化调整子弹 / 武器动作 / 特效偏移（仅武器）"
	_offset_preview_btn.pressed.connect(func(): _open_offset_preview())
	right.add_child(_offset_preview_btn)

	_region_preview_btn = _button("区域预览", false)
	_region_preview_btn.position = Vector2(202, 384)
	_region_preview_btn.size = Vector2(152, 28)
	_region_preview_btn.tooltip_text = "可视化调整攻击判定区域：近战矩形 / 推击矩形+溅射圈 / 子弹射程（仅武器）"
	_region_preview_btn.pressed.connect(func(): _open_region_preview())
	right.add_child(_region_preview_btn)

	_preview_info = _label("", 12, C_MUTED)
	_preview_info.position = Vector2(14, 420)
	_preview_info.size = Vector2(360, 200)
	_preview_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_preview_info)

	# Toast
	_toast = _label("", 13, C_OK)
	_toast.position = Vector2(0, 0)
	_toast.size = Vector2(400, 28)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	add_child(_toast)


func _layout() -> void:
	var w: float = size.x
	var h: float = size.y
	if w < 100.0 or h < 100.0:
		w = get_viewport_rect().size.x
		h = get_viewport_rect().size.y

	var top: Control = get_node_or_null("TopBar")
	if top != null:
		top.position = Vector2(0, 0)
		top.size = Vector2(w, 56)
	var save: Control = get_node_or_null("TopBar/SaveBtn")
	if save != null:
		save.position = Vector2(w - 150, 12)
		save.size = Vector2(134, 32)
	var reload: Control = get_node_or_null("TopBar/ReloadBtn")
	if reload != null:
		reload.position = Vector2(w - 260, 12)
		reload.size = Vector2(100, 32)
	if _path_label != null:
		_path_label.size = Vector2(maxf(200.0, w - 520.0), 22)

	var left: Control = get_node_or_null("LeftPanel")
	if left != null:
		left.position = Vector2(14, 66)
		left.size = Vector2(356, h - 80)
	if _list_scroll != null:
		_list_scroll.size = Vector2(340, h - 80 - 92)

	var right: Control = get_node_or_null("PreviewPanel")
	var right_w: float = 390.0
	if right != null:
		right.position = Vector2(w - 14 - right_w, 66)
		right.size = Vector2(right_w, h - 80)

	var insp: Control = get_node_or_null("InspectorPanel")
	if insp != null:
		insp.position = Vector2(382, 66)
		insp.size = Vector2(maxf(300.0, w - 14 - right_w - 382 - 12), h - 80)
	if _inspector_scroll != null:
		_inspector_scroll.size = insp.size - Vector2(16, 16)

	if _toast != null:
		_toast.position = Vector2((w - 400) * 0.5, h - 46)


# ═══════════════════════════════════════
# 资源扫描（只读 .tres 头部，避免一次加载 78 把武器的全部特效/音效）
# ═══════════════════════════════════════

func _scan_resources() -> void:
	_entries.clear()
	_icon_cache.clear()
	_filter.clear()
	for k: String in KIND_ORDER:
		_filter[k] = true
	_scan_dir("res://")
	_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ia: int = KIND_ORDER.find(str(a.get("kind", K_OTHER)))
		var ib: int = KIND_ORDER.find(str(b.get("kind", K_OTHER)))
		if ia != ib:
			return ia < ib
		return str(a.get("name", "")) < str(b.get("name", "")))


func _scan_dir(dir_path: String) -> void:
	var da := DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var name: String = da.get_next()
	while name != "":
		if name.begins_with("."):
			name = da.get_next()
			continue
		var full := dir_path.path_join(name)
		if da.current_is_dir():
			if name not in SKIP_DIRS:
				_scan_dir(full)
		elif name.get_extension().to_lower() == "tres":
			_entries.append(_parse_tres_header(full))
		name = da.get_next()
	da.list_dir_end()


func _parse_tres_header(path: String) -> Dictionary:
	var e: Dictionary = {
		"path": path, "kind": K_OTHER, "name": path.get_file().get_basename(),
		"id": "", "cls": "", "icon": "", "item_type": -1,
	}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return e
	var text: String = f.get_as_text()
	f.close()
	var first: String = text.get_slice("\n", 0)
	var cls: String = _between(first, "script_class=\"", "\"")
	if cls.is_empty():
		## 不是脚本资源（TileSet / DropPoolData 的子资源等）：用 gd_resource 的 type 字段
		cls = _between(first, "type=\"", "\"")
	e["cls"] = cls

	var ext: Dictionary = {}
	var item_id: String = ""
	var item_name: String = ""
	var item_type: int = -1
	var is_ranged: bool = true
	var icon_id: String = ""
	var pickup_id: String = ""
	var character_name: String = ""
	var character_id: String = ""
	var resource_id: String = ""
	var fallback_tex: String = ""
	var weapon_state: String = ""
	var icon_index: int = -1
	var icon_cols: int = 4
	var icon_rows: int = 4
	for line: String in text.split("\n"):
		var t: String = line.strip_edges()
		if t.begins_with("[ext_resource"):
			var rid: String = _between_last(t, "id=\"", "\"")
			var rp: String = _between(t, "path=\"", "\"")
			if not rid.is_empty() and not rp.is_empty():
				ext[rid] = rp
		elif t.begins_with("item_id = "):
			item_id = _value_of(t)
		elif t.begins_with("item_name = "):
			item_name = _value_of(t)
		elif t.begins_with("item_type = "):
			item_type = int(_value_of(t))
		elif t.begins_with("is_ranged = "):
			is_ranged = t.ends_with("true")
		elif t.begins_with("weapon_state_name = "):
			weapon_state = _value_of(t)
		elif t.begins_with("icon = ExtResource("):
			icon_id = _between(t, "ExtResource(\"", "\"")
		elif t.begins_with("pickup_texture = ExtResource("):
			pickup_id = _between(t, "ExtResource(\"", "\"")
		elif t.begins_with("character_name = "):
			character_name = _value_of(t)
		elif t.begins_with("character_id = "):
			character_id = _value_of(t)
		elif t.begins_with("id = "):
			resource_id = _value_of(t)
		elif t.begins_with("portrait_index = "):
			icon_index = int(_value_of(t))
		elif t.begins_with("portrait_grid_cols = "):
			icon_cols = maxi(1, int(_value_of(t)))
		elif t.begins_with("portrait_grid_rows = "):
			icon_rows = maxi(1, int(_value_of(t)))
		elif t.begins_with("portrait = ExtResource(") or t.begins_with("select_portrait = ExtResource(") \
				or t.begins_with("normal_texture = ExtResource(") or t.begins_with("texture = ExtResource("):
			fallback_tex = _between(t, "ExtResource(\"", "\"")

	var kind: String = K_OTHER
	if cls == "CharacterData":
		kind = K_PLAYER
	elif cls == "ZombieVariant":
		kind = K_ENEMY_Z
	elif cls == "SpecialEnemyData":
		kind = K_ENEMY_S
	elif cls == "ThrowableData":
		kind = K_THROW
	elif cls == "WeaponData":
		kind = K_WR if is_ranged else K_WM
	elif cls == "ItemData":
		match item_type:
			5: kind = K_AMMO
			6: kind = K_HEAL
			7: kind = K_SUPPORT
			8: kind = K_THROW
			3: kind = K_WR if is_ranged else K_ITEM
			_: kind = K_ITEM
	e["kind"] = kind
	var display_name: String = item_name
	if display_name.is_empty():
		display_name = character_name
	if display_name.is_empty():
		display_name = resource_id
	e["name"] = display_name if not display_name.is_empty() else str(e["name"])
	e["id"] = item_id if not item_id.is_empty() else (character_id if not character_id.is_empty() else resource_id)
	e["item_type"] = item_type
	var icon: String = str(ext.get(icon_id, ""))
	if icon.is_empty():
		icon = str(ext.get(pickup_id, ""))
	if icon.is_empty() and not fallback_tex.is_empty():
		icon = str(ext.get(fallback_tex, ""))
	e["icon"] = icon
	e["icon_index"] = icon_index
	e["icon_cols"] = icon_cols
	e["icon_rows"] = icon_rows
	## 武器状态名：贴图字典（weapon_walk_textures / weapon_attack_walk_textures / shove_walk_textures）的键建议用
	e["state"] = weapon_state
	return e


func _between(s: String, a: String, b: String) -> String:
	var i: int = s.find(a)
	if i < 0:
		return ""
	i += a.length()
	var j: int = s.find(b, i)
	if j < 0:
		return ""
	return s.substr(i, j - i)


## 和 _between 相同，但从右侧找起点。ext_resource 行里的 `uid="..."` 包含 `id="` 子串，
## 必须取最后一个 id=" 才是真正的资源 id（否则会把 uid 当成 id，图标全丢）。
func _between_last(s: String, a: String, b: String) -> String:
	var i: int = s.rfind(a)
	if i < 0:
		return ""
	i += a.length()
	var j: int = s.find(b, i)
	if j < 0:
		return ""
	return s.substr(i, j - i)


func _value_of(line: String) -> String:
	var i: int = line.find("= ")
	if i < 0:
		return ""
	var v: String = line.substr(i + 2).strip_edges()
	if v.begins_with("&\"") and v.ends_with("\"") and v.length() >= 3:
		v = v.substr(2, v.length() - 3)
	elif v.begins_with("\"") and v.ends_with("\"") and v.length() >= 2:
		v = v.substr(1, v.length() - 2)
	return v


# ═══════════════════════════════════════
# 左侧列表 + 筛选
# ═══════════════════════════════════════

func _on_search_changed(text: String) -> void:
	_search = text.strip_edges().to_lower()
	_rebuild_list()


func _passes(entry: Dictionary) -> bool:
	if not bool(_filter.get(str(entry.get("kind", K_OTHER)), true)):
		return false
	if _search.is_empty():
		return true
	var hay: String = ("%s %s %s" % [
		entry.get("name", ""), entry.get("id", ""), entry.get("path", "")]).to_lower()
	return hay.contains(_search)


func _rebuild_list() -> void:
	for c: Node in _list_box.get_children():
		c.queue_free()
	_row_bgs.clear()
	_row_marks.clear()
	var shown: int = 0
	var counts: Dictionary = {}
	for e: Dictionary in _entries:
		var k: String = str(e.get("kind", K_OTHER))
		counts[k] = int(counts.get(k, 0)) + 1
		if not _passes(e):
			continue
		_list_box.add_child(_make_row(e))
		shown += 1
	_left_count.text = "%d / %d" % [shown, _entries.size()]
	if shown == 0:
		var empty := _label("没有匹配的资源。\n试试放宽筛选或清空搜索。", 13, C_MUTED)
		empty.custom_minimum_size = Vector2(0, 80)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list_box.add_child(empty)


func _make_row(entry: Dictionary) -> Control:
	var path: String = str(entry.get("path", ""))
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, 50)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(_on_row_gui_input.bind(entry))

	var bg := ColorRect.new()
	bg.color = C_ACCENT_DIM if path == _selected_path else Color(0, 0, 0, 0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bg)
	_row_bgs[path] = bg

	var mark := ColorRect.new()
	mark.color = C_ACCENT
	mark.position = Vector2(0, 4)
	mark.size = Vector2(3, 42)
	mark.visible = path == _selected_path
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mark)
	_row_marks[path] = mark

	var icon := TextureRect.new()
	icon.position = Vector2(10, 6)
	icon.size = Vector2(38, 38)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex: Texture2D = _icon_for(entry)
	if tex != null:
		icon.texture = tex
	row.add_child(icon)

	var name_label := _label(str(entry.get("name", "")), 14, C_TEXT)
	name_label.position = Vector2(56, 5)
	name_label.size = Vector2(200, 22)
	name_label.clip_text = true
	name_label.tooltip_text = path
	row.add_child(name_label)

	var sub: String = str(entry.get("id", ""))
	if sub.is_empty():
		sub = str(entry.get("path", "")).replace("res://", "")
	var sub_label := _label(sub, 11, C_MUTED)
	sub_label.position = Vector2(56, 28)
	sub_label.size = Vector2(200, 18)
	sub_label.clip_text = true
	row.add_child(sub_label)

	var kind_label := _label(str(KIND_SHORT.get(str(entry.get("kind", K_OTHER)), "其它")), 10, C_MUTED)
	kind_label.position = Vector2(258, 6)
	kind_label.size = Vector2(62, 16)
	kind_label.tooltip_text = str(KIND_LABELS.get(str(entry.get("kind", K_OTHER)), "其它"))
	kind_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(kind_label)
	return row


func _on_row_gui_input(event: InputEvent, entry: Dictionary) -> void:
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	_select_entry(entry)


func _select_entry(entry: Dictionary) -> void:
	if _dirty:
		## 有未保存修改时切走：自动保存；保存失败则留在当前资源，避免丢修改。
		_save_current(false)
		if _dirty:
			return
	var old_path: String = _selected_path
	_selected_path = str(entry.get("path", ""))
	_entry = entry
	_dirty = false
	for p: String in _row_bgs.keys():
		var bg: ColorRect = _row_bgs[p]
		if is_instance_valid(bg):
			bg.color = C_ACCENT_DIM if p == _selected_path else Color(0, 0, 0, 0)
	for p: String in _row_marks.keys():
		var m: ColorRect = _row_marks[p]
		if is_instance_valid(m):
			m.visible = p == _selected_path
	var kind: String = str(entry.get("kind", K_OTHER))
	if kind == K_OTHER:
		_res = null
		_update_header()
		_show_other_resource(entry)
	else:
		_res = load(_selected_path)
		_update_header()
		if _res == null:
			_show_error("加载失败：%s" % _selected_path)
			return
		_rebuild_inspector()
	_refresh_preview_from_entry()
	if old_path != _selected_path:
		_inspector_scroll.scroll_vertical = 0


func _update_header() -> void:
	if _offset_preview_btn != null:
		_offset_preview_btn.disabled = not (_res is WeaponData)
	if _region_preview_btn != null:
		_region_preview_btn.disabled = not (_res is WeaponData)
	if _selected_path.is_empty():
		_path_label.text = ""
		_dirty_label.text = ""
		return
	_path_label.text = _selected_path
	if _res == null:
		_dirty_label.text = "只读（不支持可视化编辑的资源类型）"
		_dirty_label.add_theme_color_override("font_color", C_MUTED)
		return
	if _dirty:
		_dirty_label.text = "● 未保存的修改"
		_dirty_label.add_theme_color_override("font_color", C_WARN)
	else:
		_dirty_label.text = "已保存"
		_dirty_label.add_theme_color_override("font_color", C_OK)


func _icon_for(entry: Dictionary) -> Texture2D:
	var icon_path: String = str(entry.get("icon", ""))
	if icon_path.is_empty() or not ResourceLoader.exists(icon_path):
		return null
	var idx: int = int(entry.get("icon_index", -1))
	var cols: int = maxi(1, int(entry.get("icon_cols", 1)))
	var rows: int = maxi(1, int(entry.get("icon_rows", 1)))
	var key: String = "%s|%d|%d|%d" % [icon_path, idx, cols, rows]
	if _icon_cache.has(key):
		return _icon_cache[key] as Texture2D
	var tex: Texture2D = load(icon_path) as Texture2D
	if tex != null and idx >= 0 and (cols > 1 or rows > 1):
		## 玩家头像/角色图集：按 portrait_index 裁一格，列表和预览都只显示本人头像。
		var cell_w: float = float(tex.get_width()) / float(cols)
		var cell_h: float = float(tex.get_height()) / float(rows)
		var col: int = idx % cols
		var row: int = (idx / cols) % rows
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(col * cell_w, row * cell_h, cell_w, cell_h)
		tex = at
	_icon_cache[key] = tex
	return tex


# ═══════════════════════════════════════
# 检查器
# ═══════════════════════════════════════

func _show_empty_inspector() -> void:
	_clear(_inspector_box)
	var hint := _label("左侧选择一个 .tres 开始编辑。\n\n· 支持物品 / 武器 / 投掷物的全部导出字段\n· 贴图直接显示缩略图，点「…」打开项目图像浏览器\n· Ctrl+S 保存回原文件；切换资源会自动保存当前修改", 14, C_MUTED)
	hint.custom_minimum_size = Vector2(0, 200)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_box.add_child(hint)


func _show_error(text: String) -> void:
	_clear(_inspector_box)
	_inspector_box.add_child(_label(text, 14, C_ERR))


func _show_other_resource(entry: Dictionary) -> void:
	_clear(_inspector_box)
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	_inspector_box.add_child(head)
	head.add_child(_label(str(entry.get("name", "")), 18, C_TEXT))
	head.add_child(_label("类型：%s" % str(entry.get("cls", "Resource")), 12, C_MUTED))
	var path := _label(str(entry.get("path", "")), 12, C_MUTED)
	path.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	head.add_child(path)
	head.add_child(_label("这个资源类型不在物品编辑器的可视化范围内（只读）。\n物品 / 武器 / 投掷物可以直接编辑。", 13, C_MUTED))
	_preview_title.text = "预览"
	_preview_tex.texture = null
	_preview_placeholder.visible = true
	_preview_placeholder.text = "只读资源"
	_preview_info.text = ""


func _rebuild_inspector() -> void:
	_clear(_inspector_box)
	_asset_rows.clear()
	if _res == null:
		_show_empty_inspector()
		return

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_inspector_box.add_child(head)

	var icon_rect := TextureRect.new()
	icon_rect.custom_minimum_size = Vector2(56, 56)
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.texture = _icon_for(_entry)
	head.add_child(icon_rect)

	var head_text := VBoxContainer.new()
	head_text.add_theme_constant_override("separation", 2)
	head_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_text)
	head_text.add_child(_label(str(_entry.get("name", "")), 18, C_TEXT))
	var cls_name: String = str(_entry.get("cls", _res.get_class()))
	var id_text: String = str(_entry.get("id", ""))
	head_text.add_child(_label("%s%s" % [cls_name, ("  ·  " + id_text) if not id_text.is_empty() else ""], 12, C_MUTED))
	var path_label := _label(_selected_path, 11, C_MUTED)
	path_label.clip_text = true
	path_label.tooltip_text = _selected_path
	head_text.add_child(path_label)
	if _is_item_kind(str(_entry.get("kind", K_OTHER))):
		var sync_hint := _label("改名 / item_id / 图标后：重跑 tools/gen_item_catalog.py 同步收藏馆", 10, C_MUTED)
		sync_hint.tooltip_text = "收藏馆列表读的是生成文件 script/item_catalog_data.gd；不重跑会显示旧名称。"
		head_text.add_child(sync_hint)

	var sep := ColorRect.new()
	sep.color = C_BORDER
	sep.custom_minimum_size = Vector2(0, 1)
	_inspector_box.add_child(sep)

	_collect_prop_info()
	_collect_field_docs()
	var groups: Array[Dictionary] = _group_plan()
	var grouped: Dictionary = {}
	for g: Dictionary in groups:
		for f: String in g.get("fields", []):
			grouped[f] = true

	var used: Dictionary = {}
	for g: Dictionary in groups:
		var fields: Array = []
		for f: String in g.get("fields", []):
			if _prop_info.has(f) and not used.has(f):
				fields.append(f)
		if fields.is_empty():
			continue
		for f: String in fields:
			used[f] = true
		_add_group(str(g.get("name", "常规")), fields)

	## 源码里没解析到分组的导出字段：兜底放「其它」
	var leftovers: Array = []
	for name: String in _prop_info.keys():
		if not used.has(name):
			leftovers.append(name)
	if not leftovers.is_empty():
		_add_group("其它", leftovers)


func _collect_prop_info() -> void:
	_prop_info.clear()
	var props: Array = _res.get_property_list()
	for p: Dictionary in props:
		var usage: int = int(p.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		if not (usage & PROPERTY_USAGE_STORAGE):
			continue
		var name: String = str(p.get("name", ""))
		if name.is_empty() or name == "script" or name.begins_with("resource_"):
			continue
		_prop_info[name] = p


func _init_regex() -> void:
	_re_group = RegEx.new()
	_re_group.compile("^@export_group\\(\"([^\"]*)\"\\)")
	_re_var = RegEx.new()
	_re_var.compile("^@export(?:_[a-z_]+(?:\\([^)]*\\))?)?\\s+var\\s+([A-Za-z_]\\w*)")


## 解析一个 .gd 的 @export_group / @export var 顺序；结果缓存。
func _parse_script_groups(path: String) -> Dictionary:
	if _group_cache.has(path):
		return _group_cache[path]
	var groups: Array[String] = []
	var order: Array[String] = []
	var field_group: Dictionary = {}
	var field_doc: Dictionary = {}
	var current: String = "常规"
	groups.append(current)
	var pending_doc: Array[String] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var text: String = f.get_as_text()
		f.close()
		for raw: String in text.split("\n"):
			var t: String = raw.strip_edges()
			if t.is_empty():
				pending_doc.clear()
				continue
			if t.begins_with("##"):
				pending_doc.append(t.substr(2).strip_edges())
				continue
			if t.begins_with("#"):
				pending_doc.clear()
				continue
			var mg := _re_group.search(t)
			if mg != null:
				current = mg.get_string(1)
				if current.is_empty():
					current = "常规"
				if not groups.has(current):
					groups.append(current)
				pending_doc.clear()
				continue
			if t.begins_with("@export_subgroup") or t.begins_with("@export_category"):
				pending_doc.clear()
				continue
			var mv := _re_var.search(t)
			if mv != null:
				var field: String = mv.get_string(1)
				if not field_group.has(field):
					order.append(field)
					field_group[field] = current
				## 行尾 ## 注释通常最贴近字段；没有行尾时才用上一行/上一段的文档注释。
				var doc: String = ""
				var hash_pos: int = t.find("##")
				if hash_pos >= 0:
					doc = t.substr(hash_pos + 2).strip_edges()
				if doc.is_empty() and not pending_doc.is_empty():
					doc = "\n".join(pending_doc).strip_edges()
				field_doc[field] = doc
				pending_doc.clear()
	var out: Dictionary = {"groups": groups, "order": order, "field_group": field_group, "field_doc": field_doc}
	_group_cache[path] = out
	return out


func _collect_field_docs() -> void:
	_field_docs.clear()
	var scr: Script = _res.get_script() as Script if _res != null else null
	while scr != null:
		var path: String = scr.resource_path
		if not path.is_empty():
			var g: Dictionary = _parse_script_groups(path)
			for field: String in (g.get("field_doc", {}) as Dictionary).keys():
				var doc: String = str((g.get("field_doc", {}) as Dictionary)[field]).strip_edges()
				if not doc.is_empty():
					_field_docs[field] = doc
		scr = scr.get_base_script()


func _is_item_kind(kind: String) -> bool:
	return kind in [K_WR, K_WM, K_HEAL, K_SUPPORT, K_THROW, K_AMMO, K_ITEM]


func _group_plan() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var index: Dictionary = {}
	var scr: Script = _res.get_script() as Script if _res != null else null
	var chain: Array[String] = []
	while scr != null:
		if not scr.resource_path.is_empty():
			chain.push_front(scr.resource_path)
		scr = scr.get_base_script()
	for path: String in chain:
		var g: Dictionary = _parse_script_groups(path)
		for name: String in g.get("groups", []):
			if not index.has(name):
				index[name] = out.size()
				out.append({"name": name, "fields": []})
		for field: String in g.get("order", []):
			var gname: String = str((g.get("field_group", {}) as Dictionary).get(field, "常规"))
			var gi: int = int(index.get(gname, -1))
			if gi < 0:
				gi = out.size()
				index[gname] = gi
				out.append({"name": gname, "fields": []})
			(out[gi]["fields"] as Array).append(field)
	return out


func _add_group(group_name: String, fields: Array) -> void:
	var head := Button.new()
	head.text = "▾  " + group_name
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.focus_mode = Control.FOCUS_NONE
	head.custom_minimum_size = Vector2(0, 30)
	head.add_theme_font_override("font", _font)
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", C_TEXT)
	var normal := _panel_sb(C_PANEL2, C_BORDER, 2)
	var hover := _panel_sb(Color("#343438"), C_BORDER, 2)
	var pressed := _panel_sb(Color("#202022"), C_BORDER, 2)
	head.add_theme_stylebox_override("normal", normal)
	head.add_theme_stylebox_override("hover", hover)
	head.add_theme_stylebox_override("pressed", pressed)
	_inspector_box.add_child(head)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 3)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_box.add_child(body)

	head.pressed.connect(func():
		body.visible = not body.visible
		head.text = ("▸  " if not body.visible else "▾  ") + group_name)

	for field: String in fields:
		_add_property_row(body, field)


func _add_property_row(parent: VBoxContainer, prop: String) -> void:
	var info: Dictionary = _prop_info[prop]
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	parent.add_child(row)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	row.add_child(hbox)

	var name_label := _label(prop, 12, C_MUTED)
	name_label.custom_minimum_size = Vector2(156, 0)
	name_label.clip_text = true
	name_label.tooltip_text = "%s\n类型：%s" % [prop, _type_name(int(info.get("type", 0)))]
	if prop == "item_id":
		name_label.tooltip_text += "\n⚠ 改 item_id 不会自动更新掉落池 / 存档 / 收藏目录引用"
	hbox.add_child(name_label)

	var editor: Control = _build_editor(prop, info)
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(editor)

	## 武器状态名容易被误认成状态机路由：把 get_state_node_name() 的实际值标在旁边。
	## 放在源码注释**上面**，保证不用滚到底就能看到。
	if prop == "weapon_state_name" and _res != null and _res.has_method("get_state_node_name"):
		var route_margin := MarginContainer.new()
		route_margin.add_theme_constant_override("margin_left", 8)
		route_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var route_label := _label(
			"状态机路由 → %s（get_state_node_name()，不是上面这个字段）"
			% str(_res.call("get_state_node_name")), 10, Color("#6f9f6f"))
		route_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		route_margin.add_child(route_label)
		row.add_child(route_margin)

	## 源码里的 ## 注释：放在属性名/编辑器下面，灰色小字，自动折行。
	var doc: String = str(_field_docs.get(prop, "")).strip_edges()
	if not doc.is_empty():
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 8)
		margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var doc_label := _label(doc, 11, Color("#8f8f8f"))
		doc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		doc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		doc_label.custom_minimum_size = Vector2(0, 0)
		margin.add_child(doc_label)
		row.add_child(margin)

	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.035)
	line.custom_minimum_size = Vector2(0, 1)
	parent.add_child(line)


func _build_editor(prop: String, info: Dictionary) -> Control:
	var type: int = int(info.get("type", 0))
	var hint: int = int(info.get("hint", 0))
	var hint_string: String = str(info.get("hint_string", ""))
	var value: Variant = _res.get(prop)

	if FRIENDLY_ENUMS.has(prop):
		return _build_friendly_enum(prop, FRIENDLY_ENUMS[prop], int(value))

	match type:
		TYPE_BOOL:
			var cb := CheckBox.new()
			cb.button_pressed = bool(value)
			cb.focus_mode = Control.FOCUS_NONE
			cb.toggled.connect(func(on: bool): _set_prop(prop, on))
			return cb
		TYPE_INT:
			if hint == PROPERTY_HINT_ENUM:
				return _build_enum(prop, hint_string, int(value))
			return _build_spin(prop, value, hint, hint_string, true)
		TYPE_FLOAT:
			return _build_spin(prop, value, hint, hint_string, false)
		TYPE_STRING:
			if hint == PROPERTY_HINT_ENUM:
				return _build_string_enum(prop, hint_string, str(value))
			if hint == PROPERTY_HINT_MULTILINE_TEXT:
				var te := TextEdit.new()
				te.text = str(value)
				te.custom_minimum_size = Vector2(0, 84)
				te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
				te.add_theme_font_override("font", _font)
				te.add_theme_font_size_override("font_size", 13)
				te.text_changed.connect(func(): _set_prop(prop, te.text))
				return te
			var le := LineEdit.new()
			le.text = str(value)
			le.add_theme_font_override("font", _font)
			le.add_theme_font_size_override("font_size", 13)
			le.text_changed.connect(func(t: String): _set_prop(prop, t))
			return le
		TYPE_STRING_NAME:
			var sn := LineEdit.new()
			sn.text = str(value)
			sn.add_theme_font_override("font", _font)
			sn.add_theme_font_size_override("font_size", 13)
			sn.text_changed.connect(func(t: String): _set_prop(prop, StringName(t)))
			return sn
		TYPE_COLOR:
			var cp := ColorPickerButton.new()
			cp.color = value if value is Color else Color.WHITE
			cp.custom_minimum_size = Vector2(90, 30)
			cp.edit_alpha = true
			cp.color_changed.connect(func(c: Color): _set_prop(prop, c))
			return cp
		TYPE_VECTOR2:
			return _build_vector2(prop, value)
		TYPE_OBJECT:
			return _build_object_editor(prop, info, value as Resource)
		TYPE_ARRAY:
			return _build_array_editor(prop, info, value as Array)
		TYPE_DICTIONARY:
			return _build_dict_editor(prop, value as Dictionary)
	return _label("暂不支持的类型 (%s)" % _type_name(type), 12, C_MUTED)


## 源码里没写 hint 的枚举（item_type 等），按类定义补一份可读下拉。
const FRIENDLY_ENUMS := {
	"item_type": [
		["消耗品", 0], ["材料", 1], ["关键道具", 2], ["武器", 3], ["防具", 4],
		["弹药", 5], ["治疗品", 6], ["辅助品", 7], ["投掷物", 8],
	],
	"fire_mode": [["TAP（点按）", 0], ["HOLD（按住连发）", 1]],
	"reload_mode": [["NORMAL（一次装满）", 0], ["SHOTGUN（逐发装填）", 1]],
}


func _build_string_enum(prop: String, hint_string: String, current: String) -> Control:
	var ob := OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	var parts: PackedStringArray = hint_string.split(",")
	var selected: int = 0
	for i: int in range(parts.size()):
		var v: String = parts[i]
		ob.add_item(v, i)
		ob.set_item_metadata(i, v)
		if v == current:
			selected = i
	if ob.item_count > 0:
		ob.select(selected)
	ob.item_selected.connect(func(idx: int): _set_prop(prop, str(ob.get_item_metadata(idx))))
	return ob


func _build_friendly_enum(prop: String, table: Array, current: int) -> Control:
	var ob := OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	var selected: int = 0
	for i: int in range(table.size()):
		var row: Array = table[i]
		ob.add_item(str(row[0]), i)
		ob.set_item_metadata(i, int(row[1]))
		if int(row[1]) == current:
			selected = i
	if ob.item_count > 0:
		ob.select(selected)
	ob.item_selected.connect(func(idx: int):
		var v: Variant = ob.get_item_metadata(idx)
		_set_prop(prop, int(v)))
	return ob


func _build_enum(prop: String, hint_string: String, current: int) -> Control:
	var ob := OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	var selected: int = 0
	var parts: PackedStringArray = hint_string.split(",")
	for i: int in range(parts.size()):
		var part: String = parts[i]
		var label: String = part
		var val: int = i
		var colon: int = part.rfind(":")
		if colon >= 0:
			label = part.substr(0, colon)
			val = int(part.substr(colon + 1))
		ob.add_item(label, i)
		ob.set_item_metadata(i, val)
		if val == current:
			selected = i
	if ob.item_count > 0:
		ob.select(selected)
	ob.item_selected.connect(func(idx: int):
		var v: Variant = ob.get_item_metadata(idx)
		_set_prop(prop, int(v)))
	return ob


func _build_spin(prop: String, value: Variant, hint: int, hint_string: String, is_int: bool) -> Control:
	var sb := SpinBox.new()
	sb.min_value = -1000000.0
	sb.max_value = 1000000.0
	sb.step = 1.0 if is_int else 0.01
	sb.allow_greater = true
	sb.allow_lesser = true
	sb.custom_minimum_size = Vector2(120, 28)
	if hint == PROPERTY_HINT_RANGE and not hint_string.is_empty():
		var p: PackedStringArray = hint_string.split(",")
		if p.size() >= 2:
			sb.min_value = float(p[0])
			sb.max_value = float(p[1])
		if p.size() >= 3:
			var s: float = float(p[2])
			if s > 0.0:
				sb.step = s if not is_int else maxf(1.0, s)
	if is_int:
		sb.value = float(int(value))
		sb.rounded = true
	else:
		sb.value = float(value)
	sb.value_changed.connect(func(v: float):
		_set_prop(prop, int(round(v)) if is_int else v))
	return sb


func _build_vector2(prop: String, value: Variant) -> Control:
	var v: Vector2 = value if value is Vector2 else Vector2.ZERO
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var sx := SpinBox.new()
	sx.min_value = -100000.0
	sx.max_value = 100000.0
	sx.step = 1.0
	sx.value = v.x
	sx.custom_minimum_size = Vector2(86, 28)
	var sy := SpinBox.new()
	sy.min_value = -100000.0
	sy.max_value = 100000.0
	sy.step = 1.0
	sy.value = v.y
	sy.custom_minimum_size = Vector2(86, 28)
	sx.value_changed.connect(func(x: float): _set_prop(prop, Vector2(x, sy.value)))
	sy.value_changed.connect(func(y: float): _set_prop(prop, Vector2(sx.value, y)))
	box.add_child(sx)
	box.add_child(sy)
	return box


func _build_object_editor(prop: String, info: Dictionary, obj: Resource) -> Control:
	var hint_string: String = str(info.get("hint_string", ""))
	var mode: int = MODE_RESOURCE
	if hint_string == "Texture2D" or obj is Texture2D:
		mode = MODE_TEXTURE
	elif hint_string == "AudioStream" or obj is AudioStream:
		mode = MODE_AUDIO
	elif hint_string == "PackedScene" or obj is PackedScene:
		mode = MODE_SCENE
	return _build_asset_row(prop, obj, mode)


func _build_asset_row(prop: String, obj: Resource, mode: int) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var thumb: TextureRect = null
	if mode == MODE_TEXTURE:
		thumb = TextureRect.new()
		thumb.custom_minimum_size = Vector2(44, 44)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.texture = obj as Texture2D
		thumb.mouse_filter = Control.MOUSE_FILTER_STOP
		thumb.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_preview_show(obj as Texture2D, _res_path_of(obj), prop)
				_open_browser(mode, _res_path_of(obj), func(path: String): _set_texture_prop(prop, path))
		)
		box.add_child(thumb)

	var full_path: String = _res_path_of(obj)
	var path_label := _label(full_path.get_file() if not full_path.is_empty() else "（未设置）", 11, C_MUTED)
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.clip_text = true
	path_label.tooltip_text = full_path
	box.add_child(path_label)

	var pick := _button("…", false)
	pick.custom_minimum_size = Vector2(30, 28)
	pick.pressed.connect(func(): _open_browser_for_prop(prop, mode))
	box.add_child(pick)

	if mode == MODE_AUDIO:
		var play := _button("▶", false)
		play.custom_minimum_size = Vector2(30, 28)
		play.pressed.connect(func():
			if obj is AudioStream and obj != null:
				var player := AudioStreamPlayer.new()
				player.stream = obj as AudioStream
				add_child(player)
				player.finished.connect(player.queue_free)
				player.play())
		box.add_child(play)

	var clear := _button("✕", false)
	clear.custom_minimum_size = Vector2(30, 28)
	clear.pressed.connect(func(): _set_prop(prop, null))
	box.add_child(clear)

	_asset_rows[prop] = {"path": path_label, "thumb": thumb, "obj": obj}
	return box


func _build_array_editor(prop: String, info: Dictionary, arr: Array) -> Control:
	var hint_string: String = str(info.get("hint_string", ""))
	if hint_string.begins_with("4:") or hint_string.begins_with("21:"):
		## Array[String] / Array[StringName]：一行一项（用换行分隔，避免台词里的逗号被拆开）
		var te := TextEdit.new()
		var lines: Array[String] = []
		for v: Variant in arr:
			lines.append(str(v))
		te.text = "\n".join(lines)
		te.custom_minimum_size = Vector2(0, 74)
		te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		te.add_theme_font_override("font", _font)
		te.add_theme_font_size_override("font_size", 13)
		var is_string_name: bool = hint_string.begins_with("21:")
		te.text_changed.connect(func():
			var lines_out: Array[String] = []
			for line: String in te.text.split("\n"):
				if not line.strip_edges().is_empty():
					lines_out.append(line.strip_edges())
			if is_string_name:
				var out_n: Array[StringName] = []
				for v: String in lines_out:
					out_n.append(StringName(v))
				_set_prop(prop, out_n)
			else:
				_set_prop(prop, lines_out))
		return te
	if hint_string.begins_with("2:") or hint_string.begins_with("3:"):
		var is_int: bool = hint_string.begins_with("2:")
		var le := LineEdit.new()
		var parts: PackedStringArray = []
		for v: Variant in arr:
			parts.append(str(int(v)) if is_int else str(v))
		le.text = ", ".join(parts)
		le.add_theme_font_override("font", _font)
		le.add_theme_font_size_override("font_size", 13)
		le.tooltip_text = "逗号分隔，例如 3, 4, 5, 2"
		var apply := func():
			var out: Array = []
			for piece: String in le.text.split(","):
				var t: String = piece.strip_edges()
				if t.is_empty():
					continue
				out.append(int(t) if is_int else float(t))
			if is_int:
				var typed: Array[int] = []
				for v: Variant in out:
					typed.append(int(v))
				_set_prop(prop, typed)
			else:
				var typedf: Array[float] = []
				for v: Variant in out:
					typedf.append(float(v))
				_set_prop(prop, typedf)
		le.text_submitted.connect(func(_t: String): apply.call())
		le.focus_exited.connect(func(): apply.call())
		return le

	var summary := _label("资源数组 · %d 项" % arr.size(), 12, C_MUTED)
	var paths: Array[String] = []
	for v: Variant in arr:
		if v is Resource and not (v as Resource).resource_path.is_empty():
			paths.append((v as Resource).resource_path)
	if not paths.is_empty():
		summary.tooltip_text = "\n".join(paths)
		summary.text += "（鼠标悬停查看路径）"
	return summary


func _build_dict_editor(prop: String, dict: Dictionary) -> Control:
	## 角色 / 武器的「状态名 → 贴图」字典（weapon_walk_textures / weapon_attack_walk_textures /
	## shove_walk_textures）不能走 JSON：值是 Texture2D。给一套行式编辑器（键 + 缩略图 + 选图）。
	if _dict_is_texture_dict(prop, dict):
		return _build_texture_dict_editor(prop, dict)
	## 标量 / Resource（如四方向偏移 WeaponEffectOffsets）也走行式编辑，
	## 类型优先按现有值推断；空字典按字段名认。推断不出来才退回 JSON。
	var ti: Dictionary = _dict_type_info(prop, dict)
	if ti.get("kind", DV_JSON) != DV_JSON:
		return _build_generic_dict_editor(prop, dict, ti)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var summary := _label("%d 项" % dict.size(), 12, C_MUTED)
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(summary)
	var editable: bool = _dict_is_json_editable(dict)
	var btn := _button("编辑…", false)
	btn.custom_minimum_size = Vector2(64, 28)
	btn.disabled = not editable
	if not editable:
		btn.tooltip_text = "字典里的值类型不一致或无法用 JSON / 行式编辑器表示，请在 Godot 检查器编辑"
	btn.pressed.connect(func(): _open_json_dialog(prop, dict))
	box.add_child(btn)
	return box


## 值全是 Texture2D 的字典（或空字典但字段名是 *walk_textures）。
## 空字典无法从值判断类型，所以对这几个已知字段按名字认定，否则空字典仍走 JSON。
func _dict_is_texture_dict(prop: String, dict: Dictionary) -> bool:
	if dict.is_empty():
		return prop == "weapon_walk_textures" or prop == "shove_walk_textures" \
			or prop == "weapon_attack_walk_textures"
	for v: Variant in dict.values():
		if not (v is Texture2D):
			return false
	return true


## 推断一个字典的「键类型 + 值类型」。优先看现有值（全一致才认），
## 空字典按已知字段名认；实在认不出返回 DV_JSON（走旧 JSON 编辑器）。
## 返回：{kind, label, key_int, res_script, flexible}
func _dict_type_info(prop: String, dict: Dictionary) -> Dictionary:
	var info: Dictionary = {
		"kind": DV_JSON, "label": "混合 / JSON",
		"key_int": false, "res_script": null, "flexible": false,
	}
	if dict.is_empty():
		match prop:
			"melee_weapon_sprite_seq_cols", "melee_weapon_sprite_attack2_seq_cols":
				return {
					"kind": DV_INT, "label": "int（帧列号）",
					"key_int": true, "res_script": null, "flexible": false,
				}
			"melee_weapon_sprite_offsets", "melee_weapon_sprite_step_offsets", "melee_weapon_sprite_attack2_step_offsets", "bullet_spawn_offsets", "attack_effect_offsets":
				return {
					"kind": DV_RESOURCE, "label": "WeaponEffectOffsets",
					"key_int": false,
					"res_script": load("res://script/weapon_effect_offsets.gd"),
					"flexible": false,
				}
			_:
				## 真正未知的空字典：允许在弹窗里自己选值类型（默认 String）
				return {
					"kind": DV_STRING, "label": "String（可改）",
					"key_int": false, "res_script": null, "flexible": true,
				}

	info["key_int"] = _dict_keys_are_int(dict)
	var kinds: Dictionary = {}
	for v: Variant in dict.values():
		kinds[_dict_value_kind(v)] = true
	if kinds.is_empty():
		return info
	var kind: String = ""
	if kinds.size() == 1:
		kind = str(kinds.keys()[0])
	elif kinds.size() == 2 and kinds.has("int") and kinds.has("float"):
		## int/float 混排：全是整数值（如 2.0）就按 int 处理，否则按 float。
		## 例：防火斧 melee_weapon_sprite_seq_cols = {0:0, 1:1, 2:2.0} 实际是列号表。
		var integral: bool = true
		for v: Variant in dict.values():
			if v is float and not is_equal_approx(v, round(v)):
				integral = false
				break
		kind = "int" if integral else "float"
	else:
		return info
	match kind:
		"int", "float", "bool", "string", "vector2", "color":
			info["kind"] = kind
			info["label"] = _dict_value_kind_label(kind, null)
		"resource":
			var script: Script = null
			var mixed: bool = false
			for v: Variant in dict.values():
				var s: Script = (v as Resource).get_script()
				if script == null:
					script = s
				elif s != script:
					mixed = true
					break
			if mixed:
				return info
			info["kind"] = DV_RESOURCE
			info["res_script"] = script
			info["label"] = _script_display_name(script)
		_:
			return info
	return info


func _dict_keys_are_int(dict: Dictionary) -> bool:
	for k: Variant in dict.keys():
		if not (k is int):
			return false
	return true


func _dict_value_kind(v: Variant) -> String:
	if v is bool:
		return "bool"
	if v is int:
		return "int"
	if v is float:
		return "float"
	if v is String or v is StringName:
		return "string"
	if v is Vector2:
		return "vector2"
	if v is Color:
		return "color"
	if v is Texture2D:
		return "texture"
	if v is Resource:
		return "resource"
	return "other"


func _dict_value_kind_label(kind: String, script: Script) -> String:
	match kind:
		DV_INT: return "int"
		DV_FLOAT: return "float"
		DV_BOOL: return "bool"
		DV_STRING: return "String"
		DV_VECTOR2: return "Vector2"
		DV_COLOR: return "Color"
		DV_TEXTURE: return "Texture2D"
		DV_RESOURCE: return _script_display_name(script)
	return "混合"


func _script_display_name(script: Script) -> String:
	if script == null:
		return "Resource"
	var n: String = script.get_global_name()
	if not n.is_empty():
		return n
	var p: String = script.resource_path
	return p.get_file().get_basename() if not p.is_empty() else "Resource"


func _build_generic_dict_editor(prop: String, dict: Dictionary, ti: Dictionary) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var summary := _label("%d 项 · %s" % [dict.size(), str(ti.get("label", ""))], 12, C_MUTED)
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var keys: Array[String] = []
	for k: Variant in dict.keys():
		keys.append(str(k))
	if not keys.is_empty():
		summary.tooltip_text = "\n".join(keys)
	box.add_child(summary)
	if prop.ends_with("_offsets"):
		var pv := _button("预览", false)
		pv.custom_minimum_size = Vector2(52, 28)
		pv.tooltip_text = "可视化调整偏移（拖黄点 / 武器图）"
		pv.pressed.connect(func(): _open_offset_preview(prop))
		box.add_child(pv)
	var btn := _button("编辑…", false)
	btn.custom_minimum_size = Vector2(64, 28)
	btn.pressed.connect(func(): _open_generic_dict_dialog(prop, dict, ti))
	box.add_child(btn)
	return box


func _build_texture_dict_editor(prop: String, dict: Dictionary) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var summary := _label("贴图列表 · %d 项" % dict.size(), 12, C_MUTED)
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var keys: Array[String] = []
	for k: Variant in dict.keys():
		keys.append(str(k))
	if not keys.is_empty():
		summary.tooltip_text = "\n".join(keys)
	box.add_child(summary)
	var btn := _button("编辑…", false)
	btn.custom_minimum_size = Vector2(64, 28)
	btn.pressed.connect(func(): _open_texture_dict_dialog(prop, dict))
	box.add_child(btn)
	return box


## 项目里出现过的所有 WeaponData.weapon_state_name（去重排序），用作键下拉建议。
func _weapon_state_names() -> Array[String]:
	var out: Array[String] = []
	for e: Dictionary in _entries:
		var s: String = str(e.get("state", "")).strip_edges()
		if not s.is_empty() and not out.has(s):
			out.append(s)
	out.sort()
	return out


func _next_weapon_state(used: Dictionary) -> String:
	for s: String in _weapon_state_names():
		if not used.has(s):
			return s
	return ""


func _dict_is_json_editable(dict: Dictionary) -> bool:
	for v: Variant in dict.values():
		if v is int or v is float or v is bool or v is String or v is Vector2:
			continue
		return false
	return true


func _set_prop(prop: String, value: Variant) -> void:
	if _res == null:
		return
	_res.set(prop, value)
	if not _dirty:
		_dirty = true
		_update_header()


func _set_texture_prop(prop: String, path: String) -> void:
	var tex: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
	_set_prop(prop, tex)
	var row: Dictionary = _asset_rows.get(prop, {})
	if not row.is_empty():
		if row.get("thumb") != null and is_instance_valid(row["thumb"]):
			(row["thumb"] as TextureRect).texture = tex
		if row.get("path") != null and is_instance_valid(row["path"]):
			(row["path"] as Label).text = path
	_preview_show(tex, path, prop)


func _res_path_of(obj: Resource) -> String:
	if obj == null:
		return ""
	return obj.resource_path


# ═══════════════════════════════════════
# 资源浏览器
# ═══════════════════════════════════════

func _open_browser_for_prop(prop: String, mode: int) -> void:
	var current: String = ""
	var obj: Variant = _res.get(prop) if _res != null else null
	if obj is Resource:
		current = (obj as Resource).resource_path
	_open_browser(mode, current, func(path: String):
		match mode:
			MODE_TEXTURE: _set_texture_prop(prop, path)
			MODE_AUDIO: _set_prop(prop, load(path) as AudioStream)
			MODE_SCENE: _set_prop(prop, load(path) as PackedScene)
			_: _set_prop(prop, load(path))
		_refresh_asset_row(prop))


func _open_browser(mode: int, current: String, on_pick: Callable) -> void:
	if _browser != null:
		return
	var b: Control = BROWSER.new()
	_browser = b
	add_child(b)
	b.picked.connect(func(path: String):
		if is_instance_valid(b):
			b.queue_free()
		_browser = null
		on_pick.call(path))
	b.closed.connect(func():
		if is_instance_valid(b):
			b.queue_free()
		_browser = null)
	b.open(mode, current)


func _refresh_asset_row(prop: String) -> void:
	var row: Dictionary = _asset_rows.get(prop, {})
	if row.is_empty():
		return
	var obj: Variant = _res.get(prop)
	if row.get("thumb") != null and is_instance_valid(row["thumb"]):
		(row["thumb"] as TextureRect).texture = obj as Texture2D
	if row.get("path") != null and is_instance_valid(row["path"]):
		(row["path"] as Label).text = _res_path_of(obj as Resource)


func _open_current_texture_browser() -> void:
	if _res == null:
		return
	var current: String = ""
	for prop: String in _asset_rows.keys():
		var obj: Variant = _res.get(prop)
		if obj is Texture2D:
			current = (obj as Texture2D).resource_path
			_open_browser(MODE_TEXTURE, current, func(path: String): _set_texture_prop(prop, path))
			return
	_open_browser(MODE_TEXTURE, current, func(path: String): pass)


# ═══════════════════════════════════════
# 保存 / 重新加载
# ═══════════════════════════════════════

func _save_current(show_toast: bool = true) -> void:
	if _res == null or _selected_path.is_empty():
		return
	## 数值数组等字段在 focus_exited 才提交：保存前先让当前输入框失焦。
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()
	var err: Error = ResourceSaver.save(_res, _selected_path)
	if err != OK:
		_toast_show("保存失败（%d）：%s" % [err, _selected_path], C_ERR)
		return
	_dirty = false
	_update_header()
	## 列表可能改了名称 / id / 图标 → 重建但保住选中项
	_entry["name"] = str(_res.get("item_name")) if _res.get("item_name") != null else _entry.get("name", "")
	_entry["id"] = str(_res.get("item_id")) if _res.get("item_id") != null else _entry.get("id", "")
	_rebuild_list()
	if show_toast:
		_toast_show("已保存：%s" % _selected_path.get_file(), C_OK)


func _reload_current() -> void:
	if _selected_path.is_empty():
		return
	if str(_entry.get("kind", K_OTHER)) == K_OTHER:
		return
	var res: Resource = ResourceLoader.load(_selected_path, "", ResourceLoader.CACHE_MODE_REPLACE) as Resource
	if res == null:
		_toast_show("重新加载失败：%s" % _selected_path, C_ERR)
		return
	_res = res
	_dirty = false
	_update_header()
	_rebuild_inspector()
	_refresh_preview_from_entry()
	_toast_show("已从磁盘重新加载", C_OK)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.ctrl_pressed and key.keycode == KEY_S:
			_save_current()
			get_viewport().set_input_as_handled()
			return
		if key.keycode == KEY_ESCAPE:
			## 资源浏览器自己处理 Esc；它开着时不要把背后的弹窗一起关掉。
			if _browser != null:
				return
			if _offset_overlay != null:
				_offset_overlay.queue_free()
				_offset_overlay = null
				get_viewport().set_input_as_handled()
			elif _region_overlay != null:
				_region_overlay.queue_free()
				_region_overlay = null
				get_viewport().set_input_as_handled()
			elif _resource_overlay != null:
				_resource_overlay.queue_free()
				_resource_overlay = null
				get_viewport().set_input_as_handled()
			elif _generic_dict_overlay != null:
				_generic_dict_overlay.queue_free()
				_generic_dict_overlay = null
				get_viewport().set_input_as_handled()
			elif _texture_dict_overlay != null:
				_texture_dict_overlay.queue_free()
				_texture_dict_overlay = null
				get_viewport().set_input_as_handled()
			elif _json_overlay != null:
				_json_overlay.queue_free()
				_json_overlay = null
				get_viewport().set_input_as_handled()
			elif _filter_overlay != null:
				_filter_overlay.queue_free()
				_filter_overlay = null
				get_viewport().set_input_as_handled()


# ═══════════════════════════════════════
# 预览
# ═══════════════════════════════════════

func _refresh_preview_from_entry() -> void:
	var tex: Texture2D = _icon_for(_entry)
	_preview_show(tex, str(_entry.get("icon", "")), "")
	var name_text: String = str(_entry.get("name", ""))
	_preview_title.text = name_text if not name_text.is_empty() else "预览"


func _preview_show(tex: Texture2D, path: String, prop: String) -> void:
	_preview_texture = tex
	_preview_tex.texture = tex
	_preview_placeholder.visible = tex == null
	if tex == null:
		_preview_info.text = ""
		_zoom_label.text = "100%"
		_preview_title.text = "预览"
		return
	_fit_zoom()
	var title: String = prop if not prop.is_empty() else path.get_file()
	_preview_title.text = title if not title.is_empty() else "预览"
	_preview_info.text = "%d × %d\n%s" % [tex.get_width(), tex.get_height(), path]


func _fit_zoom() -> void:
	if _preview_texture == null:
		return
	var s: Vector2 = _preview_texture.get_size()
	if s.x <= 0.0 or s.y <= 0.0:
		return
	var fit: float = minf((_preview_clip.size.x - 12.0) / s.x, (_preview_clip.size.y - 12.0) / s.y)
	_zoom = clampf(minf(fit, 1.0), 0.05, 8.0)
	_apply_zoom()


func _zoom_by(f: float) -> void:
	if _preview_texture == null:
		return
	_zoom = clampf(_zoom * f, 0.05, 8.0)
	_apply_zoom()


func _apply_zoom() -> void:
	if _preview_texture == null:
		return
	var s: Vector2 = _preview_texture.get_size() * _zoom
	_preview_tex.size = s
	_preview_tex.position = ((_preview_clip.size - s) * 0.5).floor()
	_zoom_label.text = "%d%%" % int(round(_zoom * 100.0))


func _on_preview_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(1.15)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(0.87)


# ═══════════════════════════════════════
# 筛选弹窗
# ═══════════════════════════════════════

func _open_filter() -> void:
	if _filter_overlay != null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_filter_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	panel.size = Vector2(470, 590)
	panel.position = ((vp - panel.size) * 0.5).floor()
	overlay.add_child(panel)

	var title := _label("筛选资源", 18, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(300, 28)
	panel.add_child(title)

	var counts: Dictionary = {}
	for e: Dictionary in _entries:
		var k: String = str(e.get("kind", K_OTHER))
		counts[k] = int(counts.get(k, 0)) + 1

	var checks: Dictionary = {}
	var y: float = 56.0
	for k: String in KIND_ORDER:
		var cb := CheckBox.new()
		cb.text = str(KIND_LABELS.get(k, k))
		cb.button_pressed = bool(_filter.get(k, true))
		cb.position = Vector2(20, y)
		cb.size = Vector2(300, 28)
		cb.add_theme_font_override("font", _font)
		cb.add_theme_font_size_override("font_size", 14)
		panel.add_child(cb)
		checks[k] = cb
		var cnt := _label("(%d)" % int(counts.get(k, 0)), 12, C_MUTED)
		cnt.position = Vector2(360, y + 5)
		cnt.size = Vector2(80, 20)
		cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		panel.add_child(cnt)
		y += 38.0

	var all_btn := _button("全选", false)
	all_btn.position = Vector2(20, y + 8)
	all_btn.size = Vector2(80, 30)
	all_btn.pressed.connect(func():
		for k: String in checks.keys():
			(checks[k] as CheckBox).button_pressed = true)
	panel.add_child(all_btn)

	var none_btn := _button("全不选", false)
	none_btn.position = Vector2(108, y + 8)
	none_btn.size = Vector2(80, 30)
	none_btn.pressed.connect(func():
		for k: String in checks.keys():
			(checks[k] as CheckBox).button_pressed = false)
	panel.add_child(none_btn)

	var cancel := _button("取消", false)
	cancel.position = Vector2(190, y + 8)
	cancel.size = Vector2(80, 30)
	cancel.pressed.connect(func(): overlay.queue_free(); _filter_overlay = null)
	panel.add_child(cancel)

	var apply := _button("应用", true)
	apply.position = Vector2(300, y + 8)
	apply.size = Vector2(150, 30)
	apply.pressed.connect(func():
		for k: String in checks.keys():
			_filter[k] = (checks[k] as CheckBox).button_pressed
		overlay.queue_free()
		_filter_overlay = null
		_rebuild_list())
	panel.add_child(apply)


# ═══════════════════════════════════════
# 字典 JSON 弹窗
# ═══════════════════════════════════════

func _open_json_dialog(prop: String, dict: Dictionary) -> void:
	if _json_overlay != null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_json_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	panel.size = Vector2(760, 600)
	panel.position = ((vp - panel.size) * 0.5).floor()
	overlay.add_child(panel)

	var title := _label("编辑字典：%s" % prop, 16, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(600, 26)
	panel.add_child(title)

	var text := TextEdit.new()
	text.position = Vector2(18, 48)
	text.size = Vector2(724, 470)
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.add_theme_font_override("font", _font)
	text.add_theme_font_size_override("font_size", 13)
	text.text = JSON.stringify(_dict_to_json(dict), "\t", false)
	panel.add_child(text)

	var err_label := _label("", 12, C_ERR)
	err_label.position = Vector2(18, 526)
	err_label.size = Vector2(500, 20)
	panel.add_child(err_label)

	var cancel := _button("取消", false)
	cancel.position = Vector2(500, 550)
	cancel.size = Vector2(100, 32)
	cancel.pressed.connect(func(): overlay.queue_free(); _json_overlay = null)
	panel.add_child(cancel)

	var apply := _button("应用", true)
	apply.position = Vector2(620, 550)
	apply.size = Vector2(122, 32)
	apply.pressed.connect(func():
		var parsed: Variant = JSON.parse_string(text.text)
		if not (parsed is Dictionary):
			err_label.text = "JSON 解析失败：必须是一个对象 { ... }"
			return
		var out: Dictionary = _json_to_dict(parsed as Dictionary, dict)
		_set_prop(prop, out)
		overlay.queue_free()
		_json_overlay = null
		_rebuild_inspector())
	panel.add_child(apply)


func _dict_to_json(dict: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in dict.keys():
		var v: Variant = dict[k]
		if v is Vector2:
			out[str(k)] = [(v as Vector2).x, (v as Vector2).y]
		else:
			out[str(k)] = v
	return out


func _json_to_dict(parsed: Dictionary, original: Dictionary) -> Dictionary:
	var int_keys: bool = false
	var vector_values: bool = false
	for k: Variant in original.keys():
		if k is int:
			int_keys = true
		if original[k] is Vector2:
			vector_values = true
	var out: Dictionary = {}
	for k: String in parsed.keys():
		var key: Variant = int(k) if int_keys and k.is_valid_int() else k
		var v: Variant = parsed[k]
		if vector_values and v is Array and (v as Array).size() == 2:
			out[key] = Vector2(float(v[0]), float(v[1]))
		elif original.get(key) is int and v is float:
			out[key] = int(v)
		else:
			out[key] = v
	return out


# ═══════════════════════════════════════
# 贴图字典弹窗（角色 / 武器：状态名 → 行走图）
# ═══════════════════════════════════════

func _open_texture_dict_dialog(prop: String, dict: Dictionary) -> void:
	if _texture_dict_overlay != null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_texture_dict_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	panel.size = Vector2(780, 660)
	panel.position = ((vp - panel.size) * 0.5).floor()
	overlay.add_child(panel)

	var title := _label("编辑贴图列表：%s" % prop, 16, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(600, 26)
	panel.add_child(title)

	var what: String = "攻击行走图" if prop == "weapon_attack_walk_textures" else "行走图"
	var fallback_line: String = "未配置的键回退到武器自带的 weapon_walk_texture。"
	if prop == "weapon_attack_walk_textures":
		fallback_line = "未配置的键回退 weapon_attack_walk_texture → 再回退举起图（默认＝举起图）。"
	var hint := _label(
		"键 = weapon_state_name；值 = 该武器状态下的%s。\n%s" % [what, fallback_line],
		11, C_MUTED)
	hint.position = Vector2(18, 40)
	hint.size = Vector2(744, 34)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(hint)

	var head_key := _label("武器状态（键）", 11, C_MUTED)
	head_key.position = Vector2(24, 78)
	head_key.size = Vector2(150, 16)
	panel.add_child(head_key)
	var head_tex := _label("贴图 / 路径", 11, C_MUTED)
	head_tex.position = Vector2(248, 78)
	head_tex.size = Vector2(300, 16)
	panel.add_child(head_tex)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(18, 100)
	scroll.size = Vector2(744, 456)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var rows: Array[Dictionary] = []
	for k: Variant in dict.keys():
		_add_texture_dict_row(list, rows, str(k), dict[k] as Texture2D)

	var err := _label("", 12, C_ERR)
	err.position = Vector2(18, 566)
	err.size = Vector2(480, 18)
	panel.add_child(err)

	var add := _button("＋ 添加一项", false)
	add.position = Vector2(18, 594)
	add.size = Vector2(140, 32)
	add.pressed.connect(func():
		var used: Dictionary = {}
		for r: Dictionary in rows:
			used[(r["key"] as LineEdit).text.strip_edges()] = true
		_add_texture_dict_row(list, rows, _next_weapon_state(used), null)
		err.text = "")
	panel.add_child(add)

	var cancel := _button("取消", false)
	cancel.position = Vector2(536, 594)
	cancel.size = Vector2(100, 32)
	cancel.pressed.connect(func():
		overlay.queue_free()
		_texture_dict_overlay = null)
	panel.add_child(cancel)

	var apply := _button("确定", true)
	apply.position = Vector2(648, 594)
	apply.size = Vector2(114, 32)
	apply.pressed.connect(func():
		var out: Dictionary = {}
		for i: int in range(rows.size()):
			var r: Dictionary = rows[i]
			var key: String = (r["key"] as LineEdit).text.strip_edges()
			if key.is_empty():
				err.text = "第 %d 行的武器状态名为空（不要的项请点行尾 −）" % [i + 1]
				return
			if out.has(key):
				err.text = "武器状态名重复：%s" % key
				return
			var tex: Texture2D = r["tex"] as Texture2D
			if tex == null:
				err.text = "「%s」还没有选择贴图" % key
				return
			out[key] = tex
		_set_prop(prop, out)
		overlay.queue_free()
		_texture_dict_overlay = null
		_rebuild_inspector())
	panel.add_child(apply)


## 一行：键输入 + 已有状态名下拉 + 缩略图 + 路径 + 选图/清除/删除。
## `rows` 里存 {root,key,tex,thumb,path}，确定时按行顺序收集。
func _add_texture_dict_row(list: VBoxContainer, rows: Array[Dictionary],
		key_text: String, tex: Texture2D) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(0, 52)
	list.add_child(row)

	var key_edit := LineEdit.new()
	key_edit.text = key_text
	key_edit.custom_minimum_size = Vector2(150, 30)
	key_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	key_edit.placeholder_text = "如 Pistol / Melee"
	key_edit.add_theme_font_override("font", _font)
	key_edit.add_theme_font_size_override("font_size", 13)
	row.add_child(key_edit)

	var menu := MenuButton.new()
	menu.text = "▾"
	menu.tooltip_text = "从项目里出现过的 weapon_state_name 选择"
	menu.custom_minimum_size = Vector2(32, 30)
	menu.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	menu.add_theme_font_override("font", _font)
	menu.add_theme_font_size_override("font_size", 13)
	menu.add_theme_color_override("font_color", C_TEXT)
	menu.add_theme_stylebox_override("normal", _panel_sb(Color("#333333"), Color("#454545"), 3))
	menu.add_theme_stylebox_override("hover", _panel_sb(Color("#3d3d3d"), Color("#505050"), 3))
	menu.add_theme_stylebox_override("pressed", _panel_sb(Color("#2a2a2a"), Color("#454545"), 3))
	var popup: PopupMenu = menu.get_popup()
	popup.add_theme_font_override("font", _font)
	for state: String in _weapon_state_names():
		popup.add_item(state)
	popup.id_pressed.connect(func(id: int):
		key_edit.text = popup.get_item_text(id))
	row.add_child(menu)

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(48, 48)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = tex
	row.add_child(thumb)

	var path_label := _label("（未选择）" if tex == null else tex.resource_path, 11, C_MUTED)
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.clip_text = true
	path_label.mouse_filter = Control.MOUSE_FILTER_PASS
	path_label.tooltip_text = "" if tex == null else tex.resource_path
	row.add_child(path_label)

	var pick := _button("…", false)
	pick.custom_minimum_size = Vector2(30, 30)
	pick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pick.tooltip_text = "打开项目图像浏览器"
	row.add_child(pick)

	var clear := _button("✕", false)
	clear.custom_minimum_size = Vector2(30, 30)
	clear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	clear.tooltip_text = "清除贴图（保留键）"
	row.add_child(clear)

	var del := _button("−", false)
	del.custom_minimum_size = Vector2(30, 30)
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	del.tooltip_text = "删除这一项"
	row.add_child(del)

	var entry: Dictionary = {
		"root": row, "key": key_edit, "tex": tex,
		"thumb": thumb, "path": path_label,
	}
	rows.append(entry)

	pick.pressed.connect(func():
		var current: String = ""
		var t: Texture2D = entry["tex"] as Texture2D
		if t != null:
			current = t.resource_path
		_open_browser(MODE_TEXTURE, current, func(path: String):
			var nt: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
			entry["tex"] = nt
			thumb.texture = nt
			path_label.text = path if nt != null else "（未选择）"
			path_label.tooltip_text = path_label.text))
	clear.pressed.connect(func():
		entry["tex"] = null
		thumb.texture = null
		path_label.text = "（未选择）"
		path_label.tooltip_text = "")
	del.pressed.connect(func():
		for i: int in range(rows.size() - 1, -1, -1):
			if rows[i].get("root") == row:
				rows.remove_at(i)
				break
		row.queue_free())


# ═══════════════════════════════════════
# 通用字典弹窗（标量 / Resource 值）
# ═══════════════════════════════════════

## 行式编辑任意「键 → 标量 / Resource」字典：
##   · 键类型 / 值类型由 _dict_type_info 推断（空字典可从下拉选）；
##   · 标量（int/float/bool/String/Vector2/Color）直接内联编辑；
##   · Resource（如 WeaponEffectOffsets）点「编辑…」打开对象字段弹窗。
func _open_generic_dict_dialog(prop: String, dict: Dictionary, ti: Dictionary) -> void:
	if _generic_dict_overlay != null:
		return
	var info: Dictionary = ti.duplicate(true)
	## 「按步号」偏移表的键是 `角色:步号` 复合串：行里给两个下拉，别让用户手打。
	## 这样和「预览」里的按步号设置是同一套口径，值也能在同一个弹窗里逐条改。
	## 第二击的步号表（2026-10-26）同样处理 —— 步号范围取第二击自己的序列长度。
	if _is_step_offset_prop(prop):
		info["step_key"] = true
		info["step_count"] = _weapon_step_count(prop)
		info["char_ids"] = _player_ids_for_step_key()
	var vp: Vector2 = get_viewport_rect().size
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_generic_dict_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	panel.size = Vector2(880, 700)
	panel.position = ((vp - panel.size) * 0.5).floor()
	overlay.add_child(panel)

	var title := _label("编辑字典：%s" % prop, 16, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(600, 26)
	panel.add_child(title)

	var key_label := _label(
		"键：角色 + 步号" if bool(info.get("step_key", false))
		else "键类型：%s" % ("int" if bool(info.get("key_int", false)) else "String"),
		11, C_MUTED)
	key_label.position = Vector2(18, 44)
	key_label.size = Vector2(150, 18)
	panel.add_child(key_label)

	var val_label := _label("值类型：%s" % str(info.get("label", "")), 11, C_MUTED)
	val_label.position = Vector2(180, 44)
	val_label.size = Vector2(300, 18)
	panel.add_child(val_label)

	var type_btn: OptionButton = null
	if bool(info.get("flexible", false)):
		type_btn = OptionButton.new()
		type_btn.position = Vector2(480, 40)
		type_btn.size = Vector2(170, 26)
		type_btn.add_theme_font_override("font", _font)
		type_btn.add_theme_font_size_override("font_size", 12)
		var type_rows: Array = [
			[DV_STRING, "String"], [DV_INT, "int"], [DV_FLOAT, "float"],
			[DV_BOOL, "bool"], [DV_VECTOR2, "Vector2"], [DV_COLOR, "Color"],
			[DV_TEXTURE, "Texture2D"],
		]
		for i: int in range(type_rows.size()):
			type_btn.add_item(str(type_rows[i][1]), i)
			type_btn.set_item_metadata(i, str(type_rows[i][0]))
			if str(type_rows[i][0]) == str(info.get("kind", DV_STRING)):
				type_btn.select(i)
		type_btn.item_selected.connect(func(idx: int):
			info["kind"] = str(type_btn.get_item_metadata(idx))
			info["label"] = _dict_value_kind_label(str(info["kind"]), null)
			val_label.text = "值类型：%s" % str(info["label"]))
		panel.add_child(type_btn)

	var hint := _label(
		("键 = 角色 + 步号（`角色:步号`）；`*` = 所有角色共用这一步。\n"
			+ "值点「编辑…」改四方向偏移；没配的步号会回退角色基线 `melee_weapon_sprite_offsets`。")
		if bool(info.get("step_key", false)) else
		("键 / 值类型按现有条目自动推断；新增行会沿用这个类型。\n"
			+ "Resource 值点「编辑…」改对象字段（如四方向偏移），改的是副本，确定后才写回。"),
		11, C_MUTED)
	hint.position = Vector2(18, 72)
	hint.size = Vector2(844, 34)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(hint)

	var head_key := _label("角色 / 步号" if bool(info.get("step_key", false)) else "键", 11, C_MUTED)
	head_key.position = Vector2(24, 116)
	head_key.size = Vector2(150, 16)
	panel.add_child(head_key)
	var head_val := _label("值", 11, C_MUTED)
	head_val.position = Vector2(196, 116)
	head_val.size = Vector2(300, 16)
	panel.add_child(head_val)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(18, 138)
	scroll.size = Vector2(844, 456)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var rows: Array[Dictionary] = []
	for k: Variant in dict.keys():
		_add_generic_dict_row(list, rows, prop, k, dict[k], info)

	var err := _label("", 12, C_ERR)
	err.position = Vector2(18, 606)
	err.size = Vector2(520, 18)
	panel.add_child(err)

	var add := _button("＋ 添加一项", false)
	add.position = Vector2(18, 634)
	add.size = Vector2(140, 32)
	add.pressed.connect(func():
		if type_btn != null:
			type_btn.disabled = true
			type_btn.tooltip_text = "已有条目后值类型固定"
		var next_key: Variant = _next_generic_key(prop, rows, bool(info.get("key_int", false)))
		var next_val: Variant = _default_dict_value(str(info.get("kind", DV_STRING)),
			info.get("res_script") as Script)
		_add_generic_dict_row(list, rows, prop, next_key, next_val, info)
		err.text = "")
	panel.add_child(add)

	var cancel := _button("取消", false)
	cancel.position = Vector2(636, 634)
	cancel.size = Vector2(100, 32)
	cancel.pressed.connect(func():
		overlay.queue_free()
		_generic_dict_overlay = null)
	panel.add_child(cancel)

	var apply := _button("确定", true)
	apply.position = Vector2(748, 634)
	apply.size = Vector2(114, 32)
	apply.pressed.connect(func():
		var out: Dictionary = {}
		for i: int in range(rows.size()):
			var r: Dictionary = rows[i]
			var key: Variant = _generic_row_key(r)
			if key is String and (key as String).strip_edges().is_empty():
				err.text = "第 %d 行的键为空" % [i + 1]
				return
			if out.has(key):
				err.text = "键重复：%s" % str(key)
				return
			var v: Variant = _generic_row_value(r)
			var kind: String = str(r.get("kind", DV_STRING))
			if (kind == DV_RESOURCE or kind == DV_TEXTURE) and v == null:
				err.text = "「%s」还没有配置值" % str(key)
				return
			out[key] = v
		_set_prop(prop, out)
		overlay.queue_free()
		_generic_dict_overlay = null
		_rebuild_inspector())
	panel.add_child(apply)


func _next_generic_key(prop: String, rows: Array[Dictionary], key_int: bool) -> Variant:
	var used: Dictionary = {}
	for r: Dictionary in rows:
		used[_generic_row_key(r)] = true
	if _is_step_offset_prop(prop):
		## 先按角色顺序找第一个空位（nobita:0、nobita:1…），最后才给 `*`。
		for cid: String in _player_ids_for_step_key():
			for i: int in range(_weapon_step_count(prop)):
				var k: String = "%s:%d" % [cid, i]
				if not used.has(k):
					return k
		for i: int in range(_weapon_step_count(prop)):
			var w: String = "*:%d" % i
			if not used.has(w):
				return w
		return ""
	if key_int:
		var mx: int = -1
		for k: Variant in used.keys():
			mx = maxi(mx, int(k))
		return mx + 1
	for s: String in _dict_key_suggestions(prop):
		if not used.has(s):
			return s
	return ""


## 当前武器有几个攻击步（步号表的下拉范围）。非武器资源回退 3。
## `prop` 传第二击的步号表时用第二击序列算（两段步数常常不同）。
func _weapon_step_count(prop: String = "") -> int:
	if _res is WeaponData:
		var wd := _res as WeaponData
		if prop == "melee_weapon_sprite_attack2_step_offsets":
			return maxi(wd.get_melee_attack2_char_sequence().size(), 1)
		return maxi(wd.get_melee_attack_char_sequence().size(), 1)
	return 3


## 是否是「按步号」的偏移表（第一击 / 第二击两套，结构相同）。
func _is_step_offset_prop(prop: String) -> bool:
	return prop == "melee_weapon_sprite_step_offsets" \
		or prop == "melee_weapon_sprite_attack2_step_offsets"


## 步号表可选的「角色」：项目里所有玩家角色 id（`*` 在 UI 里单独加）。
func _player_ids_for_step_key() -> Array[String]:
	var out: Array[String] = []
	for e: Dictionary in _entries:
		if str(e.get("kind", "")) != K_PLAYER:
			continue
		var cid: String = str(e.get("id", "")).strip_edges()
		if not cid.is_empty() and not out.has(cid):
			out.append(cid)
	out.sort()
	## のび太 放最前（预览默认角色）：新加步号条目时第一顺位就是 nobita:N。
	if out.has("nobita"):
		out.erase("nobita")
		out.insert(0, "nobita")
	return out


func _dict_key_suggestions(prop: String) -> Array[String]:
	var out: Array[String] = []
	## 动作图「按步号」偏移表：键是 `角色:步号` 复合串，先给 `*:步号` 再给每个角色。
	if _is_step_offset_prop(prop):
		var steps: int = _weapon_step_count(prop)
		for i: int in range(steps):
			out.append("*:%d" % i)
		for e: Dictionary in _entries:
			if str(e.get("kind", "")) != K_PLAYER:
				continue
			var pid: String = str(e.get("id", "")).strip_edges()
			if pid.is_empty():
				continue
			for i: int in range(steps):
				out.append("%s:%d" % [pid, i])
		return out
	## 偏移表按角色 id 配（bullet_spawn_offsets / attack_effect_offsets /
	## melee_weapon_sprite_offsets）；键建议直接列项目里的玩家角色 id。
	if prop.ends_with("_offsets"):
		for e: Dictionary in _entries:
			if str(e.get("kind", "")) != K_PLAYER:
				continue
			var cid: String = str(e.get("id", "")).strip_edges()
			if not cid.is_empty() and not out.has(cid):
				out.append(cid)
		out.sort()
	return out


func _default_dict_value(kind: String, res_script: Script) -> Variant:
	match kind:
		DV_INT: return 0
		DV_FLOAT: return 0.0
		DV_BOOL: return false
		DV_STRING: return ""
		DV_VECTOR2: return Vector2.ZERO
		DV_COLOR: return Color.WHITE
		DV_TEXTURE: return null
		DV_RESOURCE:
			if res_script != null:
				return res_script.new()
			return null
	return null


func _add_generic_dict_row(list: VBoxContainer, rows: Array[Dictionary],
		prop: String, key_val: Variant, val: Variant, info: Dictionary) -> void:
	var kind: String = str(info.get("kind", DV_STRING))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(0, 50)
	list.add_child(row)

	var key_ctrl: Control = null
	## 步号表的第二个下拉（步号）；其它字典保持 null。
	var step_ctrl: OptionButton = null
	if bool(info.get("step_key", false)):
		## 角色 + 步号两个下拉 → 组合成 `角色:步号`。
		## 手打复合键太容易拼错（nobita:1 / nobita1 / 1:nobita），而且看不出有几步。
		var parts: PackedStringArray = str(key_val).split(":")
		var cur_char: String = parts[0] if parts.size() > 0 else "*"
		var cur_step: int = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else 0
		var chars: Array[String] = ["*"]
		for cid: String in (info.get("char_ids", []) as Array):
			if not chars.has(cid):
				chars.append(cid)
		var char_opt := OptionButton.new()
		char_opt.custom_minimum_size = Vector2(132, 30)
		char_opt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		char_opt.add_theme_font_override("font", _font)
		char_opt.add_theme_font_size_override("font_size", 12)
		for i: int in range(chars.size()):
			char_opt.add_item("*（所有角色）" if chars[i] == "*" else chars[i], i)
			char_opt.set_item_metadata(i, chars[i])
			if chars[i] == cur_char:
				char_opt.select(i)
		var step_opt := OptionButton.new()
		step_opt.custom_minimum_size = Vector2(96, 30)
		step_opt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		step_opt.add_theme_font_override("font", _font)
		step_opt.add_theme_font_size_override("font_size", 12)
		var step_count: int = maxi(1, int(info.get("step_count", 3)))
		for i: int in range(step_count):
			step_opt.add_item("第%d步" % (i + 1), i)
			step_opt.set_item_metadata(i, i)
		step_opt.select(clampi(cur_step, 0, step_count - 1))
		key_ctrl = char_opt
		step_ctrl = step_opt
		row.add_child(char_opt)
		row.add_child(step_opt)
	elif bool(info.get("key_int", false)):
		var ks := SpinBox.new()
		ks.min_value = -999999
		ks.max_value = 999999
		ks.step = 1
		ks.value = int(key_val)
		ks.custom_minimum_size = Vector2(120, 30)
		ks.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ks.add_theme_font_override("font", _font)
		ks.add_theme_font_size_override("font_size", 12)
		key_ctrl = ks
	else:
		var ke := LineEdit.new()
		ke.text = str(key_val)
		ke.placeholder_text = "键（如 nobita）"
		ke.custom_minimum_size = Vector2(150, 30)
		ke.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ke.add_theme_font_override("font", _font)
		ke.add_theme_font_size_override("font_size", 13)
		key_ctrl = ke
		var suggestions := _dict_key_suggestions(prop)
		if not suggestions.is_empty():
			var menu := MenuButton.new()
			menu.text = "▾"
			menu.tooltip_text = "从项目里的角色 id 选择"
			menu.custom_minimum_size = Vector2(30, 30)
			menu.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			menu.add_theme_font_override("font", _font)
			menu.add_theme_font_size_override("font_size", 13)
			menu.add_theme_color_override("font_color", C_TEXT)
			menu.add_theme_stylebox_override("normal", _panel_sb(Color("#333333"), Color("#454545"), 3))
			menu.add_theme_stylebox_override("hover", _panel_sb(Color("#3d3d3d"), Color("#505050"), 3))
			menu.add_theme_stylebox_override("pressed", _panel_sb(Color("#2a2a2a"), Color("#454545"), 3))
			var popup: PopupMenu = menu.get_popup()
			popup.add_theme_font_override("font", _font)
			for s: String in suggestions:
				popup.add_item(s)
			popup.id_pressed.connect(func(id: int):
				ke.text = popup.get_item_text(id))
			## 键固定 150，剩余宽度全部给值（偏移摘要/编辑器），否则键框会吃掉一半。
			key_ctrl.size_flags_horizontal = Control.SIZE_FILL
			row.add_child(key_ctrl)
			row.add_child(menu)
		else:
			key_ctrl.size_flags_horizontal = Control.SIZE_FILL
			row.add_child(key_ctrl)
	if key_ctrl.get_parent() == null:
		key_ctrl.size_flags_horizontal = Control.SIZE_FILL
		row.add_child(key_ctrl)

	var entry: Dictionary = {"root": row, "key": key_ctrl, "kind": kind}
	if step_ctrl != null:
		entry["key_step"] = step_ctrl
	row.add_child(_make_dict_value_control(kind, val, info, entry))
	rows.append(entry)

	var del := _button("−", false)
	del.custom_minimum_size = Vector2(30, 30)
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	del.tooltip_text = "删除这一项"
	del.pressed.connect(func():
		for i: int in range(rows.size() - 1, -1, -1):
			if rows[i].get("root") == row:
				rows.remove_at(i)
				break
		row.queue_free())
	row.add_child(del)


func _generic_row_key(row: Dictionary) -> Variant:
	var c: Control = row.get("key") as Control
	if c is OptionButton and row.get("key_step") != null:
		var step_opt: OptionButton = row.get("key_step") as OptionButton
		return "%s:%d" % [str((c as OptionButton).get_item_metadata((c as OptionButton).selected)),
			step_opt.selected]
	if c is SpinBox:
		return int((c as SpinBox).value)
	if c is LineEdit:
		return (c as LineEdit).text.strip_edges()
	return ""


func _generic_row_value(row: Dictionary) -> Variant:
	match str(row.get("kind", DV_STRING)):
		DV_INT:
			return int((row["value"] as SpinBox).value)
		DV_FLOAT:
			return float((row["value"] as SpinBox).value)
		DV_BOOL:
			return bool((row["value"] as CheckBox).button_pressed)
		DV_STRING:
			return (row["value"] as LineEdit).text
		DV_VECTOR2:
			return Vector2(float((row["vx"] as SpinBox).value),
				float((row["vy"] as SpinBox).value))
		DV_COLOR:
			return (row["value"] as ColorPickerButton).color
		DV_TEXTURE:
			return row.get("tex")
		DV_RESOURCE:
			return row.get("res")
	return null


func _make_dict_value_control(kind: String, val: Variant, info: Dictionary,
		row: Dictionary) -> Control:
	match kind:
		DV_INT:
			var si := SpinBox.new()
			si.min_value = -999999
			si.max_value = 999999
			si.step = 1
			si.value = int(val) if val != null else 0
			si.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			si.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			si.add_theme_font_override("font", _font)
			si.add_theme_font_size_override("font_size", 12)
			row["value"] = si
			return si
		DV_FLOAT:
			var sf := SpinBox.new()
			sf.min_value = -999999.0
			sf.max_value = 999999.0
			sf.step = 0.1
			sf.value = float(val) if val != null else 0.0
			sf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sf.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			sf.add_theme_font_override("font", _font)
			sf.add_theme_font_size_override("font_size", 12)
			row["value"] = sf
			return sf
		DV_BOOL:
			var cb := CheckBox.new()
			cb.button_pressed = bool(val) if val != null else false
			cb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row["value"] = cb
			return cb
		DV_STRING:
			var le := LineEdit.new()
			le.text = str(val) if val != null else ""
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			le.add_theme_font_override("font", _font)
			le.add_theme_font_size_override("font_size", 13)
			row["value"] = le
			return le
		DV_VECTOR2:
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 4)
			box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var v: Vector2 = val if val is Vector2 else Vector2.ZERO
			var sx := SpinBox.new()
			sx.min_value = -99999.0
			sx.max_value = 99999.0
			sx.step = 0.1
			sx.value = v.x
			sx.custom_minimum_size = Vector2(100, 30)
			sx.add_theme_font_override("font", _font)
			sx.add_theme_font_size_override("font_size", 12)
			var sy := SpinBox.new()
			sy.min_value = -99999.0
			sy.max_value = 99999.0
			sy.step = 0.1
			sy.value = v.y
			sy.custom_minimum_size = Vector2(100, 30)
			sy.add_theme_font_override("font", _font)
			sy.add_theme_font_size_override("font_size", 12)
			var lx := _label("x", 11, C_MUTED)
			var ly := _label("y", 11, C_MUTED)
			box.add_child(lx)
			box.add_child(sx)
			box.add_child(ly)
			box.add_child(sy)
			row["vx"] = sx
			row["vy"] = sy
			row["value"] = box
			return box
		DV_COLOR:
			var cp := ColorPickerButton.new()
			cp.color = val if val is Color else Color.WHITE
			cp.custom_minimum_size = Vector2(140, 30)
			cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row["value"] = cp
			return cp
		DV_TEXTURE:
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var tex: Texture2D = val as Texture2D
			var thumb := TextureRect.new()
			thumb.custom_minimum_size = Vector2(42, 42)
			thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			thumb.texture = tex
			var path_label := _label("（未选择）" if tex == null else tex.resource_path, 11, C_MUTED)
			path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			path_label.clip_text = true
			path_label.mouse_filter = Control.MOUSE_FILTER_PASS
			path_label.tooltip_text = "" if tex == null else tex.resource_path
			var pick := _button("…", false)
			pick.custom_minimum_size = Vector2(30, 30)
			var clear := _button("✕", false)
			clear.custom_minimum_size = Vector2(30, 30)
			box.add_child(thumb)
			box.add_child(path_label)
			box.add_child(pick)
			box.add_child(clear)
			row["tex"] = tex
			row["thumb"] = thumb
			row["path"] = path_label
			row["value"] = box
			pick.pressed.connect(func():
				var current: String = ""
				var t: Texture2D = row.get("tex") as Texture2D
				if t != null:
					current = t.resource_path
				_open_browser(MODE_TEXTURE, current, func(path: String):
					var nt: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
					row["tex"] = nt
					thumb.texture = nt
					path_label.text = path if nt != null else "（未选择）"
					path_label.tooltip_text = path_label.text))
			clear.pressed.connect(func():
				row["tex"] = null
				thumb.texture = null
				path_label.text = "（未选择）"
				path_label.tooltip_text = "")
			return box
		DV_RESOURCE:
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var res: Resource = val as Resource
			var summary := _label(_resource_summary(res), 11, C_MUTED)
			summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			summary.clip_text = true
			summary.mouse_filter = Control.MOUSE_FILTER_PASS
			var edit := _button("编辑…", false)
			edit.custom_minimum_size = Vector2(64, 30)
			edit.disabled = res == null
			box.add_child(summary)
			box.add_child(edit)
			row["res"] = res
			row["res_label"] = summary
			row["value"] = box
			edit.pressed.connect(func():
				var cur: Resource = row.get("res") as Resource
				if cur == null:
					return
				_open_resource_dialog(_script_display_name(cur.get_script()), cur,
					func(new_res: Resource):
						row["res"] = new_res
						summary.text = _resource_summary(new_res)))
			return box
	return _label("（不支持的类型）", 11, C_ERR)


func _resource_summary(res: Resource) -> String:
	if res == null:
		return "（未设置）"
	## WeaponEffectOffsets 的四方向：紧凑显示，方便一眼看出哪一项偏了。
	if res.get("down") is Vector2 and res.get("left") is Vector2 \
			and res.get("right") is Vector2 and res.get("up") is Vector2:
		return "下%s 左%s 右%s 上%s" % [
			_fmt_vec(res.get("down")), _fmt_vec(res.get("left")),
			_fmt_vec(res.get("right")), _fmt_vec(res.get("up"))]
	var parts: Array[String] = []
	for p: Dictionary in res.get_property_list():
		if not (int(p.get("usage", 0)) & PROPERTY_USAGE_EDITOR):
			continue
		var n: String = str(p.get("name", ""))
		if n.is_empty() or n == "script" or n.begins_with("resource_"):
			continue
		var v: Variant = res.get(n)
		if v is int or v is float or v is bool or v is String:
			parts.append("%s=%s" % [n, str(v)])
		if parts.size() >= 3:
			break
	return " ".join(parts) if not parts.is_empty() else "（对象）"


func _fmt_vec(v: Vector2) -> String:
	return "(%.0f,%.0f)" % [v.x, v.y]


# ═══════════════════════════════════════
# 子对象弹窗（Resource 的简单字段）
# ═══════════════════════════════════════

## 编辑 Resource 值（如 WeaponEffectOffsets）的简单字段。
## 写的是 duplicate 出来的副本，点确定才通过 on_ok 回写；取消/关窗不改原对象。
func _open_resource_dialog(display_name: String, res: Resource, on_ok: Callable) -> void:
	if _resource_overlay != null or res == null:
		return
	var work: Resource = res.duplicate(true)
	var fields: Array[Dictionary] = []
	for p: Dictionary in work.get_property_list():
		var usage: int = int(p.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR) or not (usage & PROPERTY_USAGE_STORAGE):
			continue
		var n: String = str(p.get("name", ""))
		if n.is_empty() or n == "script" or n.begins_with("resource_"):
			continue
		var t: int = int(p.get("type", 0))
		if t in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME,
				TYPE_VECTOR2, TYPE_COLOR, TYPE_OBJECT]:
			fields.append(p)

	var vp: Vector2 = get_viewport_rect().size
	var panel_h: float = clampf(170.0 + float(fields.size()) * 66.0, 280.0, 780.0)
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_resource_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	panel.size = Vector2(640, panel_h)
	panel.position = ((vp - panel.size) * 0.5).floor()
	overlay.add_child(panel)

	var title := _label("编辑对象：%s" % display_name, 15, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(500, 24)
	panel.add_child(title)

	var sub := _label("改的是副本；点「确定」才写回字典。", 11, C_MUTED)
	sub.position = Vector2(18, 40)
	sub.size = Vector2(500, 18)
	panel.add_child(sub)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(18, 66)
	scroll.size = Vector2(604, panel_h - 132.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var docs: Dictionary = {}
	var scr: Script = work.get_script()
	if scr != null and not scr.resource_path.is_empty():
		docs = _parse_script_groups(scr.resource_path).get("field_doc", {})

	var shown: int = 0
	for p: Dictionary in fields:
		var n: String = str(p.get("name", ""))
		var editor: Control = _make_resource_field_editor(work, n, p)
		if editor == null:
			continue
		shown += 1
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 1)
		list.add_child(row)
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		row.add_child(hbox)
		var name_label := _label(n, 12, C_MUTED)
		name_label.custom_minimum_size = Vector2(140, 0)
		name_label.clip_text = true
		name_label.tooltip_text = n
		hbox.add_child(name_label)
		editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(editor)
		var doc: String = str(docs.get(n, "")).strip_edges()
		if not doc.is_empty():
			var doc_label := _label(doc, 11, Color("#8f8f8f"))
			doc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			doc_label.custom_minimum_size = Vector2(0, 0)
			row.add_child(doc_label)
		var line := ColorRect.new()
		line.color = Color(1, 1, 1, 0.035)
		line.custom_minimum_size = Vector2(0, 1)
		list.add_child(line)

	if shown == 0:
		var empty := _label("这个对象没有可用简单字段编辑（可能包含数组/嵌套资源）。", 12, C_MUTED)
		empty.custom_minimum_size = Vector2(0, 60)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(empty)

	var cancel := _button("取消", false)
	cancel.position = Vector2(396, panel_h - 48.0)
	cancel.size = Vector2(100, 32)
	cancel.pressed.connect(func():
		overlay.queue_free()
		_resource_overlay = null)
	panel.add_child(cancel)

	var ok := _button("确定", true)
	ok.position = Vector2(508, panel_h - 48.0)
	ok.size = Vector2(114, 32)
	ok.pressed.connect(func():
		overlay.queue_free()
		_resource_overlay = null
		on_ok.call(work))
	panel.add_child(ok)


func _make_resource_field_editor(res: Resource, prop: String, info: Dictionary) -> Control:
	var type: int = int(info.get("type", 0))
	var value: Variant = res.get(prop)
	match type:
		TYPE_BOOL:
			var cb := CheckBox.new()
			cb.button_pressed = bool(value)
			cb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			cb.toggled.connect(func(on: bool): res.set(prop, on))
			return cb
		TYPE_INT:
			var si := SpinBox.new()
			si.min_value = -999999
			si.max_value = 999999
			si.step = 1
			si.value = int(value)
			si.add_theme_font_override("font", _font)
			si.add_theme_font_size_override("font_size", 12)
			si.value_changed.connect(func(v: float): res.set(prop, int(v)))
			return si
		TYPE_FLOAT:
			var sf := SpinBox.new()
			sf.min_value = -999999.0
			sf.max_value = 999999.0
			sf.step = 0.1
			sf.value = float(value)
			sf.add_theme_font_override("font", _font)
			sf.add_theme_font_size_override("font_size", 12)
			sf.value_changed.connect(func(v: float): res.set(prop, float(v)))
			return sf
		TYPE_STRING:
			var le := LineEdit.new()
			le.text = str(value)
			le.add_theme_font_override("font", _font)
			le.add_theme_font_size_override("font_size", 13)
			le.text_changed.connect(func(t: String): res.set(prop, t))
			return le
		TYPE_STRING_NAME:
			var sn := LineEdit.new()
			sn.text = str(value)
			sn.add_theme_font_override("font", _font)
			sn.add_theme_font_size_override("font_size", 13)
			sn.text_changed.connect(func(t: String): res.set(prop, StringName(t)))
			return sn
		TYPE_VECTOR2:
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 4)
			var v: Vector2 = value if value is Vector2 else Vector2.ZERO
			var sx := SpinBox.new()
			sx.min_value = -99999.0
			sx.max_value = 99999.0
			sx.step = 0.1
			sx.value = v.x
			sx.custom_minimum_size = Vector2(120, 30)
			sx.add_theme_font_override("font", _font)
			sx.add_theme_font_size_override("font_size", 12)
			var sy := SpinBox.new()
			sy.min_value = -99999.0
			sy.max_value = 99999.0
			sy.step = 0.1
			sy.value = v.y
			sy.custom_minimum_size = Vector2(120, 30)
			sy.add_theme_font_override("font", _font)
			sy.add_theme_font_size_override("font_size", 12)
			box.add_child(_label("x", 11, C_MUTED))
			box.add_child(sx)
			box.add_child(_label("y", 11, C_MUTED))
			box.add_child(sy)
			var apply_vec := func(_v: float):
				res.set(prop, Vector2(float(sx.value), float(sy.value)))
			sx.value_changed.connect(apply_vec)
			sy.value_changed.connect(apply_vec)
			return box
		TYPE_COLOR:
			var cp := ColorPickerButton.new()
			cp.color = value if value is Color else Color.WHITE
			cp.custom_minimum_size = Vector2(160, 30)
			cp.color_changed.connect(func(c: Color): res.set(prop, c))
			return cp
		TYPE_OBJECT:
			## 只处理 Texture2D；其它对象（嵌套 Resource / 场景）跳过，避免做成半个通用检查器。
			if not (value is Texture2D) and not (info.get("hint_string", "") == "Texture2D"):
				return null
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			var tex: Texture2D = value as Texture2D
			var thumb := TextureRect.new()
			thumb.custom_minimum_size = Vector2(42, 42)
			thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			thumb.texture = tex
			var path_label := _label("（未选择）" if tex == null else tex.resource_path, 11, C_MUTED)
			path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			path_label.clip_text = true
			path_label.mouse_filter = Control.MOUSE_FILTER_PASS
			var pick := _button("…", false)
			pick.custom_minimum_size = Vector2(30, 30)
			var clear := _button("✕", false)
			clear.custom_minimum_size = Vector2(30, 30)
			box.add_child(thumb)
			box.add_child(path_label)
			box.add_child(pick)
			box.add_child(clear)
			pick.pressed.connect(func():
				var current: String = ""
				if res.get(prop) is Texture2D:
					current = (res.get(prop) as Texture2D).resource_path
				_open_browser(MODE_TEXTURE, current, func(path: String):
					var nt: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
					res.set(prop, nt)
					thumb.texture = nt
					path_label.text = path if nt != null else "（未选择）"))
			clear.pressed.connect(func():
				res.set(prop, null)
				thumb.texture = null
				path_label.text = "（未选择）")
			return box
	return null


# ═══════════════════════════════════════
# 偏移可视化预览（子弹 / 武器动作 / 特效）
# ═══════════════════════════════════════

func _offset_prop(mode: String) -> String:
	match mode:
		"weapon": return "melee_weapon_sprite_offsets"
		"effect": return "attack_effect_offsets"
	return "bullet_spawn_offsets"


func _offset_mode_label(mode: String) -> String:
	match mode:
		"weapon": return "武器动作"
		"effect": return "攻击特效"
	return "子弹"


func _offset_modes(wd: WeaponData) -> Array[String]:
	var out: Array[String] = []
	if not wd.bullet_list.is_empty():
		out.append("bullet")
	if wd.has_melee_weapon_sprite(false) or wd.melee_weapon_sprite_attack2 != null:
		out.append("weapon")
	if wd.attack_effect_anim_down != null or wd.attack_effect_anim_left != null \
			or wd.attack_effect_anim_right != null or wd.attack_effect_anim_up != null:
		out.append("effect")
	return out


func _player_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in _entries:
		if str(e.get("kind", "")) != K_PLAYER:
			continue
		var cid: String = str(e.get("id", "")).strip_edges()
		if cid.is_empty():
			continue
		var path: String = str(e.get("path", ""))
		var cname: String = str(e.get("name", cid))
		var cd: CharacterData = load(path) as CharacterData
		if cd != null and not cd.character_name.is_empty():
			cname = cd.character_name
		out.append({"id": cid, "name": cname, "path": path})
	return out


func _character_by_id(cid: String) -> CharacterData:
	for e: Dictionary in _entries:
		if str(e.get("kind", "")) == K_PLAYER and str(e.get("id", "")) == cid:
			var cd: CharacterData = load(str(e.get("path", ""))) as CharacterData
			if cd != null:
				return cd
	var fallback: CharacterData = load("res://object/character_nobita.tres") as CharacterData
	return fallback


func _offset_field(res: Resource, direction: int) -> Vector2:
	if res == null:
		return Vector2.ZERO
	match direction:
		0: return res.get("down") as Vector2 if res.get("down") is Vector2 else Vector2.ZERO
		1: return res.get("left") as Vector2 if res.get("left") is Vector2 else Vector2.ZERO
		2: return res.get("right") as Vector2 if res.get("right") is Vector2 else Vector2.ZERO
		3: return res.get("up") as Vector2 if res.get("up") is Vector2 else Vector2.ZERO
	return Vector2.ZERO


func _set_offset_field(res: Resource, direction: int, value: Vector2) -> void:
	match direction:
		0: res.set("down", value)
		1: res.set("left", value)
		2: res.set("right", value)
		3: res.set("up", value)


## 当前显示的偏移值 + 它来自哪一层。
## 武器动作模式按 `scope` 决定看哪一层：
##   scope = "step"（默认）→ 本步专用 → 所有角色本步 → 角色基线 → 零；
##   scope = "char"        → 只看角色基线（旧行为，所有步共用）。
## 这样「显示的值」永远等于「拖动会写进去的那一层」，不会出现拖了却没反应。
func _offset_effective(wd: WeaponData, mode: String, cid: String, direction: int,
		bullet_index: int, step: int = -1, scope: String = "step") -> Dictionary:
	if mode == "weapon":
		if scope == "char":
			var base: Resource = wd.melee_weapon_sprite_offsets.get(cid) as Resource
			return {
				"value": _offset_field(base, direction),
				"using_default": base == null,
				"source": "char" if base != null else "none",
				"res": base,
			}
		var source: String = wd.get_melee_weapon_sprite_offset_source(cid, step)
		var value: Vector2 = wd.get_melee_weapon_sprite_offset_by_key(cid, direction, step)
		return {"value": value, "using_default": source == "none", "source": source, "res": null}
	var dict: Dictionary = wd.get(_offset_prop(mode))
	var res: Resource = dict.get(cid) as Resource
	if res != null:
		return {"value": _offset_field(res, direction), "using_default": false,
			"source": "char", "res": res}
	var fallback: Vector2 = Vector2.ZERO
	match mode:
		"bullet":
			if bullet_index >= 0 and bullet_index < wd.bullet_list.size():
				fallback = (wd.bullet_list[bullet_index] as BulletData).get_extra_offset(direction)
		"effect":
			fallback = wd.attack_effect_offset_override
	return {"value": fallback, "using_default": true, "source": "none", "res": null}


func _offset_commit(wd: WeaponData, state: Dictionary, value: Vector2) -> void:
	var mode: String = str(state.get("mode", "bullet"))
	var cid: String = str(state.get("char_id", ""))
	var direction: int = int(state.get("direction", 0))
	if cid.is_empty():
		return
	var prop: String = _offset_prop(mode)
	var key: String = cid
	## 武器动作：默认写「角色:步号」这一层；关掉「按步号」才写回角色基线。
	if mode == "weapon" and str(state.get("scope", "step")) == "step":
		prop = "melee_weapon_sprite_step_offsets"
		key = "%s:%d" % [cid, maxi(0, int(state.get("step", 0)))]
	var dict: Dictionary = wd.get(prop)
	var res: Resource = dict.get(key) as Resource
	if res == null:
		res = load("res://script/weapon_effect_offsets.gd").new()
		dict[key] = res
	_set_offset_field(res, direction, value)
	wd.set(prop, dict)
	_set_prop(prop, dict)


## 删掉「本步专用」条目，让这一步回退到角色基线（没有条目就不动）。
func _offset_drop_step(wd: WeaponData, state: Dictionary) -> bool:
	if str(state.get("mode", "")) != "weapon":
		return false
	var cid: String = str(state.get("char_id", ""))
	if cid.is_empty():
		return false
	var key: String = "%s:%d" % [cid, maxi(0, int(state.get("step", 0)))]
	var dict: Dictionary = wd.get("melee_weapon_sprite_step_offsets")
	if not dict.has(key):
		return false
	dict.erase(key)
	wd.set("melee_weapon_sprite_step_offsets", dict)
	_set_prop("melee_weapon_sprite_step_offsets", dict)
	return true


func _offset_preview_row(text: String, ctrl: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var l := _label(text, 12, C_MUTED)
	l.custom_minimum_size = Vector2(92, 0)
	h.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(ctrl)
	return h


func _offset_spin(value: float, min_v: float, max_v: float) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = 1
	sp.value = value
	sp.add_theme_font_override("font", _font)
	sp.add_theme_font_size_override("font_size", 12)
	return sp


func _offset_option(items: Array, selected: int) -> OptionButton:
	var opt := OptionButton.new()
	opt.add_theme_font_override("font", _font)
	opt.add_theme_font_size_override("font_size", 12)
	for i: int in range(items.size()):
		opt.add_item(str(items[i][0]), i)
		opt.set_item_metadata(i, items[i][1])
	if opt.item_count > 0:
		opt.select(clampi(selected, 0, opt.item_count - 1))
	return opt


func _offset_preview_refresh(wd: WeaponData, state: Dictionary, preview: Control,
		ui: Dictionary, reset_drag: bool = false) -> void:
	var mode: String = str(state.get("mode", "bullet"))
	var cid: String = str(state.get("char_id", ""))
	var direction: int = clampi(int(state.get("direction", 0)), 0, 3)
	var step: int = maxi(0, int(state.get("step", 0)))
	var bullet_index: int = maxi(0, int(state.get("bullet_index", 0)))
	if mode == "weapon":
		var seq: Array[int] = wd.get_melee_attack_char_sequence()
		if not seq.is_empty():
			state["char_idx"] = seq[clampi(step, 0, seq.size() - 1)]
	var char_idx: int = maxi(0, int(state.get("char_idx", wd.get_ready_char_index())))
	var frame: int = clampi(int(state.get("frame", 1)), 0, 2)
	var cd: CharacterData = _character_by_id(cid)
	var scope: String = str(state.get("scope", "step"))
	var eff: Dictionary = _offset_effective(wd, mode, cid, direction, bullet_index, step, scope)
	preview.call("set_preview", wd, cd, mode, direction, step, char_idx, frame,
		bullet_index, eff["value"], eff["using_default"])
	if reset_drag:
		preview.call("cancel_drag")

	if ui.has("bullet_row"):
		(ui["bullet_row"] as Control).visible = mode == "bullet"
	if ui.has("step_row"):
		(ui["step_row"] as Control).visible = mode == "weapon"
	if ui.has("scope_row"):
		(ui["scope_row"] as Control).visible = mode == "weapon"
	if ui.has("drop_step"):
		var drop: Button = ui["drop_step"] as Button
		drop.visible = mode == "weapon"
		drop.disabled = mode != "weapon" or scope != "step" \
			or not wd.melee_weapon_sprite_step_offsets.has(
				"%s:%d" % [cid, maxi(0, int(state.get("step", 0)))])
	if ui.has("step_opt") and mode == "weapon":
		## 在步号下拉里标出哪些步已经有单独条目（✓），否则用户看不出「按步号」有没有生效。
		var sop: OptionButton = ui["step_opt"] as OptionButton
		var bases: Array = ui.get("step_base_labels", [])
		var step_dict: Dictionary = wd.melee_weapon_sprite_step_offsets
		for i: int in range(sop.item_count):
			var base: String = str(bases[i]) if i < bases.size() else sop.get_item_text(i)
			var has_entry: bool = step_dict.has("%s:%d" % [cid, i]) \
				or step_dict.has("*:%d" % i)
			sop.set_item_text(i, base + ("  ✓" if has_entry else ""))
	if ui.has("char_row"):
		(ui["char_row"] as Control).visible = mode != "weapon"
	if ui.has("frame_row"):
		## 武器动作也能切 0/1/2 帧查看（默认 1 = 游戏里攻击使用的站立帧）
		(ui["frame_row"] as Control).visible = true
	if ui.has("x"):
		(ui["x"] as SpinBox).set_value_no_signal(float(eff["value"].x))
	if ui.has("y"):
		(ui["y"] as SpinBox).set_value_no_signal(float(eff["value"].y))
	for m: String in (ui.get("mode_buttons", {}) as Dictionary).keys():
		(ui["mode_buttons"][m] as Button).button_pressed = (m == mode)
	if ui.has("status"):
		var dir_label: String = ["下", "左", "右", "上"][direction]
		var bullet_name := ""
		if mode == "bullet" and bullet_index < wd.bullet_list.size():
			var bd: BulletData = wd.bullet_list[bullet_index]
			bullet_name = bd.resource_path.get_file() if not bd.resource_path.is_empty() else "子弹%d" % (bullet_index + 1)
		var source: String = "默认兜底"
		var write_note: String = "（拖动后自动创建条目）"
		if bool(eff["using_default"]):
			source = "默认兜底"
		elif mode == "weapon":
			match str(eff["source"]):
				"step": source = "本步专用"
				"any": source = "所有角色·本步"
				"char": source = "角色基线（本步未单独设置）"
				_: source = "未配置"
		else:
			source = "武器级条目"
		if mode == "weapon":
			write_note = "（写入角色基线）" if scope == "char" else "（拖动写入本步）"
			if str(eff["source"]) == "char" and scope == "step":
				write_note = "（拖动后本步单独覆盖基线）"
		var extra: String = (" · " + bullet_name) if not bullet_name.is_empty() else ""
		var step_note := ""
		if mode == "weapon":
			step_note = " · 第%d步" % (step + 1)
		var dirty_note: String = " · 未保存（Ctrl+S）" if _dirty else ""
		(ui["status"] as Label).text = "%s%s%s · %s · %s%s\n偏移 (%d, %d) · %s%s" % [
			_offset_mode_label(mode), extra, step_note, cid, dir_label, dirty_note,
			roundi(eff["value"].x), roundi(eff["value"].y), source, write_note]


func _open_offset_preview(focus_prop: String = "") -> void:
	if _offset_overlay != null:
		return
	if not (_res is WeaponData):
		_toast_show("偏移预览只支持武器资源", C_WARN)
		return
	var wd: WeaponData = _res
	var modes: Array[String] = _offset_modes(wd)
	if modes.is_empty():
		_toast_show("这把武器没有可预览的偏移（无子弹/武器动作/特效）", C_WARN)
		return
	var players: Array[Dictionary] = _player_entries()
	if players.is_empty():
		_toast_show("没扫描到玩家角色资源", C_ERR)
		return

	var focus_mode: String = ""
	match focus_prop:
		"bullet_spawn_offsets": focus_mode = "bullet"
		"melee_weapon_sprite_offsets": focus_mode = "weapon"
		"melee_weapon_sprite_step_offsets": focus_mode = "weapon"
		"attack_effect_offsets": focus_mode = "effect"
	var mode: String = focus_mode if modes.has(focus_mode) else modes[0]
	var cid: String = "nobita"
	var has_nobita: bool = false
	for p: Dictionary in players:
		if str(p["id"]) == "nobita":
			has_nobita = true
	if not has_nobita:
		cid = str(players[0]["id"])

	var state: Dictionary = {
		"mode": mode,
		"char_id": cid,
		"direction": 0,
		"step": 0,
		"bullet_index": 0,
		"char_idx": wd.get_ready_char_index(),
		"frame": 1,
		## 武器动作默认按步号分开写；关掉才是「所有步共用角色基线」的旧行为。
		"scope": "step",
	}

	var vp: Vector2 = get_viewport_rect().size
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_offset_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	panel.size = Vector2(1120, 840)
	panel.position = ((vp - panel.size) * 0.5).floor()
	overlay.add_child(panel)

	var title := _label("偏移预览：%s" % wd.item_name, 16, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(600, 26)
	panel.add_child(title)

	var sub := _label("拖动黄点 / 武器图直接改偏移；Ctrl+S 保存到 .tres", 11, C_MUTED)
	sub.position = Vector2(18, 40)
	sub.size = Vector2(600, 18)
	panel.add_child(sub)

	## 先声明，模式按钮的闭包在上面创建时会捕获它（GDScript 需要先入作用域）。
	var preview: Control = null
	var ui: Dictionary = {"mode_buttons": {}}
	var mode_buttons: Dictionary = {}
	var group := ButtonGroup.new()
	for i: int in range(modes.size()):
		var m: String = modes[i]
		var b := _button(_offset_mode_label(m), false)
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = (m == mode)
		b.position = Vector2(18 + i * 118, 66)
		b.size = Vector2(110, 30)
		b.pressed.connect(func():
			state["mode"] = m
			state["frame"] = 1
			if m != "weapon":
				state["char_idx"] = wd.get_ready_char_index()
			_offset_preview_refresh(wd, state, preview, ui, true))
		panel.add_child(b)
		mode_buttons[m] = b
	ui["mode_buttons"] = mode_buttons

	preview = OFFSET_PREVIEW.new()
	preview.position = Vector2(18, 108)
	preview.size = Vector2(660, 700)
	preview.set("font", _font)
	panel.add_child(preview)
	preview.connect("offset_edited", func(m: String, c: String, d: int, v: Vector2):
		state["mode"] = m
		state["char_id"] = c
		state["direction"] = d
		_offset_commit(wd, state, v)
		_offset_preview_refresh(wd, state, preview, ui))

	var vb := VBoxContainer.new()
	vb.position = Vector2(700, 108)
	vb.size = Vector2(400, 700)
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var char_opt := _offset_option(
		players.map(func(p: Dictionary): return ["%s (%s)" % [p["name"], p["id"]], p["id"]]),
		_index_of_player(players, cid))
	char_opt.item_selected.connect(func(i: int):
		state["char_id"] = str(char_opt.get_item_metadata(i))
		if str(state["mode"]) != "weapon":
			state["char_idx"] = wd.get_ready_char_index()
			state["frame"] = 1
		_offset_preview_refresh(wd, state, preview, ui, true))
	vb.add_child(_offset_preview_row("角色", char_opt))

	var dir_opt := _offset_option(
		[["下", 0], ["左", 1], ["右", 2], ["上", 3]], int(state["direction"]))
	dir_opt.item_selected.connect(func(i: int):
		state["direction"] = i
		_offset_preview_refresh(wd, state, preview, ui, true))
	vb.add_child(_offset_preview_row("方向", dir_opt))

	var bullets: Array = []
	for i: int in range(wd.bullet_list.size()):
		var bd: BulletData = wd.bullet_list[i]
		var nm: String = bd.resource_path.get_file() if not bd.resource_path.is_empty() else "子弹%d" % (i + 1)
		bullets.append([nm, i])
	var bullet_opt := _offset_option(bullets, int(state["bullet_index"]))
	bullet_opt.item_selected.connect(func(i: int):
		state["bullet_index"] = i
		_offset_preview_refresh(wd, state, preview, ui, true))
	var bullet_row := _offset_preview_row("子弹", bullet_opt)
	vb.add_child(bullet_row)
	ui["bullet_row"] = bullet_row

	var steps: Array = []
	var seq: Array[int] = wd.get_melee_attack_char_sequence()
	for i: int in range(seq.size()):
		var col: int = wd.get_melee_weapon_sprite_col(i)
		var col_label: String = "前摇" if col == 0 else ("挥动" if col == 1 else ("后摇" if col == 2 else "不显示"))
		steps.append(["第%d步  idx=%d  %s" % [i + 1, seq[i], col_label], i])
	var step_opt := _offset_option(steps, int(state["step"]))
	step_opt.tooltip_text = "✓ = 这一步已有单独偏移条目（否则回退角色基线）"
	var step_bases: Array = []
	for srow: Array in steps:
		step_bases.append(str(srow[0]))
	ui["step_opt"] = step_opt
	ui["step_base_labels"] = step_bases
	step_opt.item_selected.connect(func(i: int):
		state["step"] = i
		_offset_preview_refresh(wd, state, preview, ui, true))
	var step_row := _offset_preview_row("攻击步号", step_opt)
	vb.add_child(step_row)
	ui["step_row"] = step_row

	## 「按步号分别设置」：默认开。关掉 = 写回角色基线（所有步共用，旧行为）。
	var scope_box := HBoxContainer.new()
	scope_box.add_theme_constant_override("separation", 8)
	var scope_label := _label("按步号分别设置", 12, C_MUTED)
	scope_label.custom_minimum_size = Vector2(92, 0)
	scope_box.add_child(scope_label)
	var scope_check := CheckBox.new()
	scope_check.button_pressed = true
	scope_check.tooltip_text = "开：每一步各存一条偏移（推荐，前摇/挥动/后摇位置不同）\n" \
		+ "关：只改角色基线 melee_weapon_sprite_offsets（所有步共用）"
	scope_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	scope_box.add_child(scope_check)
	vb.add_child(scope_box)
	ui["scope_row"] = scope_box
	scope_check.toggled.connect(func(on: bool):
		state["scope"] = "step" if on else "char"
		_offset_preview_refresh(wd, state, preview, ui, true))

	var drop_step := _button("移除本步条目", false)
	drop_step.tooltip_text = "删掉「角色:步号」这一条，让该步回退到角色基线"
	drop_step.pressed.connect(func():
		if _offset_drop_step(wd, state):
			_toast_show("已移除本步条目，回退到角色基线", C_OK)
		else:
			_toast_show("这一步还没有单独条目", C_MUTED)
		_offset_preview_refresh(wd, state, preview, ui))
	vb.add_child(drop_step)
	ui["drop_step"] = drop_step

	var char_spin := _offset_spin(float(state["char_idx"]), 0, 63)
	char_spin.value_changed.connect(func(v: float):
		state["char_idx"] = int(v)
		_offset_preview_refresh(wd, state, preview, ui))
	var char_row := _offset_preview_row("角色索引", char_spin)
	vb.add_child(char_row)
	ui["char_row"] = char_row

	var frame_spin := _offset_spin(float(state["frame"]), 0, 2)
	frame_spin.value_changed.connect(func(v: float):
		state["frame"] = int(v)
		_offset_preview_refresh(wd, state, preview, ui))
	var frame_row := _offset_preview_row("帧", frame_spin)
	vb.add_child(frame_row)
	ui["frame_row"] = frame_row

	var x_spin := _offset_spin(0.0, -512.0, 512.0)
	var y_spin := _offset_spin(0.0, -512.0, 512.0)
	x_spin.value_changed.connect(func(_v: float):
		_offset_commit(wd, state, Vector2(x_spin.value, y_spin.value))
		_offset_preview_refresh(wd, state, preview, ui))
	y_spin.value_changed.connect(func(_v: float):
		_offset_commit(wd, state, Vector2(x_spin.value, y_spin.value))
		_offset_preview_refresh(wd, state, preview, ui))
	vb.add_child(_offset_preview_row("偏移 X", x_spin))
	vb.add_child(_offset_preview_row("偏移 Y", y_spin))
	ui["x"] = x_spin
	ui["y"] = y_spin

	var zero := _button("归零", false)
	zero.pressed.connect(func():
		_offset_commit(wd, state, Vector2.ZERO)
		_offset_preview_refresh(wd, state, preview, ui))
	vb.add_child(zero)

	var save := _button("保存到 .tres", true)
	save.pressed.connect(func():
		_save_current(false)
		(ui["status"] as Label).text = "已保存到 %s" % _selected_path
		_toast_show("已保存：%s" % _selected_path.get_file(), C_OK))
	vb.add_child(save)

	var status := _label("", 11, C_MUTED)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(0, 64)
	vb.add_child(status)
	ui["status"] = status

	var hint := _label(
		"武器动作：每一步各有一条偏移 → 键 `角色:步号`（如 nobita:1），\n"
		+ "　`*:步号` 可让所有角色共用；都没有才回退角色基线。\n"
		+ "子弹：黄点 = 角色原点 + 方向 × BulletData.spawn_offset + 武器级偏移。\n"
		+ "特效：橙十字 = 可配置偏移；不含 .tscn 内置 position_offset。\n"
		+ "拖动即写入当前层；Ctrl+S 保存到 .tres。",
		11, C_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(0, 100)
	vb.add_child(hint)

	var close := _button("关闭", false)
	close.position = Vector2(986, 796)
	close.size = Vector2(116, 32)
	close.pressed.connect(func():
		overlay.queue_free()
		_offset_overlay = null)
	panel.add_child(close)

	_offset_preview_refresh(wd, state, preview, ui, true)


# ═══════════════════════════════════════
# 攻击区域预览（近战矩形 / 推击矩形+溅射圈 / 子弹射程）
# ═══════════════════════════════════════
##
## 与「偏移预览」的分工：
##   · 偏移预览 = 点 / 武器图位置（bullet_spawn_offsets、melee_weapon_sprite_offsets…）
##   · 区域预览 = 判定范围本身（melee_range_size、shove_range_size、bullet_range…）
## 区域预览里的矩形**画成轴对齐**，因为运行时就是 `RectangleShape2D` + 零旋转。

func _region_mode_label(mode: String) -> String:
	match mode:
		"shove": return "推击区域"
		"bullet": return "子弹射程"
	return "近战区域"


## 这把武器需要预览哪些区域（按实际会用到判定框的状态给）。
func _region_modes(wd: WeaponData) -> Array[String]:
	var out: Array[String] = []
	if not wd.is_ranged:
		out.append("melee")
	## 射程 / 速度在 BulletData 上（weapon.bullet_list），没有子弹就没有射程可看
	if not wd.bullet_list.is_empty():
		out.append("bullet")
	## 推击任何武器都能用（空手也能推），所以始终可预览
	out.append("shove")
	return out


## 模式 → 字段名。没有的键表示该模式不涉及该项。
## 注意：bullet 模式**不在** WeaponData 上写任何字段（射程/速度属于 BulletData），
## 所以这里只返回空表，面板上对应行全部隐藏。
func _region_props(mode: String) -> Dictionary:
	match mode:
		"shove":
			return {
				"size": "shove_range_size",
				"forward": "shove_range_forward_offset",
				"splash": "shove_splash_radius",
			}
		"bullet":
			return {}
	return {"size": "melee_range_size", "forward": "melee_range_forward_offset"}


func _open_region_preview(focus_mode: String = "") -> void:
	if _region_overlay != null:
		return
	if not (_res is WeaponData):
		_toast_show("区域预览只支持武器资源", C_WARN)
		return
	var wd: WeaponData = _res
	var modes: Array[String] = _region_modes(wd)
	if modes.is_empty():
		_toast_show("这把武器没有可预览的攻击区域", C_WARN)
		return
	var players: Array[Dictionary] = _player_entries()
	var cid: String = "nobita"
	var has_nobita: bool = false
	for p: Dictionary in players:
		if str(p["id"]) == "nobita":
			has_nobita = true
	if not players.is_empty() and not has_nobita:
		cid = str(players[0]["id"])

	var mode: String = focus_mode if modes.has(focus_mode) else modes[0]
	var state: Dictionary = {"mode": mode, "char_id": cid, "direction": 0, "frame": 1,
		"bullet_index": 0}

	var vp: Vector2 = get_viewport_rect().size
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_region_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	panel.size = Vector2(1120, 840)
	panel.position = ((vp - panel.size) * 0.5).floor()
	overlay.add_child(panel)

	var title := _label("区域预览：%s" % wd.item_name, 16, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(700, 26)
	panel.add_child(title)

	var sub := _label("矩形 = 运行时真实判定范围（轴对齐）；拖动矩形改「前伸偏移」，数值在右侧或检查器改",
		11, C_MUTED)
	sub.position = Vector2(18, 40)
	sub.size = Vector2(760, 18)
	panel.add_child(sub)

	var preview: Control = null
	var ui: Dictionary = {"mode_buttons": {}}
	var mode_buttons: Dictionary = {}
	var group := ButtonGroup.new()
	for i: int in range(modes.size()):
		var m: String = modes[i]
		var b := _button(_region_mode_label(m), false)
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = (m == mode)
		b.position = Vector2(18 + i * 128, 66)
		b.size = Vector2(120, 30)
		b.pressed.connect(func():
			state["mode"] = m
			_region_preview_refresh(wd, state, preview, ui, true))
		panel.add_child(b)
		mode_buttons[m] = b
	ui["mode_buttons"] = mode_buttons

	preview = REGION_PREVIEW.new()
	preview.position = Vector2(18, 108)
	preview.size = Vector2(660, 700)
	preview.set("font", _font)
	panel.add_child(preview)
	preview.connect("forward_edited", func(m: String, v: float):
		state["mode"] = m
		_region_set_forward(m, v)
		_region_preview_refresh(wd, state, preview, ui))

	var vb := VBoxContainer.new()
	vb.position = Vector2(700, 108)
	vb.size = Vector2(400, 700)
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var char_opt := _offset_option(
		players.map(func(p: Dictionary): return ["%s (%s)" % [p["name"], p["id"]], p["id"]]),
		_index_of_player(players, cid))
	char_opt.item_selected.connect(func(i: int):
		state["char_id"] = str(char_opt.get_item_metadata(i))
		_region_preview_refresh(wd, state, preview, ui, true))
	vb.add_child(_offset_preview_row("角色", char_opt))

	var dir_opt := _offset_option([["下", 0], ["左", 1], ["右", 2], ["上", 3]], 0)
	dir_opt.item_selected.connect(func(i: int):
		state["direction"] = i
		_region_preview_refresh(wd, state, preview, ui, true))
	vb.add_child(_offset_preview_row("方向", dir_opt))

	## 判定宽（x，横向） / 高（y，纵深）—— 名称写清楚，避免和"前伸"混淆
	var w_spin := _offset_spin(0.0, 0.0, 512.0)
	var h_spin := _offset_spin(0.0, 0.0, 512.0)
	w_spin.value_changed.connect(func(v: float):
		_region_set_size(str(state["mode"]), v, h_spin.value)
		_region_preview_refresh(wd, state, preview, ui))
	h_spin.value_changed.connect(func(v: float):
		_region_set_size(str(state["mode"]), w_spin.value, v)
		_region_preview_refresh(wd, state, preview, ui))
	var w_row := _offset_preview_row("判定宽 x", w_spin)
	var h_row := _offset_preview_row("纵深高 y", h_spin)
	vb.add_child(w_row)
	vb.add_child(h_row)
	ui["w_row"] = w_row
	ui["h_row"] = h_row
	ui["w"] = w_spin
	ui["h"] = h_spin

	var f_spin := _offset_spin(0.0, 0.0, 512.0)
	f_spin.value_changed.connect(func(v: float):
		_region_set_forward(str(state["mode"]), v)
		_region_preview_refresh(wd, state, preview, ui))
	var f_row := _offset_preview_row("前伸偏移", f_spin)
	vb.add_child(f_row)
	ui["f_row"] = f_row
	ui["f"] = f_spin

	var s_spin := _offset_spin(0.0, 0.0, 512.0)
	s_spin.value_changed.connect(func(v: float):
		_set_prop("shove_splash_radius", v)
		_region_preview_refresh(wd, state, preview, ui))
	var s_row := _offset_preview_row("溅射半径", s_spin)
	vb.add_child(s_row)
	ui["s_row"] = s_row
	ui["s"] = s_spin

	var bullets: Array = []
	for i: int in range(wd.bullet_list.size()):
		var bd: BulletData = wd.bullet_list[i]
		var nm: String = bd.resource_path.get_file() if not bd.resource_path.is_empty() else "子弹%d" % (i + 1)
		bullets.append(["%s（%dpx）" % [nm, roundi(bd.max_range)], i])
	var bullet_opt := _offset_option(bullets, 0)
	bullet_opt.item_selected.connect(func(i: int):
		state["bullet_index"] = i
		_region_preview_refresh(wd, state, preview, ui))
	var bullet_row := _offset_preview_row("子弹", bullet_opt)
	vb.add_child(bullet_row)
	ui["bullet_row"] = bullet_row

	var save := _button("保存到 .tres", true)
	save.pressed.connect(func():
		_save_current(false)
		(ui["status"] as Label).text = "已保存到 %s" % _selected_path
		_toast_show("已保存：%s" % _selected_path.get_file(), C_OK))
	vb.add_child(save)

	var status := _label("", 11, C_MUTED)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(0, 80)
	vb.add_child(status)
	ui["status"] = status

	var hint := _label(
		"近战 / 推击：矩形中心 = 角色原点 + 朝向 × 前伸偏移，\n"
		+ "　尺寸是轴对齐宽×高（不随朝向旋转，与运行时代码一致）。\n"
		+ "推击：外圈 = 溅射半径（只卷击退，不造成伤害）。\n"
		+ "子弹：虚线长度 = BulletData.max_range；起点 = spawn_offset。\n"
		+ "　射程/速度在子弹资源里改（本窗口只读，避免误改共用子弹）。\n"
		+ "拖动矩形写回前伸偏移；修改后 Ctrl+S 保存。",
		11, C_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(0, 140)
	vb.add_child(hint)

	var close := _button("关闭", false)
	close.position = Vector2(986, 796)
	close.size = Vector2(116, 32)
	close.pressed.connect(func():
		overlay.queue_free()
		_region_overlay = null)
	panel.add_child(close)

	_region_preview_refresh(wd, state, preview, ui, true)


func _region_set_size(mode: String, w: float, h: float) -> void:
	var prop: String = str(_region_props(mode).get("size", ""))
	if prop.is_empty():
		return
	_set_prop(prop, Vector2(roundf(w), roundf(h)))


func _region_set_forward(mode: String, value: float) -> void:
	var prop: String = str(_region_props(mode).get("forward", ""))
	if prop.is_empty():
		return
	_set_prop(prop, roundf(value))


func _region_preview_refresh(wd: WeaponData, state: Dictionary, preview: Control,
		ui: Dictionary, reset_drag: bool = false) -> void:
	var mode: String = str(state.get("mode", "melee"))
	var direction: int = clampi(int(state.get("direction", 0)), 0, 3)
	var frame: int = clampi(int(state.get("frame", 1)), 0, 2)
	var bullet_index: int = maxi(0, int(state.get("bullet_index", 0)))
	var cid: String = str(state.get("char_id", ""))
	var cd: CharacterData = _character_by_id(cid)
	preview.call("set_preview", wd, cd, mode, direction, frame, bullet_index)
	if reset_drag:
		preview.call("cancel_drag")

	var props: Dictionary = _region_props(mode)
	var has_size: bool = props.has("size")
	var has_forward: bool = props.has("forward")
	## 每行是否可见（按模式）
	for key: String in ["w_row", "h_row"]:
		if ui.has(key):
			(ui[key] as Control).visible = has_size
	if ui.has("f_row"):
		(ui["f_row"] as Control).visible = has_forward
	if ui.has("s_row"):
		(ui["s_row"] as Control).visible = mode == "shove"
	if ui.has("bullet_row"):
		(ui["bullet_row"] as Control).visible = mode == "bullet"

	## 数值回填（no_signal，避免刷新又触发写入）
	if has_size and ui.has("w") and ui.has("h"):
		var sz: Vector2 = wd.get(str(props["size"])) as Vector2
		(ui["w"] as SpinBox).set_value_no_signal(sz.x)
		(ui["h"] as SpinBox).set_value_no_signal(sz.y)
	if has_forward and ui.has("f"):
		(ui["f"] as SpinBox).set_value_no_signal(float(wd.get(str(props["forward"]))))
	if mode == "shove" and ui.has("s"):
		(ui["s"] as SpinBox).set_value_no_signal(wd.shove_splash_radius)

	for m: String in (ui.get("mode_buttons", {}) as Dictionary).keys():
		(ui["mode_buttons"][m] as Button).button_pressed = (m == mode)

	if ui.has("status"):
		var lines: Array[String] = []
		lines.append("方向：%s" % ["下", "左", "右", "上"][direction])
		if has_size:
			var sz2: Vector2 = wd.get(str(props["size"])) as Vector2
			var fwd: float = float(wd.get(str(props["forward"])))
			lines.append("判定 %d×%d · 前伸 %d" % [roundi(sz2.x), roundi(sz2.y), roundi(fwd)])
			## 最实用的读数：以角色原点为 0，最远打到前方多少、最近从身后多少开始
			lines.append("覆盖范围：前方 %d px ～ 身后 %d px（相对原点）" % [
				roundi(fwd + sz2.y * 0.5), roundi(maxf(0.0, sz2.y * 0.5 - fwd))])
			if mode == "shove":
				lines.append("溅射半径 %d px（击退衰减：中心 100%% → 边缘 50%%）"
					% roundi(wd.shove_splash_radius))
		elif mode == "bullet":
			var bd: BulletData = null
			if not wd.bullet_list.is_empty():
				bd = wd.bullet_list[clampi(bullet_index, 0, wd.bullet_list.size() - 1)]
			if bd == null:
				lines.append("⚠ 没有子弹资源：运行时不会发射")
			else:
				var bname: String = bd.resource_path.get_file() if not bd.resource_path.is_empty() else "（内嵌）"
				lines.append("射程 %d px · 速度 %d px/s · 起点偏移 %d px" % [
					roundi(bd.max_range), roundi(bd.speed), roundi(bd.spawn_offset)])
				lines.append("子弹资源：%s" % bname)
				lines.append("改射程/速度：打开该子弹 .tres（本窗口只读）")
		if _dirty:
			lines.append("● 未保存（Ctrl+S）")
		(ui["status"] as Label).text = "\n".join(lines)


func _index_of_player(players: Array[Dictionary], cid: String) -> int:
	for i: int in range(players.size()):
		if str(players[i]["id"]) == cid:
			return i
	return 0


# ═══════════════════════════════════════
# 工具
# ═══════════════════════════════════════

func _toast_show(text: String, color: Color) -> void:
	_toast.text = text
	_toast.add_theme_color_override("font_color", color)
	_toast.visible = true
	_toast.modulate.a = 1.0
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.6)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.4)
	_toast_tween.tween_callback(func(): _toast.visible = false)


func _clear(parent: Node) -> void:
	for c: Node in parent.get_children():
		parent.remove_child(c)
		c.queue_free()


func _type_name(t: int) -> String:
	match t:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_COLOR: return "Color"
		TYPE_OBJECT: return "Resource"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
	return str(t)


func _checker_texture() -> Texture2D:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color("#2a2a2c"))
	for y: int in range(0, 32, 8):
		for x: int in range(0, 32, 8):
			if ((x / 8) + (y / 8)) % 2 == 0:
				img.fill_rect(Rect2i(x, y, 8, 8), Color("#343437"))
	return ImageTexture.create_from_image(img)


func _panel_sb(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	return sb


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", 13)
	if primary:
		b.add_theme_stylebox_override("normal", _panel_sb(Color("#0e639c"), Color("#1177bb"), 3))
		b.add_theme_stylebox_override("hover", _panel_sb(Color("#1177bb"), Color("#1a8ad4"), 3))
		b.add_theme_stylebox_override("pressed", _panel_sb(Color("#0a4d78"), Color("#1177bb"), 3))
		b.add_theme_stylebox_override("disabled", _panel_sb(Color("#2a2a2c"), Color("#3a3a3a"), 3))
		b.add_theme_color_override("font_color", Color("#ffffff"))
		b.add_theme_color_override("font_disabled_color", Color("#777777"))
	else:
		b.add_theme_stylebox_override("normal", _panel_sb(Color("#333333"), Color("#454545"), 3))
		b.add_theme_stylebox_override("hover", _panel_sb(Color("#3d3d3d"), Color("#505050"), 3))
		b.add_theme_stylebox_override("pressed", _panel_sb(Color("#2a2a2a"), Color("#454545"), 3))
	return b
