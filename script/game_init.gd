extends Node

## ── 架构定位 ──
## 系统：启动装配 ｜ 层：单例（关卡场景根节点脚本）
## 联机：联机会话改走 NetworkWorld 分支
## 职责：关卡载入时的总装配器：加载/初始化存档、应用待生效到达点、必要时创建 NetworkWorld，并挂载角色切换管理器。
## 依赖：Global、Net、Players、CharacterSwitchManager

## 游戏启动器 — 场景加载时初始化玩家数据 + 创建 CharacterSwitchManager

func _ready() -> void:
	## 触摸操作层已改为**全局创建**（2026-09-29，见 `Global._setup_touch_controls`）：
	## 原先挂在这里 → 标题画面 / 角色选择等**非地图场景**没有按钮，手机卡死在标题画面。
	## 安全屋台词（2026-09-28）：进入安全屋 / 章节总结结束后随机说 1~2 句。
	## 纯本地表现（各端显示自己角色的台词），不暂停游戏；延后一帧等场景节点就绪。
	call_deferred("_spawn_safehouse_dialogue")
	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("is_online_session") and net.is_online_session():
		# D2 实测修复：联机此前直接 return，跳过 _align_actor_layers —— 预置玩家留在
		# DecorLayer/PlayerSpawn 中间层，NetworkWorld 的动态玩家也跟着挂进去；
		# y_sort 只能按 PlayerSpawn 的固定 y 排序整队 → 丧尸层级永远盖过联机玩家。
		# deferred 先入队先执行：必须先于 _start_network_world 内部的 deferred 建世界，
		# 这样 NetworkWorld._find_players_parent() 拿到的就是 DecorLayer。
		call_deferred("_align_actor_layers")
		_start_network_world()
		## ★两端都要应用本图 DirectorConfig（2026-09-26）：Director._process 在
		## 联机**客户端**整体早退，配置从来不会被应用 → current_config 恒为 null →
		## A6 广播来的尸潮/Boss BGM 在客户端是 no-op，夜晚视界也不生效。
		## 音源只在本机解析，资源不经网络（白名单铁律）。
		var director: Node = get_node_or_null("/root/Director")
		if director and director.has_method("refresh_scene_config"):
			director.call("refresh_scene_config")
		## ★联机章节计时（09-27 实测修复）：本分支此前直接 return，跳过了 ChapterStats
		## 初始化 → started_msec 恒 0 → 章节总结的「用时」主机与客户端都显示 00:00。
		## 安全屋沿用单机口径（不重置章节计时）；其余场景两端各起一份本地计时（误差 <1s，
		## 结算只读本端值，无需额外同步）。
		if get_tree() and get_tree().current_scene:
			var mp_path: String = get_tree().current_scene.scene_file_path
			if not ("安全屋" in mp_path or "safe" in mp_path.to_lower()):
				var mp_stats: Node = get_node_or_null("/root/ChapterStats")
				if mp_stats and mp_stats.has_method("ensure_chapter"):
					mp_stats.ensure_chapter(mp_path)
		return

	Global.try_load_or_init()
	_apply_pending_arrival()
	# ★读档进图：补一次死亡锚点（checkpoint 是内存态，读档时为空的，见 Global.load_from_slot）
	if Global.consume_pending_checkpoint_capture():
		Global.capture_checkpoint()
		print("[GameInit] 读档进图：已建立死亡锚点")
	# 安全屋场景加载时自动存档（确保死亡后回到这里时的状态一致）
	if get_tree() and get_tree().current_scene:
		var scene_path: String = get_tree().current_scene.scene_file_path
		if "安全屋" in scene_path or "safe" in scene_path.to_lower():
			Global.capture_checkpoint()
			print("[GameInit] 安全屋自动存档: %s" % scene_path)
		else:
			var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
			if chapter_stats and chapter_stats.has_method("ensure_chapter"):
				chapter_stats.ensure_chapter(scene_path)
	var state: PlayerState = Players.get_active_state()
	print("[GameInit] 初始化完成 | debug=%s | HP=%.0f | team=%d | checkpoint=%s" % [
		Global.debug_enabled, state.current_hp, Global.get_team_size(),
		"有" if not Global.checkpoint.is_empty() else "无"
	])
	_spawn_switch_manager()
	# 预构建 A* 寻路网格（延迟到本帧节点就绪后），
	# 避免首个敌人追击时才同步创建 AStarGrid2D 造成卡顿
	call_deferred("_prebuild_astar")
	# 玩家与敌人必须在同一个 y 排序容器里，两者之间的遮挡才正确（见 _align_actor_layers）
	call_deferred("_align_actor_layers")


