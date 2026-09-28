extends CanvasLayer

## ── 架构定位 ──
## 系统：安全屋台词 ｜ 层：表现（CanvasLayer）
## 联机：**纯本地表现，零 RPC** —— 各端自己开自己的窗口、显示**自己角色**的台词。
##       原作的口径就是这样"各说各的"；同步反而会让四个人的台词互相覆盖。
## 职责：RM2K3 风格的台词窗口（窗口皮 + 头像 + 名字 + 台词 + ▼ 继续标记）。
##       按「确定键」翻到下一段；最后一段再按即关闭。
## 依赖：Global.apply_ui_font（字体唯一入口）、CharacterData.portrait_texture()（按索引裁好的头像）、
##       Global.lock_movement/unlock_movement（台词期间锁本地移动）
##
## 【不暂停游戏，但锁本地移动】（用户定稿）：
##   - 不暂停 SceneTree → 联机时**不会阻塞别人**，敌人与队友照常跑；
##   - 但**本地玩家自己不能走动**（`Global.movement_locked`，只锁移动轴，攻击/开火仍可用）。
## 本层所有节点 mouse_filter = IGNORE，绝不拦截鼠标。

signal dialogue_closed

@export_group("行为")
## 台词最多显示几段（原作每名角色 1~3 句，窗口一次显示一句、按确定键翻页）。
@export var max_pages: int = 3
## 台词出现的最小间隔（秒）——防止反复进出安全屋时刷屏。
@export var cooldown_seconds: float = 3.0

@onready var _window: Control = $Root/Window
@onready var _portrait_box: Control = $Root/Window/Content/PortraitBox
@onready var _portrait: TextureRect = $Root/Window/Content/PortraitBox/Portrait
@onready var _speaker: Label = $Root/Window/Content/TextBox/SpeakerLabel
@onready var _line: Label = $Root/Window/Content/TextBox/LineLabel
@onready var _mark: Label = $Root/Window/ContinueMark

var _pages: Array[String] = []
var _page_index: int = 0
var _opened: bool = false
var _last_closed_msec: int = -100000


func _ready() -> void:
	set_process_unhandled_input(true)
	_window.visible = false
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", _speaker, 24)
		g.call("apply_ui_font", _line, 24)
		g.call("apply_ui_font", _mark, 24)
	_speaker.add_theme_color_override("font_color", Color("e8c44b"))
	_line.add_theme_color_override("font_color", Color("e7e4d7"))
	_mark.add_theme_color_override("font_color", Color("e7e4d7"))
	_mark.text = "▼"


## 打开台词窗口。pages 为待显示的段落（已按上限裁剪）；speaker 为显示名；
## portrait 为空时自动隐藏头像框（等美术素材到位后再接）。
func open(pages: Array, speaker_name: String, portrait: Texture2D = null) -> void:
	if pages.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_closed_msec < int(cooldown_seconds * 1000.0):
		return
	_pages.clear()
	for p: Variant in pages:
		var s: String = str(p).strip_edges()
		if not s.is_empty():
			_pages.append(s)
	if _pages.is_empty():
		return
	if max_pages > 0 and _pages.size() > max_pages:
		_pages = _pages.slice(0, max_pages)
	_page_index = 0
	_speaker.text = speaker_name
	_portrait.texture = portrait
	_portrait_box.visible = portrait != null
	_opened = true
	_window.visible = true
	_lock_movement()
	_render_page()


func close() -> void:
	if not _opened:
		return
	_opened = false
	_window.visible = false
	_unlock_movement()
	_last_closed_msec = Time.get_ticks_msec()
	dialogue_closed.emit()


## ★保险：窗口被直接释放（换场景 / 父节点销毁）时也要解锁，
## 否则 movement_locked 一直为 true → 玩家再也走不动。
func _exit_tree() -> void:
	if _opened:
		_unlock_movement()


func _lock_movement() -> void:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("lock_movement"):
		g.call("lock_movement")


func _unlock_movement() -> void:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("unlock_movement"):
		g.call("unlock_movement")


func is_open() -> bool:
	return _opened


## 显示**某角色的专有台词**。
## ★原作把「谁说什么」写死在事件文本里（说话人行 = `\>\C[4]名字\C[0]\<`），**不随机抽**。
##
## `pages` 是**页数组**（外层一页、内层该页的多行）：
##   - **同一页的多行同屏显示**（原作对话框一次显示说话人 + 数行正文）；
##   - 按确定键翻到下一页 —— 原作里 A 批（刚进安全屋）与 B 批（接着说）就是连续两页。
## 也兼容直接传扁平的 `Array[String]`（每个元素各自成一页）。
func open_character(pages: Array, speaker_name: String, portrait: Texture2D = null) -> void:
	var flat: Array = []
	for page: Variant in pages:
		if page is Array:
			var lines: Array = []
			for ln: Variant in (page as Array):
				var s: String = str(ln).strip_edges()
				if not s.is_empty():
					lines.append(s)
			if not lines.is_empty():
				flat.append("\n".join(lines))
			continue
		var one: String = str(page).strip_edges()
		if not one.is_empty():
			flat.append(one)
	open(flat, speaker_name, portrait)


func _render_page() -> void:
	if _page_index < 0 or _page_index >= _pages.size():
		return
	_line.text = _pages[_page_index]
	## ★每段都显示 ▼（用户 09-28：翻到第二句箭头就没了 —— 原著窗口里 ▼ 一直都在，
	## 它表示"按确定键继续"，而不是"后面还有一句"）。
	_mark.visible = true


func _advance() -> void:
	_page_index += 1
	if _page_index >= _pages.size():
		close()
		return
	_render_page()


func _unhandled_input(event: InputEvent) -> void:
	if not _opened:
		return
	if event.is_action_pressed("确定键"):
		get_viewport().set_input_as_handled()
		_advance()
	elif event.is_action_pressed("取消键"):
		get_viewport().set_input_as_handled()
		close()
