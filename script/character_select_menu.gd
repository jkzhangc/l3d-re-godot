extends Control

## ── 架构定位 ──
## 系统：角色选择 ｜ 层：表现（Control）
## 联机：Host 统一确认与开局
## 职责：正式角色选择界面：下滚全景背景、头像图标网格、踏步预览与底部信息窗。
## 依赖：CharacterCatalog、CharacterData、campaign/difficulty 路由

## 角色选择界面 — 下滚全景背景 + 头像图标网格 + 底部信息窗
##
## 头像来自行走图格式的图标表（参考武器掉落物行走图设定）：
## 每格 48x64，每 3 格一组是同一个角色的踏步三帧；「朝向行」即纵向第几行，
## 这张表不同朝向行/不同索引指向不同角色。
## 选中框直接取图标表自带的白色方框（第3~5列/第4~7行，框体恰好套住脸部）。
## 被选中的头像播放踏步帧序列（frame1 → frame0 → frame1 → frame2），白框呼吸闪烁。

const FRAME_W: int = 48                ## 图标行走图单帧宽
const FRAME_H: int = 64                ## 图标行走图单帧高
const FRAMES_PER_CHAR: int = 3         ## 每个角色的踏步帧数（横向3格一组）

## 选中框素材在图标表中的格子坐标（白色方框，与脸部格子同尺寸可 1:1 叠加）
const SELECT_FRAME_COL: int = 3
const SELECT_FRAME_ROW: int = 4

@export_group("场景路由")
@export var campaign_select_scene: String = "res://scene/campaign_select.tscn"
@export var difficulty_select_scene: String = "res://scene/difficulty_select.tscn"
@export var max_team_size: int = 3  ## 2026-09-14 用户定稿：单人队伍最多 3 人

@export_group("界面音效")
## 留空 = 用 Global 的 ui_*_sfx_path（全局窗口音效参数）
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cursor_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_confirm_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cancel_path: String = ""

@export_group("资源路径")
@export var bg_texture_path: String = "res://art/Panorama/地下.png"
@export var icon_sheet_path: String = "res://art/misc/キャラ選択アイコン.png"
## 说明：页面文字/信息窗已节点化（scene/character_select.tscn），字号/字体/位置
## 直接在编辑器 Inspector 改；此处只剩动态内容的参数。

@export_group("背景滚动")
@export var bg_scale: float = 2.0              ## 背景放大倍数（2倍以上）
@export var bg_scroll_speed: float = 20.0      ## 滚动速度（素材像素/秒，向下）

@export_group("图标网格")
@export var icon_scale: float = 2.0            ## 图标显示倍率
@export var grid_columns: int = 4              ## 网格列数
@export var grid_gap: Vector2 = Vector2(16, 20) ## 图标间距
@export var grid_area_top: float = 130.0       ## 网格可用区域上界
@export var grid_area_bottom: float = 576.0    ## 网格可用区域下界（底部信息窗之上；2026-09-14 信息窗加高后上收）
@export var step_frames: Array[int] = [1, 0, 1, 2]  ## 踏步帧序列（与玩家/武器掉落物一致）
@export var step_duration: float = 0.25        ## 每帧持续时间（秒）
@export var frame_blink_interval: float = 0.3  ## 选中框闪烁间隔（秒）
@export var frame_blink_dim: float = 0.4       ## 选中框闪烁时的最低透明度

## 2026-09-15 用户定稿：删除介绍窗右侧的队伍槽位显示——头像网格的黄染色+白框
## 已表达入队状态，槽位与武器/SA 长文本抢空间（单行不换行会顶进去）。
## _build_team_slots/_refresh_team_slots 与 team_slot_* 导出一并移除。

var _available_characters: Array[CharacterData] = []
var _team_selection: Array[int] = []
var _cursor_idx: int = 0

## 图标节点（与 _available_characters 同序）
var _icon_rects: Array[TextureRect] = []
var _icon_atlas: Array[AtlasTexture] = []
var _frame_rects: Array[TextureRect] = []

var _step_timer: float = 0.0
var _step_idx: int = 0
var _blink_timer: float = 0.0
var _blink_on: bool = true

var _bg_sprite: Sprite2D = null
var _bg_region_size: Vector2 = Vector2.ZERO
var _bg_offset: float = 0.0

## 信息窗文字（节点化：scene/character_select.tscn / InfoWindow）
@onready var _info_labels: Array[GradientLabel] = [
	$InfoWindow/NameLabel, $InfoWindow/StatLabel, $InfoWindow/WeaponLabel,
	$InfoWindow/MukiriLabel, $InfoWindow/SkillLabel, $InfoWindow/AwakenLabel,
]
@onready var _info_window: Control = $InfoWindow


