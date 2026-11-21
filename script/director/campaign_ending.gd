class_name CampaignEnding extends CanvasLayer

const MAP_SCENE_QUERY = preload("res://script/map/map_locator.gd")

## ── 架构定位 ──
## 系统：终章 ED 编排 ｜ 层：玩法（CanvasLayer，按需创建）
## 联机：单机完整流程；联机由 Host 驱动，进名单时走 request_scene_change 带上 Client。
## 职责：黑屏淡出 → **战役总结**（2026-09-14 用户定稿改序）→ ED BGM 起播 + 角色结局
##       对话（安全屋同款窗口，逐角色按确定键翻页）→ 滚动名单场景。ED BGM 由本节点持有，
##       压进名单连续播放，名单结束/跳过时由 credits 回调 stop_ending_music() 收尾。
## 依赖：Global（字体/阴影）、Players（座位→角色）、chapter_summary.tscn、credits.tscn。
##
## 台词出处：原作 ED 地图 `E:/15.L3D/Map0021.lmu`（突袭·电车）、`Map0023.lmu`
## （夜行猎手·直升机），事件 `#121` 第 1 页；**逐字取自简体中文地图记录**，不再自译。
## 表现与安全屋台词一致：每个**存活座位**的角色依次出一段台词窗口，
## A 批（结局感想）→ B 批（登车/起飞/启动）两页；多人模式各端只显示本端存活角色。
## 与安全屋的区别：安全屋每批只显示**当前玩家角色**的一条；ED 把队伍里所有存活角色
## 按原作 ED 顺序依次全部展示一遍。完整对照见 `docs/07-原作参考/原作ED台词数据.md`。

const SUMMARY_SCENE := "res://scene/ui/chapter_summary.tscn"
const CREDITS_SCENE := "res://scene/ui/credits.tscn"
const SAFEHOUSE_DIALOGUE_SCENE := "res://scene/ui/safehouse_dialogue.tscn"
const ED_MUSIC_PATH := "res://music/l3d_ed.mp3"
## 成就弹窗脚本（**运行时 load，不用 class_name** —— 本项目 `class_name` 不跨文件的教训）
const EARNED_SCRIPT := preload("res://script/ui/achievements_earned.gd")
## 兜底文案（台词窗口场景加载失败时才用；正常走 ED 数据层）
const DIALOGUE_FALLBACK := "大家，快点上电车！"
const DIALOGUE_SECONDS_PER_LINE: float = 5.0
## ED 台词数据层：内置默认 + user://ed_dialogue.json 覆盖 + 创意工坊运行时注册。
## 数据/校验/隔离都在 ed_dialogue_data.gd 内，本文件只消费 lines_for()/order_for()。
const ED_DATA := preload("res://script/ed_dialogue_data.gd")

## 黑屏淡出时长（HoldoutMachine 注入）
var fade_seconds: float = 1.5
## 当前战役 id（"assault" / "night_hunter" / …），决定 B 批台词
var _campaign_id: String = ""
## 防止「台词窗口关闭」与兜底计时重复进名单
var _credits_started: bool = false

var _rect: ColorRect
var _dialogue_label: Label
var _ed_music: AudioStreamPlayer = null
var _fuse_timer: Timer = null
var _root: Control = null           ## EndingRoot（成就弹窗也挂这里 → 天然压在黑幕之上）


func _ready() -> void:
	layer = 90
	# 总结页 layer=100 必须压在本层之上（黑幕只盖游戏世界，不盖总结/ED UI）；
	# credits.tscn 自带 layer=95 背板，进名单时本层退到其背后（不撤，保 BGM 存活）。
	# 总结页会把树 pause；本层与计时必须照常走
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root: Control = Control.new()
	root.name = "EndingRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_root = root

	_rect = ColorRect.new()
	_rect.name = "Blackout"
	_rect.color = Color.BLACK
	_rect.modulate.a = 0.0
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_rect)

	_dialogue_label = Label.new()
	_dialogue_label.name = "DialogueLabel"
	_dialogue_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dialogue_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dialogue_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var g: Node = get_node_or_null("/root/Global")
	if g and g.has_method("get_text_font"):
		_dialogue_label.add_theme_font_override("font", g.get_text_font(24))
	_dialogue_label.add_theme_font_size_override("font_size", 24)
	_dialogue_label.add_theme_color_override("font_color", Color.WHITE)
	if g and g.has_method("apply_text_shadow"):
		g.apply_text_shadow(_dialogue_label)
	_dialogue_label.visible = false
	root.add_child(_dialogue_label)