func _apply_pending_arrival() -> void:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var arrival := Global.consume_pending_arrival(tree.current_scene.scene_file_path)
	if arrival.is_empty():
		return
	var arrival_id: String = str(arrival.get("id", ""))
	var arrival_position: Variant = ArrivalResolver.resolve(
		tree.current_scene, arrival_id, arrival.get("position")
	)
	if not arrival_position is Vector2:
		return
	## ★防卡死兜底（2026-10-05）：落点若压在存档点的 32×32 实体碰撞里（旧档存的正是
	## 存档点中心），先移出存档点矩形；再走 SpawnSpotResolver 避墙。新档存的是玩家站位，
	## 通常直接返回原坐标。详见 _resolve_safe_arrival。
	var safe_position: Vector2 = _resolve_safe_arrival(tree.current_scene as Node2D, arrival_position as Vector2)
	var player := _find_preplaced_player(tree.current_scene)
	if not player:
		push_warning("[GameInit] 找不到预置 Player，无法应用入口 ID: %s" % arrival_id)
		return
	player.global_position = safe_position
	print("[GameInit] 已应用入口 ID=%s position=%s" % [arrival_id, player.global_position])


## 取本场景**预置**的玩家实体（到达/读档落点要写它的 global_position）。
##
## ★2026-10-04 实测修复：**不能只靠 "player" 分组**。
## GameInit 是场景根（Test2）的**第一个子节点**；Godot 的 `_ready()` 按子节点顺序
## 深度优先传播 → 本节点的 `_ready()` **早于** `DecorLayer/PlayerSpawn/Player` 的
## `_ready()`。而玩家是在**自己的** `_ready()` 里 `add_to_group("player")` 的 →
## 此刻分组恒为空 → 落点应用失败，并误报「找不到预置 Player」把玩家打断。
## （同一根因也影响单机地图传送：teleport_point 走的也是 `set_pending_arrival`。）
##
## 因此：先按分组找（运行时/联机的正常路径），找不到再退回**地图约定路径**
## 「PlayerSpawn 下的 Player 节点」——所有地图的预置玩家都是这个名字。
func _find_preplaced_player(scene: Node) -> CharacterBody2D:
	for node: Node in scene.get_tree().get_nodes_in_group("player"):
		if node is CharacterBody2D:
			return node as CharacterBody2D
	## 兜底：场景内名为 "Player" 的 CharacterBody2D（不含 PlayerSpawn —— find_child 是精确匹配）。
	if scene != null:
		var preplaced: Node = scene.find_child("Player", true, false)
		if preplaced is CharacterBody2D:
			return preplaced as CharacterBody2D
	return null


## ── 读档 / 传送落点防卡死（2026-10-05 用户反馈）──
## 存档点实体碰撞 32×32 → 半宽 16；玩家碰撞盒 24×27 → 半宽 12 / 半高 14（与 player.tscn 同口径）。
const SAVE_POINT_HALF: float = 16.0
const ARRIVAL_PLAYER_HALF: Vector2 = Vector2(12.0, 14.0)
const ARRIVAL_PUSH_MARGIN: float = 4.0


