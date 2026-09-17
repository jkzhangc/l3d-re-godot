extends CanvasLayer

## ── 架构定位 ──
## 系统：制作人名单（ED）｜ 层：UI（CanvasLayer 95，独立场景，change_scene 进入）
## 联机：纯本地表现（由 CampaignEnding 经 request_scene_change 把所有端带进来）。
## 职责：黑底 + 名单文字自下而上滚动（L4D2 式），l3d_ed.mp3；滚完或按确定/取消/菜单键 → 标题。
## 2026-09-14 改版：
##   · 名单文本整体中文化（原作为日文；译文为本项目自译，可在 Inspector 改 credits_text）。
##   · 原「[もっとも演技のよかったキャスト]」角色平铺段移除，替换为 L4D2 式
##     「幸存者战报」排名段（击杀/爆头/受伤/死亡最多 + 最终生死状态），
##     数据取 ChapterStats 战役累计（跨章节），运行时填入 @@STATS@@ 占位行。
##   · BGM 接管：CampaignEnding 的 ED BGM 从对话段连续压进来（单机/Host）；
##     找不到该节点（如直接跑本场景 / 联机 Client）时自播 l3d_ed.mp3。
## CanvasLayer 95：压过终章黑幕（90，进本场景后仍由 CampaignEnding 持有 BGM）与世界（0）。

const TITLE_SCENE := "res://scene/title_screen.tscn"
const ED_MUSIC_PATH := "res://music/l3d_ed.mp3"
const SKIP_ACTIONS: Array[String] = ["确定键", "取消键", "菜单键"]
## 战报占位行：credits_text 里出现该行 → 运行时替换为排名段（无数据时替换为空）
const STATS_PLACEHOLDER := "@@STATS@@"

## 名单文本（可在 Inspector 编辑；默认 = 原作名单全文中译 + 本项目段占位）
@export_multiline var credits_text: String = """　　　　　野比大雄的生化危机 〜LEFT 3 DEAD〜


　　[原作]
　　藤子·F·不二雄（哆啦A梦）
　　aaa 等（野比大雄的生化危机）

　　[导演]
　　正宗金田

　　[助理导演]
　　ティンダロス

　　[NG镜头最多的卡司]
　　布蕾尔女士以 1/5 的概率乱入香艳镜头

　　[贡献香艳镜头最多的卡司]
　　布蕾尔女巫

　　[最敬业的僵尸卡司]
　　僵尸A
　　僵尸B
　　3号酱
　　僵尸D
　　僵尸E
　　僵尸F
　　僵尸G

　　[最有猎人风范的卡司]
　　猎人α
　　猎人β
　　猎人γ
　　奇美拉

　　[最不受女性待见的虫子卡司]
　　脑螨虫
　　黑虎

　　[最具职业精神的Boss卡司]
　　暴君
　　复仇女神
　　生物巨兽
　　ティンダロス

　　[程序]
　　红锹甲

　　[战役剪辑]
　　诗织

　　[特别鸣谢]
　　野比ハザCODE:Vow制作团队
　　冲绳

@@STATS@@

　　―――

　　野比大雄的求生之路 〜L3D 重制版〜

　　[重制]
　　野比ハザ重制组（Godot 4）
　　制作：剑客
　　策划/玩法设计：Eluniht、剑客、阿茶Atea
　　特别感谢：Eluniht、阿茶Atea、乔杉杉、划水员

　　 感谢游玩！
　　　　在本片拍摄中牺牲的
　　　　　僵尸等的数量　……　众多"""

@export_range(10.0, 300.0, 5.0) var scroll_speed: float = 40.0  ## 上滚速度（px/s）

var _label: Label
var _music: AudioStreamPlayer
var _external_ending: CampaignEnding = null  ## 承接 CampaignEnding 的连续 BGM
var _started: bool = false
var _finished: bool = false
var _armed: bool = false


func _ready() -> void:
	var black: ColorRect = ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(black)

	_label = Label.new()
	_label.text = credits_text.replace(STATS_PLACEHOLDER, _build_stats_block())
	# 字体/阴影走全局（ark-pixel 固定色规范）
	var g: Node = get_node_or_null("/root/Global")
	if g and g.has_method("get_text_font"):
		_label.add_theme_font_override("font", g.get_text_font(24))
		_label.add_theme_font_size_override("font_size", 24)
	if g and g.has_method("apply_text_shadow"):
		g.apply_text_shadow(_label)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_label)
	# 布局：先强制排版拿到高度，再放到屏幕底部
	# （CanvasLayer 不是 CanvasItem，没有 get_viewport_rect()——走 viewport 实例取）
	_label.reset_size()
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	_label.position = Vector2(0.0, vp_size.y)
	_label.size.x = vp_size.x

	# ED 音乐：优先接 CampaignEnding 的连续 BGM（对话段已在播）；没有才自播
	_external_ending = _find_external_ending()
	if _external_ending == null or not _external_ending.is_ending_music_playing():
		_external_ending = null
		if ResourceLoader.exists(ED_MUSIC_PATH):
			_music = AudioStreamPlayer.new()
			_music.stream = load(ED_MUSIC_PATH)
			_music.bus = "Music"
			add_child(_music)
			_music.play()
	else:
		## 已接管连续 BGM = credits 正常起来了：解除 CampaignEnding 的 30s 保险丝，
		## 否则滚动超过 30 秒时 BGM 会被保险丝半路掐断（名单全程远超 30s，实测教训）。
		_external_ending.notify_credits_attached()

	# 0.5s 输入防误触（上一场景的确定键残留）
	get_tree().create_timer(0.5).timeout.connect(func(): _armed = true)