## 由 HoldoutMachine 调用：开始终章流程。
func start() -> void:
	## 成就：战役通关结算（通关 / 单人 / 无伤 / 不存档 / 速通 / 战役专属）——
	## 必须在这里做，而不是弹窗那一步：弹窗之前玩家可能按跳过，结算不能丢。
	## 战役 id 决定「太勉强了吧」（第二战役）这类专属成就是否给。
	## 优先按**当前场景**反查（选章节 / 调试跳关不经过 campaign_select，selected_campaign 可能是旧值）；
	## 查不到再退回 Global.selected_campaign。
	var campaign_id: String = ""
	var tree: SceneTree = get_tree()
	if tree != null and MAP_SCENE_QUERY.get_map_root(tree) != null:
		campaign_id = CampaignData.campaign_id_for_scene(MAP_SCENE_QUERY.get_map_root(tree).scene_file_path)
	if campaign_id.is_empty():
		var g: Node = get_node_or_null("/root/Global")
		if g != null:
			var cd: Variant = g.get("selected_campaign")
			if cd is CampaignData:
				campaign_id = str((cd as CampaignData).campaign_id)
	_campaign_id = campaign_id
	ACHIEVEMENTS.finish_campaign(Players.all_entities(true).size(), campaign_id)
	# 黑幕淡出前先清场：触发 ED 前残留的伤害数字飘字（layer 100 > 黑幕 90）会
	# 压在黑幕和总结页上直到切场景——直接全清。
	DamageNumber.clear_all()
	## ★BGM 交接（2026-09-26）：终章演出开始 = 战斗结束，先收掉 Boss/尸潮 BGM。
	## 它们挂 /root/Director 下不进场景树释放，且 AudioStreamPlayer 在树暂停时照常出声
	## —— 不收就会压在结算页 summary_music / ED 的 l3d_ed 上（用户实测两首一起响）。
	var director: Node = get_node_or_null("/root/Director")
	## 2026-11-02：必须连**常驻铺底（calm）**一起收。
	## 旧接口 `stop_battle_music()` 只收 Boss / 尸潮，铺底曲会一直压在 ED 音乐下面
	##（用户实测「播放 ED 时鼓底音乐还在响」）。优先用新接口，旧接口兜底。
	if director != null:
		if director.has_method("stop_all_music"):
			director.call("stop_all_music", true)
		elif director.has_method("stop_battle_music"):
			director.call("stop_battle_music")
	# 淡出瞬间冻结全场（用户 2026-09-13：黑屏过程玩家/敌人全部暂停、不能移动）。
	# 本层 PROCESS_MODE_ALWAYS，计时/补间不受影响。
	get_tree().paused = true
	var tween: Tween = create_tween()
	tween.tween_property(_rect, "modulate:a", 1.0, maxf(fade_seconds, 0.1))
	# 2026-09-14 改序：先章节总结 → 再 ED BGM + 角色话语 → 最后滚动名单
	tween.tween_callback(_show_summary)


## 战役总结（复用安全屋结算页；确认后进 ED 段）。
func _show_summary() -> void:
	var packed: PackedScene = load(SUMMARY_SCENE) as PackedScene
	if packed == null:
		printerr("[CampaignEnding] 结算页加载失败: %s" % SUMMARY_SCENE)
		_after_summary()
		return
	var summary: Node = packed.instantiate()
	## 终章 ED 的结算页是**过场页**（2026-09-26 用户实测：客户端按确定键不能准备、
	## 流程走不下去）—— 打开 cutscene_mode 后不再走"全员准备"闸门：
	## 本端按键即推进本端，Host 关闭时广播让其余端一并关闭。
	## ⚠ 必须在 add_child 之前置位：ChapterSummary._ready 会立即 show_summary() 读它。
	summary.set("cutscene_mode", true)
	# 进 ED 时不允许 auto_show 关闭形态；确认由 ChapterSummary 自身的确定键流程处理
	add_child(summary)
	if summary.has_signal("summary_finished"):
		# 2026-09-14 改序后总结在前：必须**同步**接住 summary_finished——
		# ChapterSummary._finish_summary 会先把树解除暂停再 emit，若走 DEFERRED
		# 会留出活动帧；同步回调里立刻重新冻结，ED 对话段全场保持暂停。
		summary.connect("summary_finished", _after_summary)
	else:
		_after_summary()