## 把落点从「存档点碰撞矩形」内移出去（旧档恰存存档点中心、无方向 → 固定下移到下沿外侧），
## 再交给 SpawnSpotResolver 做泛化避墙（图块碰撞 + 物理体）。
##
## ★为什么用**节点几何**而不是物理探测：GameInit 是场景根的第一个子节点，此刻存档点的
## `_ready()/_ensure_collision()` 可能尚未跑、碰撞体也可能还没进物理空间 → 物理探测会
## 静默漏判。直接用存档点的导出字段（`global_position + collision_offset`）算矩形最稳。
func _resolve_safe_arrival(scene: Node2D, pos: Vector2) -> Vector2:
	var out: Vector2 = pos
	if scene != null and is_instance_valid(scene):
		var half: Vector2 = Vector2(SAVE_POINT_HALF, SAVE_POINT_HALF) + ARRIVAL_PLAYER_HALF
		for node: Node in scene.find_children("*", "Node2D", true, false):
			if not node is SavePoint:
				continue
			var sp := node as SavePoint
			var center: Vector2 = sp.global_position + sp.collision_offset
			if absf(out.x - center.x) <= half.x and absf(out.y - center.y) <= half.y:
				out = Vector2(center.x, center.y + half.y + ARRIVAL_PUSH_MARGIN)
	## 只在**确实触发了存档点兜底**时才走避墙（宁可不动正常落点）：
	## 新档存的是玩家站位、传送点落点是作者摆的可站点 —— 都没触发时原样返回，
	## 避免「泛化避墙」把既有传送落点悄悄挪位。
	if out.is_equal_approx(pos):
		return pos
	return SpawnSpotResolver.resolve(scene, out, true)


func _start_network_world() -> void:
	## 当前场景仍在执行 _ready()，直接 add_child 会被 Godot 拒绝；延后到下一帧创建。
	call_deferred("_create_network_world")


func _create_network_world() -> void:
	## Phase 1 联机只启用 Host 权威移动世界；跳过单机存档、队友切换和 Director 初始化。
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	if tree.current_scene.get_node_or_null("NetworkWorld"):
		return
	# 【回归专用】--net-test-host-scene-delay-ms=N：延迟创建 NetworkWorld，模拟
	# "Host 加载缓慢、Client 的 scene-ready 报告先于 Host 世界就绪到达"的竞态，
	# 配合 --net-test=slow-host-ready 使用；正式游戏绝不会带此参数。
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-host-scene-delay-ms="):
			var delay_sec := float(argument.trim_prefix("--net-test-host-scene-delay-ms=").to_int()) / 1000.0
			if delay_sec > 0.0:
				print("[GameInit] AUTO_SLOWHOST 模拟 Host 场景延迟 %.2fs" % delay_sec)
				await tree.create_timer(delay_sec).timeout
			break
	if not is_inside_tree() or not tree.current_scene:
		return
	## 仅当命令行含 `--net-test` 前缀参数（无头回归）时才加载 harness 子类；
	## 正式游戏路径始终使用生产脚本，绝不触碰回归脚手架。
	var world_script_path := "res://script/network_world.gd"
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test"):
			world_script_path = "res://script/net_regression_harness.gd"
			break
	var world: Node = (load(world_script_path) as GDScript).new()
	world.name = "NetworkWorld"
	tree.current_scene.add_child(world)
	print("[GameInit] 已进入 Phase 1 Host 权威联机世界")

## ── 安全屋台词（2026-09-28 用户需求）──
## 台词数据来自原作事件数据（见 `原作安全屋台词数据.md`），每张安全屋一张台词池。
## 触发：初始安全屋进图即说；**有章节总结的安全屋在总结关闭后**说（与到达音乐同一时机）。
## 联机：各端本地执行、显示**自己角色**的台词（中文名 + `CharacterData.portrait`），零 RPC。
const SAFEHOUSE_DIALOGUE_SCENE := preload("res://scene/ui/safehouse_dialogue.tscn")
const SAFEHOUSE_DIALOGUE_DATA := preload("res://script/safehouse_dialogue_data.gd")