func _process(delta: float) -> void:
	if _finished:
		return
	_label.position.y -= scroll_speed * delta
	# 滚完（文本底部离开屏幕顶部）→ 结束
	if _label.position.y + _label.size.y < -8.0:
		_finish()


func _unhandled_input(event: InputEvent) -> void:
	if not _armed or _finished:
		return
	for action: String in SKIP_ACTIONS:
		if event.is_action_pressed(action):
			get_viewport().set_input_as_handled()
			_finish()
			return


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _external_ending and is_instance_valid(_external_ending):
		_external_ending.stop_ending_music()  ## 收连续 BGM 并撤掉它手上的黑幕层
	if _music:
		_music.stop()
	# 回标题
	get_tree().change_scene_to_file.call_deferred(TITLE_SCENE)


func _find_external_ending() -> CampaignEnding:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	for child: Node in tree.root.get_children():
		if child is CampaignEnding:
			return child as CampaignEnding
	return null


# ═══════════════════════════════════════
# 幸存者战报（L4D2 式排名段，2026-09-14）
# ═══════════════════════════════════════

func _build_stats_block() -> String:
	## 按战役累计统计生成排名段；无任何战役数据（如编辑器直跑本场景）返回空串。
	var stats_node: Node = get_node_or_null("/root/ChapterStats")
	var players: Node = get_node_or_null("/root/Players")
	if stats_node == null or players == null:
		return ""
	if not stats_node.has_method("get_campaign_totals"):
		return ""
	var total: Dictionary = stats_node.get_campaign_totals()
	if int(total.get("kills", 0)) <= 0:
		return ""  ## 一场都没打过 → 不显示战报

	# 收集每个座位：显示名 + 战役统计
	var g: Node = get_node_or_null("/root/Global")
	var names: Array[String] = []
	var per_seat: Array[Dictionary] = []
	for i: int in players.seat_count():
		var st: PlayerState = players.get_seat(i)
		if st == null or st.character == null:
			continue
		var jp: String = st.character.character_name
		var display: String = jp
		if g and g.get("CHARACTER_NAME_ZH") is Dictionary:
			display = (g.CHARACTER_NAME_ZH as Dictionary).get(jp, jp)
		if display in names:
			continue  ## 双持/重复座位只算一次
		names.append(display)
		per_seat.append({
			"name": display,
			"stats": stats_node.get_campaign_stats_for_seat(i) \
					if stats_node.has_method("get_campaign_stats_for_seat") else {},
			"alive": st.is_alive(),
		})
	if per_seat.is_empty():
		return ""

	var lines: Array[String] = []
	lines.append("　　[幸存者战报]")
	lines.append("")
	## 排名条目：label → 统计键 → 单位（空 = 不带括号数值）
	var rank_defs: Array = [
		["击杀最多的", "kills", " 人"],
		["爆头最多的", "headshots", " 人"],
		["输出伤害最多的", "damage_dealt", ""],
		["承受伤害最多的", "damage_taken", ""],
		["用掉医疗品最多的", "healing_items", " 次"],
		["死了最多次的", "deaths", " 次"],
	]
	for def: Array in rank_defs:
		var best: Dictionary = _pick_top(per_seat, def[1])
		if best.is_empty():
			continue
		if def[1] == "deaths" and int(best.get("value", 0)) <= 0:
			continue  ## 没人死过就不放这一条
		var value_text: String = str(roundi(float(best.get("value", 0)))) + String(def[2])
		lines.append("　　%s：%s（%s）" % [def[0], best.get("name", "?"), value_text])

	## 最终生死状态（L4D2 名单惯例：谁活着走到了终点）
	var survivors: Array[String] = []
	var fallen: Array[String] = []
	for entry: Dictionary in per_seat:
		if bool(entry.get("alive", false)):
			survivors.append(String(entry.get("name", "?")))
		else:
			fallen.append(String(entry.get("name", "?")))
	if not survivors.is_empty():
		lines.append("　　活着走到终点的：%s" % "、".join(survivors))
	if not fallen.is_empty():
		lines.append("　　没能走到终点的：%s" % "、".join(fallen))
	lines.append("")
	return "\n".join(lines)


func _pick_top(per_seat: Array[Dictionary], key: String) -> Dictionary:
	## 在座位统计里取 key 值最高者。全 0 视为并列（返回空 = 该排名不展示）。
	var best: Dictionary = {}
	var best_value: float = -1.0
	for entry: Dictionary in per_seat:
		var stats: Dictionary = entry.get("stats", {}) as Dictionary
		var value: float = float(stats.get(key, 0.0))
		if value > best_value:
			best_value = value
			best = {"name": entry.get("name", "?"), "value": value}
	if best_value <= 0.0:
		return {}
	return best
