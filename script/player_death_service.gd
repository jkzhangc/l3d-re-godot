extends RefCounted

## ── 架构定位 ──
## 系统：玩家死亡系统 + 武器丢弃 ｜ 层：服务类（RefCounted，由 player 持有）
## 联机：Host 权威裁决（联机死亡先走倒地表现，生死由 NetworkWorld 决定）；丢弃武器联机走 Host 事务
## 职责：死亡流程（オートスプレー自动复活 → 切人 → 真死：停状态机/切躺地帧/禁用碰撞/黑屏遮罩/
##       重载 checkpoint）、尸检与队伍诊断日志、E 键丢弃全部武器（单机本地 / 联机请求 Host）。
## 依赖：player 实体（读写死亡标志与外观）、Players、Global
##
## 【为什么从 player.gd 抽出（2026-10-08）】死亡系统 + 丢弃武器约 360 行，是独立闭环的
## 生命周期逻辑。抽出后 player.gd 保留**同名转发门面**，外部调用点（EnemySwallowState /
## CharacterSwitchManager / 测试）零改动。
##
## 【状态变量为何留在 player】`_is_dying` / `_death_phase` / `_death_fade_timer` /
## `_death_fade_overlay` / `_recent_damage_sources` / `_switch_on_death_attempted` /
## `network_downed` **全部保留在 player.gd** —— 这些「死亡状态标志」被 director /
## intensity_tracker / player_nameplate / character_switch_manager / NetworkWorld 等
## 当字段直接读写，绝不能迁入 RefCounted 服务。本服务只搬「逻辑」，经 `_p.<字段>` 读写。
##
## 【帧常量真源】切躺地帧用到的 FRAME_W 等改从 player_sprite_renderer.gd 引用。
const Sprite := preload("res://script/player_sprite_renderer.gd")
## 武器拾取物脚本（静态工具：drop_weapon_for_player / mark_auto_picked）。
const WEAPON_PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")

## 宿主 player 实体。
var _p: Node = null


func _init(player: Node) -> void:
	_p = player


# ═══════════════════════════════════════
# 死亡系统
# ═══════════════════════════════════════

## 尝试在死亡时切换到其他存活队员
func _try_switch_on_death() -> bool:
	if _p._switch_on_death_attempted:
		return false
	_p._switch_on_death_attempted = true
	var mgr: Node = null
	var tree: SceneTree = _p.get_tree()
	if tree:
		var nodes: Array[Node] = tree.get_nodes_in_group("character_switch_manager")
		if nodes.size() > 0:
			mgr = nodes[0]
	if not mgr:
		return false
	# 把本实体对应座位标记为死亡（否则 next_living_seat 还会把它算作存活）
	var state: PlayerState = Players.get_state_for_entity(_p)
	if state:
		state.current_hp = 0.0
	# 尝试切换
	var switched: bool = mgr.switch_after_death()
	if switched:
		print("[玩家] 死亡→切换到下一队员")
	return switched


func _clean_expired_damage_sources(now: int) -> void:
	## 清理超过冷却时间的伤害源记录，防止字典无限增长
	var to_erase: Array[int] = []
	for sid: int in _p._recent_damage_sources:
		if now - _p._recent_damage_sources[sid] >= _p.DAMAGE_SOURCE_COOLDOWN_MSEC:
			to_erase.append(sid)
	for sid: int in to_erase:
		_p._recent_damage_sources.erase(sid)


func _apply_network_death_state() -> void:
	print("[玩家] 联机死亡表现")
	# 【倒地与死亡共用同一套躺地表现】
	# HP=0 后本节点一律先进入这个状态：停动画、切躺地精灵、关碰撞与受击区。
	# 之后它究竟是"倒地（可救援、可爬行）"还是"真死亡"，由 NetworkWorld 的
	# Host 权威状态决定 —— 倒地时 NetworkWorld 会在下一帧通过
	# set_network_downed(true) 重新打开移动碰撞并染红；真死亡则维持本状态。
	# 本函数自己不做任何生死裁决，也不能在 deferred 关闭之外再碰碰撞体。
	_p._is_dying = true
	_p._death_phase = 3
	_p._moving = false
	# 冻结远端实体，避免延迟快照把死亡表现继续向旧目标位置拖动。
	_p._network_target_position = _p.global_position
	_p._network_has_target = false
	_p.player_in_weapon_state = false
	_p.velocity = Vector2.ZERO
	_p._weapon_mode = false
	_p._weapon_data = null
	_p.apply_network_throwable_presentation(null, false, false, 0)
	_p._shove_mode = false
	_p._shove_texture = null
	if _p.animation_timer:
		_p.animation_timer.stop()
	var tex: Texture2D = _p.death_texture if _p.death_texture else _p.walk_texture
	if tex:
		_p.sprite.texture = tex
		var char_col: int = _p.death_char_index % Sprite.CHARS_PER_ROW
		var char_row: int = _p.death_char_index / Sprite.CHARS_PER_ROW
		var dir_row: int = Sprite.DIR_ROWS[_p._facing]
		_p.sprite.region_rect = Rect2(char_col * (Sprite.FRAME_W * 3) + Sprite.STAND_FRAME * Sprite.FRAME_W, char_row * (Sprite.FRAME_H * Sprite.DIRECTIONS) + dir_row * Sprite.FRAME_H, Sprite.FRAME_W, Sprite.FRAME_H)
	var cs: CollisionShape2D = _p.get_node_or_null("CollisionShape2D")
	if cs:
		cs.set_deferred("disabled", true)
	## 真死亡的尸体同样不该阻挡别人：上面虽已整体禁用碰撞体，这里再加一道保险 ——
	## 即使某条路径把 shape 又打开，敌人/队友也检测不到尸体（layer 归零）。
	_p._set_body_collision_layer(0)
	if _p.hurt_area:
		_p.hurt_area.set_deferred("monitoring", false)
		_p.hurt_area.set_deferred("monitorable", false)