func _ready() -> void:
	_load_characters()
	_build_background()
	_build_icon_grid()
	_refresh_all()


func _load_characters() -> void:
	_available_characters = CharacterCatalog.load_available_characters()
	for character: CharacterData in _available_characters:
		print("[角色选择] 已加载角色: %s (%s)" % [character.character_name, character.resource_path])
	if _available_characters.is_empty():
		push_error("[角色选择] 没有可用 CharacterData；请检查 CharacterCatalog 的正式角色资源")
	print("[角色选择] 可选角色数量: %d" % _available_characters.size())


# ═══════════════════════════════════════
# 界面构建
# ═══════════════════════════════════════
func _build_background() -> void:
	var tex: Texture2D = load(bg_texture_path) as Texture2D
	if not tex:
		push_error("[角色选择] 背景素材加载失败: %s" % bg_texture_path)
		var fallback := ColorRect.new()
		fallback.color = Color(0.02, 0.02, 0.08, 1.0)
		fallback.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(fallback)
		return

	var view := get_viewport_rect().size
	_bg_region_size = (view / bg_scale).ceil()
	_bg_sprite = Sprite2D.new()
	_bg_sprite.name = "ScrollingBackground"
	_bg_sprite.texture = tex
	_bg_sprite.centered = false
	_bg_sprite.scale = Vector2(bg_scale, bg_scale)
	_bg_sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_bg_sprite.region_enabled = true
	_bg_sprite.region_rect = Rect2(Vector2.ZERO, _bg_region_size)
	add_child(_bg_sprite)

	# 轻微压暗，保证图标和文字可读
	var dim := ColorRect.new()
	dim.name = "DimOverlay"
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	# 2026-09-14：UI 节点化后 tscn 子节点排在前，add_child 追加的背景会盖住它们
	# —— 垫底到索引 0/1（同 campaign/difficulty 的 move_child(backdrop, 0) 惯例）
	move_child(_bg_sprite, 0)
	move_child(dim, 1)


func _get_icon_sheet_for(cd: CharacterData) -> Texture2D:
	if cd.select_icon_sheet:
		return cd.select_icon_sheet
	return load(icon_sheet_path) as Texture2D


func _make_select_frame_texture(sheet: Texture2D) -> AtlasTexture:
	## 图标表自带的白色选中框（整格 48x64 裁切，与头像格 1:1 对齐）
	var at := AtlasTexture.new()
	at.atlas = sheet
	at.filter_clip = true
	at.region = Rect2(SELECT_FRAME_COL * FRAME_W, SELECT_FRAME_ROW * FRAME_H, FRAME_W, FRAME_H)
	return at


func _build_icon_grid() -> void:
	var cell := Vector2(FRAME_W, FRAME_H) * icon_scale
	var pitch := cell + grid_gap
	var rows: int = ceili(float(_available_characters.size()) / grid_columns)
	var area_h: float = grid_area_bottom - grid_area_top
	var y0: float = grid_area_top + maxf(0.0, (area_h - rows * pitch.y + grid_gap.y) * 0.5)

	for i: int in range(_available_characters.size()):
		var cd: CharacterData = _available_characters[i]
		var row: int = i / grid_columns
		var col: int = i % grid_columns
		var row_count: int = mini(grid_columns, _available_characters.size() - row * grid_columns)
		# 每行独立水平居中
		var row_w: float = row_count * pitch.x - grid_gap.x
		var x0: float = (get_viewport_rect().size.x - row_w) * 0.5
		var pos := Vector2(x0 + col * pitch.x, y0 + row * pitch.y)

		var sheet: Texture2D = _get_icon_sheet_for(cd)
		var at := AtlasTexture.new()
		at.atlas = sheet
		at.filter_clip = true
		at.region = _icon_region(cd, 0)

		var rect := TextureRect.new()
		rect.name = "Icon_%s" % cd.character_name
		rect.texture = at
		rect.stretch_mode = TextureRect.STRETCH_KEEP
		rect.scale = Vector2(icon_scale, icon_scale)
		rect.position = pos
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_icon_atlas.append(at)
		_icon_rects.append(rect)

		# 白色选中框叠加在头像上方（同位置同缩放）
		var frame_rect := TextureRect.new()
		frame_rect.name = "SelectFrame_%d" % i
		frame_rect.texture = _make_select_frame_texture(sheet)
		frame_rect.stretch_mode = TextureRect.STRETCH_KEEP
		frame_rect.scale = Vector2(icon_scale, icon_scale)
		frame_rect.position = pos
		frame_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(frame_rect)
		_frame_rects.append(frame_rect)


