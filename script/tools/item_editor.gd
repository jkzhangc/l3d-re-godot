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
##   字典行「编辑…」→ JSON 编辑器（支持 int 键与 Vector2 值）
##
## ★本文件是开发工具，使用系统 UI 字体（14/16/20），不受游戏内像素字体 12 倍数规则约束。

const BROWSER := preload("res://script/tools/asset_browser.gd")

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

	_preview_info = _label("", 12, C_MUTED)
	_preview_info.position = Vector2(14, 392)
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
		btn.tooltip_text = "字典里含资源/颜色等无法用 JSON 表示的值，请在 Godot 检查器编辑"
	btn.pressed.connect(func(): _open_json_dialog(prop, dict))
	box.add_child(btn)
	return box


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
			if _json_overlay != null:
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