## 强制致死（无视 ガッツ / 见切 / 无敌帧）。
##
## 用途：丸呑み（ハンターγ）这类原作明确定为「伤害是致死」的必杀技。
## 常规 take_damage 路径会被 ガッツ（HP≥2 保底 1 HP）拦下，无法表达"必死"语义，
## 因此单独开一个入口，直接归零 HP 并走 _die()（保留切人 / オートスプレー 的判定链）。
##
## source_id 仅用于日志与去重记录，不参与判定。
func force_lethal_death(source_id: int = 0) -> void:
	if _p._is_dying:
		return
	print("[玩家] 强制致死（source_id=%d）" % source_id)
	var state: PlayerState = Players.get_state_for_entity(_p)
	if state:
		state.current_hp = 0.0
	_p.current_hp = 0.0
	_die()


## 施加额外的武器削り（弹药/耐久）。供外部必杀技（丸呑み「多段削りで武器も駄目に」）调用。
## extra 为额外削减量：远程扣弹夹，近战扣耐久（0 或负值 = 无动作）。
func apply_weapon_attrition(extra: float = 0.0) -> void:
	if extra <= 0.0:
		return
	# 复用内置削り（每次固定量），再按 extra 追加一轮
	var rounds: int = maxi(1, int(ceilf(extra / maxf(1.0, _p.ATTRITION_DURABILITY))))
	for i: int in rounds:
		_p._apply_attrition()
	print("[玩家] 丸呑み多段削り：武器削减 %d 轮" % rounds)


func _die() -> void:
	BurnEffect.detach(_p)  ## 死亡不留火焰（_update_burn_status 死态早退不摘，在此统一摘）
	if _p.network_controlled:
		# D2 实测修复：联机此前直接进躺地/死亡流程，オートスプレー（HP=0 自动喷雾
		# 满血复活）永远不会触发——表现为「空血条后急救喷雾没起作用」。原作语义
		# 喷雾在 HP=0 拦截，成功则满血继续（HP 经快照 40Hz 同步到 Client 表现）；
		# 无喷雾才落进倒地/真死亡裁决。
		if _try_auto_spray_revive():
			# 伤害信号已在本帧把 entry["downed"] 置 true（先于 _die），必须清除。
			var world: Node = _p.get_tree().current_scene.find_child("NetworkWorld", true, false) \
					if _p.get_tree() and _p.get_tree().current_scene else null
			if world and world.has_method("notify_player_revived"):
				world.call("notify_player_revived", _p)
			return
		_apply_network_death_state()
		return
	# ── オートスプレー（原作 system.html）：HP=0 时自动使用急救喷雾 → 满血复活 ──
	# （2026-09-13 用户定稿：**当前角色**直接用喷雾复活，不再"有队友先切人"——
	#   旧顺序先切人，导致只有最后一个角色才轮得到喷雾）
	if _try_auto_spray_revive():
		return
	# 没有喷雾 → 有其他存活队员才切换，否则真死
	if _try_switch_on_death():
		return
	print("[玩家] 死亡！")
	_p._is_dying = true
	_p._death_phase = 0

	# 播放死亡音效
	_p._play_sound(_p.death_sound)

	# 更新本实体对应座位的 HP。
	var state: PlayerState = Players.get_state_for_entity(_p)
	if state:
		state.current_hp = 0.0
		# 真死亡计入战役累计（终章 ED「谁死了最多」排名用）
		var chapter_stats: Node = _p.get_node_or_null("/root/ChapterStats")
		if chapter_stats and chapter_stats.has_method("record_death"):
			chapter_stats.record_death(state.seat_index)

	# 停止状态机
	var sm: Node = _p.get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)

	# 停止移动 & 动画（防止 timer 回调 _refresh_sprite 覆盖死亡帧）
	_p._moving = false
	_p.player_in_weapon_state = false
	_p.velocity = Vector2.ZERO
	_p._weapon_mode = false
	_p._shove_mode = false
	_p._shove_texture = null
	if _p.animation_timer:
		_p.animation_timer.stop()

	# 显示死亡精灵
	var tex: Texture2D = _p.death_texture if _p.death_texture else _p.walk_texture
	if tex:
		_p.sprite.texture = tex
		var char_col: int = _p.death_char_index % Sprite.CHARS_PER_ROW
		var char_row: int = _p.death_char_index / Sprite.CHARS_PER_ROW
		var dir_row: int = Sprite.DIR_ROWS[_p._facing]
		var x: int = char_col * (Sprite.FRAME_W * 3) + Sprite.STAND_FRAME * Sprite.FRAME_W
		var y: int = char_row * (Sprite.FRAME_H * Sprite.DIRECTIONS) + dir_row * Sprite.FRAME_H
		_p.sprite.region_rect = Rect2(x, y, Sprite.FRAME_W, Sprite.FRAME_H)

	# 禁用碰撞
	var cs: CollisionShape2D = _p.get_node_or_null("CollisionShape2D")
	if cs:
		cs.set_deferred("disabled", true)
	# 禁用受击碰撞体
	if _p.hurt_area:
		_p.hurt_area.set_deferred("monitoring", false)
		_p.hurt_area.set_deferred("monitorable", false)

	# 播放死亡音乐
	if not Global.death_music_path.is_empty():
		var music: AudioStream = load(Global.death_music_path) as AudioStream
		if music:
			_p._play_music(music)

	# 创建黑屏遮罩
	_create_fade_overlay()


