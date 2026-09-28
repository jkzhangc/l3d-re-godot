extends CanvasLayer

## ── 架构定位 ──
## 系统：安全屋台词 ｜ 层：表现（CanvasLayer）
## 联机：**纯本地表现，零 RPC** —— 各端自己开自己的窗口、显示**自己角色**的台词。
##       原作的口径就是这样"各说各的"；同步反而会让四个人的台词互相覆盖。
## 职责：RM2K3 风格的台词窗口（窗口皮 + 头像 + 名字 + 台词 + ▼ 继续标记）。
##       按「确定键」翻到下一段；最后一段再按即关闭。
## 依赖：Global.apply_ui_font（字体唯一入口）、CharacterData.portrait_texture()（按索引裁好的头像）
##
## 【不暂停】用户定稿：台词**不暂停游戏**，玩家可以无视它继续打（联机时也不会阻塞别人）。
## 因此本层所有节点 mouse_filter = IGNORE，绝不拦截游戏输入。

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
	_render_page()


func close() -> void:
	if not _opened:
		return
	_opened = false
	_window.visible = false
	_last_closed_msec = Time.get_ticks_msec()
	dialogue_closed.emit()


func is_open() -> bool:
	return _opened


## 显示**某角色的专有台词**。
## ★原作把「谁说什么」写死在事件文本里（说话人行 = `\>\C[4]名字\C[0]\<`），**不随机抽**，
##   所以这里按顺序显示该角色的句子；超过 max_pages 的截断（窗口一次只显示一句，按确定键翻页）。
func open_character(lines: Array, speaker_name: String, portrait: Texture2D = null) -> void:
	open(lines, speaker_name, portrait)


func _render_page() -> void:
	if _page_index < 0 or _page_index >= _pages.size():
		return
	_line.text = _pages[_page_index]
	## 还有下一段才显示 ▼（最后一段不显示，提示"按下去就关掉了"）。
	_mark.visible = _page_index < _pages.size() - 1


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
