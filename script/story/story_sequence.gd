@tool
extends Node2D

## ── 架构定位 ──
## 系统：自定义剧情 ｜ 层：玩法（Node2D，地图上的可交互剧情点）
## 联机：Host 权威（剧情/开关只在本机推进；联机的场景与开关同步由 NetworkWorld 负责）
## 职责：地图上一个「带行走图 + 踏步/朝向动画」的剧情点。玩家触发后播放一段
##       按角色分支的对话（复用安全屋台词窗口），结束后播音效、设/清任务开关、
##       显形指定节点，并可切换自己的行走图（路灯式「开/关」两态）。
## 依赖：VXWalkSheet（取帧）、safehouse_dialogue.tscn（台词窗口）、StoryScriptData（台词表）、Global
## 被调用：地图场景（摆节点 + 配参数），以及将来的剧情演出
##
## 【为什么复用安全屋台词窗口】
## 用户要求「跟安全屋初始台词一样的表现形式」。`scene/ui/safehouse_dialogue.tscn`
## 的 `open_mixed_pages(entries)` 已经支持「多页 + 每页换说话人 + 可选头像」，
## entries 结构 = `[{speaker, lines, portrait}]`。再写一套窗口只会分叉。
##
## 【台词从哪来】
## ① `story_key` → `script/story/story_script_data.gd` 里按「固定 NPC 页 + 角色分支 + 收尾」拼；
## ② `inline_pages` 非空时直接用它（不查表），方便临时/一次性演出。
## 角色分支按 **日文原名**（`CharacterData.character_name`）匹配。

const WALK := preload("res://script/vx_walk_sheet.gd")
const DIALOGUE_SCENE := preload("res://scene/ui/safehouse_dialogue.tscn")
const STORY_DATA := preload("res://script/story/story_script_data.gd")

enum TriggerMode {
	CLICK,   ## 走到范围内按「确定键」
	TOUCH,   ## 玩家走进范围立即触发
}


# ═══════════════════════════════════════
# 剧情
# ═══════════════════════════════════════
@export_group("剧情")
## 台词表 key（见 story_script_data.gd）。留空则必须填 inline_pages。
@export var story_key: String = ""
## 满足 `alternate_flag` 时改用这个 key（例：看过初次见面后换成委托对话）。
@export var alternate_story_key: String = ""
@export var alternate_flag: String = ""
## 内联页面：`[{speaker: "名字", lines: ["第一句","第二句"]}]`。非空时不查表。
@export var inline_pages: Array[Dictionary] = []
## 只播一次（用 quest flag 记，读过就不再触发）。
@export var once_only: bool = false
## 记录「已看过」用的 flag；留空时用 `story_seen:<story_key>`。
@export var seen_flag: String = ""

# ═══════════════════════════════════════
# 外观
# ═══════════════════════════════════════
@export_group("外观（行走图）")
@export var walk_texture: Texture2D:
	set(v):
		walk_texture = v
		_refresh_sprite()
@export_range(0, 7, 1) var char_index: int = 0:
	set(v):
		char_index = v
		_refresh_sprite()
@export_range(0, 3, 1) var direction: int = 0:
	set(v):
		direction = v
		_refresh_sprite()
@export var sprite_offset: Vector2 = Vector2.ZERO

@export_group("踏步动画")
@export var step_frames: Array[int] = [1, 0, 1, 2]
@export_range(0.02, 5.0, 0.01) var step_duration: float = 0.25
@export var animated: bool = true

@export_group("朝向动画")
## 非空时覆盖踏步动画（例：[0, 1, 2, 1] 做左右张望）。
@export var facing_frames: Array[int] = [0]
@export_range(0.02, 5.0, 0.01) var facing_duration: float = 0.25
@export var facing_animated: bool = false

# ═══════════════════════════════════════
# 对话前后换图（路灯式两态）
# ═══════════════════════════════════════
@export_group("对话前行走图")
## 开启后：对话开始时切到这一组（模仿路灯的「点亮前」）。
@export var change_appearance_before: bool = false
@export var before_texture: Texture2D = null
@export_range(0, 7, 1) var before_char_index: int = 0
@export_range(0, 3, 1) var before_direction: int = 0

@export_group("对话后行走图")
## 开启后：对话结束时切到这一组（模仿路灯的「点亮后」）。
@export var change_appearance_after: bool = false
@export var after_texture: Texture2D = null
@export_range(0, 7, 1) var after_char_index: int = 0
@export_range(0, 3, 1) var after_direction: int = 0

