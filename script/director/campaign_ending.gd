class_name CampaignEnding extends CanvasLayer

## ── 架构定位 ──
## 系统：终章 ED 编排 ｜ 层：玩法（CanvasLayer，按需创建）
## 联机：单机完整流程；联机由 Host 驱动，进名单时走 request_scene_change 带上 Client。
## 职责：黑屏淡出 → **战役总结**（2026-09-14 用户定稿改序）→ ED BGM 起播 + 角色结局
##       对话（每条 5 秒）→ 滚动名单场景。ED BGM 由本节点持有，压进名单连续播放，
##       名单结束/跳过时由 credits 回调 stop_ending_music() 收尾。
## 依赖：Global（字体/阴影）、Players（座位→角色）、chapter_summary.tscn、credits.tscn。
##
## 台词出处：E:/15.L3D/Map0022.lmu（テンプラED）事件文本；中译为本项目自译
## （原作简体中文版文本未能取得，找到官方中文文案后可直接替换下方字符串）。
## 我方四人阵容有专属台词；其余角色回退共通台词（「大家，快点上电车！」）。
## 角色日文名→中文显示名走 Global.CHARACTER_NAME_ZH（与 credits 战报共用）。

const SUMMARY_SCENE := "res://scene/ui/chapter_summary.tscn"
const CREDITS_SCENE := "res://scene/ui/credits.tscn"
const ED_MUSIC_PATH := "res://music/l3d_ed.mp3"
## 2026-09-14 用户定稿：每条话语固定显示 5 秒
const DIALOGUE_SECONDS_PER_LINE: float = 5.0

## 原作台词（按 CharacterData.character_name 匹配；键 = 日文角色名）。
## 中文为自译，注释保留原文以便回溯校对。
const DIALOGUE_BY_NAME: Dictionary = {
	"のび太": "不用靠哆啦A梦，\n我也能靠自己的力量做到！",
	# ドラえもんに頼らなくたって、僕ひとりの力でやれるんだ！
	"ジャイアン": "真不争气！\n你连一只都杀不了吗！？",
	# だらしねえな！俺ひとりも殺せないのかよ！？
	"静香": "太好了！我们成功了！",
	# やった！　やったんだわ！
	"スネ夫": "该不会我其实是最强的吧？\n嘻嘻嘻嘻。",
	# 僕ちゃんって、もしかして最強だったりして！　ウフフフフ。
	"聖奈": "原来神明真的存在啊。",
	# 神様って本当にいたんですね。
	"健治": "咿呀嗷————！\n我还活着！混蛋们！！",
	# イヤッホオオオイ！生きてるぜ！　コンチクショー！！
	"出木杉": "没想到自己的生存能力这么高，\n连我自己都大吃一惊。",
	# こんなにサバイバル能力が高かったなんて、自分でも知らなかったよ。
	"安雄": "我是手雷安雄！\n给我记住了！",
	# 俺がグレネード安雄だ！おぼえてろよ！
	"サーシャ": "本以为这次死定了，\n不过我的坏运气也真是厉害呢——。",
	# 今度こそ死んだと思ったけど、私の悪運も大したもんだねー。
	"咲夜": "没用的。\n今天的我，感觉根本不会死！",
	# 無駄よ。今日の私は死ぬ気がしないわ！
}
const DIALOGUE_FALLBACK := "大家，快点上电车！"
# みんな、早く電車に乗るんだ！

## 黑屏淡出时长（HoldoutMachine 注入）
var fade_seconds: float = 1.5

var _rect: ColorRect
var _dialogue_label: Label
var _ed_music: AudioStreamPlayer = null
var _fuse_timer: Timer = null


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
	# 黑幕淡出前先清场：触发 ED 前残留的伤害数字飘字（layer 100 > 黑幕 90）会
	# 压在黑幕和总结页上直到切场景——直接全清。
	DamageNumber.clear_all()
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


## 供 credits 判断是否接管本节点的 BGM（Client 端没有本节点 → credits 自播）。
func is_ending_music_playing() -> bool:
	return _ed_music != null and _ed_music.playing


## 名单结束 / 跳过时由 credits 调用：收 BGM 并整体退场。
func stop_ending_music() -> void:
	if _ed_music:
		_ed_music.stop()
	queue_free()


## 角色结局对话：每个存活/已确认座位一条（按角色名取台词中译），逐条展示 5 秒。
func _show_dialogue() -> void:
	var lines: Array[String] = []
	var players: Node = get_node_or_null("/root/Players")
	var g: Node = get_node_or_null("/root/Global")
	if players:
		for i: int in players.seat_count():
			var st: PlayerState = players.get_seat(i)
			if st == null or st.character == null:
				continue
			if not st.is_alive():
				continue
			var name: String = st.character.character_name
			var display: String = name
			if g and g.get("CHARACTER_NAME_ZH") is Dictionary:
				display = (g.CHARACTER_NAME_ZH as Dictionary).get(name, name)
			var line: String = DIALOGUE_BY_NAME.get(name, DIALOGUE_FALLBACK)
			var entry: String = "%s「%s」" % [display, line.replace("\n", "」\n　「")]
			if not lines.has(entry):
				lines.append(entry)
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
	_dialogue_label.visible = false
	# 解除冻结：名单是独立 UI 场景，需要自己的 _process 驱动滚动
	get_tree().paused = false
	# 联机：Host 统一拉所有客户端进名单（单机等价于空操作）
	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("is_online_session") and bool(net.is_online_session()) \
			and net.has_method("request_scene_change"):
		net.request_scene_change(CREDITS_SCENE)
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
	if _fuse_timer != null and is_instance_valid(_fuse_timer):
		_fuse_timer.stop()
		_fuse_timer.queue_free()
		_fuse_timer = null