func _spawn_safehouse_dialogue() -> void:
	## ★无头（headless）回归下**不创建**台词窗口：它靠「确定键」翻页并
	## `set_input_as_handled()`，会抢走自动化用例推进流程用的按键（安全门 / 结算页 
	## 都在等同一个键）→ 用例一直收不到确认而超时。真实游戏里按键属于玩家，照常显示。
	if DisplayServer.get_name() == "headless":
		return
	var tree: SceneTree = get_tree()
	if tree == null or tree.current_scene == null:
		return
	var key: String = SAFEHOUSE_DIALOGUE_DATA.key_for_scene(tree.current_scene.scene_file_path)
	if key.is_empty():
		return
	## ★已看过就不再重放（2026-10-05）：读档进安全屋时，若存档前已看过本图台词则跳过。
	if Global.has_seen_safehouse_dialogue(key):
		return
	## 总结页还开着就先等它关闭再说话（否则台词会被总结页盖住）。
	## ★时机只有一个：原作里 A 批（刚进安全屋）与 B 批（接着说）是**同一段对话的连续两页**，
	##   由窗口内部按确定键翻页完成，不再是两个独立的触发时机。
	var summary: Node = tree.current_scene.find_child("ChapterSummary", true, false)
	if summary != null and summary.visible and summary.has_signal("summary_finished"):
		summary.summary_finished.connect(
			func() -> void: _open_safehouse_dialogue(key), CONNECT_ONE_SHOT)
		return
	_open_safehouse_dialogue(key)


func _open_safehouse_dialogue(key: String) -> void:
	var tree: SceneTree = get_tree()
	if tree == null or tree.current_scene == null:
		return
	## ★台词归属到**当前操控角色**（原作把「谁说什么」写死在事件文本里）。
	## 联机各端各取自己的角色 —— 纯本地表现，零 RPC。
	var speaker: String = ""
	var char_id: String = ""
	var portrait: Texture2D = null
	var state: PlayerState = Players.get_active_state()
	if state != null and state.character != null:
		var jp: String = state.character.character_name
		## ★台词框用**短名**（原作口径：大雄 / 静香 / 小夫 / 胖虎）；
		## 全名版 CHARACTER_NAME_ZH 继续留给 ED 对话与 credits 战报。
		speaker = str(Global.CHARACTER_NAME_SHORT.get(
			jp, Global.CHARACTER_NAME_ZH.get(jp, jp)))
		char_id = state.character.get_character_key()
		portrait = state.character.portrait_texture()
	## ★一次给出全部**页**（A 批一屏 → 按确定键 → B 批一屏），每页内部的多行同屏显示。
	var pages: Array = SAFEHOUSE_DIALOGUE_DATA.pages_for(key, char_id)
	if pages.is_empty():
		return
	## ★只在「确实要显示」时标记已看过（角色无台词不记，避免误抑制后续正常台词）。
	Global.mark_safehouse_dialogue_seen(key)
	var dlg: Node = SAFEHOUSE_DIALOGUE_SCENE.instantiate()
	tree.current_scene.add_child(dlg)
	dlg.call("open_character", pages, speaker, portrait)
	print("[GameInit] 安全屋台词：%s（角色=%s，%d 页，说话人=%s，头像=%s）" % [
		key, char_id, pages.size(), speaker, "有" if portrait != null else "无"])