# ═══════════════════════════════════════
# 交互
# ═══════════════════════════════════════
@export_group("交互")
@export var trigger_mode: TriggerMode = TriggerMode.CLICK
@export var interact_label: String = "交谈"
@export_range(8.0, 256.0, 1.0) var interact_range: float = 56.0
## 同一时刻只允许一个剧情点响应（避免重叠范围里两个一起触发）。
@export var exclusive: bool = true

# ═══════════════════════════════════════
# 结束表现
# ═══════════════════════════════════════
@export_group("结束表现")
## 对话结束后播放的音效（原作：门打开时放「ドア開け」）。
@export var finish_sound: AudioStream = null
## 结束后设置为 true 的任务开关（例：剧情已看、门已开）。
@export var set_flags_on_finish: Array[String] = []
## 结束后设置为 false 的任务开关（例：隐藏某个提示事件）。
@export var clear_flags_on_finish: Array[String] = []
## 结束后显形的节点（相对本节点解析；例：原本 visible=false 的传送点）。
@export var reveal_node_paths: Array[NodePath] = []

signal story_finished

var _sprite: Sprite2D = null
var _area: Area2D = null
var _step_index: int = 0
var _step_timer: float = 0.0
var _playing: bool = false
var _player_nearby: bool = false


func _ready() -> void:
	_ensure_children()
	_refresh_sprite()
	if Engine.is_editor_hint():
		return
	add_to_group(&"story_sequence")
	_create_interact_area()
	if trigger_mode == TriggerMode.TOUCH:
		## 触摸触发：进范围就自己开（不用等按键）
		set_process_unhandled_input(false)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _playing:
		return
	var frames: Array[int] = facing_frames if facing_animated else step_frames
	var dur: float = facing_duration if facing_animated else step_duration
	if not animated and not facing_animated:
		return
	if frames.size() <= 1:
		return
	_step_timer -= delta
	if _step_timer <= 0.0:
		_step_timer += maxf(dur, 0.02)
		_step_index = (_step_index + 1) % frames.size()
		_refresh_sprite()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or _playing:
		return
	if trigger_mode != TriggerMode.CLICK or not _player_nearby:
		return
	if event.is_action_pressed("确定键"):
		## 与 safe_door / teleport_point 一致：标记已处理，避免同一次按键又开别的界面。
		get_viewport().set_input_as_handled()
		_play()


# ═══════════════════════════════════════
# 播放
# ═══════════════════════════════════════

## 手动触发（脚本 / 调试 / 联机 Host 广播都可以直接调）。
func play() -> void:
	_play()


func _play() -> void:
	if _playing:
		return
	if exclusive and _another_story_playing():
		return
	var pages: Array = _collect_pages()
	if pages.is_empty():
		push_warning("[StorySequence] %s 没有可用台词（story_key=%s）" % [name, story_key])
		return
	if _already_seen():
		return

	_playing = true
	_apply_before_preset()

	var map_root: Node = _map_root()
	if map_root == null:
		_playing = false
		return
	var dlg: Node = DIALOGUE_SCENE.instantiate()
	map_root.add_child(dlg)
	dlg.connect("dialogue_closed", _on_dialogue_closed, CONNECT_ONE_SHOT)
	dlg.call("open_mixed_pages", pages)
	print("[StorySequence] %s 开始剧情：%s（%d 页）" % [name, story_key if not story_key.is_empty() else "inline", pages.size()])


func _on_dialogue_closed() -> void:
	_playing = false
	_mark_seen()
	_apply_after_preset()
	_play_finish_sound()
	_apply_flags()
	_reveal_nodes()
	story_finished.emit()
	print("[StorySequence] %s 剧情结束" % name)


## 组装页面：内联优先，否则查表并按本机角色拼「固定 + 分支 + 收尾」。
func _collect_pages() -> Array:
	if not inline_pages.is_empty():
		return inline_pages.duplicate()
	var key: String = _resolve_key()
	if key.is_empty():
		return []
	return STORY_DATA.pages_for(key, _local_character_name())


## 主 key 与备选 key 的切换（例：开关 500 为 ON 时换成委托对话）。
func _resolve_key() -> String:
	if not alternate_story_key.is_empty() and not alternate_flag.is_empty():
		var g: Node = get_node_or_null("/root/Global")
		if g != null and g.has_method("has_quest_flag") and bool(g.call("has_quest_flag", alternate_flag)):
			return alternate_story_key
	return story_key