func _create_fade_overlay() -> void:
	# CanvasLayer 确保 Control 节点能在 2D 场景之上渲染
	var cl := CanvasLayer.new()
	cl.name = "DeathFadeCanvas"
	cl.layer = 128  # 最顶层

	_p._death_fade_overlay = ColorRect.new()
	_p._death_fade_overlay.name = "DeathFadeOverlay"
	_p._death_fade_overlay.color = Color(0, 0, 0, 0)  # 初始透明
	_p._death_fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_p._death_fade_overlay.size = _p.get_viewport().get_visible_rect().size

	cl.add_child(_p._death_fade_overlay)

	var tree: SceneTree = _p.get_tree()
	if tree and tree.current_scene:
		tree.current_scene.add_child(cl)
		_p._death_fade_timer = 0.0
		_p._death_phase = 1


## オートスプレー（原作 §4）：HP=0 时自动消耗急救喷雾（单机=共用池；联机=**自己那一格**），
## 满血复活。返回 true = 已复活，跳过死亡流程。
## ⚠ 联机「只用自己那一格」（2026-09-24 用户定稿）：自己没有喷雾就不再自动复活，
##   直接进入倒地/死亡裁决（等队友救援）—— 不再借队友的喷雾。
func _try_auto_spray_revive() -> bool:
	var own: PlayerState = Players.get_state_for_entity(_p)
	# 消耗规则统一走 Players.consume_spray_for（单机共用池 / 联机只用自己那一格），
	# 与联机 Host 权威侧（network_world._try_host_use_healing）共用同一条规则。
	var used: ItemData = Players.consume_spray_for(own)
	if not used:
		return false
	_p.current_hp = _p.max_hp
	if own:
		own.current_hp = _p.current_hp
	_p._play_hit_feedback(Color(1.6, 2.0, 1.6, 1.0), 0.4)
	print("[自动喷雾] HP=0 → 自动使用急救喷雾（%s），满血复活（队伍剩余 %d）" % [
		used.item_id, Players.spray_total()])
	return true


## 全队共用喷雾总数（HUD 显示与日志用）。
func _team_spray_total() -> int:
	return Players.spray_total()


func _process_death(delta: float) -> void:
	match _p._death_phase:
		1:  # 渐黑
			_p._death_fade_timer += delta
			var progress: float = clampf(_p._death_fade_timer / Global.death_fade_duration, 0.0, 1.0)
			if _p._death_fade_overlay:
				_p._death_fade_overlay.color = Color(0, 0, 0, progress)
			if progress >= 1.0:
				_p._death_fade_timer = 0.0
				_p._death_phase = 2
				print("[玩家] 黑屏完成，等待重载...")

		2:  # 全黑等待
			_p._death_fade_timer += delta
			if _p._death_fade_timer >= Global.death_black_hold:
				_p._death_phase = 3
				_reload_from_save()

		3:  # 已触发重载，等待
			pass