func _spawn_switch_manager() -> void:
	## 如果队伍 > 1人且场景中不存在，自动创建 CharacterSwitchManager
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var existing: Node = tree.current_scene.find_child("CharacterSwitchManager", true, false)
	if existing:
		return
	var script_path := "res://script/character_switch_manager.gd"
	if not ResourceLoader.exists(script_path):
		return
	var mgr_script: Script = load(script_path) as Script
	var mgr := Node.new()
	mgr.set_script(mgr_script)
	mgr.name = "CharacterSwitchManager"
	# 延迟添加，避免在场景初始化期间 add_child
	tree.current_scene.call_deferred("add_child", mgr)
	var log_cb: Callable = func(): print("[GameInit] CharacterSwitchManager 已创建 team=%d" % Global.get_team_size())
	log_cb.call_deferred()


func _prebuild_astar() -> void:
	## 场景树就绪后启动 A* 网格构建（一次性同步 update() 前移到加载阶段）
	EnemyChaseState.prebuild()


func _physics_process(_delta: float) -> void:
	## 每物理帧驱动 A* 网格分帧构建，敌人未追击时也能推进；闲置时开销可忽略
	EnemyChaseState.tick_build()


## ── 玩家与敌人的绘制层级对齐 ──
## 敌人由 Director 生成，父节点固定是名字含 "decor" 的 DecorLayer（两张图的 DecorLayer 都开了
## y_sort_enabled）。玩家却是场景里预摆的，且两张图的挂法不一致：
##   街道 = DecorLayer/PlayerSpawn/Player；学校内部 = PlayerSpawn/Player（挂在关卡根下）。
## 后者与敌人不在同一个 y 排序容器 → 整个玩家子树按根节点顺序画在敌人之后，
## 表现为「玩家永远盖住敌人 / 敌人永远钻到玩家底下」。这里在关卡就绪后把玩家
## reparent 到 DecorLayer，与敌人成为兄弟节点，参与同一轮 y 排序。
func _align_actor_layers() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var net: Node = get_node_or_null("/root/Net")
	var players: Array[Node] = tree.get_nodes_in_group("player")
	if players.is_empty():
		return
	var player := players[0] as Node2D
	if player == null or not is_instance_valid(player):
		return
	var decor := _find_decor_container(tree.root)
	if decor == null or player.get_parent() == decor:
		return
	var old_parent := player.get_parent()
	var gp: Vector2 = player.global_position
	player.get_parent().remove_child(player)
	decor.add_child(player)
	player.global_position = gp

	## ⚠ reparent（remove_child/add_child）的两个副作用，都必须手动补救：
	## ① 触发 player._exit_tree() → 从 Players 注册表注销，而 _ready 不会重跑 ——
	##    必须重新注册，否则 Director 的生成/回收、角色切换等全部失联
	##    （注册表虽有 group 兜底自愈，但显式重注册不依赖兜底时序）；
	## ② 发出 tree_exiting → PhantomCamera2D 把 _should_follow 关掉（见
	##    camera_follow.rebind_follow_target 的注释），镜头从此钉死在原地。
	if not player.get("network_controlled"):
		# 联机（D2 实测修复）：此刻 NetworkWorld 尚未创建（deferred 顺序保证 align 先行），
		# 预置玩家马上会被 Host/Client 初始化接管——座位注册与相机绑定都由
		# _register_host_player / _client_initialize_world 负责，这里跳过防重复注册。
		if not (net and net.has_method("is_online_session") and bool(net.is_online_session())):
			Players.register_entity(player)
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam and cam.has_method("rebind_follow_target"):
		# 相机 unbind 是 reparent 的副作用（tree_exiting），联机也要重绑：
		# 预置玩家仍是本地玩家本体，NetworkWorld 的 _set_local_player 会再绑一次（幂等）。
		cam.rebind_follow_target(player)

	print("[GameInit] 玩家已移入与敌人相同的 y 排序容器 %s（原父节点 %s，镜头与注册已重绑）" % [
		str(decor.get_path()), str(old_parent.get_path())])


func _find_decor_container(node: Node) -> Node:
	if node is Node2D and "decor" in node.name.to_lower():
		return node
	for child: Node in node.get_children():
		var found: Node = _find_decor_container(child)
		if found:
			return found
	return null