func _icon_region(cd: CharacterData, frame: int) -> Rect2:
	## 行走图寻址（同武器掉落物）：横向 = 索引组*3帧 + 踏步帧，纵向 = 朝向行*64
	var x: int = cd.select_icon_index * (FRAME_W * FRAMES_PER_CHAR) + clampi(frame, 0, FRAMES_PER_CHAR - 1) * FRAME_W
	var y: int = cd.select_icon_direction * FRAME_H
	return Rect2(x, y, FRAME_W, FRAME_H)


# ═══════════════════════════════════════
# 每帧更新：背景滚动 / 踏步动画 / 选中框闪烁
# ═══════════════════════════════════════
func _process(delta: float) -> void:
	_process_background(delta)
	_process_step_animation(delta)
	_process_frame_blink(delta)


func _process_background(delta: float) -> void:
	if not _bg_sprite:
		return
	# region 原点上移 = 画面内容向下滚动；取模避免浮点漂移，纹理重复保证无缝衔接
	_bg_offset = fmod(_bg_offset + bg_scroll_speed * delta, 240.0)
	_bg_sprite.region_rect = Rect2(Vector2(0.0, -_bg_offset), _bg_region_size)


func _process_step_animation(delta: float) -> void:
	if _icon_atlas.is_empty() or step_frames.is_empty():
		return
	_step_timer += delta
	if _step_timer < step_duration:
		return
	_step_timer -= step_duration
	_step_idx = (_step_idx + 1) % step_frames.size()
	# 只有被选中的头像播放踏步动画，其余停在站立帧
	for i: int in range(_icon_atlas.size()):
		var cd: CharacterData = _available_characters[i]
		var frame: int = step_frames[_step_idx] if i == _cursor_idx else 0
		_icon_atlas[i].region = _icon_region(cd, frame)


func _process_frame_blink(delta: float) -> void:
	## 被选中头像的白框周期性变暗再亮起（呼吸闪烁），其余白框常亮
	if _frame_rects.is_empty():
		return
	_blink_timer += delta
	if _blink_timer < frame_blink_interval:
		return
	_blink_timer = 0.0
	_blink_on = not _blink_on
	for i: int in range(_frame_rects.size()):
		var alpha: float = frame_blink_dim if (i == _cursor_idx and not _blink_on) else 1.0
		_frame_rects[i].modulate = Color(1, 1, 1, alpha)