func _reload_from_save() -> void:
	# 死亡后从 checkpoint 恢复所有状态（HP/装备/弹药/队伍），再回到安全屋。
	## ⚠ 2026-09-16 修复「复活多次后队伍从 3 人缩到 1 人」：
	## 旧实现在恢复后立刻 Global.checkpoint.clear()。若玩家在「再次抵达安全屋捕获新快照」之前
	## 又死一次，restore_checkpoint() 就只剩「无 checkpoint，保持当前状态」分支 —— 把上次死亡
	## 留下的「某角色 HP=0」原样保留，于是每死一次就永久少一个可操控角色（测试者实测）。
	## checkpoint 只在「新游戏 / 选角确认」时清除（init_new_game / _confirm_team），
	## 安全屋每次到位都会重新 capture 覆盖 —— 因此这里必须保留它作为复活锚点。
	print("[玩家] 死亡，从 checkpoint 恢复...")
	var safehouse: String = Global.get_checkpoint_scene()
	Global.restore_checkpoint()
	_log_team_state("死亡复活后")
	var tree: SceneTree = _p.get_tree()
	if not tree:
		return
	if not safehouse.is_empty() and safehouse != tree.current_scene.scene_file_path:
		# 不在安全屋 → 切回安全屋场景
		var err := tree.change_scene_to_file(safehouse)
		if err != OK:
			printerr("[玩家] 无法切回安全屋: %s (err=%d)" % [safehouse, err])
			tree.reload_current_scene()
	else:
		# 已在安全屋死亡 → 直接重载
		tree.reload_current_scene()


## 复活/队伍诊断（2026-09-16）：逐席位打印「角色 + HP」，
## 用于定位「选了 N 人却只剩 1 人可操控」这类队伍缩水问题（配合 [Checkpoint] 日志一起看）。
func _log_team_state(tag: String) -> void:
	var parts: Array[String] = []
	for i: int in range(Players.seat_count()):
		var st: PlayerState = Players.get_seat(i)
		if st and st.character:
			parts.append("席位%d=%s HP=%.0f" % [i, st.character.resource_path.get_file(), st.current_hp])
		elif st:
			parts.append("席位%d=<无角色> HP=%.0f" % [i, st.current_hp])
		else:
			parts.append("席位%d=<空>" % i)
	print("[玩家] %s 队伍=%d 人 | %s" % [tag, Players.seat_count(), " ".join(parts)])


# ═══════════════════════════════════════
# 丢弃全部武器（E 键，2026-09-16 用户需求）
# ═══════════════════════════════════════

## E 键入口：单机本地丢弃；联机交给 Host 权威事务（Client 只提交意图，等快照回包）。
func request_drop_all_weapons() -> void:
	if _p._is_dying or _p.network_downed:
		return
	var scene: Node = _p.get_tree().current_scene
	var world: Node = scene.find_child("NetworkWorld", true, false) if scene else null
	var net: Node = _p.get_node_or_null("/root/Net")
	var online: bool = net != null and net.has_method("is_online_session") and bool(net.is_online_session())
	if online and world and world.has_method("request_drop_all"):
		## 丢弃即视为一次拾取：置位闩锁，避免 Client 端本地判定把刚脱手的武器又请求回来
		## （2026-09-23 用户反馈：丢下的武器被自己立刻捡回）。
		WEAPON_PICKUP_SCRIPT.mark_auto_picked(_p.get_tree(), _p)
		world.call("request_drop_all")
		return
	_drop_all_weapons_locally()


## 单机：两个武器槽全部丢到地上（落点自动避让 24px，见 weapon_pickup.find_free_drop_position）。
func _drop_all_weapons_locally() -> void:
	var state: PlayerState = Players.get_state_for_entity(_p)
	if not state:
		return
	var dropped: int = 0
	for slot: String in ["primary", "secondary"]:
		var wd: WeaponData = state.get_equipped_weapon(slot)
		if wd == null:
			continue
		WEAPON_PICKUP_SCRIPT.drop_weapon_for_player(_p, wd)
		state.unequip_slot(slot)
		dropped += 1
	if dropped == 0:
		return
	## 丢弃即视为一次拾取：置位自动拾取闩锁 —— 否则刚脱手的武器（落点在脚下附近）
	## 会被自己的自动拾取立刻捡回一件（2026-09-23 用户反馈）。走开即重新武装。
	WEAPON_PICKUP_SCRIPT.mark_auto_picked(_p.get_tree(), _p)
	## 手里空了 → 收起武器模式（状态机在 _wd == null 时会自愈回 Idle）
	if _p.is_weapon_mode_active():
		_p.exit_weapon_mode()
	print("[玩家] 丢弃全部武器：%d 件" % dropped)