## 本机玩家角色的**日文原名**（与 story_script_data 的 by_character 键一致）。
## 联机取 Net 的角色路径（早于座位表可用），单机取激活座位。
func _local_character_name() -> String:
	var net: Node = get_node_or_null("/root/Net")
	if net != null and net.has_method("is_online_session") and bool(net.call("is_online_session")) \
			and net.has_method("get_player_character_path") and net.has_method("get_my_peer_id"):
		var path: String = str(net.call("get_player_character_path", int(net.call("get_my_peer_id"))))
		if not path.is_empty() and ResourceLoader.exists(path):
			var res: Resource = load(path)
			if res is CharacterData:
				return (res as CharacterData).character_name
	var players: Node = get_node_or_null("/root/Players")
	if players != null and players.has_method("get_active_state"):
		var st: PlayerState = players.call("get_active_state") as PlayerState
		if st != null and st.character != null:
			return st.character.character_name
	return ""


func _already_seen() -> bool:
	if not once_only:
		return false
	var flag: String = _seen_flag_name()
	if flag.is_empty():
		return false
	var g: Node = get_node_or_null("/root/Global")
	return g != null and g.has_method("has_quest_flag") and bool(g.call("has_quest_flag", flag))


func _mark_seen() -> void:
	if not once_only:
		return
	var flag: String = _seen_flag_name()
	if flag.is_empty():
		return
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("request_quest_flag"):
		g.call("request_quest_flag", flag, true)


func _seen_flag_name() -> String:
	if not seen_flag.is_empty():
		return seen_flag
	if not story_key.is_empty():
		return "story_seen:%s" % story_key
	return ""


# ═══════════════════════════════════════
# 结束表现
# ═══════════════════════════════════════

func _play_finish_sound() -> void:
	if finish_sound == null:
		return
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("play_sfx_managed"):
		## parent 兜底 self：探针/独立测试里 current_scene 可能为空，
		## play_sfx_managed 会 add_child 到 parent，传 null 直接崩。
		var parent: Node = _map_root()
		if parent == null:
			parent = self
		g.call("play_sfx_managed", finish_sound, parent)


func _apply_flags() -> void:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("request_quest_flag"):
		return
	for flag: String in set_flags_on_finish:
		if not flag.is_empty():
			g.call("request_quest_flag", flag, true)
	for flag: String in clear_flags_on_finish:
		if not flag.is_empty():
			g.call("request_quest_flag", flag, false)


func _reveal_nodes() -> void:
	for p: NodePath in reveal_node_paths:
		var n: Node = get_node_or_null(p)
		if n is CanvasItem:
			(n as CanvasItem).visible = true
			## 传送点这类还要能交互：本身不是 CanvasItem 就只跳过隐藏
		elif n != null:
			n.set("visible", true)


func _apply_before_preset() -> void:
	if not change_appearance_before:
		return
	if before_texture != null:
		walk_texture = before_texture
	char_index = before_char_index
	direction = before_direction
	_refresh_sprite()


func _apply_after_preset() -> void:
	if not change_appearance_after:
		return
	if after_texture != null:
		walk_texture = after_texture
	char_index = after_char_index
	direction = after_direction
	_refresh_sprite()


# ═══════════════════════════════════════
# 交互 / 外观
# ═══════════════════════════════════════

func _create_interact_area() -> void:
	_area = get_node_or_null("InteractArea") as Area2D
	if _area == null:
		_area = Area2D.new()
		_area.name = "InteractArea"
		add_child(_area)
	var shape_node: CollisionShape2D = _area.get_node_or_null("Shape") as CollisionShape2D
	if shape_node == null:
		shape_node = CollisionShape2D.new()
		shape_node.name = "Shape"
		_area.add_child(shape_node)
	var circle: CircleShape2D = shape_node.shape as CircleShape2D
	if circle == null:
		circle = CircleShape2D.new()
		shape_node.shape = circle
	circle.radius = maxf(8.0, interact_range)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	_player_nearby = true
	if trigger_mode == TriggerMode.TOUCH:
		_play()


func _on_body_exited(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	_player_nearby = false


func _another_story_playing() -> bool:
	for n: Node in get_tree().get_nodes_in_group("story_sequence"):
		if n != self and bool(n.get("_playing")):
			return true
	return false


func _map_root() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	return tree.current_scene


func _ensure_children() -> void:
	_sprite = get_node_or_null("Sprite2D") as Sprite2D
	if _sprite == null:
		_sprite = Sprite2D.new()
		_sprite.name = "Sprite2D"
		_sprite.centered = true
		add_child(_sprite)


func _refresh_sprite() -> void:
	if _sprite == null:
		return
	_sprite.texture = walk_texture
	_sprite.position = sprite_offset
	_sprite.visible = walk_texture != null
	if walk_texture == null:
		return
	_sprite.region_enabled = true
	var frames: Array[int] = facing_frames if facing_animated else step_frames
	if frames.is_empty():
		frames = [0]
	var f: int = clampi(frames[_step_index % frames.size()], 0, 2)
	_sprite.region_rect = WALK.region_rect(walk_texture, char_index, direction, f)