## 总结确认完毕 → 重新冻结全场 → ED BGM 起播（压进名单连续）+ 角色结局对话。
func _after_summary() -> void:
	# ChapterSummary 关闭时把树解除暂停了（pause_game=true 分支）；ED 对话段
	# 是黑屏 UI 演出，世界必须保持冻结——否则玩家会被活着的尸潮咬死（实测教训）。
	get_tree().paused = true
	_start_ed_music()
	## 成就弹窗（2026-10-02 用户需求）：**章节总结确定之后、ED 对话之前**展示本次解锁。
	## 无解锁 → 直接进对话（不白等 3 秒）。弹窗自己 3 秒后发 finished 续上对话段，
	## 多人两端走同一时间轴（不等按键），保证名单同步。
	if EARNED_SCRIPT.has_content():
		var earned: Control = EARNED_SCRIPT.new()
		_root.add_child(earned)
		## ★2026-10-02 用户实测「成就 3 秒后不继续、按菜单键才行」的根因：
		## 结算页关闭时 `_dialogue_label` 可能**残留 visible = true**（上一次 ED 段留下的），
		## 于是成就弹窗（3 秒）与对话文字在屏幕上**同时显示**；3 秒后弹窗消失，
		## 玩家看到的仍是那行对话 → 误以为"没继续"，其实对话段正在按
		## `DIALOGUE_SECONDS_PER_LINE`(5s) 各自计时。修法：弹窗期间**强制隐藏对话文字**，
		## 由弹窗的 `finished` 独占推进权。
		if _dialogue_label != null:
			_dialogue_label.visible = false
		earned.connect("finished", _show_dialogue)
	else:
		_show_dialogue()


## ED BGM：挂在本节点（root 子节点，场景切换不释放），从对话段一直压到名单结束。
func _start_ed_music() -> void:
	if not ResourceLoader.exists(ED_MUSIC_PATH):
		printerr("[CampaignEnding] ED 音乐缺失: %s" % ED_MUSIC_PATH)
		return
	if _ed_music == null:
		_ed_music = AudioStreamPlayer.new()
		_ed_music.name = "EndingMusic"
		_ed_music.stream = load(ED_MUSIC_PATH)
		_ed_music.bus = &"Music"
		add_child(_ed_music)
	_ed_music.play()


## 本节点是否**持有**可用的 ED 播放器（不代表此刻正在出声：可能被暂停或已播完）。
func has_ending_music() -> bool:
	return _ed_music != null and is_instance_valid(_ed_music) and _ed_music.stream != null


## 此刻是否确实在出声。
## ⚠ Godot 4.6 实测（本轮探针 `.workbuddy/tmp/probe_audio_playing.gd`）：
## `playing` 在 **stream_paused = true 时返回 false**；process_mode 为 INHERIT 的播放器在
## **场景树暂停**时同样返回 false（ALWAYS 节点不受影响 —— 本层是 ALWAYS，故正常情况下安全）。
## 判据取 `playing or stream_paused`；节点被释放后直接读 `_ed_music.playing` 会报错
## → 必须先 is_instance_valid。
func is_ending_music_playing() -> bool:
	if not has_ending_music():
		return false
	return _ed_music.playing or _ed_music.stream_paused


## ★credits 交接的唯一入口（2026-09-27）：返回 true = 本节点继续持有并在播 ED BGM，
## credits **不要**再自播一份；返回 false = 本节点没有可用播放器，credits 自行起播。
##
## 为什么收敛成"一个入口 + 明确裁决"：旧写法是 credits 自己读 is_ending_music_playing()
## 判断，判据一旦为假（被暂停 / 已播完 / 找到的是上一轮残留实例）就会**同时存在两份
## l3d_ed** —— 用户实测「进入制作人员名单时 ED BGM 又再次播放了」。
func take_over_ending_music() -> bool:
	if not has_ending_music():
		return false
	## 保险丝只为"credits 根本没起来"兜底；既然 credits 起来了就必须解除，
	## 否则滚动超过 30 秒时 BGM 会被半路掐断（2026-09-15 实测教训）。
	_cancel_fuse()
	if _ed_music.stream_paused:
		_ed_music.stream_paused = false      ## 只解暂停，**不**从头重播
	elif not _ed_music.playing:
		_ed_music.play()                     ## 已被打断 / 已播完 → 原地接回，总比名单静音好
	print("[CampaignEnding] ED_BGM 已交接给 credits（playing=%s paused=%s）" % [
		str(_ed_music.playing), str(_ed_music.stream_paused)])
	return true