# ═══════════════════════════════════════
# 输入
# ═══════════════════════════════════════
func _input(event: InputEvent) -> void:
	if _available_characters.is_empty():
		return
	if event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		if _team_selection.is_empty():
			_go_back()
		else:
			_team_selection.pop_back()
			_refresh_all()
		return
	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		_toggle_character()
		return
	if event.is_action_pressed("开始游戏键"):
		if _team_selection.size() > 0:
			Global.play_ui_sfx("confirm", sfx_confirm_path)
			_confirm_team()
		return
	var item_count: int = _available_characters.size()
	var cols: int = maxi(1, grid_columns)
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - cols + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + cols) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()
	elif event.is_action_pressed("左"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()
	elif event.is_action_pressed("右"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()


func _toggle_character() -> void:
	var idx: int = _team_selection.find(_cursor_idx)
	if idx != -1:
		_team_selection.remove_at(idx)
	else:
		if _team_selection.size() >= max_team_size:
			return
		_team_selection.append(_cursor_idx)
	_refresh_all()


# ═══════════════════════════════════════
# 刷新显示
# ═══════════════════════════════════════
func _refresh_all() -> void:
	# 光标移动后旧图标回到站立帧，重新开始新选中者的踏步动画
	_step_idx = 0
	_step_timer = 0.0
	for i: int in range(_icon_atlas.size()):
		var cd: CharacterData = _available_characters[i]
		var frame: int = step_frames[0] if (i == _cursor_idx and step_frames.size() > 0) else 0
		_icon_atlas[i].region = _icon_region(cd, frame)
	_refresh_info()
	for i: int in range(_icon_rects.size()):
		_icon_rects[i].modulate = Color(1.0, 0.9, 0.2, 1) if _team_selection.has(i) else Color.WHITE


func _refresh_info() -> void:
	if _info_labels.size() < 6 or _available_characters.is_empty():
		return
	var cd: CharacterData = _available_characters[_cursor_idx]
	_info_labels[0].text = "「%s」" % cd.character_name
	_info_labels[1].text = "Lv.%d　HP %d　ATK %d" % [cd.level, cd.get_effective_max_hp(), cd.get_effective_attack()]
	_info_labels[2].text = _get_weapon_compat_text(cd)
	_info_labels[3].text = "见切: 攻击后 0.3 秒内被击中=无伤，并自动发动角色专属反击"
	_info_labels[4].text = _get_skills_text(cd)
	_info_labels[5].text = _get_awaken_text(cd)


## 武器 ID → 中文名映射（与 object/weapon_*.tres 的 item_name 一致）
const WEAPON_ID_ZH: Dictionary = {
	"pistol_01": "手枪",
	"rifle_01": "步枪",
	"shotgun_01": "霰弹枪",
	"smg_01": "冲锋枪",
	"sniper_01": "狙击枪",
	"magnum_01": "马格南",
	"launcher_01": "榴弹发射器",
	"rocket_01": "火箭筒（RPG-7）",
	"knife_01": "小刀",
}


func _weapon_zh(id: String) -> String:
	return WEAPON_ID_ZH.get(id, id)


func _get_weapon_compat_text(cd: CharacterData) -> String:
	if cd.allowed_primary_weapons.is_empty() and cd.allowed_secondary_weapons.is_empty():
		return "武器: 全部可用"
	var parts: Array[String] = []
	if not cd.allowed_primary_weapons.is_empty():
		var names: Array[String] = []
		for id: String in cd.allowed_primary_weapons:
			names.append(_weapon_zh(id))
		parts.append("主: %s" % "、".join(names))
	if not cd.allowed_secondary_weapons.is_empty():
		var names: Array[String] = []
		for id: String in cd.allowed_secondary_weapons:
			names.append(_weapon_zh(id))
		parts.append("副: %s" % "、".join(names))
	if parts.is_empty():
		return "武器: 全部可用"
	return "武器: %s" % ", ".join(parts)


## 技能行：取角色 SA 技能（跳过测试占位），格式 = 「名」描述
func _get_skills_text(cd: CharacterData) -> String:
	var parts: Array[String] = []
	for skill: Resource in cd.skills:
		if skill == null:
			continue
		var sname: String = str(skill.get("skill_name"))
		if sname.is_empty() or sname.contains("测试"):
			continue
		var desc: String = str(skill.get("description"))
		## 2026-09-15 用户要求：SA 介绍显示完整（信息窗内容区约 1100px，24px 字约容纳
		## 45 字，当前各角色 SA 描述长度内不溢出；GradientLabel 不换行，超长会超窗）
		parts.append(sname if desc.is_empty() else "%s: %s" % [sname, desc])
	if parts.is_empty():
		return "SA 技能: ——"
	return "SA 技能: %s" % "；".join(parts)


## 觉醒行（角色专属；当前仅のび太=集中射撃）
func _get_awaken_text(cd: CharacterData) -> String:
	match String(cd.get("awaken_type")):
		"concentrated_fire":
			return "觉醒: 集中射撃——空格发动，威力×1.5、子弹即死（Boss 免疫）"
		_:
			return "觉醒: ——"


# ═══════════════════════════════════════
# 场景流转（与原逻辑一致）
# ═══════════════════════════════════════
func _confirm_team() -> void:
	Players.clear_seats()
	# 新队伍 = 新一局：清掉上一局残留的 checkpoint，
	# 否则死亡重载会回到上一局的安全屋/队伍（2026-09-13 回归）
	Global.checkpoint.clear()
	for idx: int in _team_selection:
		var cd: CharacterData = _available_characters[idx]
		# duplicate() 让每个座位独占一份 CharacterData 实例，
		# 否则同角色的多个座位会共享运行时字段、并污染资源缓存里的 .tres 母本
		var cd_copy: CharacterData = cd.duplicate()
		cd_copy.init_runtime_hp()
		cd_copy.init_runtime_tp()
		var st: PlayerState = PlayerState.new()
		st.init_from_character(cd_copy, cd.resource_path)
		Players.add_seat(st)
	Players.seats_authored = true
	Players.active_seat_index = 0
	print("[角色选择] 确认队伍: %d人" % Players.seat_count())
	var err: Error = get_tree().change_scene_to_file(difficulty_select_scene)
	if err != OK:
		printerr("[角色选择] 场景切换失败: %s" % difficulty_select_scene)


func _go_back() -> void:
	get_tree().change_scene_to_file(campaign_select_scene)