## 名单结束 / 跳过时由 credits 调用（幂等：重复调用安全）。
func stop_ending_music() -> void:
	if _ed_music != null and is_instance_valid(_ed_music):
		_ed_music.stop()
		_ed_music = null
	queue_free()


## 角色结局对话：按原作 ED 顺序取**存活座位**的角色；
## 每个角色两页（A 批结局感想 → B 批登车/起飞/启动），用安全屋同款台词窗口展示。
## 数据来自 ED_DATA（内置默认 + user:// 覆盖 + 创意工坊注册），这里只负责取人与播放。
func _show_dialogue() -> void:
	var entries: Array[Dictionary] = _build_dialogue_entries()
	if entries.is_empty():
		entries.append({"lines": [DIALOGUE_FALLBACK], "speaker": "", "portrait": null})
	_play_dialogue_entries(entries)


## 存活座位 → { 日文角色名: PlayerState }（同一角色只取一次）。
## `ジャイ` 归一到 `ジャイアン`：character_bigg.tres 用短名，ED 表按原作写全名。
func _alive_characters() -> Dictionary:
	var out: Dictionary = {}
	var players: Node = get_node_or_null("/root/Players")
	if players == null:
		return out
	for i: int in players.seat_count():
		var st: PlayerState = players.get_seat(i)
		if st == null or st.character == null or not st.is_alive():
			continue
		var name: String = st.character.character_name
		if name == "ジャイ":
			name = "ジャイアン"
		if not out.has(name):
			out[name] = st
	return out


func _build_dialogue_entries() -> Array[Dictionary]:
	var alive: Dictionary = _alive_characters()
	var table: Dictionary = ED_DATA.lines_for(_campaign_id)
	var entries: Array[Dictionary] = []
	for jp: String in ED_DATA.order_for(_campaign_id):
		if not alive.has(jp):
			continue
		var st: PlayerState = alive[jp]
		var speaker: String = _short_name(jp)
		var portrait: Texture2D = st.character.portrait_texture() if st.character != null else null
		var item: Dictionary = table.get(jp, {})
		var a: Array = item.get("a", [])
		if not a.is_empty():
			entries.append({"lines": a, "speaker": speaker, "portrait": portrait})
		var b: Array = item.get("b", [])
		if not b.is_empty():
			entries.append({"lines": b, "speaker": speaker, "portrait": portrait})
	return entries


func _short_name(jp: String) -> String:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.get("CHARACTER_NAME_SHORT") is Dictionary:
		return str((g.CHARACTER_NAME_SHORT as Dictionary).get(jp, jp))
	return jp


## 用安全屋同款台词窗口播放；场景缺失/打开失败时退回居中文字兜底。
func _play_dialogue_entries(entries: Array[Dictionary]) -> void:
	var packed: PackedScene = load(SAFEHOUSE_DIALOGUE_SCENE) as PackedScene
	if packed == null:
		_play_dialogue_fallback(entries)
		return
	var dlg: Node = packed.instantiate()
	## 压在本层（90）之上；summary=100、credits=95 —— 台词段在两者之间。
	dlg.set("layer", 96)
	## 场景树此刻是暂停的，必须 ALWAYS 才能收到「确定键」
	dlg.process_mode = Node.PROCESS_MODE_ALWAYS
	## 不限页数（最多 2×座位 页），否则 open_mixed_pages 会裁到默认 3 页
	dlg.set("max_pages", 0)
	add_child(dlg)
	if dlg.has_signal("dialogue_closed"):
		dlg.connect("dialogue_closed", _go_credits)
	if dlg.has_method("open_mixed_pages"):
		dlg.call("open_mixed_pages", entries)
		if dlg.has_method("is_open") and not bool(dlg.call("is_open")):
			dlg.queue_free()
			_play_dialogue_fallback(entries)
	else:
		dlg.queue_free()
		_play_dialogue_fallback(entries)


## 兜底：台词窗口不可用时，退回旧的居中文字（每条 5 秒）。
func _play_dialogue_fallback(entries: Array[Dictionary]) -> void:
	var lines: Array[String] = []
	for e: Dictionary in entries:
		var speaker: String = str(e.get("speaker", ""))
		var body: String = "\n".join(PackedStringArray(e.get("lines", [])))
		lines.append(body if speaker.is_empty() else "%s\n%s" % [speaker, body])
	if lines.is_empty():
		lines.append(DIALOGUE_FALLBACK)
	_show_dialogue_line(lines, 0)


func _show_dialogue_line(lines: Array[String], idx: int) -> void:
	if idx >= lines.size():
		_go_credits()
		return
	_dialogue_label.text = lines[idx]
	_dialogue_label.visible = true
	var timer: Timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = DIALOGUE_SECONDS_PER_LINE
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	timer.timeout.connect(func():
		timer.queue_free()
		_show_dialogue_line(lines, idx + 1))
	add_child(timer)
	timer.start()


## 对话完毕 → 进滚动名单场景。
func _go_credits() -> void:
	## 窗口关闭信号与兜底计时都可能触发，只放行一次。
	if _credits_started:
		return
	_credits_started = true
	_dialogue_label.visible = false
	# 解除冻结：名单是独立 UI 场景，需要自己的 _process 驱动滚动
	get_tree().paused = false
	var net: Node = get_node_or_null("/root/Net")
	var online: bool = net != null and net.has_method("is_online_session") \
		and bool(net.is_online_session())
	var is_client: bool = online and not bool(net.get("is_host"))
	## ★2026-09-27 实测修复（"在看名单的玩家会重新看"）：
	## 旧实现里**每个 peer 都各自发起一次换场** —— Host 自己调 request_scene_change
	##（内部 start_game.rpc 带 call_local），每个 Client 也发 request_scene_change_rpc，
	## Host 收到后**又**跑一次 start_game.rpc。谁晚到 credits，谁就触发一次全量换场，
	## 把已经在看名单的人整场重建 → 从底部重新滚。
	## 现在：**Host 是唯一驱动者**，Client 到这一步只等 Host 的 start_game 握手把它带过去；
	## 单机（无联机会话）才直接本地换场。
	if online:
		if not is_client and net.has_method("request_scene_change"):
			net.request_scene_change(CREDITS_SCENE)
	else:
		get_tree().change_scene_to_file.call_deferred(CREDITS_SCENE)
	# 2026-09-14：本节点**不** queue_free —— 黑幕退到 credits 背板（95）之后，
	# ED BGM 继续压进名单；名单结束/跳过时 credits 会调 stop_ending_music() 收尾。
	# 保险丝：万一 credits 未能回调，30 秒后自裁，避免黑幕残留在标题画面上。
	# credits._ready 接管连续 BGM 时会调 notify_credits_attached() 解除——
	# 名单滚动全程可能远超 30 秒，不解除会把还压在名单下的 ED BGM 半路掐断（实测教训）。
	_fuse_timer = Timer.new()
	_fuse_timer.one_shot = true
	_fuse_timer.wait_time = 30.0
	_fuse_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_fuse_timer.timeout.connect(func():
		if is_instance_valid(self):
			printerr("[CampaignEnding] ED BGM 保险丝触发：credits 未回调，强制退场")
			stop_ending_music())
	add_child(_fuse_timer)
	_fuse_timer.start()


## credits 场景已正常接管 ED BGM：解除保险丝（名单滚动可远超 30 秒，BGM 必须一直压到底）。
func notify_credits_attached() -> void:
	_cancel_fuse()


func _cancel_fuse() -> void:
	if _fuse_timer != null and is_instance_valid(_fuse_timer):
		_fuse_timer.stop()
		_fuse_timer.queue_free()
	_fuse_timer = null

## 成就系统入口（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error —— 见 MEMORY「class_name 不跨文件」）。
const ACHIEVEMENTS := preload("res://script/achievements.gd")
