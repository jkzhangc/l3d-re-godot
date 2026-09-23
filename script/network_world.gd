extends Node

## ── 架构定位 ──
## 系统：联机世界 ｜ 层：网络（Node，场景内）
## 联机：Host 全量权威模拟
## 职责：联机世界：Host 权威模拟移动/战斗/拾取/复活，Client 只提交输入并渲染快照；禁用 MultiplayerSpawner/Synchronizer。
## 依赖：Net、Players、PlayerState、敌人/子弹/掉落物实体、快照插值

## 第一阶段联机世界：Host 全量权威移动，客户端只提交输入并渲染快照。
##
## 禁止使用 MultiplayerSpawner / MultiplayerSynchronizer；所有实体均由可靠 RPC 显式
## spawn/despawn，位置快照通过 unreliable_ordered 广播。
##
## 【阅读地图 / 数据流】
## - _ready()、_process()：按 Host/Client 分支初始化，并调度输入、模拟、快照与定期重同步；
## - submit_input() 及 attack/reload/throw/pickup 等 request RPC：Client 只能提交“操作意图”；
## - _host_*：唯一会改变 HP、弹药、背包、敌人、子弹、掉落物与复活进度的权威模拟；
## - *_snapshot / spawn_* / despawn_* RPC：Host 将权威结果复制为 Client 的表现状态；
## - _try_host_pickup()：掉落物事务的唯一提交点，先验证距离/归属/槽位，再修改 PlayerState 并广播；
## - 安全门、场景 ready 与 _scene_transitioning：跨图期间关闭旧节点的通信窗口。
##
## 重要边界：Client 可以做本地镜头和动画预测，但不能决定伤害、资源路径、武器参数或库存。
## NetworkManager 管连接与跨图 PlayerState；本节点只管理“当前场景”的实体引用，换图后会被释放。

const PLAYER_SCENE: PackedScene = preload("res://object/player.tscn")
const BULLET_SCENE: PackedScene = preload("res://object/bullet.tscn")
const ENEMY_SCENE: PackedScene = preload("res://object/enemy.tscn")
const PICKUP_SCENE: PackedScene = preload("res://object/weapon_pickup.tscn")
## 武器拾取物脚本（静态工具：落点避让 find_free_drop_position 等）
const PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")
const HEALING_PICKUP_SCENE: PackedScene = preload("res://object/healing_pickup.tscn")
const NETWORK_PISTOL: WeaponData = preload("res://object/weapon_pistol.tres")
const NETWORK_KNIFE: WeaponData = preload("res://object/weapon_knife.tres")
const NETWORK_RIFLE: WeaponData = preload("res://object/weapon_rifle.tres")
const NETWORK_SMG: WeaponData = preload("res://object/weapon_smg.tres")
const NETWORK_SHOTGUN: WeaponData = preload("res://object/weapon_shotgun.tres")
const NETWORK_SNIPER: WeaponData = preload("res://object/weapon_sniper.tres")
const NETWORK_MAGNUM: WeaponData = preload("res://object/weapon_magnum.tres")
const NETWORK_LAUNCHER: WeaponData = preload("res://object/weapon_grenade_launcher.tres")
const NETWORK_ROCKET: WeaponData = preload("res://object/weapon_rocket_launcher.tres")
const NETWORK_BOWGUN: WeaponData = preload("res://object/weapon_bowgun.tres")
const NETWORK_LAUNCHER_ACID: WeaponData = preload("res://object/weapon_launcher_acid.tres")
const NETWORK_LAUNCHER_ICE: WeaponData = preload("res://object/weapon_launcher_ice.tres")
const NETWORK_LAUNCHER_THUNDER: WeaponData = preload("res://object/weapon_launcher_thunder.tres")
const NETWORK_FRYSPAN: WeaponData = preload("res://object/weapon_frypan.tres")
const NETWORK_BAT: WeaponData = preload("res://object/weapon_metal_bat.tres")
const NETWORK_GRENADE: ThrowableData = preload("res://object/item_grenade.tres")
const NETWORK_MOLOTOV: ThrowableData = preload("res://object/item_molotov.tres")
const NETWORK_FLASH: ThrowableData = preload("res://object/throwable_flash.tres")
## 治疗品白名单（D2 实测修复）：喷雾/药品此前不在联机同步范围——动态刷出的治疗品
## Client 看不见、预摆的 Client 本地私拿（Host 权威域无感知）→ 倒地时无喷雾可用。
const NETWORK_SPRAY: ItemData = preload("res://object/item_first_aid_spray.tres")
const NETWORK_PILLS: ItemData = preload("res://object/item_pills.tres")
const NETWORK_HEALINGS: Dictionary = {
	"first_aid_spray": NETWORK_SPRAY,
	"pills_01": NETWORK_PILLS,
}
## 联机武器必须从 Host 固定白名单解析，绝不根据客户端输入动态 load() 资源。
const NETWORK_WEAPONS: Dictionary = {
	"pistol_01": NETWORK_PISTOL,
	"knife_01": NETWORK_KNIFE,
	"rifle_01": NETWORK_RIFLE,
	"smg_01": NETWORK_SMG,
	"shotgun_01": NETWORK_SHOTGUN,
	"sniper_01": NETWORK_SNIPER,
	"magnum_01": NETWORK_MAGNUM,
	"launcher_01": NETWORK_LAUNCHER,
	"rocket_01": NETWORK_ROCKET,
	"bowgun_01": NETWORK_BOWGUN,
	"launcher_acid_01": NETWORK_LAUNCHER_ACID,
	"launcher_ice_01": NETWORK_LAUNCHER_ICE,
	"launcher_thunder_01": NETWORK_LAUNCHER_THUNDER,
	"frypan_01": NETWORK_FRYSPAN,
	"bat_01": NETWORK_BAT,
}
## 投掷物同样必须由 Host 的固定白名单解析；客户端 RPC 绝不能指定资源或伤害。
const NETWORK_THROWABLES: Dictionary = {
	"grenade_01": NETWORK_GRENADE,
	"molotov_01": NETWORK_MOLOTOV,
	"flash_01": NETWORK_FLASH,
}
## 特感（SpecialEnemyData）白名单：键 = tres 的 id 字段（StringName 转字符串）。
## Host 在 spawn_special_enemy 注入 enemy.special_data 后，spawn 快照携带
## special_id 下发；Client 命中白名单才在本地重建表现节点（外观/帧表/受击盒）。
## 与武器/投掷物同铁律：Client RPC 永远只传 id，资源只从本表解析。
const NETWORK_SPECIAL_GREEN: SpecialEnemyData = preload("res://tres/specials/グリーンソルジャー.tres")
const NETWORK_SPECIAL_TYRANT: SpecialEnemyData = preload("res://tres/specials/タイラントT002.tres")
const NETWORK_SPECIAL_HUNTER: SpecialEnemyData = preload("res://tres/specials/ハンター.tres")
const NETWORK_SPECIAL_HUNTER_BETA: SpecialEnemyData = preload("res://tres/specials/ハンターβ.tres")
const NETWORK_SPECIAL_HUNTER_GAMMA: SpecialEnemyData = preload("res://tres/specials/ハンターγ.tres")
const NETWORK_SPECIAL_WITCH: SpecialEnemyData = preload("res://tres/specials/ブレアウィッチ.tres")
const NETWORK_SPECIALDEMOS: SpecialEnemyData = preload("res://tres/specials/ブレインディモス.tres")
const NETWORK_SPECIALS: Dictionary = {
	"green_soldier": NETWORK_SPECIAL_GREEN,
	"tyrant_t002": NETWORK_SPECIAL_TYRANT,
	"hunter": NETWORK_SPECIAL_HUNTER,
	"hunter_beta": NETWORK_SPECIAL_HUNTER_BETA,
	"hunter_gamma": NETWORK_SPECIAL_HUNTER_GAMMA,
	"blare_witch": NETWORK_SPECIAL_WITCH,
	"brain_demos": NETWORK_SPECIALDEMOS,
}
## 僵尸变体白名单（A5）：键 = tres 的 id 字段。Host 在 spawn_enemy 按 zombie_pool
## 选种后登记 enemy.variant_data，spawn 快照携带 variant_id；Client 命中白名单
## 才在本地重建差异化行走图。狂暴换皮不走本表 —— 随快照 element_state bit3 实时同步。
const NETWORK_VARIANT_MALE: ZombieVariant = preload("res://tres/zombies/男性ゾンビ.tres")
const NETWORK_VARIANT_FEMALE: ZombieVariant = preload("res://tres/zombies/女性ゾンビ.tres")
const NETWORK_VARIANT_STUDENT: ZombieVariant = preload("res://tres/zombies/学生ゾンビ.tres")
const NETWORK_VARIANT_CHUNEN: ZombieVariant = preload("res://tres/zombies/中年ゾンビ.tres")
const NETWORK_VARIANT_SHIKAN: ZombieVariant = preload("res://tres/zombies/士官ゾンビ.tres")
const NETWORK_VARIANT_JOSHI: ZombieVariant = preload("res://tres/zombies/女子学生ゾンビ.tres")
const NETWORK_VARIANT_JIKKENTAI: ZombieVariant = preload("res://tres/zombies/実験体ゾンビ.tres")
const NETWORK_VARIANT_KENKYUIN: ZombieVariant = preload("res://tres/zombies/研究員ゾンビ.tres")
const NETWORK_VARIANT_SHOKUIN: ZombieVariant = preload("res://tres/zombies/職員ゾンビ.tres")
const NETWORK_VARIANT_KUNRENSEI: ZombieVariant = preload("res://tres/zombies/訓練生ゾンビ.tres")
const NETWORK_VARIANT_RUNNER: ZombieVariant = preload("res://enemys/疾走体.tres")
const NETWORK_VARIANT_TANK: ZombieVariant = preload("res://enemys/重装体.tres")
const NETWORK_VARIANTS: Dictionary = {
	"male": NETWORK_VARIANT_MALE,
	"female": NETWORK_VARIANT_FEMALE,
	"student": NETWORK_VARIANT_STUDENT,
	"chunen": NETWORK_VARIANT_CHUNEN,
	"shikan": NETWORK_VARIANT_SHIKAN,
	"joshi_gakusei": NETWORK_VARIANT_JOSHI,
	"jikkentai": NETWORK_VARIANT_JIKKENTAI,
	"kenkyuin": NETWORK_VARIANT_KENKYUIN,
	"shokuin": NETWORK_VARIANT_SHOKUIN,
	"kunrensei": NETWORK_VARIANT_KUNRENSEI,
	"runner": NETWORK_VARIANT_RUNNER,
	"tank": NETWORK_VARIANT_TANK,
}
## 快照节拍说明：
## - Host 每帧运行真实玩家、敌人、子弹和伤害逻辑。
## - Client 只提交输入，并接收 Host 的表现数据。
## - 玩家位置单独以 60Hz 发送；敌人位置与玩家表现合并为 40Hz 快照。
## - 高频快照使用 unreliable_ordered，因为旧位置没有保存价值；可靠快照只用于
##   首次进图、掉落物变化、实体列表收敛等结构性同步。
const SNAPSHOT_INTERVAL := 1.0 / 40.0
const PLAYER_SNAPSHOT_INTERVAL := 1.0 / 60.0
const LOCAL_INPUT_INTERVAL := 1.0 / 60.0
const RELIABLE_WORLD_RESYNC_INTERVAL := 2.0
const SPAWN_SEPARATION := 56.0

## 当前场景的玩家表：peer_id → {node, state, input, walking, moving, ...}。
## node 是临时场景节点；state 是 Host 的 PlayerState（跨图持久化副本在 Net 中），
## input 仅保存客户端最近一次意图，绝不可把它当作已验证的游戏结果。
var _players: Dictionary = {} # peer_id -> {node, state, input, walking, moving}
## 敌人表：Host 生成的稳定 entity_id → 当前场景节点及可重建资料。Client 只按 id 应用快照。
var _enemies: Dictionary = {} # entity_id -> {node, scene_path}
var _next_enemy_id := 1
## 已用可靠 RPC 广播过死亡的敌人 entity_id。紧凑快照会跳过尸体，死亡必须
## 主动广播，否则 Client 要等 2 秒一次的可靠重同步才看到尸体表现。
var _announced_dead_enemy_ids: Dictionary = {}
## 掉落物表：稳定 pickup_id → 武器或治疗/投掷物节点。所有拾取都必须由 Host 提交并广播变化，
## 这样多个 Client 同时按键也只会有一个获准拿到物品。
var _pickups: Dictionary = {} # pickup_id -> weapon/throwable pickup Node2D
var _next_pickup_id := 1
## 仅向已创建本场景 NetworkWorld 并报告 ready 的 Client 发送场景 RPC。
var _ready_client_peers: Dictionary = {}
## 客户端预置掉落物按场景相对路径缓存，可靠快照必须复用原节点，
## 否则主机删除后会留下未纳入 _pickups 的旧可见节点。
var _client_preplaced_pickups_by_path: Dictionary = {}

## 剧情机关 flag 是否已向 Host 拉取过全量（客户端首个世界快照后触发一次）
var _quest_flags_synced: bool = false
## 已确认安全门路径 -> true；Host 只跟踪最后一次有效确认的门，并权威统计到门人数。
var _safe_door_ready: Dictionary = {}
var _door_ready_status: Dictionary = {}
## 子弹表：稳定 bullet_id → 表现节点。命中和伤害由 Host 计算；Client 的同名节点只负责看见轨迹。
var _bullets: Dictionary = {} # bullet_id -> Bullet Node2D
var _next_bullet_id := 1
## 攻击冷却按「玩家 + Host 当前武器」独立记录，避免切换武器后互相影响。
var _last_attack_msec: Dictionary = {}
## Host 记录会锁定攻击输入的短时战斗动作（目前用于装填，单位为 Time.get_ticks_msec）。
var _combat_busy_until_msec: Dictionary = {}
## peer_id -> {"held": bool, "aiming": bool, "range": int}; Host 是唯一写入者。
var _network_throwable_state: Dictionary = {}
## reviver peer -> {"target": peer_id, "started_msec": int}; only Host advances or completes revives.
var _revive_attempts: Dictionary = {}
## peer_id -> "raising" / "lowering"; published so late snapshots never reset transition presentation.
var _weapon_transition_state: Dictionary = {}
## Client 尚未收到 Host 确认的朝向锁定意图：peer_id -> desired locked state。
var _facing_lock_requests: Dictionary = {}
const REVIVE_RANGE := 52.0
const REVIVE_DURATION_MSEC := 3000
const REVIVE_HP_RATIO := 0.30
## 倒地（L4D2 式 incapacitated）：HP=0 不再直接死亡，而是先倒地 —— 躺地表现、
## 仍可按 DOWNED_CRAWL_SPEED 爬行，流血池按 DOWNED_BLEED_RATE 每秒递减，
## 耗尽后才转为真死亡（不可再救）。数值推进只发生在 Host；Client 通过快照观察。
const DOWNED_BLEED_HP := 100.0
const DOWNED_BLEED_RATE := 5.0
const DOWNED_CRAWL_SPEED := 60.0
## 团灭：全员非站立（全部倒地或死亡）→ 广播黑屏，FADE+HOLD 秒后由 Host 复用
## 既有切图协议重载本章（会话 PlayerState 满血重置）。倒地/死亡不跨场景持久化。
const WIPE_FADE_SECONDS := 2.0
const WIPE_HOLD_SECONDS := 1.0
## 救援进度环脚本。Host 与 Client 各自驱动：Host 来自权威 attempts，
## Client 来自快照 revive_progress 字段；两条路径共用同一个挂载/摘除函数。
const REVIVE_INDICATOR_SCRIPT := preload("res://script/network_revive_indicator.gd")
## 头顶名牌（1P/2P 编号 + 昵称 + 正式 HUD 血条），联机玩家实体注册时挂载。
const NAMEPLATE_SCRIPT := preload("res://script/player_nameplate.gd")
var _wipe_active := false
var _wipe_started_msec := 0
var _wipe_restart_requested := false
var _wipe_fade_overlay: ColorRect = null
var _snapshot_accumulator := 0.0
var _player_snapshot_accumulator := 0.0
var _reliable_resync_accumulator := 0.0
var _input_accumulator := 0.0
var _scene_path := ""
var _players_parent: Node = null
var _camera_bound_local_node: Node2D = null
var _initial_world_received := false
## 本地预置玩家已被接管后即可发送输入和战斗请求；完整世界快照只负责补齐远端实体/掉落物。
var _client_local_ready := false
## 客户端长按连发的本地请求节流；Host 仍执行武器、弹药和射速的最终校验。
var _last_client_fire_request_msec := 0
## Net 在双方真正换图前发出的过渡信号；置位后本场景不再发送任何 RPC，避免旧节点路径的在途包。
var _scene_transitioning := false
var _last_logged_remote_input: Dictionary = {}
var _auto_client_fire_confirmed := false
var _auto_client_bullet_seen := false
## 自动双端回归统计本次攻击由 Host 确认并生成的视觉弹丸数量。
## 这会让单发步枪和多弹丸霰弹枪都能验证，而不是仅检查「至少看到一颗」。
var _auto_client_bullets_seen := 0
var _auto_client_attack_weapon_id := ""
## --net-test-features 专用：只统计 Client 收到的可靠受伤表现 RPC，不参与正式玩法。
var _auto_client_player_hurt_presentations := 0
var _auto_client_enemy_hurt_presentations := 0
## --net-test-features 专用：统计 Client 收到的可靠吐酸表现 RPC（A2 酸弹镜像回归断言用）。
var _auto_client_enemy_acid_spits := 0
## --net-test-features 专用：统计 Client 收到的可靠敌人音效事件 RPC（A3 回归断言用）。
var _auto_client_enemy_sfx := 0
var _auto_client_enemy_action := 0  ## A4：enemy_action_presentation 回归计数
## --net-test-features 专用：统计 Client 收到的可靠导演 BGM 事件 RPC（A6 回归断言用）。
var _auto_client_director_music := 0
## --net-test-features 专用：统计 Client 收到的可靠覚醒染色表现 RPC（C1 回归断言用）。
var _auto_client_awaken_presentations := 0
var _auto_client_sa_presentations := 0      ## C2：sa_presentation 回归计数
var _auto_client_swallow_presentations := 0 ## C3：swallow_presentation 回归计数
var _sa_crouch_hold_reported: bool = false  ## C2：Client 侧蹲下按住上报边沿记忆
## Host：当前覚醒中的玩家 peer 集合（C1）——中途加入的 Client 据此补发染色。
var _awaken_active_peers := {}
## --net-test-enemies 专用：统计 Client 收到的可靠敌人死亡表现 RPC。
var _auto_client_enemy_death_presentations := 0
var _auto_client_ready_input_seen_by_host := false
## --net-test-multi-disconnect 专用：Host 在玩家断线后通知留在房间的 Client 校验收敛。
var _auto_multi_disconnect_complete := false
## 多个留存 Client 都确认状态收敛后，Host 才统一让它们退出回归进程，避免测试自身触发第二次断线。
var _auto_multi_disconnect_acks: Dictionary = {}
var _auto_multi_disconnect_release := false
## --net-test-character-select 专用：Host 收到 Client 对进图角色状态的确认后才结束回归。
var _auto_character_world_acks: Dictionary = {}
## --net-test=slow-host-ready 专用：统计本场景发出的可靠世界快照次数，
## 用于断言"ready 报告先于 Host 场景就绪到达"的竞态下快照最终仍被补发。
var _auto_world_snapshot_sent_count := 0
## 避免依赖编辑器正在重载的全局 Autoload 标识符；运行时取常驻 Net 节点。
var net: Variant = null

## 防守战倒计时权威同步状态。由 Host 的 HoldoutMachine 每帧写入，供中途加入的 Client
## 补发（_accept_ready_peer），并用于丢弃旧场景残留的过期 RPC（token 不符即忽略）。
## 结构：{"phase":int, "remaining":float, "total":float, "token":int}；空字典表示当前无进行中的防守战。
var _holdout_state: Dictionary = {}
var _holdout_last_broadcast_msec: int = -999999


func _ready() -> void:
	net = get_node_or_null("/root/Net")
	if not net:
		push_error("[NetworkWorld] 未找到 Net Autoload")
		return
	# 无头回归确定性：facing_lock 的"显式 RPC 加锁"语义属于切换式（mode=0），
	# 绝不能继承 config.json 里可能残留的"按住式"（mode=1）。否则 Client 每帧的
	# _capture_facing_lock_input 会因未按住取消键而立即把锁解掉，导致 features 用例假失败。
	# 仅影响当前无头进程；不写回 config，真实玩家的设置不受影响。
	for _a in OS.get_cmdline_user_args():
		if _a.begins_with("--net-test"):
			Global.facing_lock_mode = 0
			break
	_scene_path = get_tree().current_scene.scene_file_path if get_tree().current_scene else ""
	_players_parent = _find_players_parent()
	if not _players_parent:
		push_error("[NetworkWorld] 未找到预置 Player 的父节点")
		return

	net.peer_left.connect(_on_peer_left)
	net.game_scene_ready_received.connect(_on_game_scene_ready_received)
	net.scene_transition_started.connect(_on_scene_transition_started)

	if net.is_host:
		_host_initialize_world()
	else:
		# 先接管地图预置 Player，阻止其继续执行离线状态机；随后才告知 Host 场景已就绪。
		_client_initialize_world()
		# 专用回归在 scene-ready 上报前直接调用生产输入采集函数，
		# 从而证明首图无需等待 world_snapshot 也能发出 submit_input。
		if _is_auto_client_ready_input_test():
			Input.action_press("右")
			_capture_client_input(LOCAL_INPUT_INTERVAL)
			print("[NetworkWorld] AUTO_CLIENT_READY_INPUT_CLIENT_SENT initial_world_received=%s" % _initial_world_received)
		# 不能直接对场景根 RPC：Host 可能尚在切图；Net 是常驻 Autoload，会缓冲 ready。
		net.report_game_scene_ready.rpc_id(1, _scene_path)
		if "--net-test=client" in OS.get_cmdline_user_args():
			if _is_auto_multi_disconnect_test():
				call_deferred("_run_auto_client_multi_disconnect_test")
			elif _is_auto_team_wipe_test():
				# 团灭回归：第一次进图执行倒地/流血/团灭触发；换图后同一入口走验证分支。
				call_deferred("_run_auto_client_team_wipe_test")
			elif _is_auto_slow_host_ready_test():
				# 慢速主机回归：Client 先就绪并上报 ready，验证被缓冲的 ready 最终仍能收到世界快照。
				call_deferred("_run_auto_client_slow_host_ready_test")
			elif _is_auto_character_select_test():
				call_deferred("_run_auto_client_character_select_world_test")
			elif _is_auto_network_feature_test():
				call_deferred("_run_auto_client_feature_test")
			elif _is_auto_client_ready_input_test():
				call_deferred("_run_auto_client_ready_input_test")
			elif _is_auto_enemy_test_scene():
				call_deferred("_run_auto_client_enemy_test")
			elif _is_auto_appearance_test():
				call_deferred("_run_auto_client_appearance_test")
			elif _is_auto_safe_door_test_scene():
				call_deferred("_run_auto_client_safe_door_test")
			elif "--net-test-safe-door" not in OS.get_cmdline_user_args():
				call_deferred("_run_auto_client_input_test")
	if net.is_host:
		if _is_auto_multi_disconnect_test():
			call_deferred("_run_auto_host_multi_disconnect_test")
		elif _is_auto_team_wipe_test():
			# 团灭回归：第一次进图执行倒地/流血/团灭触发；换图后同一入口走验证分支。
			call_deferred("_run_auto_host_team_wipe_test")
		elif _is_auto_slow_host_ready_test():
			# 慢速主机回归：配合 game_init 的 --net-test-host-scene-delay-ms= 复现
			# "Client ready 报告先于 Host 场景就绪到达"竞态，断言世界快照最终仍被补发。
			call_deferred("_run_auto_host_slow_host_ready_test")
		elif _is_auto_character_select_test():
			call_deferred("_run_auto_host_character_select_world_test")
		elif _is_auto_network_feature_test():
			call_deferred("_run_auto_host_feature_test")
		elif _is_auto_client_ready_input_test():
			call_deferred("_run_auto_host_ready_input_test")
		elif _is_auto_enemy_test_scene():
			call_deferred("_run_auto_host_enemy_test")
		elif _is_auto_appearance_test():
			call_deferred("_run_auto_host_appearance_test")
		elif _is_auto_safe_door_test_scene():
			call_deferred("_run_auto_host_safe_door_test")
	print("[NetworkWorld] ready host=%s scene=%s" % [net.is_host, _scene_path])


func _exit_tree() -> void:
	if not is_instance_valid(net):
		return
	if net.peer_left.is_connected(_on_peer_left):
		net.peer_left.disconnect(_on_peer_left)
	if net.game_scene_ready_received.is_connected(_on_game_scene_ready_received):
		net.game_scene_ready_received.disconnect(_on_game_scene_ready_received)
	if net.scene_transition_started.is_connected(_on_scene_transition_started):
		net.scene_transition_started.disconnect(_on_scene_transition_started)


func _on_scene_transition_started(target_scene_path: String) -> void:
	## 两端在同一可靠 start_game RPC 内进入静默期，保留旧树短暂排空此前的 RPC。
	if _scene_transitioning:
		return
	_scene_transitioning = true
	_client_local_ready = false
	# 进入新场景前清空防守战权威快照；旧场景的在途包也会因 _scene_transitioning 被 RPC 端丢弃。
	_holdout_state.clear()
	print("[NetworkWorld] SCENE_TRANSITION_QUIET current=%s target=%s" % [_scene_path, target_scene_path])


## 每个物理帧的联机总调度入口。
##
## Host 分支的顺序很重要：先接收/采集输入，再模拟玩家，再注册 Director
## 新生成的敌人，最后发送快照。这样快照描述的是本帧模拟后的状态。
## Client 分支只负责发送输入和更新本地/远端表现，绝不能在这里执行权威伤害、
## 敌人 AI 或弹药扣除。
func _physics_process(delta: float) -> void:
	# 断线/自动回归收束期间，Net 仍是有效节点但其 ENet peer 已被 leave() 清空；
	# 此时再上传输入或广播快照会触发“no multiplayer peer is active”。
	if not is_instance_valid(net) or not net.has_network() or _scene_transitioning:
		return
	var local_menu_open := _is_local_menu_open()
	var local_life := _get_local_player_life_state()
	# 丸呑み（C3）：本地玩家被吞期间输入全冻结（移动按 blocked 归零提交，
	# Host 侧由 network_swallow_locked 同步冻结，两端一致静止在吞入点）。
	var local_swallowed := _is_local_player_swallow_locked()
	# 输入冻结条件：菜单打开、本地玩家真死亡、团灭收束中、或被丸呑み吞入
	# ——四者都把移动输入归零。
	# 倒地（local_life == 1）仍可提交移动输入，由 Host 以爬行速度结算。
	var inputs_frozen := local_menu_open or local_life == 2 or _wipe_active or local_swallowed
	if not inputs_frozen and local_life == 0:
		# 救援占用功能键(D)、投掷占用确定键，都必须在普通战斗输入前优先处理。
		# 倒地/死亡的本地玩家不进入此分支：他们不能开火、装填、投掷或救援他人。
		var revive_input_active := _capture_revive_input()
		var throwable_input_active := false if revive_input_active else _capture_throwable_input()
		if not revive_input_active and not throwable_input_active:
			_capture_weapon_switch_input()
			_capture_weapon_raise_input()
			_capture_facing_lock_input()
			_capture_reload_input()
			_capture_shove_input()
			_capture_fire_input()
			_capture_awaken_input()
			_capture_sa_input()
	if net.is_host:
		_capture_host_input(inputs_frozen)
		_simulate_host_players(delta)
		# Host 权威推进顺序：先 reconcile 倒地表现与流血（可能把玩家转成真死亡），
		# 再推进救援（只认仍在流血期内的倒地目标），最后检测团灭与到时重启。
		_update_host_downed(delta)
		_update_host_revives()
		_check_host_team_wipe()
		_update_host_wipe()
		_register_untracked_host_enemies()
		# 动态掉落物收编（09-22）：ItemManager 运行期投放的喷雾/药品/弹药堆。
		_register_untracked_host_pickups(delta)
		_announce_host_enemy_deaths()
		_refresh_host_safe_door_readiness()
		_snapshot_accumulator += delta
		_player_snapshot_accumulator += delta
		if _player_snapshot_accumulator >= PLAYER_SNAPSHOT_INTERVAL:
			_player_snapshot_accumulator = fmod(_player_snapshot_accumulator, PLAYER_SNAPSHOT_INTERVAL)
			for peer_id: int in _ready_client_peers.keys():
				if net.get_peer_ids().has(peer_id):
					player_position_snapshot.rpc_id(peer_id, _build_compact_player_snapshot())
		if _snapshot_accumulator >= SNAPSHOT_INTERVAL:
			_snapshot_accumulator = fmod(_snapshot_accumulator, SNAPSHOT_INTERVAL)
			# 高频不可靠快照使用紧凑数组格式，避免敌人数量增长后超过 ENet MTU。
			for peer_id: int in _ready_client_peers.keys():
				if net.get_peer_ids().has(peer_id):
					player_snapshot.rpc_id(peer_id, _build_compact_player_snapshot(), _build_enemy_snapshot(true))
		_reliable_resync_accumulator += delta
		if _reliable_resync_accumulator >= RELIABLE_WORLD_RESYNC_INTERVAL:
			_reliable_resync_accumulator = fmod(_reliable_resync_accumulator, RELIABLE_WORLD_RESYNC_INTERVAL)
			# 定期可靠重同步可恢复高延迟/丢包客户端的敌人、玩家与掉落物列表。
			_broadcast_reliable_world_snapshot()
	else:
		_predict_client_local_movement(inputs_frozen)
		_capture_client_input(delta, inputs_frozen)


func _is_local_menu_open() -> bool:
	for menu: Node in get_tree().get_nodes_in_group("local_pause_menu"):
		if menu.has_method("is_menu_open") and menu.is_menu_open():
			return true
	return false


## 菜单需查询 NetworkWorld 的实际本地网络实体，不能依赖切图期间可能滞后的 Players 绑定。
func is_local_weapon_mode_active() -> bool:
	if not is_instance_valid(net):
		return false
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	return is_instance_valid(node) and node.is_weapon_mode_active()


## 本地玩家的三态生命状态，供输入闸门使用：
## 0 = 站立（可战斗、可救援他人）、1 = 倒地（只能爬行移动，等待救援）、2 = 死亡（全部输入冻结）。
## 【为什么需要三态】节点层的 is_network_dead() 对"倒地"与"真死亡"都返回 true
## （两者共用躺地表现），只有 NetworkWorld entry 的权威 downed 标记能区分二者；
## 而倒地玩家恰恰需要保留移动输入通道（爬行），所以不能用旧的二值 alive 判断。
func _get_local_player_life_state() -> int:
	if not is_instance_valid(net):
		return 2
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(node):
		return 2
	if not node.is_network_dead():
		return 0
	return 1 if bool(entry.get("downed", false)) else 2


## 本地玩家是否处于丸呑み被吞锁定（C3，供输入闸门使用）。
func _is_local_player_swallow_locked() -> bool:
	if not is_instance_valid(net):
		return false
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	return is_instance_valid(node) and node.get("network_swallow_locked") == true


# ---------------------------------------------------------------- Host simulation

## 初始化 Host 场景中的权威实体。
##
## 场景切换会销毁旧的 NetworkWorld，但 Net 单例中的 PlayerState 会保留跨场景
## 数据。因此这里必须先清除旧的实体绑定，再把当前地图节点绑定到已有状态，
## 而不是重新创建一套玩家数据。
func _host_initialize_world() -> void:
	# Scene switching must only discard old node bindings. Persistent PlayerState lives in Net.
	Players.clear_entity_bindings()
	_claim_local_network_state()
	var local_id: int = int(net.my_peer_id)
	var host_node := _find_preplaced_player()
	_apply_arrival_to_preplaced_player(host_node)
	if host_node:
		_register_host_player(local_id, host_node, true)
	else:
		_register_host_player(local_id, _instantiate_player(_spawn_position(0), local_id), true)
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			_register_host_player(peer_id, _instantiate_player(_spawn_position(_players.size()), peer_id), false)
	# 【场景 ready 竞态】Client 的 scene-ready 报告可能先于 Host 场景加载完成到达
	# （Net 缓冲在 _pending_scene_ready）。这里必须走 _accept_ready_peer：
	# 它会把对端记入 _ready_client_peers 并补建实体。绝不能只调 _add_host_peer ——
	# 对端玩家已在上方 get_peer_ids() 循环里注册过，_add_host_peer 会整个 no-op，
	# ready 记录被这一行 take 掉之后就再也无人处理，Host 永远不会向该 Client 发送
	# 世界快照（客户端表现为画面永久卡死、远端精灵全部不刷出）。
	# 快照本身延后到 _finish_host_world_initialization（send_snapshot=false），
	# 因为敌人/掉落物要到那时才注册完毕，提前发会丢掉预置内容。
	for peer_id: int in net.take_pending_scene_ready(_scene_path):
		_accept_ready_peer(peer_id, false)
	_reconcile_network_seats(net.get_peer_ids())
	# Enemy/Pickup joins its groups from _ready(), so scan after the scene is completely ready.
	call_deferred("_finish_host_world_initialization")


func _finish_host_world_initialization() -> void:
	if not is_instance_valid(self) or not net.is_host:
		return
	_register_initial_host_enemies()
	_register_initial_host_pickups()
	_consume_pending_scene_ready()
	# 兜底补发：对"在 Host 世界初始化前就已 ready"的 Client（ready 被 Net 缓冲、
	# 上方只标记未发快照），此刻世界已完整，统一补发可靠世界快照。
	# 对已在 _accept_ready_peer 中收过快照的对端，重复收一次是幂等的可靠包。
	_broadcast_reliable_world_snapshot()


## 初始化 Client 场景中的表现实体。
##
## Client 会先接管地图预置 Player，再向 Host 发送 scene-ready。此时玩家可以
## 立即显示和发送输入，但位置、装备和敌人列表仍要等待 Host 的可靠快照确认。
## Client 本地玩家使用 Host 权威位置，避免本地预测与 Host 模拟产生两套坐标。
func _client_initialize_world() -> void:
	# Keep snapshot data during map loads, only invalidate scene-node bindings.
	Players.clear_entity_bindings()
	_claim_local_network_state()
	var local_id: int = int(net.my_peer_id)
	var local_node := _find_preplaced_player()
	_apply_arrival_to_preplaced_player(local_node)
	if not local_node:
		local_node = _instantiate_player(_spawn_position(0), local_id)
	var state := _find_or_create_player_state(local_id, "", local_node.current_hp)
	# 与 Host 侧 _register_host_player 相同的章节推进复活兜底（详见彼处注释）：
	# Host 满血后会经快照同步，这里先行恢复，避免本地先以 0 HP 表现一帧。
	if state.current_hp <= 0.0:
		state.current_hp = state.get_max_hp()
	state.owner_peer_id = local_id
	state.position = local_node.global_position
	state.facing = local_node.facing
	var seat_index := _ensure_player_state_seat(state)
	local_node.configure_network_entity(local_id, local_id)
	local_node.network_local_player = true
	# 本地预测：Client 立即按本地输入移动自己，Host 权威坐标经快照平滑纠偏。
	# 关闭预测会导致位置完全由 60Hz 快照硬赋值 —— 移动一顿一顿且输入延迟等于 RTT。
	local_node.set_network_local_prediction(true)
	local_node.apply_network_spawn_state(state.character, state.current_hp, state.position, state.facing, true)
	local_node.reset_network_prediction_sync()
	local_node.exit_weapon_mode()
	Players.register_entity(local_node, seat_index)
	_attach_player_nameplate(local_node, local_id, seat_index)
	_players[local_id] = {
		"node": local_node,
		"state": state,
		"input": Vector2.ZERO,
		"moving": false,
		"walking": false,
	}
	_set_local_player(local_node, seat_index)
	_reconcile_network_seats(net.get_peer_ids())
	_prepare_client_preplaced_enemies()
	_prepare_client_preplaced_pickups()
	_client_local_ready = true
	print("[NetworkWorld] CLIENT_LOCAL_READY peer=%d" % local_id)


## 找到 peer_id 玩家救援范围内最近的"可救援目标"。
## 【倒地语义】只有 entry["downed"] 为 true 的玩家可被救援 —— 流血耗尽后的
## 真死亡（downed=false、dead=true）同样躺地、同样 is_network_dead()，但不再响应救援。
## reviver 自身倒地/死亡时在开头就被拦下（is_network_dead() 覆盖两种状态），
## 因此倒地玩家无法救他人，其未完成的救援尝试也会在 _update_host_revives 中自动取消。
## Host 用它做权威校验；Client 在 _capture_revive_input 里基于快照同步来的 downed
## 预估目标，Host 仍会重新验证身份、距离与状态。
func _find_revive_target_for(peer_id: int) -> int:
	var entry: Dictionary = _players.get(peer_id, {})
	var node := entry.get("node") as Node2D
	if not is_instance_valid(node) or node.is_network_dead():
		return 0
	var closest_id := 0
	var closest_distance := REVIVE_RANGE
	for value: Variant in _players.keys():
		var target_id := int(value)
		if target_id == peer_id:
			continue
		var target_entry: Dictionary = _players[target_id]
		if not bool(target_entry.get("downed", false)):
			continue
		var target_node := target_entry.get("node") as Node2D
		if is_instance_valid(target_node):
			var distance := node.global_position.distance_to(target_node.global_position)
			if distance <= closest_distance:
				closest_distance = distance
				closest_id = target_id
	return closest_id


func _capture_revive_input() -> bool:
	var peer_id := int(net.my_peer_id)
	if Input.is_action_just_pressed("功能键"):
		var target_id := _find_revive_target_for(peer_id)
		if target_id > 0:
			if net.is_host:
				_try_host_start_revive(peer_id, target_id)
			elif _client_local_ready:
				# 本地仅记录按键占用，Host 仍会重新验证目标和距离。
				_revive_attempts[peer_id] = {"target": target_id, "started_msec": 0}
				revive_start_request.rpc_id(1, target_id)
			return true
	if Input.is_action_just_released("功能键") and _revive_attempts.has(peer_id):
		if net.is_host:
			_cancel_host_revive(peer_id)
		elif _client_local_ready:
			_revive_attempts.erase(peer_id)
			revive_cancel_request.rpc_id(1)
		return true
	return _revive_attempts.has(peer_id)


## Host 权威受理救援开始。目标合法性完全由 _find_revive_target_for 复核：
## 必须是距离内的"倒地"玩家（站立/真死亡都不行），reviver 自身必须站立且不在
## 战斗锁定（装填等）中。Client 的本地记录只是按键占位，这里才是唯一权威起点。
func _try_host_start_revive(reviver_id: int, target_id: int) -> void:
	if not net.is_host or reviver_id == target_id or not _players.has(reviver_id) or not _players.has(target_id):
		return
	if _is_host_combat_busy(reviver_id) or _find_revive_target_for(reviver_id) != target_id:
		return
	_revive_attempts[reviver_id] = {"target": target_id, "started_msec": Time.get_ticks_msec()}
	print("[NetworkWorld] HOST_REVIVE_START reviver=%d target=%d" % [reviver_id, target_id])


func _cancel_host_revive(reviver_id: int) -> void:
	if _revive_attempts.erase(reviver_id):
		print("[NetworkWorld] HOST_REVIVE_CANCEL reviver=%d" % reviver_id)


func _update_host_revives() -> void:
	if not net.is_host or _revive_attempts.is_empty():
		return
	var now := Time.get_ticks_msec()
	for value: Variant in _revive_attempts.keys().duplicate():
		var reviver_id := int(value)
		var attempt: Dictionary = _revive_attempts[reviver_id]
		var target_id := int(attempt.get("target", 0))
		if _find_revive_target_for(reviver_id) != target_id:
			_cancel_host_revive(reviver_id)
			continue
		if now - int(attempt.get("started_msec", now)) < REVIVE_DURATION_MSEC:
			continue
		var target_entry: Dictionary = _players.get(target_id, {})
		var target_node := target_entry.get("node") as CharacterBody2D
		var target_state := target_entry.get("state") as PlayerState
		# 目标必须是仍在流血期内的倒地玩家：is_network_dead() 无法区分倒地与真死亡
		# （共用躺地表现），权威依据是 entry["downed"]。目标若已流血耗尽或状态异常，
		# 一律取消本次救援，避免"把尸体扶起来"。
		if not is_instance_valid(target_node) or not target_state or not bool(target_entry.get("downed", false)):
			_cancel_host_revive(reviver_id)
			continue
		var hp := maxf(1.0, target_node.max_hp * REVIVE_HP_RATIO)
		target_state.current_hp = hp
		# 先清权威倒地标记再播放复活表现：entry 是快照与救援筛选的唯一事实来源；
		# apply_network_revive_state 会同步复位节点层的 network_downed/染色/碰撞。
		target_entry["downed"] = false
		target_entry["dead"] = false
		_players[target_id] = target_entry
		target_node.apply_network_revive_state(hp)
		_revive_attempts.erase(reviver_id)
		revive_presentation.rpc(target_id, hp)
		print("[NetworkWorld] HOST_REVIVE_COMPLETE reviver=%d target=%d hp=%.1f" % [reviver_id, target_id, hp])


## Host：倒地状态推进（每帧）。
## 职责一：把 entry 的 downed/dead 权威状态 reconcile 到节点表现 —— 倒地时重新
##         启用移动碰撞并染红（_die() 的 deferred 关闭在前一帧已生效，这里下一帧
##         覆盖为开启，时序安全）；真死亡时恢复关闭与普通染色。
## 职责二：推进流血池；耗尽后转真死亡（downed=false / dead=true），此后
##         _find_revive_target_for 不再返回该玩家，安全门也不再等他到常。
## 职责三：驱动 Host 本地的救援进度环（Client 侧由快照 revive_progress 驱动）。
func _update_host_downed(delta: float) -> void:
	if not net.is_host:
		return
	for value: Variant in _players.keys():
		var peer_id := int(value)
		var entry: Dictionary = _players[peer_id]
		var node := entry.get("node") as CharacterBody2D
		if not is_instance_valid(node):
			continue
		var downed := bool(entry.get("downed", false))
		if node.is_network_downed() != downed:
			node.set_network_downed(downed)
		if not downed:
			_update_network_revive_indicator(node, 0.0)
			continue
		var bleed_hp := maxf(0.0, float(entry.get("downed_hp", DOWNED_BLEED_HP)) - DOWNED_BLEED_RATE * delta)
		entry["downed_hp"] = bleed_hp
		_players[peer_id] = entry
		if bleed_hp <= 0.0:
			# 流血耗尽 → 真死亡：节点表现由下一帧 reconcile 回落（碰撞关闭、染色复位），
			# 未完成的"救他"尝试会在 _update_host_revives 的 downed 校验里被取消。
			entry["downed"] = false
			entry["dead"] = true
			_players[peer_id] = entry
			print("[NetworkWorld] HOST_BLEEDOUT peer=%d" % peer_id)
			continue
		_update_network_revive_indicator(node, _get_host_revive_progress_for(peer_id))


## 目标玩家当前被救援的进度（0–1）；没有任何进行中的救援尝试时返回 0。
## 仅供 Host 调用（attempts 是 Host 权威状态）；Client 的进度来自快照字段。
func _get_host_revive_progress_for(target_id: int) -> float:
	for attempt: Dictionary in _revive_attempts.values():
		if int(attempt.get("target", 0)) != target_id:
			continue
		var started := int(attempt.get("started_msec", 0))
		if started > 0:
			return clampf(float(Time.get_ticks_msec() - started) / float(REVIVE_DURATION_MSEC), 0.0, 1.0)
	return 0.0


## 在倒地玩家头顶挂/更新/摘除救援进度环。
## Host：进度来自 _revive_attempts（_update_host_downed 调用）；
## Client：进度来自快照 revive_progress（_ensure_client_player 调用）。
## progress <= 0 表示当前没有救援进行中 —— 摘除节点，避免常驻空绘制。
func _update_network_revive_indicator(node: CharacterBody2D, progress: float) -> void:
	if not is_instance_valid(node):
		return
	var indicator := node.get_node_or_null("NetworkReviveIndicator") as Node2D
	if progress <= 0.0:
		if indicator:
			indicator.queue_free()
		return
	if not indicator:
		indicator = Node2D.new()
		indicator.name = "NetworkReviveIndicator"
		indicator.z_index = 20
		indicator.set_script(REVIVE_INDICATOR_SCRIPT)
		node.add_child(indicator)
	# 用 set() 而非静态属性访问：indicator 声明为 Node2D，脚本字段需动态写入。
	indicator.set("progress", clampf(progress, 0.0, 1.0))


## Host：团灭检测 —— 全员非站立（全部倒地或死亡）即触发。
## _players 为空时跳过（切图间隙等无玩家瞬间不做误判）；
## _scene_transitioning 由 _physics_process 顶部统一拦截，这里无需重复判断。
func _check_host_team_wipe() -> void:
	if not net.is_host or _wipe_active or _players.is_empty():
		return
	for entry: Dictionary in _players.values():
		var node := entry.get("node") as CharacterBody2D
		if is_instance_valid(node) and not node.is_network_dead():
			return
	_trigger_host_team_wipe()


## Host：发起团灭收束 —— 置位 _wipe_active 冻结全部输入与移动（含倒地爬行），
## 清空未完成的救援尝试，广播黑屏表现（call_local：Host 自己也要看到遮罩）。
func _trigger_host_team_wipe() -> void:
	_wipe_active = true
	_wipe_started_msec = Time.get_ticks_msec()
	_wipe_restart_requested = false
	_revive_attempts.clear()
	team_wipe_presentation.rpc()
	print("[NetworkWorld] HOST_TEAM_WIPE players=%d" % _players.size())


## Host：黑屏淡出 + 停留结束后，重置会话 PlayerState（全员满血 —— 倒地/死亡
## 是场景运行时状态，不跨场景持久化），再复用既有切图协议重载本章。
## Client 不需要单独的重启指令：request_scene_change 会经 start_game 广播，
## 双端按同一 serial 走"静默 → ack → flush → 换图"流程。
func _update_host_wipe() -> void:
	if not net.is_host or not _wipe_active or _wipe_restart_requested:
		return
	if Time.get_ticks_msec() - _wipe_started_msec < int((WIPE_FADE_SECONDS + WIPE_HOLD_SECONDS) * 1000.0):
		return
	_wipe_restart_requested = true
	for value: Variant in _players.keys():
		var state := (_players[int(value)] as Dictionary).get("state") as PlayerState
		if state:
			state.current_hp = state.get_max_hp()
	print("[NetworkWorld] HOST_TEAM_WIPE_RESTART scene=%s hp_reset=done" % _scene_path)
	net.request_scene_change(_scene_path)


## 团灭黑屏表现：authority + call_local，Host 与所有 Client 各自本地建遮罩。
## Client 同时置位 _wipe_active 冻结本地输入，直到切图协议接管（旧场景节点随
## 换图被释放，新场景的 NetworkWorld 会以全新状态启动）。
@rpc("authority", "call_local", "reliable")
func team_wipe_presentation() -> void:
	_wipe_active = true
	_wipe_started_msec = Time.get_ticks_msec()
	_revive_attempts.clear()
	_show_team_wipe_fade()
	print("[NetworkWorld] TEAM_WIPE_PRESENTATION host=%s" % net.is_host)


## 建一层顶层黑屏遮罩（layer=128，与单人死亡黑屏同级）。只建不重建：
## RPC 重复到达时复用已有节点，避免叠加多层遮罩；换图时随场景一起释放。
func _show_team_wipe_fade() -> void:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	if is_instance_valid(_wipe_fade_overlay):
		return
	var canvas_layer := CanvasLayer.new()
	canvas_layer.name = "TeamWipeFadeCanvas"
	canvas_layer.layer = 128
	_wipe_fade_overlay = ColorRect.new()
	_wipe_fade_overlay.name = "TeamWipeFadeOverlay"
	_wipe_fade_overlay.color = Color(0, 0, 0, 0)
	_wipe_fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wipe_fade_overlay.size = tree.current_scene.get_viewport().get_visible_rect().size
	canvas_layer.add_child(_wipe_fade_overlay)
	tree.current_scene.add_child(canvas_layer)


## 团灭黑屏渐变驱动（Host 与 Client 通用）。Host 到时后的重启在
## _update_host_wipe（物理帧）执行；遮罩随换图自动消失。
func _process(_delta: float) -> void:
	if not _wipe_active or not is_instance_valid(_wipe_fade_overlay):
		return
	var elapsed := float(Time.get_ticks_msec() - _wipe_started_msec) / 1000.0
	_wipe_fade_overlay.color = Color(0, 0, 0, clampf(elapsed / WIPE_FADE_SECONDS, 0.0, 1.0))


func _capture_throwable_input() -> bool:
	var local_id := int(net.my_peer_id)
	var local_throw_state: Dictionary = _network_throwable_state.get(local_id, {})
	var held := bool(local_throw_state.get("held", false))
	var aiming := bool(local_throw_state.get("aiming", false))
	if Global.item_key_just_pressed("投掷物键"):
		if net.is_host:
			_try_host_set_throwable_held(local_id, not held)
		elif _client_local_ready:
			throwable_hold_request.rpc_id(1, not held)
		return true
	if not held:
		return false
	if Global.item_key_just_pressed("主武器键") or Global.item_key_just_pressed("副武器键"):
		if net.is_host:
			_try_host_set_throwable_held(local_id, false)
		elif _client_local_ready:
			throwable_hold_request.rpc_id(1, false)
		return true
	if not aiming and Input.is_action_just_pressed("确定键"):
		if net.is_host:
			_try_host_set_throwable_aiming(local_id, true)
		elif _client_local_ready:
			throwable_aim_request.rpc_id(1, true)
		return true
	if aiming:
		if Input.is_action_just_pressed("取消键"):
			if net.is_host:
				_try_host_set_throwable_aiming(local_id, false)
			elif _client_local_ready:
				throwable_aim_request.rpc_id(1, false)
		elif Input.is_action_just_pressed("投掷加格键"):
			_request_throwable_range(1)
		elif Input.is_action_just_pressed("投掷减格键"):
			_request_throwable_range(-1)
		elif Input.is_action_just_released("确定键"):
			if net.is_host:
				_try_host_throw_throwable(local_id)
			elif _client_local_ready:
				throwable_throw_request.rpc_id(1)
		return true
	return true


func _request_throwable_range(delta: int) -> void:
	if net.is_host:
		_try_host_adjust_throwable_range(int(net.my_peer_id), delta)
	elif _client_local_ready:
		throwable_range_request.rpc_id(1, clampi(delta, -1, 1))


func _capture_weapon_switch_input() -> void:
	if Global.item_key_just_pressed("主武器键"):
		_request_weapon_switch("primary")
	elif Global.item_key_just_pressed("副武器键"):
		_request_weapon_switch("secondary")


func _capture_weapon_raise_input() -> void:
	if not Input.is_action_just_pressed("举起放下武器键"):
		return
	if net.is_host:
		_try_host_toggle_weapon(int(net.my_peer_id))
	elif _client_local_ready:
		weapon_toggle_request.rpc_id(1)


## 联机接管后离线武器状态机不再读取取消键，因此这里将固定朝向意图提交给 Host。
## 投掷瞄准会先由 _capture_throwable_input() 吞掉取消键，避免两种取消操作冲突。
func _capture_facing_lock_input() -> void:
	var local_id := int(net.my_peer_id)
	var entry: Dictionary = _players.get(local_id, {})
	var node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(node) or node.current_hp <= 0.0 or not node.is_weapon_mode_active() or node.player_in_weapon_state:
		return
	if Global.facing_lock_mode == 0:
		if Input.is_action_just_pressed("取消键"):
			_request_facing_lock(true, false)
		return
	var should_lock := Input.is_action_pressed("取消键")
	if should_lock != node.is_facing_locked():
		_request_facing_lock(false, should_lock)


func _request_facing_lock(toggle: bool, locked: bool) -> void:
	var local_id := int(net.my_peer_id)
	if net.is_host:
		_try_host_set_facing_lock(local_id, toggle, locked)
	elif _client_local_ready:
		var entry: Dictionary = _players.get(local_id, {})
		var node := entry.get("node") as CharacterBody2D
		if not is_instance_valid(node):
			return
		var desired_locked: bool = (not node.is_facing_locked()) if toggle else locked
		_facing_lock_requests[local_id] = desired_locked
		facing_lock_request.rpc_id(1, false, desired_locked)
		# 仅做视觉预测；最终状态由 Host 的 facing_lock_presentation 覆盖。
		node.apply_facing_lock_state(desired_locked, node.facing)


func _request_weapon_switch(slot: String) -> void:
	if net.is_host:
		_try_host_weapon_switch(int(net.my_peer_id), slot)
	elif _client_local_ready:
		# Client 只提交槽位意图；Host 从自身 PlayerState 校验真实装备。
		weapon_switch_request.rpc_id(1, slot)


func _capture_reload_input() -> void:
	if not Input.is_action_just_pressed("装填键"):
		return
	if net.is_host:
		_try_host_reload(int(net.my_peer_id))
	elif _client_local_ready:
		# Client 仅请求装填；Host 校验库存并一次性提交权威弹药结果。
		reload_request.rpc_id(1)


func _capture_shove_input() -> void:
	if not Input.is_action_just_pressed("推击键"):
		return
	if net.is_host:
		_try_host_shove(int(net.my_peer_id))
	elif _client_local_ready:
		# 带本机位置上报（滞后补偿）：Host 按权威坐标做命中查询，需要客户端位置提示。
		shove_request.rpc_id(1, _local_claim_position())


## 覚醒（集中射撃）输入收集（C1）：構え（武器模式）中按覚醒键上报请求，
## Host 校验 awaken_type/TP/存活后统一结算并发染色表现。
func _capture_awaken_input() -> void:
	if not Input.is_action_just_pressed("覚醒键"):
		return
	if net.is_host:
		_try_host_awaken(int(net.my_peer_id))
	elif _client_local_ready:
		# 轻量预校验（本地 node 的武器模式由表现接口维护）减少无效请求；TP 由 Host 权威校验。
		var entry: Dictionary = _players.get(int(net.my_peer_id), {})
		var node := entry.get("node") as CharacterBody2D
		if is_instance_valid(node) and node.is_weapon_mode_active():
			awaken_request.rpc_id(1)


## SA / 见切 输入收集（C2）：SA 键=技能释放请求；确定键=攻击兼见切（同原作）
## 的窗口登记请求。Host 不进入本函数——Host 本机玩家由 player._update_sa_state
## 直读输入并经 _use_skill_core 扣 TP，这里再发请求会双扣；投掷瞄准（占用
## 确定键）时与开火一样被外层跳过。搓招缓冲由 poll_network_motion_input 按帧
## 代为驱动，SA 请求信任 Client 的 validate_skill_motion 预校验（Host 无法
## 重放输入序列，与射击瞄准同类的意图信任）。
func _capture_sa_input() -> void:
	if net.is_host or not _client_local_ready:
		return
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(node):
		return
	node.poll_network_motion_input()
	# SA 键：技能释放请求（TP/存活由 Host 权威校验）。
	if Input.is_action_just_pressed("SA键"):
		if node.validate_skill_motion("SA键"):
			sa_skill_request.rpc_id(1, "SA键")
	# 确定键：见切窗口登记请求（窗口/间隔状态登记在 Host 权威实体上；
	# _try_mukiri_input 只读 Time/Heat，零拆分直调）。
	if Input.is_action_just_pressed("确定键"):
		mukiri_request.rpc_id(1)
	# しゃがみ回避发动中：SA 键按住状态的边沿上报（Host 权威实体据此延长蹲下）。
	# 表现晚到时按 mismatch 补报：蹲下染色生效瞬间按住=true 而登记=false 会立即上报。
	var crouch_active: bool = node.get("_sa_crouch_active") == true
	if crouch_active:
		var hold := Input.is_action_pressed("SA键")
		if hold != _sa_crouch_hold_reported:
			_sa_crouch_hold_reported = hold
			sa_crouch_hold.rpc_id(1, hold)
	elif _sa_crouch_hold_reported:
		_sa_crouch_hold_reported = false
		sa_crouch_hold.rpc_id(1, false)


func _capture_fire_input() -> void:
	var local_id := int(net.my_peer_id)
	var entry: Dictionary = _players.get(local_id, {})
	var state := entry.get("state") as PlayerState
	var weapon: WeaponData = state.get_active_weapon() if state else null
	var held_fire := weapon != null and weapon.fire_mode == WeaponData.FireMode.HOLD
	if (not held_fire and not Input.is_action_just_pressed("确定键")) or (held_fire and not Input.is_action_pressed("确定键")):
		return
	if net.is_host:
		_try_host_attack(local_id)
	elif _client_local_ready:
		# Client 只提交攻击意图；位置、朝向、武器、弹药和伤害均由 Host 重建与校验。
		var now := Time.get_ticks_msec()
		var interval := _get_attack_cooldown_msec(weapon) if weapon else 100
		if now - _last_client_fire_request_msec < interval:
			return
		_last_client_fire_request_msec = now
		# 带本机位置上报（滞后补偿）：Host 的形状查询/命中判定在权威坐标上做。
		fire_request.rpc_id(1, _local_claim_position())


## 客户端自报位置（滞后补偿用）：本地预测实体当前坐标；无有效实体返回 null。
func _local_claim_position() -> Variant:
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	return node.global_position if is_instance_valid(node) else null


func _capture_host_input(blocked: bool = false) -> void:
	if not _players.has(net.my_peer_id):
		return
	_set_input(net.my_peer_id, Vector2.ZERO if blocked else _read_local_direction(), false if blocked else Input.is_action_pressed("行走键"))


## 按固定节拍向 Host 提交当前输入状态。
##
## 这里发送的是“持续状态”而不是按键事件，例如方向向量和是否慢走。
## RPC 丢失时，下一次输入包会覆盖旧状态；因此该 RPC 可以使用 unreliable_ordered。
## Host 收到后才会真正改变远端玩家的速度和位置。
func _capture_client_input(delta: float, blocked: bool = false) -> void:
	# 首图的本地预置玩家在 _client_initialize_world() 已安全接管；不必等待完整世界快照。
	if not _client_local_ready:
		return
	_input_accumulator += delta
	if _input_accumulator < LOCAL_INPUT_INTERVAL:
		return
	_input_accumulator = fmod(_input_accumulator, LOCAL_INPUT_INTERVAL)
	submit_input.rpc_id(1, Vector2.ZERO if blocked else _read_local_direction(), false if blocked else Input.is_action_pressed("行走键"))


func _predict_client_local_movement(blocked: bool = false) -> void:
	if not _client_local_ready:
		return
	var peer_id := int(net.my_peer_id)
	var entry: Dictionary = _players.get(peer_id, {})
	var node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(node) or node.is_network_dead() or not node.network_local_prediction:
		return
	var direction := Vector2.ZERO if blocked else _read_local_direction()
	var walking := false if blocked else Input.is_action_pressed("行走键")
	var moving := not direction.is_zero_approx()
	node.velocity = direction * (node.walk_speed if walking else node.run_speed)
	if moving:
		node.update_facing(direction)
	node.move_with_corner_assist()
	node.update_appearance(moving, walking)
	_set_input(peer_id, direction, walking)


func _read_local_direction() -> Vector2:
	return Input.get_vector("左", "右", "上", "下")


func _set_input(peer_id: int, direction: Vector2, walking: bool) -> void:
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var normalized := direction.limit_length(1.0)
	entry["input"] = normalized
	entry["walking"] = walking
	_players[peer_id] = entry
	if net.is_host and peer_id != int(net.my_peer_id):
		if _is_auto_client_ready_input_test() and normalized.x > 0.5:
			_auto_client_ready_input_seen_by_host = true
		var previous: Vector2 = _last_logged_remote_input.get(peer_id, Vector2.INF)
		if previous != normalized:
			_last_logged_remote_input[peer_id] = normalized
			print("[NetworkWorld] HOST_INPUT peer=%d dir=(%.2f, %.2f) walk=%s" % [peer_id, normalized.x, normalized.y, walking])


## Host 权威模拟所有玩家。
##
## `_players[peer_id]` 中的 input 是最近一次 Client 提交的输入。Host 不信任
## Client 上传的位置，而是用同一套速度、碰撞和 move_and_slide() 重新计算位置。
## 因此所有攻击距离、拾取距离和子弹出生点都必须使用这里产生的 Host 坐标。
func _simulate_host_players(_delta: float) -> void:
	for key: Variant in _players.keys():
		var peer_id := int(key)
		var entry: Dictionary = _players[peer_id]
		var node := entry.get("node") as CharacterBody2D
		if not is_instance_valid(node):
			continue
		if node.has_method("is_network_dead") and node.is_network_dead():
			_clear_host_combat_state_for_dead_peer(peer_id)
			# 倒地（downed）与真死亡（dead）都进入本分支，但移动规则不同：
			# 倒地玩家仍可按 DOWNED_CRAWL_SPEED 缓慢爬行（方向来自其 Client 提交的
			# 输入），真死亡玩家完全冻结。躺地状态下 _refresh_sprite 拒绝刷新精灵，
			# 因此移动不会破坏死亡帧，只会同步位置与朝向（爬行转向）。
			# 团灭收束（_wipe_active）期间连爬行也一并冻结。
			if not bool(entry.get("downed", false)) or _wipe_active:
				node.velocity = Vector2.ZERO
				_set_input(peer_id, Vector2.ZERO, false)
				_sync_state_from_node(peer_id, node, false, false)
				continue
			var crawl_dir: Vector2 = entry.get("input", Vector2.ZERO)
			var crawling := not crawl_dir.is_zero_approx()
			node.velocity = crawl_dir.limit_length(1.0) * DOWNED_CRAWL_SPEED
			if crawling:
				node.update_facing(crawl_dir)
			node.move_with_corner_assist()
			node.update_appearance(crawling, true)
			_sync_state_from_node(peer_id, node, crawling, true)
			continue
		if node.get("network_swallow_locked") == true:
			# 丸呑み（C3）：被吞玩家由 EnemySwallowState 冻结在吞入点，
			# 不吃提交输入（_hide_victim 的 set_physics_process(false) 挡不住
			# 本函数的直接移动，必须在此显式冻结，否则会从 Hunterγ 肚子里走出去）。
			node.velocity = Vector2.ZERO
			_set_input(peer_id, Vector2.ZERO, false)
			_sync_state_from_node(peer_id, node, false, false)
			continue
		var direction: Vector2 = entry.get("input", Vector2.ZERO)
		var walking: bool = bool(entry.get("walking", false))
		var moving := not direction.is_zero_approx()
		node.velocity = direction * (node.walk_speed if walking else node.run_speed)
		if moving:
			node.update_facing(direction)
		node.move_with_corner_assist()
		node.update_appearance(moving, walking)
		_sync_state_from_node(peer_id, node, moving, walking)


func _sync_state_from_node(peer_id: int, node: CharacterBody2D, moving: bool, walking: bool) -> void:
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var state := entry.get("state") as PlayerState
	if state:
		state.position = node.global_position
		state.facing = node.facing
		state.current_hp = node.current_hp
	entry["moving"] = moving
	entry["walking"] = walking
	_players[peer_id] = entry


func _register_host_player(peer_id: int, node: CharacterBody2D, is_preplaced: bool) -> void:
	if not is_instance_valid(node) or _players.has(peer_id):
		return
	var state := _find_or_create_player_state(peer_id, "", node.current_hp)
	# 章节推进复活：上一章真死亡的玩家在新场景按满血归队。
	# 倒地/死亡是场景运行时状态（entry 字段），换图后 entry 全新，无需清理；
	# 只有会话 PlayerState 的 HP 需要在这里兜底恢复，否则会以 0 HP 站立出场。
	# 这同时解决了"一人死亡、全员卡安全门"的软锁：过门后死者满血回归。
	if state.current_hp <= 0.0:
		state.current_hp = state.get_max_hp()
	state.owner_peer_id = peer_id
	state.position = node.global_position
	state.facing = node.facing
	node.configure_network_entity(peer_id, peer_id)
	if _is_network_regression_loadout():
		_configure_network_loadout(state, node)
	else:
		node.exit_weapon_mode()
	var seat_index := _ensure_player_state_seat(state)
	if not is_preplaced:
		node.global_position = _spawn_position(_players.size())
	Players.register_entity(node, seat_index)
	_attach_player_nameplate(node, peer_id, seat_index)
	# Host 也走同一套表现初始化，保证新实体的角色、HP 和朝向与 PlayerState 一致。
	node.apply_network_spawn_state(state.character, state.current_hp, node.global_position, state.facing, true)
	if peer_id == net.my_peer_id:
		_set_local_player(node, seat_index)
	_players[peer_id] = {
		"node": node,
		"state": state,
		"input": Vector2.ZERO,
		"moving": false,
		"walking": false,
	}
	_sync_state_from_node(peer_id, node, false, false)
	_connect_host_player_damage_signal(peer_id, node)
	print("[NetworkWorld] HOST_SPAWN peer=%d preplaced=%s" % [peer_id, is_preplaced])


func _connect_host_player_damage_signal(peer_id: int, node: CharacterBody2D) -> void:
	if not net.is_host or not is_instance_valid(node) or not node.has_signal("network_damage_applied"):
		return
	var callback := Callable(self, "_on_host_player_damage_applied").bind(peer_id)
	if not node.is_connected("network_damage_applied", callback):
		node.connect("network_damage_applied", callback)


func _connect_host_enemy_damage_signal(entity_id: int, node: CharacterBody2D) -> void:
	if not net.is_host or not is_instance_valid(node) or not node.has_signal("network_damage_applied"):
		return
	var callback := Callable(self, "_on_host_enemy_damage_applied").bind(entity_id)
	if not node.is_connected("network_damage_applied", callback):
		node.connect("network_damage_applied", callback)


## Host 收到玩家实体受伤信号（player.take_damage → network_damage_applied）。
## 【时序】信号在 take_damage() 内部、`_die()` 之前发出 —— 此刻 current_hp 已扣减，
## 但躺地表现尚未播放。这里只把"HP 归零"登记为权威倒地状态；躺地表现由
## player._die() 自己完成，碰撞再启用交给 _update_host_downed 下一帧 reconcile，
## 避免与 _apply_network_death_state 中 deferred 关闭碰撞的写入争抢顺序。
func _on_host_player_damage_applied(damage: float, position: Vector2, _is_headshot: bool, peer_id: int) -> void:
	if not net.is_host or damage <= 0.0:
		return
	player_hurt_presentation.rpc(peer_id, damage, position)
	var entry: Dictionary = _players.get(peer_id, {})
	var node := entry.get("node") as CharacterBody2D
	if is_instance_valid(node) and node.current_hp <= 0.0:
		_handle_host_player_downed(peer_id)


## Host：HP 归零的玩家被オートスプレー救回（player._die 联机分支）后调用。
## 伤害信号先于 _die() 把 entry["downed"] 登记为 true，喷雾复活必须清掉，
## 否则 _update_host_downed 下一帧会把满血玩家 reconcile 回倒地流血。
func notify_player_revived(node: Node2D) -> void:
	if not net.is_host:
		return
	var peer_id := _peer_id_for_node(node)
	if peer_id <= 0:
		return
	var entry: Dictionary = _players.get(peer_id, {})
	if bool(entry.get("downed", false)):
		entry["downed"] = false
		entry["downed_hp"] = 0.0
		_players[peer_id] = entry
		if is_instance_valid(node) and node.has_method("set_network_downed"):
			node.call("set_network_downed", false)
		print("[NetworkWorld] HOST_AUTO_SPRAY_REVIVE peer=%d" % peer_id)


## Host：把 HP 归零的玩家登记为倒地（可救援）。流血池从 DOWNED_BLEED_HP 满值起算。
## 已倒地/已真死亡的玩家直接忽略 —— take_damage 对躺地实体本就不生效
## （_is_dying 挡板），这里是防御性的二次进入保护。
func _handle_host_player_downed(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	if bool(entry.get("downed", false)) or bool(entry.get("dead", false)):
		return
	entry["downed"] = true
	entry["dead"] = false
	entry["downed_hp"] = DOWNED_BLEED_HP
	_players[peer_id] = entry
	print("[NetworkWorld] HOST_DOWNED peer=%d bleed_hp=%.0f" % [peer_id, DOWNED_BLEED_HP])


func _on_host_enemy_damage_applied(damage: float, position: Vector2, is_headshot: bool, entity_id: int) -> void:
	if net.is_host and damage > 0.0:
		enemy_hurt_presentation.rpc(entity_id, damage, position, is_headshot)


func _add_host_peer(peer_id: int) -> void:
	if _players.has(peer_id):
		return
	var node := _instantiate_player(_spawn_position(_players.size()), peer_id)
	_register_host_player(peer_id, node, false)
	_broadcast_spawn_player(peer_id)


# ---------------------------------------------------------------- Host-authoritative combat

func _is_network_regression_loadout() -> bool:
	return "--net-test=host" in OS.get_cmdline_user_args() and _get_network_primary_loadout_weapon() != null


func _configure_network_loadout(state: PlayerState, node: CharacterBody2D) -> void:
	var primary_weapon := _get_network_primary_loadout_weapon()
	if not state or not is_instance_valid(node) or not primary_weapon or not NETWORK_KNIFE:
		return
	# 不使用 WeaponData.weapon_slot：现有手枪和小刀资源都写成了 1。
	# 正常联机默认手枪；无头回归可由本机启动参数选择白名单中的主武器，仍不接受 Client RPC 的武器数据。
	state.equipment["primary"] = primary_weapon
	state.equipment["secondary"] = NETWORK_KNIFE
	state.active_weapon_slot = "primary"
	state.set_magazine_ammo(primary_weapon.item_id, primary_weapon.magazine_capacity)
	node.enter_weapon_mode(primary_weapon)
	node.set_weapon_ready_frame()


func _get_network_primary_loadout_weapon() -> WeaponData:
	var has_pickup_test := false
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--net-test-pickup" or argument == "--net-test-throwable-pickup":
			has_pickup_test = true
			continue
		if not argument.begins_with("--net-test-weapon="):
			continue
		var weapon_id := argument.trim_prefix("--net-test-weapon=")
		var requested := _get_network_weapon_data_by_id(weapon_id)
		if requested and requested.is_ranged:
			return requested
		push_warning("[NetworkWorld] 忽略无效的联机回归主武器: %s" % weapon_id)
	# 掉落物回归必须从“已装备的另一把远程武器”开始，才能验证替换与旧武器回落。
	# 仅对专用无头测试提供默认值，不改变正常联机大厅的权威装备来源。
	return NETWORK_SMG if has_pickup_test else null

func _get_network_weapon_data_by_id(weapon_id: String) -> WeaponData:
	return NETWORK_WEAPONS.get(weapon_id) as WeaponData


func _get_network_throwable_data_by_id(item_id: String) -> ThrowableData:
	return NETWORK_THROWABLES.get(item_id) as ThrowableData


func _get_network_special_data(special_id: String) -> SpecialEnemyData:
	if special_id.is_empty():
		return null
	return NETWORK_SPECIALS.get(special_id) as SpecialEnemyData


func _get_network_variant_data(variant_id: String) -> ZombieVariant:
	if variant_id.is_empty():
		return null
	return NETWORK_VARIANTS.get(variant_id) as ZombieVariant


func _get_host_throwable_state(peer_id: int) -> Dictionary:
	return _network_throwable_state.get(peer_id, {"held": false, "aiming": false, "range": 3}) as Dictionary


func _is_host_throwable_held(peer_id: int) -> bool:
	return bool(_get_host_throwable_state(peer_id).get("held", false))


## 玩家死亡后取消其投掷、主动救援和举放过渡；保留其他队友对该倒地玩家的救援进度。
func _clear_host_combat_state_for_dead_peer(peer_id: int) -> void:
	if not net.is_host:
		return
	if _is_host_throwable_held(peer_id):
		_network_throwable_state[peer_id] = {"held": false, "aiming": false, "range": 3}
		_apply_host_throwable_presentation(peer_id)
	_revive_attempts.erase(peer_id)
	_weapon_transition_state.erase(peer_id)
	_combat_busy_until_msec.erase(peer_id)
	_send_host_facing_lock_state(peer_id)


func _apply_host_throwable_presentation(peer_id: int) -> void:
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node):
		return
	var throw_state := _get_host_throwable_state(peer_id)
	var td: ThrowableData = state.throwable if state else null
	node.apply_network_throwable_presentation(td, bool(throw_state.get("held", false)), bool(throw_state.get("aiming", false)), int(throw_state.get("range", 3)))


func _try_host_set_throwable_held(peer_id: int, held: bool) -> void:
	if not net.is_host or not _players.has(peer_id) or _is_host_combat_busy(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0:
		return
	var td: ThrowableData = state.throwable
	if held and not td:
		return
	_network_throwable_state[peer_id] = {"held": held, "aiming": false, "range": clampi(int(_get_host_throwable_state(peer_id).get("range", 3)), 0, td.throw_range_max if td else 0)}
	if held:
		node.exit_weapon_mode()
		node.unlock_facing()
	_apply_host_throwable_presentation(peer_id)
	throwable_state_presentation.rpc(peer_id, td.item_id if td else "", held, false, int(_get_host_throwable_state(peer_id).get("range", 3)))
	_send_host_facing_lock_state(peer_id)


func _try_host_set_throwable_aiming(peer_id: int, aiming: bool) -> void:
	if not net.is_host or not _players.has(peer_id) or _is_host_combat_busy(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var throw_state := _get_host_throwable_state(peer_id)
	var td: ThrowableData = state.throwable if state else null
	if not is_instance_valid(node) or not td or not bool(throw_state.get("held", false)) or node.current_hp <= 0.0:
		return
	throw_state["aiming"] = aiming
	_network_throwable_state[peer_id] = throw_state
	_apply_host_throwable_presentation(peer_id)
	throwable_state_presentation.rpc(peer_id, td.item_id, true, aiming, int(throw_state.get("range", 3)))
	_send_host_facing_lock_state(peer_id)


func _try_host_adjust_throwable_range(peer_id: int, delta: int) -> void:
	if not net.is_host or not _players.has(peer_id) or abs(delta) > 1:
		return
	var entry: Dictionary = _players[peer_id]
	var state := entry.get("state") as PlayerState
	var throw_state := _get_host_throwable_state(peer_id)
	var td: ThrowableData = state.throwable if state else null
	if not td or not bool(throw_state.get("held", false)) or not bool(throw_state.get("aiming", false)):
		return
	throw_state["range"] = clampi(int(throw_state.get("range", 3)) + delta, 0, td.throw_range_max)
	_network_throwable_state[peer_id] = throw_state
	_apply_host_throwable_presentation(peer_id)
	throwable_state_presentation.rpc(peer_id, td.item_id, true, true, int(throw_state["range"]))


func _try_host_throw_throwable(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id) or _is_host_combat_busy(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var throw_state := _get_host_throwable_state(peer_id)
	var td: ThrowableData = state.throwable if state else null
	if not is_instance_valid(node) or not td or node.current_hp <= 0.0 or not bool(throw_state.get("held", false)) or not bool(throw_state.get("aiming", false)):
		return
	var start := node.global_position
	var landing_position: Vector2 = start + node.get_facing_vector() * (clampi(int(throw_state.get("range", 3)), 0, td.throw_range_max) * 32.0)
	state.consume_throwable()
	_network_throwable_state[peer_id] = {"held": false, "aiming": false, "range": 3}
	if state.throwable and state.throwable_count > 0:
		# 炸药类叠数投掷物：槽没空 → 保留举起外观，只清瞄准状态
		node.apply_network_throwable_presentation(td, false, false, 3)
		throwable_state_presentation.rpc(peer_id, td.item_id, false, false, 3)
	else:
		node.apply_network_throwable_presentation(null, false, false, 3)
		throwable_state_presentation.rpc(peer_id, "", false, false, 3)
	ThrowableProjectile.spawn(td, start, landing_position, node, true, false)
	throwable_presentation.rpc(peer_id, td.item_id, start, landing_position)
	print("[NetworkWorld] HOST_THROWABLE peer=%d item=%s" % [peer_id, td.item_id])


func _get_attack_cooldown_msec(wd: WeaponData) -> int:
	var seconds := 0.0
	if wd.is_ranged:
		for index: int in range(wd.attack_char_sequence.size()):
			seconds += wd.get_attack_frame_duration(index)
	else:
		var melee_sequence: Array[int] = wd.get_melee_attack_char_sequence()
		for index: int in range(melee_sequence.size()):
			seconds += wd.get_melee_attack_frame_duration(index)
	seconds = maxf(0.1, seconds / maxf(0.01, wd.attack_speed))
	return int(roundi(seconds * 1000.0))


func _is_host_combat_busy(peer_id: int) -> bool:
	return Time.get_ticks_msec() < int(_combat_busy_until_msec.get(peer_id, 0))


func _get_network_weapon_transition_duration(wd: WeaponData) -> float:
	if not wd:
		return 0.1
	var duration := 0.0
	for index: int in range(wd.get_raise_char_sequence().size()):
		duration += wd.get_raise_frame_duration(index)
	return maxf(0.1, duration)


func _clear_host_weapon_transition_after(peer_id: int, duration: float) -> void:
	if duration > 0.0 and is_inside_tree():
		await get_tree().create_timer(duration).timeout
	if is_inside_tree():
		_weapon_transition_state.erase(peer_id)


func _try_host_weapon_switch(peer_id: int, slot: String) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	if slot != "primary" and slot != "secondary":
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0 or _is_host_combat_busy(peer_id) or _is_host_throwable_held(peer_id):
		return
	var wd := state.get_equipped_weapon(slot)
	if not wd or state.active_weapon_slot == slot:
		return
	state.active_weapon_slot = slot
	if node.is_weapon_mode_active():
		node.enter_weapon_mode(wd)
		node.set_weapon_ready_frame()
	print("[NetworkWorld] HOST_WEAPON_SWITCH peer=%d slot=%s weapon=%s" % [peer_id, slot, wd.item_id])


func _try_host_toggle_weapon(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var wd: WeaponData = state.get_active_weapon() if state else null
	if not is_instance_valid(node) or not wd or node.current_hp <= 0.0 or _is_host_combat_busy(peer_id) or _is_host_throwable_held(peer_id):
		return
	var raising: bool = not node.is_weapon_mode_active()
	var duration := _get_network_weapon_transition_duration(wd)
	_combat_busy_until_msec[peer_id] = Time.get_ticks_msec() + int(ceili(duration * 1000.0))
	_weapon_transition_state[peer_id] = "raising" if raising else "lowering"
	node.play_network_weapon_transition(wd, raising)
	weapon_transition_presentation.rpc(peer_id, wd.item_id, raising)
	_clear_host_weapon_transition_after(peer_id, duration)
	print("[NetworkWorld] HOST_WEAPON_TOGGLE peer=%d transition=%s" % [peer_id, _weapon_transition_state[peer_id]])


## Host 保留唯一朝向权威：客户端仅提交操作意图，结果通过可靠确认回传。
func _try_host_set_facing_lock(peer_id: int, toggle: bool, locked: bool) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(node) or node.current_hp <= 0.0 or not node.is_weapon_mode_active() or _is_host_combat_busy(peer_id) or _is_host_throwable_held(peer_id):
		_send_host_facing_lock_state(peer_id)
		return
	var desired_locked: bool = (not node.is_facing_locked()) if toggle else locked
	node.apply_facing_lock_state(desired_locked, node.facing)
	_send_host_facing_lock_state(peer_id)
	print("[NetworkWorld] HOST_FACING_LOCK peer=%d locked=%s" % [peer_id, node.is_facing_locked()])


func _send_host_facing_lock_state(peer_id: int) -> void:
	if not net.is_host or peer_id <= 1 or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if not is_instance_valid(node):
		return
	facing_lock_presentation.rpc(peer_id, node.is_facing_locked(), node.get_locked_facing())


## Host 权威换弹：立即提交库存/弹夹结果，并在动画持续时间内锁住射击、切枪和举放。
## 这样客户端永远不能伪造备用弹药或通过重复 RPC 多扣/多装。
func _try_host_reload(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id) or _is_host_combat_busy(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0 or not node.is_weapon_mode_active() or _is_host_throwable_held(peer_id):
		return
	var wd := state.get_active_weapon()
	if not wd or not wd.is_ranged or wd.magazine_capacity <= 0:
		return
	var current := state.get_magazine_ammo(wd.item_id)
	var missing := maxi(0, wd.magazine_capacity - current)
	var available := state.count_ammo_item(wd.ammo_item_id)
	var load_count := mini(missing, available)
	if load_count <= 0:
		return
	if state.consume_ammo_item(wd.ammo_item_id, load_count) != load_count:
		return
	state.set_magazine_ammo(wd.item_id, current + load_count)
	var duration := _get_network_reload_duration(wd, load_count)
	_combat_busy_until_msec[peer_id] = Time.get_ticks_msec() + int(ceili(duration * 1000.0))
	node.play_network_reload_presentation(wd, load_count)
	reload_presentation.rpc(peer_id, wd.item_id, current + load_count, load_count)
	print("[NetworkWorld] HOST_RELOAD peer=%d weapon=%s loaded=%d ammo=%d" % [peer_id, wd.item_id, load_count, current + load_count])


func _get_network_reload_duration(wd: WeaponData, load_count: int) -> float:
	if not wd:
		return 0.1
	var duration := wd.reload_wait_duration
	if wd.reload_mode == WeaponData.ReloadMode.SHOTGUN:
		for index: int in range(wd.get_shotgun_loop_char_sequence().size()):
			duration += wd.get_shotgun_loop_frame_duration(index) * load_count
		for index: int in range(wd.get_shotgun_end_char_sequence().size()):
			duration += wd.get_shotgun_end_frame_duration(index)
	else:
		for index: int in range(wd.get_reload_char_sequence().size()):
			duration += wd.get_reload_frame_duration(index)
	return maxf(0.1, duration)


## Host 权威推击：客户端只发送一次意图；命中查询、击退和疲劳均只在 Host 执行。
func _try_host_shove(peer_id: int, claimed_position: Variant = null) -> void:
	if not net.is_host or not _players.has(peer_id) or _is_host_combat_busy(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0 or not node.is_weapon_mode_active() or not node.can_shove() or _is_host_throwable_held(peer_id):
		return
	# 滞后补偿：推击的命中查询在权威坐标上做，先对齐客户端自报位置。
	_apply_lag_compensated_position(peer_id, node, claimed_position)
	var wd := state.get_active_weapon()
	if not wd:
		return
	var duration := maxf(0.05, wd.shove_frame_duration * wd.get_shove_char_sequence().size())
	_combat_busy_until_msec[peer_id] = Time.get_ticks_msec() + int(ceili(duration * 1000.0))
	var facing: Vector2 = node.get_facing_vector()
	node.on_shove_performed()
	node.play_network_shove_presentation(wd)
	shove_presentation.rpc(peer_id, wd.item_id)
	_schedule_host_shove_hit(node, wd, facing)
	print("[NetworkWorld] HOST_SHOVE peer=%d weapon=%s" % [peer_id, wd.item_id])


func _schedule_host_shove_hit(node: CharacterBody2D, wd: WeaponData, facing: Vector2) -> void:
	if not is_inside_tree():
		return
	var delay := wd.shove_frame_duration * clampi(wd.shove_hit_at_sequence_idx, 0, wd.get_shove_char_sequence().size())
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if is_inside_tree() and is_instance_valid(node) and node.is_inside_tree():
		_perform_host_shove(node, wd, facing)


func _perform_host_shove(node: CharacterBody2D, wd: WeaponData, facing: Vector2) -> void:
	var shape := RectangleShape2D.new()
	shape.size = wd.shove_range_size
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	var center := node.global_position + facing * wd.shove_range_forward_offset
	query.transform = Transform2D(0.0, center)
	query.collision_mask = 24
	query.exclude = [node.get_rid()]
	query.collide_with_bodies = true
	query.collide_with_areas = true
	var results: Array[Dictionary] = node.get_world_2d().direct_space_state.intersect_shape(query, 64)
	var hit_enemies: Dictionary = {}
	for result: Dictionary in results:
		var collider := result.get("collider") as Node
		if not is_instance_valid(collider):
			continue
		for enemy_entry: Dictionary in _enemies.values():
			var enemy := _resolve_enemy_entry(enemy_entry)
			if not is_instance_valid(enemy) or enemy.get("_is_dead") == true or (collider != enemy and not enemy.is_ancestor_of(collider)):
				continue
			var enemy_id := enemy.get_instance_id()
			if not hit_enemies.has(enemy_id):
				hit_enemies[enemy_id] = true
				enemy.take_damage(0.0, wd.shove_knockback_force, facing, false, wd.shove_knockback_duration, 0.0, int(Time.get_ticks_msec()))
				print("[NetworkWorld] HOST_SHOVE_HIT enemy=%s" % enemy.name)
			break
	if hit_enemies.is_empty() or wd.shove_splash_radius <= 0.0:
		return
	for enemy_entry: Dictionary in _enemies.values():
		var enemy := _resolve_enemy_entry(enemy_entry)
		if not is_instance_valid(enemy) or enemy.get("_is_dead") == true or hit_enemies.has(enemy.get_instance_id()):
			continue
		var distance := enemy.global_position.distance_to(center)
		if distance > wd.shove_splash_radius:
			continue
		var splash_direction := (enemy.global_position - center).normalized()
		if splash_direction.is_zero_approx():
			splash_direction = facing
		var falloff := 1.0 - (distance / wd.shove_splash_radius) * 0.5
		enemy.take_damage(0.0, wd.shove_knockback_force * falloff, splash_direction, false, wd.shove_knockback_duration * falloff, 0.0, int(Time.get_ticks_msec()))


func _try_host_attack(peer_id: int, claimed_position: Variant = null) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0 or _is_host_combat_busy(peer_id) or _is_host_throwable_held(peer_id):
		return
	# 滞后补偿：近战形状查询/子弹出生点都在权威坐标上算，先对齐客户端自报位置
	# （近战尤其敏感——实测 weapon 用例在无补偿时连续挥空）。
	_apply_lag_compensated_position(peer_id, node, claimed_position)
	# 武器完全从 Host 当前 PlayerState 读取，客户端 RPC 不携带 weapon_id/目标/伤害等参数。
	var wd := state.get_active_weapon()
	if not wd or not node.is_weapon_mode_active():
		return
	var now := Time.get_ticks_msec()
	var cooldown_msec := _get_attack_cooldown_msec(wd)
	var attack_key := "%d:%s" % [peer_id, wd.item_id]
	if now - int(_last_attack_msec.get(attack_key, -cooldown_msec)) < cooldown_msec:
		return
	_last_attack_msec[attack_key] = now

	if wd.is_ranged:
		if wd.magazine_capacity <= 0 or wd.bullet_list.is_empty():
			return
		var current := state.get_magazine_ammo(wd.item_id)
		if current <= 0:
			return
		state.set_magazine_ammo(wd.item_id, current - 1)
		_sync_state_from_node(peer_id, node, bool(entry.get("moving", false)), bool(entry.get("walking", false)))
		node.play_network_attack_presentation(wd)
		attack_presentation.rpc(peer_id, wd.item_id, current - 1)
		var bullet_index := 0
		for bd: BulletData in wd.bullet_list:
			_spawn_host_bullet(peer_id, node, wd, bd, bullet_index)
			bullet_index += 1
		if wd.gunshot_range > 0.0:
			_alert_host_enemies(node, wd.gunshot_range)
		print("[NetworkWorld] HOST_FIRE peer=%d ammo=%d bullets=%d" % [peer_id, current - 1, wd.bullet_list.size()])
		return

	var is_headshot := wd.critical_rate > 0.0 and randf() * 100.0 < wd.critical_rate
	node.play_network_attack_presentation(wd)
	# -1 表示近战无弹夹变化；客户端只播放 Host 确认的表现。
	attack_presentation.rpc(peer_id, wd.item_id, -1)
	_schedule_host_melee_hit(node, wd, is_headshot)
	print("[NetworkWorld] HOST_MELEE peer=%d weapon=%s" % [peer_id, wd.item_id])


func _schedule_host_melee_hit(node: CharacterBody2D, wd: WeaponData, is_headshot: bool) -> void:
	# 避免切图释放 NetworkWorld 后，旧协程再访问空的 SceneTree。
	if not is_inside_tree():
		return
	var tree := get_tree()
	if not tree:
		return
	var delay := 0.0
	for index: int in range(mini(wd.melee_hit_at_sequence_idx, wd.get_melee_attack_char_sequence().size())):
		delay += wd.get_melee_attack_frame_duration(index)
	if delay > 0.0:
		await tree.create_timer(delay).timeout
	if is_inside_tree() and is_instance_valid(node) and node.is_inside_tree():
		_perform_host_melee_attack(node, wd, is_headshot)


func _perform_host_melee_attack(node: CharacterBody2D, wd: WeaponData, is_headshot: bool) -> void:
	var shape := RectangleShape2D.new()
	shape.size = wd.melee_range_size
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = Transform2D(0.0, node.global_position + node.get_facing_vector() * wd.melee_range_forward_offset)
	query.collision_mask = 24 # 敌人 body (layer 4) + hurtbox (layer 5)
	query.exclude = [node.get_rid()]
	query.collide_with_bodies = true
	query.collide_with_areas = true
	# NetworkWorld 是普通 Node；物理 World2D 应从挥刀者这个 CanvasItem 取得。
	var results: Array[Dictionary] = node.get_world_2d().direct_space_state.intersect_shape(query, 64)
	var hit_enemy_ids: Dictionary = {}
	for result: Dictionary in results:
		var collider := result.get("collider") as Node
		if not is_instance_valid(collider):
			continue
		for enemy_entry: Dictionary in _enemies.values():
			var enemy := _resolve_enemy_entry(enemy_entry)
			if not is_instance_valid(enemy) or enemy.get("_is_dead") == true:
				continue
			if collider != enemy and not enemy.is_ancestor_of(collider):
				continue
			var enemy_id := enemy.get_instance_id()
			if hit_enemy_ids.has(enemy_id):
				break
			hit_enemy_ids[enemy_id] = true
			var melee_damage: float = wd.get_effective_damage() * (wd.critical_damage if is_headshot else 1.0)
			enemy.take_damage(melee_damage, 0.0, node.get_facing_vector(), is_headshot, 0.0, wd.hitstun_duration, 0, wd.element)
			print("[NetworkWorld] HOST_MELEE_HIT enemy=%s damage=%d headshot=%s" % [enemy.name, int(melee_damage), is_headshot])
			break


func _spawn_host_bullet(peer_id: int, shooter: CharacterBody2D, wd: WeaponData, bd: BulletData, bullet_index: int) -> void:
	var bullet_id := _next_bullet_id
	_next_bullet_id += 1
	var direction := bd.get_fire_direction(shooter.get_facing_vector())
	## 枪口偏移与单机同规则（2026-09-16）：角色专属（WeaponData.bullet_spawn_offsets）
	## **配置了条目即生效**（显式 (0,0) 合法）；未配置回退 BulletData 的逐方向 offset_*。
	## 两端必须用同一套，否则联机弹道错位。
	var shooter_cd: CharacterData = shooter.get("current_character") as CharacterData
	var muzzle_extra: Vector2
	if wd.has_bullet_spawn_offset(shooter_cd):
		muzzle_extra = wd.get_bullet_spawn_offset(shooter_cd, shooter.facing)
	else:
		muzzle_extra = bd.get_extra_offset(shooter.facing)
	var start_position := shooter.global_position + direction * bd.spawn_offset + muzzle_extra
	var bullet := BULLET_SCENE.instantiate() as Node2D
	if not bullet:
		return
	bullet.setup({
		"network_entity_id": bullet_id,
		"network_visual_only": false,
		"direction": direction,
		"speed": bd.speed,
		"max_range": bd.max_range,
		"damage": bd.get_effective_damage(wd.attack_power),
		"destroy_on_hit": bd.destroy_on_hit,
		"penetration": bd.penetration,
		"critical_rate": wd.critical_rate,
		"critical_damage": wd.critical_damage,
		"element": wd.element,
		"hit_effect_anim": wd.hit_effect_anim,
		"hit_effect_follow": wd.hit_effect_follow,
		"hit_effect_offset_override": wd.hit_effect_offset_override,
		"hit_sound": wd.hit_sound,
		"texture": bd.bullet_texture,
		"anim_frames": bd.bullet_anim_frames,
		"frame_duration": bd.bullet_frame_duration,
		"collision_size": bd.collision_size,
		"collision_offset": bd.collision_offset,
		"spawn_offset": bd.spawn_offset,
		"knockback_force": bd.knockback_force if bd.knockback_enabled else 0.0,
		"knockback_stun": bd.knockback_stun_duration if bd.knockback_enabled else 0.0,
		"hitstun_duration": bd.hitstun_duration if bd.hitstun_duration > 0.0 else wd.hitstun_duration,
		"shooter": shooter,
		# 覚醒（集中射撃）即死・怯み（C1 补缺）：单机走 PlayerPistolAttackState 同款
		# 判定（awaken or bd.instant_kill）；Host node 的 _awaken_active 由
		# awaken_request 权威流程维护，Host 权威弹据此携带即死标志。
		"instant_kill": shooter.is_awaken_active() or bd.instant_kill,
	})
	bullet.global_position = start_position
	get_tree().current_scene.add_child(bullet)
	_bullets[bullet_id] = bullet
	bullet.finished.connect(_on_host_bullet_finished)
	# Client 只从 Host 确认的白名单 weapon_id + 弹丸索引还原视觉弹道，绝不接收伤害或子弹数据对象。
	spawn_bullet.rpc(bullet_id, peer_id, start_position, direction, wd.item_id, bullet_index)


func _on_host_bullet_finished(bullet_id: int) -> void:
	if not _bullets.has(bullet_id):
		return
	_bullets.erase(bullet_id)
	despawn_bullet.rpc(bullet_id)


func _alert_host_enemies(shooter: CharacterBody2D, range: float) -> void:
	for enemy: Node in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(enemy) and enemy.global_position.distance_to(shooter.global_position) <= range and enemy.has_method("alert_by_gunshot"):
			enemy.alert_by_gunshot(shooter)


# ---------------------------------------------------------------- Explicit lifecycle and RPCs

@rpc("any_peer", "call_remote", "reliable")
func weapon_switch_request(slot: String) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_weapon_switch(sender, slot)


@rpc("any_peer", "call_remote", "reliable")
func weapon_toggle_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_toggle_weapon(sender)


@rpc("any_peer", "call_remote", "reliable")
func facing_lock_request(toggle: bool, locked: bool) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_set_facing_lock(sender, toggle, locked)


@rpc("authority", "call_remote", "reliable")
func facing_lock_presentation(peer_id: int, locked: bool, locked_facing: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if not is_instance_valid(node):
		return
	_facing_lock_requests.erase(peer_id)
	node.apply_facing_lock_state(locked, locked_facing)
	print("[NetworkWorld] CLIENT_FACING_LOCK peer=%d locked=%s facing=%d" % [peer_id, locked, locked_facing])


@rpc("any_peer", "call_remote", "reliable")
func fire_request(claimed_position: Variant = null) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_attack(sender, claimed_position)


@rpc("any_peer", "call_remote", "reliable")
func shove_request(claimed_position: Variant = null) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_shove(sender, claimed_position)


@rpc("authority", "call_remote", "reliable")
func shove_presentation(peer_id: int, weapon_id: String) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var wd := _get_network_weapon_data_by_id(weapon_id)
	if is_instance_valid(node) and wd:
		node.play_network_shove_presentation(wd)


@rpc("authority", "call_remote", "reliable")
func weapon_transition_presentation(peer_id: int, weapon_id: String, raising: bool) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var wd := _get_network_weapon_data_by_id(weapon_id)
	if is_instance_valid(node) and wd:
		_weapon_transition_state[peer_id] = "raising" if raising else "lowering"
		node.play_network_weapon_transition(wd, raising)
		_clear_host_weapon_transition_after(peer_id, _get_network_weapon_transition_duration(wd))


@rpc("any_peer", "call_remote", "reliable")
func reload_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_reload(sender)


@rpc("authority", "call_remote", "reliable")
func reload_presentation(peer_id: int, weapon_id: String, magazine_ammo: int, loaded_count: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var wd := _get_network_weapon_data_by_id(weapon_id)
	if not state or not is_instance_valid(node) or not wd:
		return
	state.set_magazine_ammo(wd.item_id, magazine_ammo)
	node.play_network_reload_presentation(wd, loaded_count)


@rpc("any_peer", "call_remote", "reliable")
func awaken_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_awaken(sender)


## Host：覚醒（集中射撃）发动结算（C1）。武器/存活可查 node，TP 为 PlayerState
## 权威值；发动核心走 _activate_awaken_core（无 Input 读取）。成功后广播染色表现，
## 并记入 _awaken_active_peers 供中途加入的 Client 补发。
func _try_host_awaken(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0:
		return
	if not node.is_weapon_mode_active():
		return
	var cd: CharacterData = node.get("current_character") as CharacterData
	if cd == null or cd.awaken_type == "none":
		return
	if state.current_tp <= 0:
		return
	if not node._activate_awaken_core():
		return
	_awaken_active_peers[peer_id] = true
	awaken_presentation.rpc(peer_id, true)
	print("[NetworkWorld] HOST_AWAKEN peer=%d tp=%d" % [peer_id, state.current_tp])


## Host：player._deactivate_awaken 的统一解除出口（TP 耗尽/死亡/放下武器）调用。
## 单机（无 NetworkWorld 节点）或 Client 端为 no-op。
func announce_player_awaken(node: Node2D, active: bool) -> void:
	if not net.is_host:
		return
	if active:
		return  # 激活广播只走 _try_host_awaken（含白名单记录）
	var peer_id := _peer_id_for_node(node)
	if peer_id <= 0 or not _awaken_active_peers.has(peer_id):
		return
	_awaken_active_peers.erase(peer_id)
	awaken_presentation.rpc(peer_id, false)
	print("[NetworkWorld] HOST_AWAKEN_OFF peer=%d" % peer_id)


func _peer_id_for_node(node: Node2D) -> int:
	for peer_id: int in _players.keys():
		if _players[peer_id].get("node") == node:
			return peer_id
	return 0


## Client：覚醒染色表现（发起者本人 + 其余远端玩家同款；后续 TP 各域独立推进）。
@rpc("authority", "call_remote", "reliable")
func awaken_presentation(peer_id: int, active: bool) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("apply_network_awaken_state"):
		node.call("apply_network_awaken_state", active)
	if _is_auto_network_feature_test():
		_auto_client_awaken_presentations += 1
	print("[NetworkWorld] CLIENT_AWAKEN peer=%d active=%s" % [peer_id, active])


# ── C2：SA / 见切 / 反击 请求-表现协议 ──

@rpc("any_peer", "call_remote", "reliable")
func sa_skill_request(trigger: String) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_sa_skill(sender, trigger)


## Host：SA 技能释放结算（C2）。存活在此校验，搓招（motion_ok=true，信任 Client
## 预校验）与 TP（PlayerState 权威值）在 _use_skill_core 内完成；效果结算
## （RECITAL 敌人组 / SEEKER 置位 / CROUCH 蹲下）天然权威，成功后经
## _execute_skill_effect 尾部的 announce 广播 sa_presentation。
func _try_host_sa_skill(peer_id: int, trigger: String) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if not is_instance_valid(node) or node.current_hp <= 0.0:
		return
	node._use_skill_core(trigger, true)


@rpc("any_peer", "call_remote", "reliable")
func mukiri_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_mukiri(sender)


## Host：见切窗口登记（C2）。_try_mukiri_input 只读 Time/Heat 状态零拆分直调；
## 窗口登记在 Host 权威实体上，命中无效化判定（_should_negate_hit，受击路径
## Host 权威）天然生效，见切成功动画经 announce 广播 mukiri_presentation。
func _try_host_mukiri(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if not is_instance_valid(node) or node.current_hp <= 0.0:
		return
	node._try_mukiri_input()


@rpc("any_peer", "call_remote", "reliable")
func sa_crouch_hold(active: bool) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	var node := (_players[sender] as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("set_network_crouch_hold"):
		node.call("set_network_crouch_hold", active)


## Host：player 侧 SA/见切/反击/Heat 事件统一出口（C2）。结算发生在哪个实体
## 就广播哪个 peer（含 Host 本机玩家，Client 据此表现远端 Host 玩家）；
## 单机（无 NetworkWorld 节点）与 Client 端 no-op。
## 事件 → 表现分发："sa:<trigger>" / "crouch_end" / "mukiri" / "counter" / "heat"。
func announce_player_sa_event(node: Node2D, event: String) -> void:
	if not net.is_host:
		return
	var peer_id := _peer_id_for_node(node)
	if peer_id <= 0:
		return
	if event.begins_with("sa:"):
		var trigger := event.substr(3)
		sa_presentation.rpc(peer_id, trigger)
		print("[NetworkWorld] HOST_SA peer=%d trigger=%s" % [peer_id, trigger])
		return
	match event:
		"crouch_end":
			crouch_end_presentation.rpc(peer_id)
			print("[NetworkWorld] HOST_CROUCH_END peer=%d" % peer_id)
		"mukiri":
			mukiri_presentation.rpc(peer_id)
			print("[NetworkWorld] HOST_MUKIRI peer=%d" % peer_id)
		"counter":
			counter_presentation.rpc(peer_id)
			print("[NetworkWorld] HOST_COUNTER peer=%d" % peer_id)
		"heat":
			heat_presentation.rpc(peer_id)
			print("[NetworkWorld] HOST_HEAT peer=%d" % peer_id)


## Client：SA 技能表现（发起者本人 + 远端玩家同款）——音效/蹲下染色/感覚向上
## 计时由 player.apply_network_sa_skill 按本地同名技能解析，零资源传输。
@rpc("authority", "call_remote", "reliable")
func sa_presentation(peer_id: int, trigger: String) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("apply_network_sa_skill"):
		node.call("apply_network_sa_skill", trigger)
	if _is_auto_network_feature_test():
		_auto_client_sa_presentations += 1
	print("[NetworkWorld] CLIENT_SA peer=%d trigger=%s" % [peer_id, trigger])


## Client：蹲下结束对齐（Host 权威侧超时/TP 尽/死亡广播；幂等）。
@rpc("authority", "call_remote", "reliable")
func crouch_end_presentation(peer_id: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("apply_network_crouch_end"):
		node.call("apply_network_crouch_end")
	print("[NetworkWorld] CLIENT_CROUCH_END peer=%d" % peer_id)


## Client：见切成功动画（远端玩家播同款见切行走图序列）。
@rpc("authority", "call_remote", "reliable")
func mukiri_presentation(peer_id: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("_play_mukiri_anim"):
		node.call("_play_mukiri_anim")
	print("[NetworkWorld] CLIENT_MUKIRI peer=%d" % peer_id)


## Client：反击音效（反击伤害/击退结算在 Host，快照体现）。
@rpc("authority", "call_remote", "reliable")
func counter_presentation(peer_id: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("play_network_counter_presentation"):
		node.call("play_network_counter_presentation")
	print("[NetworkWorld] CLIENT_COUNTER peer=%d" % peer_id)


## Client：Heat 染色 + 本地计时置位（到期褪色由实体自身 _update_network_sa_state 推进）。
@rpc("authority", "call_remote", "reliable")
func heat_presentation(peer_id: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("apply_network_heat_state"):
		node.call("apply_network_heat_state")
	print("[NetworkWorld] CLIENT_HEAT peer=%d" % peer_id)


## Host：丸呑み吞入/吐出表现广播（C3）。EnemySwallowState._hide_victim /
## _restore_victim 经 player.apply_network_swallow_state 之外的统一出口调用；
## 单机（无 NetworkWorld 节点）与 Client 端 no-op。
## enemy 尚未收编（entity_id≤0）或受害者不属于任何 peer（不该发生）时丢弃本次
## 表现——吞入整段约 1.3s，被吞玩家短暂数帧可见可接受，不为此补发快照。
func announce_enemy_swallow(enemy: Node2D, victim: Node2D, active: bool) -> void:
	if not net.is_host:
		return
	var entity_id: int = 0
	if enemy != null and is_instance_valid(enemy):
		entity_id = int(enemy.get("network_entity_id"))
	var peer_id := _peer_id_for_node(victim)
	if entity_id <= 0 or peer_id <= 0:
		return
	swallow_presentation.rpc(entity_id, peer_id, active)
	print("[NetworkWorld] HOST_SWALLOW entity=%d peer=%d active=%s" % [entity_id, peer_id, active])


## Client：被吞玩家隐藏/恢复（与 Host 侧 _hide_victim/_restore_victim 同款：
## visible + 碰撞闸 + network_swallow_locked 锁；Client 本地预测移动与输入
## 提交由锁经 inputs_frozen / _predict_client_local_movement 冻结）。
@rpc("authority", "call_remote", "reliable")
func swallow_presentation(entity_id: int, peer_id: int, active: bool) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var node := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("apply_network_swallow_state"):
		node.call("apply_network_swallow_state", active)
	if _is_auto_network_feature_test():
		_auto_client_swallow_presentations += 1
	print("[NetworkWorld] CLIENT_SWALLOW entity=%d peer=%d active=%s" % [entity_id, peer_id, active])


@rpc("any_peer", "call_remote", "reliable")
func revive_start_request(target_peer_id: int) -> void:
	if net.is_host:
		var sender := multiplayer.get_remote_sender_id()
		if sender > 1:
			_try_host_start_revive(sender, target_peer_id)


@rpc("any_peer", "call_remote", "reliable")
func revive_cancel_request() -> void:
	if net.is_host:
		var sender := multiplayer.get_remote_sender_id()
		if sender > 1:
			_cancel_host_revive(sender)


@rpc("authority", "call_remote", "reliable")
func revive_presentation(target_peer_id: int, hp: float) -> void:
	if net.is_host or not _players.has(target_peer_id):
		return
	var entry: Dictionary = _players[target_peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if state:
		state.current_hp = hp
	if is_instance_valid(node):
		node.apply_network_revive_state(hp)


@rpc("any_peer", "call_remote", "reliable")
func throwable_hold_request(held: bool) -> void:
	if net.is_host:
		var sender := multiplayer.get_remote_sender_id()
		if sender > 1:
			_try_host_set_throwable_held(sender, held)


@rpc("any_peer", "call_remote", "reliable")
func throwable_aim_request(aiming: bool) -> void:
	if net.is_host:
		var sender := multiplayer.get_remote_sender_id()
		if sender > 1:
			_try_host_set_throwable_aiming(sender, aiming)


@rpc("any_peer", "call_remote", "reliable")
func throwable_range_request(delta: int) -> void:
	if net.is_host:
		var sender := multiplayer.get_remote_sender_id()
		if sender > 1:
			_try_host_adjust_throwable_range(sender, delta)


@rpc("any_peer", "call_remote", "reliable")
func throwable_throw_request() -> void:
	if net.is_host:
		var sender := multiplayer.get_remote_sender_id()
		if sender > 1:
			_try_host_throw_throwable(sender)


@rpc("authority", "call_remote", "reliable")
func throwable_state_presentation(peer_id: int, throwable_id: String, held: bool, aiming: bool, range_tiles: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var td := _get_network_throwable_data_by_id(throwable_id)
	# Host 永远只会发白名单 ID；客户端遇到无效包时安全降级为放下，不能保留旧持物状态。
	var valid_held := held and td != null
	if state:
		# held 只描述表现；只要 Host 仍带着合法 throwable_id，背包中的投掷物就不能被错误清空。
		state.throwable = td
	_network_throwable_state[peer_id] = {"held": valid_held, "aiming": aiming and valid_held, "range": clampi(range_tiles, 0, td.throw_range_max if td else 0)}
	if is_instance_valid(node):
		node.apply_network_throwable_presentation(td, valid_held, aiming and valid_held, range_tiles)


@rpc("authority", "call_remote", "reliable")
func throwable_presentation(peer_id: int, throwable_id: String, start_position: Vector2, end_position: Vector2) -> void:
	if net.is_host or _scene_transitioning:
		return
	var td := _get_network_throwable_data_by_id(throwable_id)
	if not td:
		return
	# 表现 RPC 不依赖远端玩家节点已建立，避免投掷者生成与投掷包竞争时丢失手雷。
	ThrowableProjectile.spawn(td, start_position, end_position, self, false, false)
	print("[NetworkWorld] CLIENT_THROWABLE_PRESENTATION peer=%d item=%s" % [peer_id, throwable_id])


@rpc("authority", "call_remote", "reliable")
func player_hurt_presentation(peer_id: int, damage: float, position: Vector2) -> void:
	if net.is_host or _scene_transitioning:
		return
	var node := (_players.get(peer_id, {}) as Dictionary).get("node") as CharacterBody2D
	if is_instance_valid(node) and node.has_method("play_network_hurt_presentation"):
		node.play_network_hurt_presentation(damage, position)
		if _is_auto_network_feature_test():
			_auto_client_player_hurt_presentations += 1
			print("[NetworkWorld] CLIENT_PLAYER_HURT_PRESENTATION peer=%d damage=%.1f" % [peer_id, damage])


@rpc("authority", "call_remote", "reliable")
func enemy_hurt_presentation(entity_id: int, damage: float, position: Vector2, is_headshot: bool) -> void:
	if net.is_host or _scene_transitioning:
		return
	var node := _resolve_enemy_entry(_enemies.get(entity_id, {}) as Dictionary)
	if is_instance_valid(node) and node.has_method("play_network_hurt_presentation"):
		node.play_network_hurt_presentation(damage, position, is_headshot)
		if _is_auto_network_feature_test():
			_auto_client_enemy_hurt_presentations += 1
			print("[NetworkWorld] CLIENT_ENEMY_HURT_PRESENTATION entity=%d damage=%.1f headshot=%s" % [entity_id, damage, is_headshot])


## Host：EnemySpitState 出酸瞬间调用（A2 酸弹镜像）。单机/Client 调用为 no-op。
## 只传 entity_id + 出口坐标 + 方向；速度/特效/音效由 Client 从本地 enemy 节点字段解析
## （A1 的 apply_to_enemy 注入保证特感节点有值），资源不经网络传输（白名单铁律）。
func announce_enemy_acid_spit(enemy: Node2D, spawn_pos: Vector2, dir: Vector2) -> void:
	if not net.is_host:
		return
	var entity_id: int = enemy.network_entity_id
	if entity_id <= 0:
		# 尚未被收编（吐酸早于 register 周期的极端时序）→ 丢弃本次表现，下次吐酸照常广播。
		return
	enemy_acid_spit_presentation.rpc(entity_id, spawn_pos, dir)


## Client：生成非权威镜像酸弹并播放吐酸音（与 Host 出酸瞬间同帧语义）。
## 镜像弹撞墙/寿命/穿身只播特效音效即焚，伤害与相消全部 Host 判定。
@rpc("authority", "call_remote", "reliable")
func enemy_acid_spit_presentation(entity_id: int, spawn_pos: Vector2, dir: Vector2) -> void:
	if net.is_host or _scene_transitioning:
		return
	var enemy := _resolve_enemy_entry(_enemies.get(entity_id, {}) as Dictionary)
	if not is_instance_valid(enemy):
		return
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = enemy.get_parent()
	EnemyAcidSpit.spawn_mirror(parent, spawn_pos, dir,
		enemy.spit_projectile_speed, enemy.spit_impact_effect, enemy.spit_impact_tone)
	# 吐酸音（Client 本地 enemy 字段解析，与 Host _fire_acid 的出酸瞬间播音同语义）。
	enemy._play_sound(enemy.spit_sound, enemy.spit_sound_pitch)
	if _is_auto_network_feature_test():
		_auto_client_enemy_acid_spits += 1
	print("[NetworkWorld] CLIENT_ENEMY_ACID_SPIT entity=%d pos=%s" % [entity_id, spawn_pos])


## Host：enemy._play_sound 反查命中缺口音效（attack/discover/rage_discover/
## witch_scream/frontal_block）后调用（A3 音效事件化）。单机/Client 调用为 no-op。
## 只传 entity_id + 音效 key + pitch；AudioStream 由 Client 从本地 enemy 节点
## 同名字段解析（A1/A5 注入 + tscn 默认值保证有值），资源不经网络传输。
func announce_enemy_sfx(enemy: Node2D, sfx_key: String, pitch: float) -> void:
	if not net.is_host:
		return
	var entity_id: int = enemy.network_entity_id
	if entity_id <= 0:
		return
	enemy_sfx_presentation.rpc(entity_id, sfx_key, pitch)


## Client：按音效 key 走 enemy.play_network_sfx 本地播放（key→字段映射在 enemy 侧）。
@rpc("authority", "call_remote", "reliable")
func enemy_sfx_presentation(entity_id: int, sfx_key: String, pitch: float) -> void:
	if net.is_host or _scene_transitioning:
		return
	var enemy := _resolve_enemy_entry(_enemies.get(entity_id, {}) as Dictionary)
	if not is_instance_valid(enemy):
		return
	enemy.play_network_sfx(sfx_key, pitch)
	if _is_auto_network_feature_test():
		_auto_client_enemy_sfx += 1
	print("[NetworkWorld] CLIENT_ENEMY_SFX entity=%d key=%s pitch=%.2f" % [entity_id, sfx_key, pitch])


## Host：动作表切换转发（A4，enemy.push_action_texture/restore_walk_texture 挂出）。
## 单机/未收编（闸在 enemy._announce_network_action）与 Client 端 no-op。
## 零资源传输：贴图由 Client 从本地节点字段解析（NETWORK_TEXTURE_FIELDS 反查同表）。
func announce_enemy_action(enemy: Node2D, tex_key: String, char_idx: int, active: bool) -> void:
	if not net.is_host:
		return
	var entity_id: int = enemy.network_entity_id
	if entity_id <= 0:
		return
	enemy_action_presentation.rpc(entity_id, tex_key, char_idx, active)


## Client：动作表切到/恢复（攻击/突进/丸呑み张嘴等独立动作表的视觉预警）。
@rpc("authority", "call_remote", "reliable")
func enemy_action_presentation(entity_id: int, tex_key: String, char_idx: int, active: bool) -> void:
	if net.is_host or _scene_transitioning:
		return
	var enemy := _resolve_enemy_entry(_enemies.get(entity_id, {}) as Dictionary)
	if not is_instance_valid(enemy):
		return
	enemy.apply_network_action_texture(tex_key, char_idx, active)
	if _is_auto_network_feature_test():
		_auto_client_enemy_action += 1
	print("[NetworkWorld] CLIENT_ENEMY_ACTION entity=%d key=%s idx=%d active=%s" % [entity_id, tex_key, char_idx, active])


## Host：Director 尸潮/Boss BGM 真正起停时调用（A6 导演 BGM）。单机/Client 调用
## 为 no-op。只传 music key（"horde"/"boss"）+ 起停标志；AudioStream 由 Client 从
## 本地 Director.current_config 解析（场景切换钩子对所有 peer 生效），资源不经网络传输。
func announce_director_music(music_key: String, active: bool) -> void:
	if not net.is_host:
		return
	director_music_presentation.rpc(music_key, active)


## Client：驱动本机 Director 起停对应 BGM（音源/音量本地解析，boss_music_changed
## 信号一并维护 → Client 的 HoldoutMachine 挂起/恢复防守战 BGM 照常联动）。
@rpc("authority", "call_remote", "reliable")
func director_music_presentation(music_key: String, active: bool) -> void:
	if net.is_host or _scene_transitioning:
		return
	var director: Node = get_node_or_null("/root/Director")
	if director == null or not director.has_method("apply_network_music"):
		return
	director.call("apply_network_music", music_key, active)
	if _is_auto_network_feature_test():
		_auto_client_director_music += 1
	print("[NetworkWorld] CLIENT_DIRECTOR_MUSIC key=%s active=%s" % [music_key, active])


## Host：每帧检查是否有敌人刚刚进入死亡，并用可靠 RPC 广播死亡表现。
## 死亡是状态变更（铁律 4：状态变更走 reliable），绝不能依赖不可靠快照：
## 紧凑快照会跳过尸体，Client 不广播的话只能等 2 秒一次的可靠世界重同步，
## 表现为丧尸死后仍原地踏步一段时间才切换尸体行走图。
func _announce_host_enemy_deaths() -> void:
	if not net.is_host or _enemies.is_empty():
		return
	for key: Variant in _enemies.keys():
		var entity_id := int(key)
		if _announced_dead_enemy_ids.has(entity_id):
			continue
		var enemy := _resolve_enemy_entry(_enemies[entity_id] as Dictionary)
		if not is_instance_valid(enemy) or not enemy.is_network_dead():
			continue
		_announced_dead_enemy_ids[entity_id] = true
		enemy_death_presentation.rpc(entity_id, enemy.is_network_headshot_dead())
		print("[NetworkWorld] HOST_ENEMY_DEATH entity=%d headshot=%s" % [entity_id, enemy.is_network_headshot_dead()])


@rpc("authority", "call_remote", "reliable")
func enemy_death_presentation(entity_id: int, is_headshot: bool) -> void:
	if net.is_host or _scene_transitioning:
		return
	var node := _resolve_enemy_entry(_enemies.get(entity_id, {}) as Dictionary)
	if is_instance_valid(node) and node.has_method("apply_network_death"):
		node.apply_network_death(is_headshot)
		if _is_auto_enemy_test_scene():
			_auto_client_enemy_death_presentations += 1
			print("[NetworkWorld] CLIENT_ENEMY_DEATH_PRESENTATION entity=%d headshot=%s" % [entity_id, is_headshot])


@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_input(direction: Vector2, walking: bool) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	var entry: Dictionary = _players.get(sender, {})
	var node := entry.get("node") as CharacterBody2D
	if is_instance_valid(node) and node.is_network_dead():
		_set_input(sender, Vector2.ZERO, false)
		return
	_set_input(sender, direction, walking)


@rpc("authority", "call_remote", "reliable")
func attack_presentation(peer_id: int, weapon_id: String, magazine_ammo: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not state or not is_instance_valid(node):
		return
	var wd := _apply_client_weapon_snapshot(state, node, {
		"primary_weapon_id": weapon_id,
		"secondary_weapon_id": _weapon_id_for_slot(state, "secondary"),
		"active_weapon_slot": _find_network_weapon_slot(state, weapon_id),
		"weapon_raised": true,
	})
	if not wd:
		return
	if wd.is_ranged and magazine_ammo >= 0:
		state.set_magazine_ammo(wd.item_id, magazine_ammo)
	node.play_network_attack_presentation(wd)
	if peer_id == int(net.my_peer_id):
		_auto_client_fire_confirmed = true
		_auto_client_attack_weapon_id = wd.item_id


@rpc("authority", "call_remote", "reliable")
func spawn_bullet(bullet_id: int, shooter_peer_id: int, start_position: Vector2, direction: Vector2, weapon_id: String, bullet_index: int) -> void:
	if net.is_host or bullet_id <= 0 or _bullets.has(bullet_id):
		return
	var bd: BulletData = _get_network_bullet_data(weapon_id, bullet_index)
	if not bd:
		return
	var bullet := BULLET_SCENE.instantiate() as Node2D
	if not bullet:
		return
	bullet.call("setup", {
		"network_entity_id": bullet_id,
		"network_visual_only": true,
		"direction": direction,
		"speed": bd.speed,
		"max_range": bd.max_range,
		"damage": 0.0,
		"texture": bd.bullet_texture,
		"anim_frames": bd.bullet_anim_frames,
		"frame_duration": bd.bullet_frame_duration,
	})
	bullet.global_position = start_position
	get_tree().current_scene.add_child(bullet)
	_bullets[bullet_id] = bullet
	bullet.connect("finished", _on_client_bullet_finished)
	_auto_client_bullet_seen = true
	_auto_client_bullets_seen += 1
	print("[NetworkWorld] CLIENT_BULLET bullet=%d shooter=%d weapon=%s index=%d" % [bullet_id, shooter_peer_id, weapon_id, bullet_index])


@rpc("authority", "call_remote", "reliable")
func despawn_bullet(bullet_id: int) -> void:
	if net.is_host:
		return
	# ⚠ 先判 is_instance_valid 再 as（freed-cast 家族）：子弹可能在 finished 之外被释放。
	var bullet_value: Variant = _bullets.get(bullet_id)
	var bullet: Node = (bullet_value as Node) if is_instance_valid(bullet_value) else null
	_bullets.erase(bullet_id)
	if is_instance_valid(bullet):
		bullet.queue_free()


func _on_client_bullet_finished(bullet_id: int) -> void:
	_bullets.erase(bullet_id)


func _get_network_bullet_data(weapon_id: String, bullet_index: int) -> BulletData:
	var weapon := _get_network_weapon_data_by_id(weapon_id)
	if not weapon or not weapon.is_ranged or bullet_index < 0 or bullet_index >= weapon.bullet_list.size():
		return null
	return weapon.bullet_list[bullet_index] as BulletData


@rpc("authority", "call_remote", "reliable")
func spawn_player(peer_id: int, public_state: Dictionary) -> void:
	if net.is_host:
		return
	_ensure_client_player(peer_id, public_state, true)


@rpc("authority", "call_remote", "reliable")
func despawn_player(peer_id: int) -> void:
	if net.is_host:
		return
	_remove_player(peer_id)


## Director 在 Client 完成首次 world_snapshot 后才创建的感染者，必须走可靠 spawn 包。
## 高频紧凑敌人快照不包含场景路径，不能用于创建一个此前未知的实体。
@rpc("authority", "call_remote", "reliable")
func spawn_network_enemy(public_state: Dictionary) -> void:
	if net.is_host or _scene_transitioning:
		return
	var entity_id := int(public_state.get("entity_id", 0))
	if entity_id <= 0:
		return
	_ensure_client_enemy(entity_id, public_state, true)
	print("[NetworkWorld] CLIENT_ENEMY_SPAWN id=%d" % entity_id)


## Host：把一只敌人从全端（含 Client）移除 —— 供 Director 的「远处回收」使用。
## 直接 queue_free 的话 Client 会留下永久幽灵表现实体，所以必须走可靠 RPC 广播。
func despawn_enemy_networkwide(enemy: Node2D) -> void:
	if not net.is_host:
		return
	var entity_id := int(enemy.get("network_entity_id"))
	if entity_id <= 0:
		# 未登记的敌人：按节点实例 id 反查实体号
		for key: Variant in _enemies.keys():
			var n := _resolve_enemy_entry(_enemies[key] as Dictionary)
			if is_instance_valid(n) and n == enemy:
				entity_id = int(key)
				break
	_despawn_enemy_local(entity_id)
	if entity_id > 0:
		despawn_network_enemy.rpc(entity_id)
	if is_instance_valid(enemy):
		enemy.queue_free()


@rpc("authority", "call_remote", "reliable")
func despawn_network_enemy(entity_id: int) -> void:
	if net.is_host:
		return
	_despawn_enemy_local(entity_id)


func _despawn_enemy_local(entity_id: int) -> void:
	var entry: Dictionary = _enemies.get(entity_id, {})
	var node := _resolve_enemy_entry(entry)
	_enemies.erase(entity_id)
	if is_instance_valid(node):
		node.queue_free()


@rpc("any_peer", "call_remote", "reliable")
func auto_character_world_ack() -> void:
	if not net.is_host or not _is_auto_character_select_test():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender > 1 and net.get_peer_ids().has(sender):
		_auto_character_world_acks[sender] = true


@rpc("authority", "call_remote", "reliable")
func world_snapshot(player_states: Array, enemy_states: Array, pickup_states: Array) -> void:
	if net.is_host:
		return
	_apply_client_snapshot(player_states, true)
	_apply_client_enemy_snapshot(enemy_states, true)
	_apply_client_pickup_snapshot(pickup_states)
	# 回归观测（仅回归会话）：掉落物包明细，便于定位掉落物同步类问题。
	if _is_net_test_session():
		var kinds: Array[String] = []
		for packet_value: Variant in pickup_states:
			if packet_value is Dictionary:
				kinds.append("%s:%s" % [packet_value.get("pickup_kind", "?"), packet_value.get("item_id", packet_value.get("weapon_id", ""))])
		print("[NetworkWorld] CLIENT_PICKUPS_IN_SNAPSHOT n=%d [%s]" % [pickup_states.size(), ", ".join(kinds)])
	if not _quest_flags_synced:
		# 首个快照后补拉剧情机关 flag 全量（拾取点/爆破墙/门的状态对客户端可见性至关重要）
		_quest_flags_synced = true
		quest_flag_sync_request.rpc_id(1)
	_initial_world_received = _players.has(net.my_peer_id)
	print("[NetworkWorld] WORLD_SNAPSHOT players=%d enemies=%d local_ready=%s" % [player_states.size(), enemy_states.size(), _initial_world_received])


@rpc("any_peer", "call_remote", "reliable")
func quest_flag_sync_request() -> void:
	if not net.is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 1:
		sync_quest_flags_rpc.rpc_id(sender, Global.quest_flags.duplicate())


@rpc("authority", "call_remote", "reliable")
func sync_quest_flags_rpc(flags: Dictionary) -> void:
	_quest_flags_synced = true
	for k: Variant in flags:
		Global.apply_quest_flag(str(k), bool(flags[k]))


@rpc("authority", "call_remote", "unreliable_ordered")
func player_snapshot(player_states: Array, enemy_states: Array) -> void:
	if net.is_host:
		return
	_apply_client_snapshot(player_states, false)
	_apply_client_enemy_snapshot(enemy_states, false)


@rpc("authority", "call_remote", "unreliable_ordered")
func player_position_snapshot(player_states: Array) -> void:
	if net.is_host:
		return
	_apply_client_snapshot(player_states, false)


func _on_game_scene_ready_received(peer_id: int, ready_scene_path: String) -> void:
	if not net.is_host or ready_scene_path != _scene_path:
		return
	net.clear_pending_scene_ready(peer_id)
	_accept_ready_peer(peer_id)


func _consume_pending_scene_ready() -> void:
	if not net.is_host:
		return
	for peer_id: int in net.take_pending_scene_ready(_scene_path):
		_accept_ready_peer(peer_id)


## 把一个已上报 scene-ready 的 Client 纳入本场景的同步名单。
## send_snapshot=false 用于 Host 世界尚未初始化完成时（_host_initialize_world 的
## 缓冲 ready 路径）：只标记 + 补建实体，可靠快照由 _finish_host_world_initialization
## 统一补发，避免发出缺敌人/掉落物的世界快照。
func _accept_ready_peer(peer_id: int, send_snapshot: bool = true) -> void:
	if peer_id <= 1 or not net.get_player_names().has(peer_id):
		return
	_ready_client_peers[peer_id] = true
	_add_host_peer(peer_id)
	# 首次世界快照是可靠的，保留字典格式及预置敌人的场景路径。
	if send_snapshot:
		_send_reliable_world_snapshot(peer_id)
	# 中途加入的 Client 补发当前防守战倒计时状态（若有），使其立即看到正确剩余时间，
	# 不会因"进入时刚好错过广播"而看不到 HUD。
	if not _holdout_state.is_empty():
		holdout_state_sync.rpc_id(peer_id,
			int(_holdout_state.get("phase", 0)),
			float(_holdout_state.get("remaining", 0.0)),
			float(_holdout_state.get("total", 0.0)),
			int(_holdout_state.get("token", 0)))
	# 中途加入的 Client 补发覚醒中的玩家染色（C1）。
	for awaken_peer: int in _awaken_active_peers.keys():
		awaken_presentation.rpc_id(peer_id, awaken_peer, true)


func _send_reliable_world_snapshot(peer_id: int) -> void:
	if not net.is_host or peer_id <= 1:
		return
	world_snapshot.rpc_id(peer_id, _build_snapshot(), _build_enemy_snapshot(false), _build_pickup_snapshot())
	_auto_world_snapshot_sent_count += 1
	print("[NetworkWorld] WORLD_SNAPSHOT_SENT peer=%d enemies=%d" % [peer_id, _enemies.size()])


func _broadcast_reliable_world_snapshot() -> void:
	if not net.is_host:
		return
	for peer_id: int in _ready_client_peers.keys():
		if net.get_peer_ids().has(peer_id):
			_send_reliable_world_snapshot(peer_id)


func _on_peer_left(peer_id: int) -> void:
	if not net.is_host:
		return
	_ready_client_peers.erase(peer_id)
	var had_player := _players.has(peer_id)
	if had_player:
		_remove_player(peer_id)
		print("[NetworkWorld] HOST_DESPAWN peer=%d" % peer_id)
	_reconcile_network_seats(net.get_peer_ids())
	_clear_host_safe_door_ready_for_peer(peer_id)
	# ENet 的断线回调期间，其他 Client 也可能正在离开。延后一帧再下发结构性变更，
	# 既保持可靠同步，又避免向已关闭的通道发送 RPC。
	call_deferred("_broadcast_peer_left_state", peer_id, had_player)
	# 仅无头双端回归收束：Client 完成输入验证并离开后，让 Host 自行干净退出。
	# 正式房间继续保留 Host，不会走此分支。
	if "--net-test=host" in OS.get_cmdline_user_args() and net.get_peer_ids().size() <= 1:
		call_deferred("_finish_auto_host_after_client_leave")


func _broadcast_peer_left_state(peer_id: int, had_player: bool) -> void:
	if not net.is_host or not net.has_network() or multiplayer.get_peers().is_empty():
		return
	if had_player:
		despawn_player.rpc(peer_id)
	# 断线是结构性状态变更，不能只依赖不可靠移动快照：
	# 向每一名仍在线的 Client 可靠下发完整世界快照，让实体列表、座位和安全门人数立即收敛。
	_broadcast_reliable_world_snapshot()


func _finish_auto_host_after_client_leave() -> void:
	if not net or not net.is_host or net.get_peer_ids().size() > 1:
		return
	print("[NetworkWorld] AUTO_HOST_COMPLETE client_left=true")
	net.leave()
	get_tree().quit()


func _broadcast_spawn_player(peer_id: int) -> void:
	if not _players.has(peer_id):
		return
	var packet := _public_state(peer_id)
	for target_id: int in net.get_peer_ids():
		if target_id > 1 and target_id != peer_id:
			spawn_player.rpc_id(target_id, peer_id, packet)


# ---------------------------------------------------------------- Client presentation

func _find_network_weapon_slot(state: PlayerState, weapon_id: String) -> String:
	if not state:
		return ""
	for slot: Variant in state.equipment.keys():
		var equipped := state.equipment.get(slot) as WeaponData
		if equipped and equipped.item_id == weapon_id:
			return str(slot)
	return ""


func _apply_client_weapon_snapshot(state: PlayerState, node: CharacterBody2D, public_state: Dictionary) -> WeaponData:
	## 装备和举枪状态一律由 Host 的公开快照收敛；客户端绝不自行补默认手枪/小刀。
	if not state or not is_instance_valid(node):
		return null
	var primary := _get_network_weapon_data_by_id(str(public_state.get("primary_weapon_id", "")))
	var secondary := _get_network_weapon_data_by_id(str(public_state.get("secondary_weapon_id", "")))
	state.equipment["primary"] = primary
	state.equipment["secondary"] = secondary
	var requested_slot := str(public_state.get("active_weapon_slot", "primary"))
	state.active_weapon_slot = requested_slot if requested_slot == "primary" or requested_slot == "secondary" else "primary"
	var packet_magazines: Variant = public_state.get("weapon_magazines", {})
	if packet_magazines is Dictionary:
		state.weapon_magazines = (packet_magazines as Dictionary).duplicate()
	var remote_weapon := state.get_active_weapon()
	var transition := str(public_state.get("weapon_transition", ""))
	if not transition.is_empty() and remote_weapon:
		# 正常 Client 会先收到可靠表现 RPC；这里只服务于晚加入/丢包后的可见收敛。
		if not _weapon_transition_state.has(node.network_entity_id) and not node.player_in_weapon_state:
			_weapon_transition_state[node.network_entity_id] = transition
			node.play_network_weapon_transition(remote_weapon, transition == "raising")
	elif bool(public_state.get("weapon_raised", false)) and remote_weapon:
		if not node.is_weapon_mode_active() or node.get_network_weapon_id() != remote_weapon.item_id:
			node.enter_weapon_mode(remote_weapon)
			node.set_weapon_ready_frame()
	else:
		node.exit_weapon_mode()
	return remote_weapon


## 应用玩家快照。
##
## `snap=true` 表示可靠完整快照：允许创建/删除实体并校准初始状态。
## `snap=false` 表示高频移动快照：只能更新已有实体的表现，不能因为丢包而
## 删除玩家。玩家快照同时兼容旧的 Dictionary 格式和新的紧凑 Array 格式。
func _apply_client_snapshot(states: Array, snap: bool) -> void:
	# ★ 悬垂条目清扫必须放在最前（2026-09-23 审计）：本函数是 20Hz 热路径，
	# 若某条目的 node 已被释放而未 erase，下面的强转/访问会抛错并**静默中止整个
	# 函数** —— 而「不在快照即回收」的收敛写在函数末尾，于是收敛永远执行不到，
	# 故障被固化（客户端玩家同步永久失效）。先把失效条目清掉，收敛才有机会跑。
	for sweep_key: Variant in _players.keys():
		var sweep_value: Variant = _players[sweep_key]
		if sweep_value is Dictionary and not is_instance_valid((sweep_value as Dictionary).get("node")):
			_remove_player(int(sweep_key))
	var seen: Dictionary = {}
	var authoritative_peer_ids: Array[int] = []
	for value: Variant in states:
		var public_state := _normalize_player_snapshot(value)
		if public_state.is_empty():
			continue
		var peer_id := int(public_state.get("peer_id", 0))
		if peer_id <= 0:
			continue
		seen[peer_id] = true
		authoritative_peer_ids.append(peer_id)
		_ensure_client_player(peer_id, public_state, snap)
	# 不可靠移动快照可能丢包或乱序；只允许可靠的 world_snapshot 收敛实体列表。
	if snap:
		for key: Variant in _players.keys():
			var existing_id := int(key)
			if not seen.has(existing_id):
				_remove_player(existing_id)
		_reconcile_network_seats(authoritative_peer_ids)


func _normalize_player_snapshot(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value as Dictionary
	if value is Array:
		var packet := value as Array
		if packet.size() < 21:
			return {}
		return {
			"peer_id": int(packet[0]),
			"name": packet[1],
			"character_path": packet[2],
			"hp": packet[3],
			"position": packet[4],
			"facing": int(packet[5]),
			"moving": bool(packet[6]),
			"walking": bool(packet[7]),
			"weapon_id": packet[8],
			"primary_weapon_id": packet[9],
			"secondary_weapon_id": packet[10],
			"active_weapon_slot": packet[11],
			"weapon_magazines": packet[12],
			"weapon_raised": bool(packet[13]),
			"weapon_transition": packet[14],
			"throwable_id": packet[15],
			"throwable_held": bool(packet[16]),
			"throwable_aiming": bool(packet[17]),
			"throw_range": int(packet[18]),
			"dead": bool(packet[19]),
			"magazine_ammo": int(packet[20]),
			# 倒地扩展字段（v2 起追加）。旧长度包按默认值降级：
			# 未倒地 / 无流血数据 / 无人施救，保证与旧 Host 的 21 字段包兼容。
			"downed": bool(packet[21]) if packet.size() > 21 else false,
			"bleed_ratio": float(packet[22]) if packet.size() > 22 else -1.0,
			"revive_progress": float(packet[23]) if packet.size() > 23 else 0.0,
			"facing_locked": bool(packet[24]) if packet.size() > 24 else false,
			"locked_facing": int(packet[25]) if packet.size() > 25 else -1,
			# D2 备弹同步（尾部追加，旧长度包降级为空 → 不动本地域）。
			"ammo_counts": (packet[26] as Dictionary).duplicate() if packet.size() > 26 and packet[26] is Dictionary else {},
		}
	return {}


## 安全取玩家节点：`entry.get("node") as CharacterBody2D` 对已释放对象会抛错并静默
## 中止整个调用函数（freed-cast 家族）。玩家快照走 20Hz 热路径，一次抛错就会让
## 整帧玩家同步中断，因此这里统一「先判 is_instance_valid 再 as」。
func _resolve_player_node(entry: Dictionary) -> CharacterBody2D:
	var node_value: Variant = entry.get("node")
	if not is_instance_valid(node_value):
		return null
	return node_value as CharacterBody2D


func _ensure_client_player(peer_id: int, public_state: Dictionary, snap: bool) -> void:
	var entry: Dictionary = _players.get(peer_id, {})
	var node := _resolve_player_node(entry)
	var created := false
	if not is_instance_valid(node):
		created = true
		node = _instantiate_player(_packet_position(public_state), peer_id)
		var state := _find_or_create_player_state(
			peer_id,
			str(public_state.get("character_path", "")),
			float(public_state.get("hp", 1.0))
		)
		state.owner_peer_id = peer_id
		node.configure_network_entity(peer_id, peer_id)
		if peer_id == int(net.my_peer_id):
			node.network_local_player = true
			node.set_network_local_prediction(true)
		node.exit_weapon_mode()
		var seat_index: int = _ensure_player_state_seat(state)
		Players.register_entity(node, seat_index)
		_attach_player_nameplate(node, peer_id, seat_index)
		entry = {"node": node, "state": state, "input": Vector2.ZERO, "moving": false, "walking": false}
		_players[peer_id] = entry
		if peer_id == int(net.my_peer_id):
			_set_local_player(node, seat_index)
	var is_local_prediction: bool = peer_id == int(net.my_peer_id) and node.network_local_prediction

	var state := entry.get("state") as PlayerState
	var character := _load_character(str(public_state.get("character_path", "")))
	if state:
		if character:
			state.character = character
			state.character_path = str(public_state.get("character_path", ""))
		state.current_hp = float(public_state.get("hp", state.current_hp))
		state.position = _packet_position(public_state)
		state.facing = int(public_state.get("facing", state.facing))
		var snapshot_locked: bool = bool(public_state.get("facing_locked", false))
		var snapshot_locked_facing: int = int(public_state.get("locked_facing", -1))
		# facing_lock 是 Host 权威属性：Host 处理远端 Client 上报的状态时，绝不能让 Client
		# 自报的 facing_locked 覆盖 Host 权威值（否则 Host 每帧把它刷回 false，再经快照广播成
		# 海量 locked=false，客户端本地 is_facing_locked() 永远对不上）。
		# 仅当"客户端接收 Host 快照"时才应用此字段。
		var is_host_applying_remote: bool = net.is_host and peer_id != int(net.my_peer_id)
		if is_host_applying_remote:
			pass  # Host 权威值由 _try_host_set_facing_lock / unlock_facing 维护，忽略 Client 自报
		else:
			# 快照也是权威收敛兜底；但不能让请求确认前的旧快照覆盖本地预测。
			var has_pending_lock_request: bool = peer_id == int(net.my_peer_id) and _facing_lock_requests.has(peer_id)
			if has_pending_lock_request:
				if bool(_facing_lock_requests[peer_id]) != snapshot_locked:
					# Host 尚未处理请求，保留预测状态，等待可靠确认包。
					pass
				else:
					_facing_lock_requests.erase(peer_id)
					node.apply_facing_lock_state(snapshot_locked, snapshot_locked_facing)
			else:
				node.apply_facing_lock_state(snapshot_locked, snapshot_locked_facing)
		# 快照中的 weapon_id 由 Host 的 active_weapon_slot 生成；只在实际变化时更新外观，
		# 避免每个 20Hz 包打断攻击动画或重置行走帧。
		var remote_weapon := _apply_client_weapon_snapshot(state, node, public_state)
		var remote_throwable := _get_network_throwable_data_by_id(str(public_state.get("throwable_id", "")))
		var throwable_held := bool(public_state.get("throwable_held", false)) and remote_throwable != null
		var throwable_aiming := bool(public_state.get("throwable_aiming", false)) and throwable_held
		var throwable_range := clampi(int(public_state.get("throw_range", 3)), 0, remote_throwable.throw_range_max if remote_throwable else 0)
		state.throwable = remote_throwable
		_network_throwable_state[peer_id] = {"held": throwable_held, "aiming": throwable_aiming, "range": throwable_range}
		# 每帧状态回放：投掷物外观照常更新，但朝向锁由 facing_lock_presentation 权威通道管理，
		# 不要因 held=false 把固定朝向锁解掉（固定朝向锁与投掷物瞄准锁共用 _facing_locked）。
		node.apply_network_throwable_presentation(remote_throwable, throwable_held, throwable_aiming, throwable_range, false)
		if remote_weapon and remote_weapon.is_ranged:
			state.set_magazine_ammo(
				remote_weapon.item_id,
				int(public_state.get("magazine_ammo", state.get_magazine_ammo(remote_weapon.item_id)))
			)
		# D2 备弹同步：Host 权威弹药库存计数收敛到 Client 域 PlayerState。
		# set_ammo_item_count 幂等（count 相同跳过），40Hz 快照反复下发无副作用。
		var ammo_counts: Variant = public_state.get("ammo_counts", {})
		if ammo_counts is Dictionary:
			for ammo_id: String in (ammo_counts as Dictionary).keys():
				var count := int((ammo_counts as Dictionary)[ammo_id])
				var prototype := _find_ammo_resource_for_weapon(state, ammo_id)
				state.set_ammo_item_count(ammo_id, count, prototype)
	# 实体是否已在平滑渲染：可靠重同步对它必须软并流（见 apply_network_resync_state），
	# 否则每 2 秒一次的可靠包会把位置硬切、把行走动画打回起点 —— 客户端表现为
	# 全体实体周期性"一顿一顿"、踏步动画相位/频率反复跳变。
	var established: bool = (not created) and node.has_network_position_tracking()
	# 只有可靠的 spawn/world snapshot 才能重置初始状态。移动快照不能先写入
	# stopped 状态再写回 moving，否则每个 20Hz 快照都会把 _anim_step 清零，
	# 客户端角色会永远停在同一张行走帧上。
	if snap and (not is_local_prediction or not _initial_world_received):
		var spawn_position := _packet_position(public_state)
		if is_local_prediction and _initial_world_received:
			# 本地预测玩家只吃首次校准；此后的权威坐标经 apply_network_authority_target 纠偏。
			pass
		elif established:
			node.apply_network_resync_state(character, spawn_position, int(public_state.get("facing", 0)))
		else:
			node.apply_network_spawn_state(character, float(public_state.get("hp", node.current_hp)), spawn_position, int(public_state.get("facing", 0)), true)
	var is_dead := bool(public_state.get("dead", false))
	node.apply_network_health_state(float(public_state.get("hp", node.current_hp)), is_dead, not snap)
	# 倒地状态 reconcile：downed 只可能伴随 dead=true（躺地表现已由
	# apply_network_health_state 触发）。set_network_downed 负责碰撞/染色；
	# 同时把权威值写回 entry —— 本地救援预估（_find_revive_target_for）与
	# 本地玩家生命三态判定（_get_local_player_life_state）都依赖它。
	# revive_progress 驱动头顶救援进度环；不可靠快照偶尔丢包只会让环短暂停顿。
	var downed := is_dead and bool(public_state.get("downed", false))
	entry["downed"] = downed
	entry["dead"] = is_dead and not downed
	entry["bleed_ratio"] = float(public_state.get("bleed_ratio", -1.0))
	var revive_progress := float(public_state.get("revive_progress", 0.0))
	entry["revive_progress"] = revive_progress
	node.set_network_downed(downed)
	_update_network_revive_indicator(node, revive_progress)
	if is_local_prediction:
		# 本地预测玩家：快照只提供权威纠偏目标与朝向，位置由本地输入驱动。
		node.apply_network_authority_target(_packet_position(public_state), int(public_state.get("facing", 0)))
	else:
		node.apply_network_presentation(
			_packet_position(public_state),
			int(public_state.get("facing", 0)),
			false if is_dead else bool(public_state.get("moving", false)),
			false if is_dead else bool(public_state.get("walking", false)),
			snap and not established
		)
	entry["moving"] = false if is_dead else bool(public_state.get("moving", false))
	entry["walking"] = false if is_dead else bool(public_state.get("walking", false))
	_players[peer_id] = entry


# ---------------------------------------------------------------- Client enemy presentation

func _apply_client_enemy_snapshot(states: Array, snap: bool) -> void:
	var seen: Dictionary = {}
	for value: Variant in states:
		var public_state := _normalize_enemy_snapshot(value)
		if public_state.is_empty():
			continue
		var entity_id := int(public_state.get("entity_id", 0))
		if entity_id <= 0:
			continue
		seen[entity_id] = true
		_ensure_client_enemy(entity_id, public_state, snap)
	# 只有可靠完整快照才收敛动态实体；预置尸体不会被 Host 自动移除。
	if snap:
		for key: Variant in _enemies.keys():
			var entity_id := int(key)
			if not seen.has(entity_id):
				_remove_client_enemy(entity_id)


## 可靠 world_snapshot 使用字典（含预置场景路径）；20Hz 快照使用紧凑数组，减少 ENet 包尺寸。
func _normalize_enemy_snapshot(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value as Dictionary
	if value is Array:
		var packet := value as Array
		if packet.size() < 8:
			return {}
		return {
			"entity_id": int(packet[0]),
			"position": packet[1],
			"facing": int(packet[2]),
			"hp": float(packet[3]),
			"moving": bool(packet[4]),
			"visual_char_index": int(packet[5]),
			"dead": bool(packet[6]),
			"headshot": bool(packet[7]),
			# P0-B3：第 9 位=元素染色字节；旧长度包按 -1 处理（保持现状不清色）。
			"element_state": int(packet[8]) if packet.size() >= 9 else -1,
		}
	return {}


func _ensure_client_enemy(entity_id: int, public_state: Dictionary, snap: bool) -> void:
	var entry: Dictionary = _enemies.get(entity_id, {})
	var node := _resolve_enemy_entry(entry)
	# 已存在的敌人属于"平滑渲染中"的实体：可靠重同步对它按软并流处理，
	# 避免每 2 秒一次的可靠包把位置硬切（客户端丧尸周期性卡顿的根源）。
	var established := is_instance_valid(node)
	if not established:
		var scene_path := str(public_state.get("scene_path", ""))
		# 紧凑不可靠包不带场景路径；在可靠 world_snapshot 建立实体前不创建未知敌人。
		if scene_path.is_empty() and not snap:
			return
		if not scene_path.is_empty() and get_tree().current_scene:
			node = get_tree().current_scene.get_node_or_null(NodePath(scene_path)) as CharacterBody2D
			# 该节点若已被别的 entity_id 认领，不得复用（同 pickup 侧的一一对应不变量）
			node = _reject_claimed_enemy(node, entity_id, _claimed_enemy_nodes())
		if not is_instance_valid(node):
			node = ENEMY_SCENE.instantiate() as CharacterBody2D
			if not is_instance_valid(node):
				return
			# ★ 唯一名（2026-09-23 审计）：镜像若沿用场景默认名（如 Zombie）直接挂进
			# 世界容器，会占用与地图预置敌人相同的 scene_path 命名空间 —— 另一个
			# entity_id 的包带着真正的地图路径过来时 get_node_or_null 会命中本镜像，
			# 于是两个 id 共用一个节点（位置/血量/动作互相覆盖）。pickup 侧实测过同款
			# 事故（手雷被喷雾覆盖），这里一并堵死。
			node.name = "NetEnemy%d" % entity_id
			# A1 特感复制 / A5 僵尸变体：可靠通道携带 id 时按白名单取同一份 tres，
			# 用与 Host 完全相同的注入代码（*.apply_to_enemy）重建表现。
			# 必须在 add_child 之前注入 —— enemy._ready() 的 _refresh_sprite 依赖 walk_texture。
			# 特感与变体互斥（同一只敌人只会走其中一条）。
			var special := _get_network_special_data(str(public_state.get("special_id", "")))
			if special:
				special.apply_to_enemy(node)
			else:
				var variant := _get_network_variant_data(str(public_state.get("variant_id", "")))
				if variant:
					variant.apply_to_enemy(node)
			node.configure_network_entity(entity_id, true)
			node.global_position = _packet_position(public_state)
			_players_parent.add_child(node)
		if is_instance_valid(_players_parent) and node.get_parent() != _players_parent:
			node.reparent(_players_parent, true)
		node.configure_network_entity(entity_id, true)
		entry = {"node_id": node.get_instance_id(), "scene_path": scene_path}
		_enemies[entity_id] = entry
	# 可靠死亡广播后，乱序迟到的不可靠位置包（死亡前发出、死亡后送达）不得
	# 把尸体重新拉回行走状态；可靠快照本身按序到达，仍可幂等刷新尸体表现。
	# （established 实体的可靠重同步按 snap=false 生效，因此这里同样拦截尸体。）
	if not snap and node.is_network_dead():
		return
	node.apply_network_presentation(
		_packet_position(public_state),
		int(public_state.get("facing", 0)),
		bool(public_state.get("moving", false)),
		float(public_state.get("hp", node.current_hp)),
		int(public_state.get("visual_char_index", -1)),
		bool(public_state.get("dead", false)),
		bool(public_state.get("headshot", false)),
		snap and not established,
		int(public_state.get("element_state", -1))  # P0-B3
	)


func _remove_client_enemy(entity_id: int) -> void:
	if not _enemies.has(entity_id):
		return
	var entry: Dictionary = _enemies[entity_id]
	var node := _resolve_enemy_entry(entry)
	_enemies.erase(entity_id)
	if is_instance_valid(node):
		node.queue_free()


func _remove_player(peer_id: int) -> void:
	_revive_attempts.erase(peer_id)
	_network_throwable_state.erase(peer_id)
	_weapon_transition_state.erase(peer_id)
	for key: Variant in _revive_attempts.keys().duplicate():
		if int((_revive_attempts[key] as Dictionary).get("target", 0)) == peer_id:
			_revive_attempts.erase(key)
	# 客户端在场景切换/丢失包期间绝不能因非完整快照销毁自己的预置实体。
	if not net.is_host and peer_id == int(net.my_peer_id):
		return
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as Node
	# Host 释放断线玩家前，先清除所有敌人的目标引用，防止 Chase 状态读取失效实例。
	if net.is_host and is_instance_valid(node):
		for enemy_node: Node in get_tree().get_nodes_in_group("enemy"):
			if enemy_node.has_method("clear_target_if_matches"):
				enemy_node.clear_target_if_matches(node)
	_players.erase(peer_id)
	if is_instance_valid(node):
		node.queue_free()


# ---------------------------------------------------------------- Host-authoritative pickups

func _register_initial_host_pickups() -> void:
	_pickups.clear()
	_next_pickup_id = 1
	var candidates: Array[Node2D] = []
	_collect_network_pickups(get_tree().current_scene, candidates)
	candidates.sort_custom(func(a: Node2D, b: Node2D) -> bool: return str(a.get_path()) < str(b.get_path()))
	for pickup: Node2D in candidates:
		_register_host_pickup(pickup)
	print("[NetworkWorld] HOST_PICKUPS_REGISTERED count=%d" % _pickups.size())
	# 回归观测：列出注册明细（仅回归会话），便于定位掉落物同步类问题。
	if _is_net_test_session():
		for key: Variant in _pickups.keys():
			var node_p := _pickups[key] as Node2D
			if not is_instance_valid(node_p):
				continue
			var w := node_p.get("weapon_data") as WeaponData
			var it := node_p.get("item") as ItemData
			print("[NetworkWorld] HOST_PICKUP_ENTRY id=%d kind=%s item=%s" % [
				int(key),
				"weapon" if w else ("throwable" if it and it.item_type == ItemData.ItemType.THROWABLE else ("healing" if it else "?")),
				w.item_id if w else (it.item_id if it else ""),
			])


## 是否回归会话（`--net-test*` 任一参数）。⚠ 不能用 `"--net-test" in args`：
## 参数是 `--net-test=client` 这种带值形式，精确匹配恒为 false。
func _is_net_test_session() -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test"):
			return true
	return false
	# 回归确定性（09-22）：random_pickup 在 Client 侧已禁用本地随机刷，「投掷物拾取」
	# 用例不能再依赖安全屋随机表的运气（Host 可能这一局没 roll 出投掷物）→
	# 回归模式下由 Host 确保场上存在投掷物掉落物（生产路径生成 + 正常注册广播）。
	if "--net-test-throwable-pickup" in OS.get_cmdline_user_args():
		_ensure_auto_host_throwable_source()


func _ensure_auto_host_throwable_source() -> void:
	for value: Variant in _pickups.values():
		if not is_instance_valid(value):
			continue
		var pickup := value as Node2D
		if not is_instance_valid(pickup):
			continue
		var throwable := pickup.get("item") as ThrowableData
		if throwable:
			return
	var player := _find_preplaced_player()
	var origin := player.global_position if is_instance_valid(player) else Vector2.ZERO
	## 落点沿用原安全屋手雷位置的经验值（出生点 +260/-20，已被历史用例证明在同一
	## 可行走走廊内，Client 单轴走位可达）。
	_spawn_host_dropped_throwable(NETWORK_GRENADE, origin + Vector2(260.0, -20.0))
	print("[NetworkWorld] AUTO_THROWABLE_SOURCE_SPAWNED（回归夹具：Host 补投掷物源）")


func _collect_network_pickups(root: Node, out: Array[Node2D]) -> void:
	if not is_instance_valid(root):
		return
	if root is Node2D and root.has_method("configure_network_pickup"):
		var weapon := root.get("weapon_data") as WeaponData
		var item := root.get("item") as ItemData
		# D2 实测修复：治疗品（喷雾 HEALING/药品 SUPPORT）一并纳入联机同步，
		# 否则 Client 端要么看不见动态刷的治疗品、要么本地私拿（Host 无感知）。
		if weapon or (item and (item.item_type == ItemData.ItemType.THROWABLE
				or item.item_type == ItemData.ItemType.HEALING
				or item.item_type == ItemData.ItemType.SUPPORT)):
			out.append(root as Node2D)
	for child: Node in root.get_children():
		_collect_network_pickups(child, out)


## Host：收编运行期动态生成的掉落物（Director/ItemManager 投放的喷雾/药品/弹药堆）。
## `_register_initial_host_pickups` 只在世界初始化跑一次，动态投放物不注册就永远
## 不进快照 —— Client 看不见、拿不了（09-22 实测「Client 看不到投掷物/喷雾」家族）。
## 用 ground_pickup 组遍历（廉价），节流到每 0.5s 一次，有新登记才广播快照。
const UNTRACKED_PICKUP_SCAN_INTERVAL := 0.5
var _untracked_pickup_scan_accumulator: float = 0.0


func _register_untracked_host_pickups(delta: float) -> void:
	if not net.is_host:
		return
	_untracked_pickup_scan_accumulator += delta
	if _untracked_pickup_scan_accumulator < UNTRACKED_PICKUP_SCAN_INTERVAL:
		return
	_untracked_pickup_scan_accumulator = fmod(_untracked_pickup_scan_accumulator, UNTRACKED_PICKUP_SCAN_INTERVAL)
	var tracked_nodes: Dictionary = {}
	for value: Variant in _pickups.values():
		var tracked := value as Node
		if is_instance_valid(tracked):
			tracked_nodes[tracked.get_instance_id()] = true
	var registered_any := false
	for node: Node in get_tree().get_nodes_in_group("ground_pickup"):
		var pickup := node as Node2D
		if not is_instance_valid(pickup) or tracked_nodes.has(pickup.get_instance_id()):
			continue
		if not pickup.has_method("configure_network_pickup"):
			continue
		_register_host_pickup(pickup)
		registered_any = true
	if registered_any:
		pickup_snapshot.rpc(_build_snapshot(), _build_pickup_snapshot())


func _register_host_pickup(pickup: Node2D) -> int:
	if not is_instance_valid(pickup):
		return 0
	for existing_id: Variant in _pickups.keys():
		if _pickups[existing_id] == pickup:
			return int(existing_id)
	var pickup_id: int = _next_pickup_id
	_next_pickup_id += 1
	pickup.call("configure_network_pickup", pickup_id, false)
	_pickups[pickup_id] = pickup
	return pickup_id


func _prepare_client_preplaced_pickups() -> void:
	_client_preplaced_pickups_by_path.clear()
	var scene := get_tree().current_scene
	var candidates: Array[Node2D] = []
	_collect_network_pickups(scene, candidates)
	for pickup: Node2D in candidates:
		var scene_path := str(scene.get_path_to(pickup)) if scene else ""
		if not scene_path.is_empty():
			_client_preplaced_pickups_by_path[scene_path] = pickup
		pickup.call("configure_network_pickup", 0, true)
		# 等 Host 的可靠快照分配稳定 ID，防止客户端在首帧走到预置物品旁时本地拾取。
		pickup.visible = false


func _build_pickup_snapshot() -> Array:
	# 先清理已释放条目（2026-09-23，Host 侧此前漏修）：`_pickups[id] as Node2D` 对已
	# 释放对象会抛 "Trying to cast a freed object" 并**静默中止整个函数**（返回 null）
	# → 该帧掉落物同步整体失效（客户端看不见/拿不了/物件错乱）。悬垂条目很常见：
	# GroundItemCap 淘汰、拾取物被外部 queue_free 都不会通知 NetworkWorld。
	# 客户端 _apply_client_pickup_snapshot 早已有同款清理，二者属同一「freed-cast 家族」。
	for stale_key: Variant in _pickups.keys():
		var stale_value: Variant = _pickups[stale_key]
		if not is_instance_valid(stale_value):
			_pickups.erase(stale_key)
	var packets: Array = []
	for value: Variant in _pickups.keys():
		var pickup_id: int = int(value)
		# ⚠ 取值必须先判 is_instance_valid 再 as Node2D（对已释放对象做 as 会抛错）
		var pickup_value: Variant = _pickups[pickup_id]
		var pickup: Node2D = (pickup_value as Node2D) if is_instance_valid(pickup_value) else null
		if not is_instance_valid(pickup):
			continue
		var weapon := pickup.get("weapon_data") as WeaponData
		var item := pickup.get("item") as ItemData
		# kind：weapon / throwable / healing（HEALING+SUPPORT 治疗品家族）
		var pickup_kind := "weapon" if weapon else \
				"throwable" if item and item.item_type == ItemData.ItemType.THROWABLE else \
				"healing" if item and (item.item_type == ItemData.ItemType.HEALING
					or item.item_type == ItemData.ItemType.SUPPORT) else ""
		if pickup_kind.is_empty():
			continue
		var scene := get_tree().current_scene
		var reserve_ammo := int(pickup.get("pickup_reserve_ammo")) if weapon else 0
		var magazine_ammo := int(pickup.get("pickup_magazine_ammo")) if weapon else -1
		var char_idx := int(pickup.get("pickup_char_idx")) if weapon else item.pickup_char_idx
		var direction := int(pickup.get("pickup_direction")) if weapon else item.pickup_direction
		var packet := {
			"pickup_id": pickup_id,
			"pickup_kind": pickup_kind,
			"scene_path": str(scene.get_path_to(pickup)) if scene else "",
			"position": pickup.global_position,
			"weapon_id": weapon.item_id if weapon else "",
			"item_id": item.item_id if item else "",
			"reserve_ammo": reserve_ammo,
			"magazine_ammo": magazine_ammo,
			"char_idx": char_idx,
			"direction": direction,
		}
		packets.append(packet)
	packets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["pickup_id"]) < int(b["pickup_id"]))
	return packets


func request_pickup(pickup_id: int, claimed_position: Variant = null) -> void:
	if net.is_host:
		_try_host_pickup(int(net.my_peer_id), pickup_id, claimed_position)
	elif _initial_world_received:
		pickup_request.rpc_id(1, pickup_id, claimed_position)


@rpc("any_peer", "call_remote", "reliable")
func pickup_request(pickup_id: int, claimed_position: Variant = null) -> void:
	if not net.is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 1:
		_try_host_pickup(sender, pickup_id, claimed_position)


## 联机滞后补偿（09-22 实测）：客户端本地预测位置领先 Host 权威模拟约 速度×RTT
## （LAN 通常 <16px）。攻击/推击/拾取请求携带客户端当前坐标作为提示，Host 在
## 权威判定前把权威实体对齐过去 —— 否则范围/距离判定按「落后的权威坐标」计算，
## 表现为客户端眼看贴在怪身上却挥空、或贴着掉落物却拾取失败。
## 限幅防作弊；对齐方向与客户端显示一致（客户端本地位置本就在该处，看不到跳变）。
const LAG_COMPENSATION_MAX_DISTANCE := 32.0


func _apply_lag_compensated_position(peer_id: int, node: CharacterBody2D, claimed: Variant) -> void:
	if not net.is_host or not (claimed is Vector2) or not is_instance_valid(node):
		return
	var claimed_pos := claimed as Vector2
	var offset := claimed_pos - node.global_position
	var offset_length := offset.length()
	if offset_length <= 1.0:
		return
	if offset_length > LAG_COMPENSATION_MAX_DISTANCE:
		offset = offset / offset_length * LAG_COMPENSATION_MAX_DISTANCE
	node.global_position += offset
	var entry: Dictionary = _players.get(peer_id, {})
	var state := entry.get("state") as PlayerState
	if state:
		state.position = node.global_position
	if _is_net_test_session():
		print("[NetworkWorld] LAG_COMPENSATION peer=%d applied=(%.1f, %.1f) len=%.1f" % [peer_id, offset.x, offset.y, offset_length])


func _try_host_pickup(peer_id: int, pickup_id: int, claimed_position: Variant = null) -> void:
	if not net.is_host or not _players.has(peer_id) or not _pickups.has(pickup_id):
		return
	var pickup_value: Variant = _pickups[pickup_id]
	var pickup: Node2D = (pickup_value as Node2D) if is_instance_valid(pickup_value) else null
	var entry: Dictionary = _players[peer_id]
	var player := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	# 滞后补偿：拾取距离按权威坐标校验，先对齐客户端自报位置（客户端贴住掉落物
	# 却因权威坐标落后而失败是实测高频问题）。
	_apply_lag_compensated_position(peer_id, player, claimed_position)
	var weapon := pickup.get("weapon_data") as WeaponData if is_instance_valid(pickup) else null
	var throwable := pickup.get("item") as ThrowableData if is_instance_valid(pickup) else null
	var healing := pickup.get("item") as ItemData if is_instance_valid(pickup) else null
	var is_healing_pickup: bool = healing != null and (healing.item_type == ItemData.ItemType.HEALING
		or healing.item_type == ItemData.ItemType.SUPPORT)
	if not is_instance_valid(pickup) or not is_instance_valid(player) or not state \
			or (not weapon and not throwable and not is_healing_pickup):
		return
	if player.global_position.distance_to(pickup.global_position) > 40.0:
		return
	if is_healing_pickup:
		# D2 实测修复：治疗品（喷雾/药品）Host 权威拾取事务。复用 healing_pickup
		# 的 _do_pickup（各自持有/上限满转投其他座位的规则都在其中），失败
		# （全队所持上限满，留在地上）不回执——Client 走 500ms 超时自愈重发。
		pickup.set("_player_ref", player)
		if not pickup.call("_do_pickup"):
			return
		_pickups.erase(pickup_id)
		pickup_snapshot.rpc(_build_snapshot(), _build_pickup_snapshot())
		print("[NetworkWorld] HOST_PICKUP peer=%d pickup=%d healing=%s" % [peer_id, pickup_id, healing.item_id])
		return
	if throwable:
		var old_throwable: ThrowableData = state.throwable
		if old_throwable == throwable and state.throwable_count > 0:
			# 同类投掷物 → 叠数累加，不掉落旧的
			state.throwable_count += 1
		else:
			if old_throwable:
				## 落点推远（2026-09-23）：与武器掉落同规则，避免旧投掷物刚脱手被自己捡回。
				_spawn_host_dropped_throwable(old_throwable, PICKUP_SCRIPT.drop_landing_position(player))
			state.throwable = throwable
			state.throwable_count = 1
		_network_throwable_state[peer_id] = {"held": false, "aiming": false, "range": 3}
		_apply_host_throwable_presentation(peer_id)
		_pickups.erase(pickup_id)
		pickup.call("disable_network_pickup") if pickup.has_method("disable_network_pickup") else pickup.hide()
		pickup.queue_free()
		pickup_snapshot.rpc(_build_snapshot(), _build_pickup_snapshot())
		print("[NetworkWorld] HOST_PICKUP peer=%d pickup=%d throwable=%s" % [peer_id, pickup_id, throwable.item_id])
		return
	if state.character and not state.character.can_use_weapon(weapon):
		return
	var slot: String = weapon.get_slot_key()
	var old: WeaponData = state.get_equipped_weapon(slot)
	if old:
		_spawn_host_dropped_weapon(old, player, state)
	state.equipment[slot] = weapon
	if weapon.is_ranged:
		var mag: int = int(pickup.get("pickup_magazine_ammo"))
		state.set_magazine_ammo(weapon.item_id, clampi(weapon.magazine_capacity if mag < 0 else mag, 0, weapon.magazine_capacity))
		# 备弹（09-22 实测「备弹还是 0」根因）：掉落物携带的转移备弹优先，**没有时
		# 必须回退武器数据的 initial_reserve_ammo** —— 单机 weapon_pickup._do_pickup
		# 一直有这个回退，网络权威路径漏了：预摆/新生成的掉落物 pickup_reserve_ammo
		# 恒为 0（只有「捡起再扔下」才带上转移值）→ 网络拾取的武器备弹永远是 0。
		var pickup_reserve: int = int(pickup.get("pickup_reserve_ammo"))
		var reserve_to_give: int = pickup_reserve if pickup_reserve > 0 else weapon.initial_reserve_ammo
		_add_host_reserve_ammo(state, weapon, reserve_to_give)
	if state.active_weapon_slot == slot and player.is_weapon_mode_active():
		player.enter_weapon_mode(weapon)
		player.set_weapon_ready_frame()
	_pickups.erase(pickup_id)
	pickup.call("disable_network_pickup") if pickup.has_method("disable_network_pickup") else pickup.hide()
	pickup.queue_free()
	# 拾取是一个不可拆分的权威事务：装备/弹匣变化与地面掉落物变化必须在同一条可靠 RPC 中抵达 Client。
	pickup_snapshot.rpc(_build_snapshot(), _build_pickup_snapshot())
	print("[NetworkWorld] HOST_PICKUP peer=%d pickup=%d weapon=%s" % [peer_id, pickup_id, weapon.item_id])


func _spawn_host_dropped_weapon(weapon: WeaponData, player: Node2D, state: PlayerState) -> void:
	var pickup := PICKUP_SCENE.instantiate() as Node2D
	if not is_instance_valid(pickup):
		return
	# 地面显示参数统一走 WeaponData（2026-09-13 约定，与 item_manager/Client 重建同款）：
	# 旧实现手动只设 texture/char_idx/direction，pickup_animated / step_frames /
	# step_duration 留默认 → 掉落物踏步动画与武器数据配置不一致（2026-09-22 实测）。
	PICKUP_SCRIPT.apply_weapon_ground_display(pickup, weapon)
	if weapon.is_ranged:
		pickup.set("pickup_magazine_ammo", state.get_magazine_ammo(weapon.item_id))
		state.weapon_magazines.erase(weapon.item_id)
		var reserve: int = state.count_ammo_item(weapon.ammo_item_id)
		pickup.set("pickup_reserve_ammo", reserve)
		if reserve > 0:
			state.consume_ammo_item(weapon.ammo_item_id, reserve)
	var parent := get_tree().current_scene.find_child("GroundLayer", true, false)
	(parent if parent else get_tree().current_scene).add_child(pickup)
	## 落点：先沿玩家朝向推远（2026-09-23 用户：丢下的离玩家远一些，且拾取范围 24→16，
	## 落点须在拾取范围外，否则刚脱手就被自己的自动拾取捡回），再做
	## ≥24px 的掉落物间距避让（2026-09-16 反馈②）。必须在 add_child（=入组）之后算，
	## 否则看不到刚掉下的那一件。
	pickup.global_position = PICKUP_SCRIPT.find_free_drop_position(
		get_tree(), PICKUP_SCRIPT.drop_landing_position(player))
	_register_host_pickup(pickup)


func _spawn_host_dropped_throwable(throwable: ThrowableData, position: Vector2) -> void:
	if not throwable:
		return
	var pickup := HEALING_PICKUP_SCENE.instantiate() as Node2D
	if not is_instance_valid(pickup):
		return
	pickup.set("item", throwable)
	pickup.global_position = position
	var parent := get_tree().current_scene.find_child("GroundLayer", true, false)
	(parent if parent else get_tree().current_scene).add_child(pickup)
	_register_host_pickup(pickup)


# ---------------------------------------------------------------- 玩家主动丢弃全部武器（2026-09-16 用户需求）

## 本地发起「丢弃全部武器」（E 键）。单机不走这里（player.gd 本地直接丢）。
## Host → 直接结算；Client → 提交意图，等 Host 权威事务 + 掉落物快照。
func request_drop_all() -> void:
	if not net.is_online_session():
		return
	if net.is_host:
		_try_host_drop_all(int(net.my_peer_id))
	elif _client_local_ready:
		drop_all_request.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func drop_all_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_drop_all(sender)


## Host 权威：把该玩家两个武器槽的武器全部丢到地上（弹夹/备弹一并转移），
## 清空槽位后广播「状态 + 掉落物」快照 —— 与拾取事务同款不可拆分提交。
func _try_host_drop_all(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var player := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(player) or not state or player.current_hp <= 0.0:
		return
	if _is_host_combat_busy(peer_id) or _is_host_throwable_held(peer_id):
		return
	var dropped: int = 0
	for slot: String in ["primary", "secondary"]:
		var wd: WeaponData = state.get_equipped_weapon(slot)
		if wd == null:
			continue
		_spawn_host_dropped_weapon(wd, player, state)
		state.unequip_slot(slot)
		_combat_busy_until_msec[peer_id] = Time.get_ticks_msec() + 200
		dropped += 1
	if dropped == 0:
		return
	## 手里空了 → 收起武器模式（表现层交给客户端 PlayerPistolState 的 _wd==null → Idle 自愈）
	if player.is_weapon_mode_active() and player.has_method("exit_weapon_mode"):
		player.exit_weapon_mode()
	pickup_snapshot.rpc(_build_snapshot(), _build_pickup_snapshot())
	print("[NetworkWorld] HOST_DROP_ALL peer=%d dropped=%d" % [peer_id, dropped])


func _add_host_reserve_ammo(state: PlayerState, weapon: WeaponData, amount: int) -> void:
	if amount <= 0 or weapon.ammo_item_id.is_empty():
		return
	var resource: ItemData = _find_ammo_resource_for_weapon(state, weapon.ammo_item_id)
	if not resource:
		return
	for index: int in range(amount):
		state.add_item(resource.duplicate())


func _find_ammo_resource_for_weapon(state: PlayerState, ammo_item_id: String) -> ItemData:
	var path := "res://object/item_%s_ammo.tres" % ammo_item_id.trim_prefix("ammo_")
	if ResourceLoader.exists(path):
		var resource := load(path)
		if resource is ItemData:
			return resource as ItemData
	for item: Resource in state.inventory:
		if item is ItemData and (item as ItemData).item_id == ammo_item_id:
			return item as ItemData
	return null


@rpc("authority", "call_remote", "reliable")
func pickup_snapshot(player_states: Array, pickup_states: Array) -> void:
	if net.is_host or _scene_transitioning:
		return
	# 与 Host 的 _try_host_pickup() 同包发送，先收敛装备/弹匣，再更新掉落物。
	_apply_client_snapshot(player_states, false)
	_apply_client_pickup_snapshot(pickup_states)


## 已被认领的镜像节点（instance_id → pickup_id）。
## ★ 联机不变量：一个节点只能被一个 pickup_id 认领 —— 否则后写的 id 会覆盖前者
## 的内容（实测：手雷被喷雾覆盖、霰弹被手枪覆盖，客户端再也找不到投掷物源）。
func _claimed_pickup_nodes() -> Dictionary:
	var claimed: Dictionary = {}
	for key: Variant in _pickups.keys():
		var value: Variant = _pickups[key]
		if is_instance_valid(value):
			claimed[(value as Node).get_instance_id()] = int(key)
	return claimed


## 候选节点若已被**别的** id 认领则作废（返回 null，调用方转而新建自己的镜像）。
func _reject_claimed(candidate: Node2D, pickup_id: int, claimed: Dictionary) -> Node2D:
	if not is_instance_valid(candidate):
		return null
	var owner_id: int = int(claimed.get(candidate.get_instance_id(), 0))
	if owner_id != 0 and owner_id != pickup_id:
		return null
	return candidate


func _apply_client_pickup_snapshot(states: Array) -> void:
	# 先清理已释放条目（09-22 实测）：_pickups 里的 queue_free 节点若残留，
	# `_pickups.get(id) as Node2D` 会抛 "Trying to cast a freed object" 并**静默
	# 中止整个应用函数** —— Client 端所有掉落物同步随之失效（表现为看不见/
	# 拿不了/多出幽灵物件）。
	for stale_key: Variant in _pickups.keys():
		if not is_instance_valid(_pickups[stale_key]):
			_pickups.erase(stale_key)
	var claimed: Dictionary = _claimed_pickup_nodes()
	var seen: Dictionary = {}
	for packet_value: Variant in states:
		if not packet_value is Dictionary:
			continue
		var packet := packet_value as Dictionary
		var pickup_id: int = int(packet.get("pickup_id", 0))
		if pickup_id <= 0:
			continue
		seen[pickup_id] = true
		var pickup_kind := str(packet.get("pickup_kind", "weapon"))
		# ⚠ 取值必须先判 is_instance_valid 再 as Node2D（对已释放对象做 as 会抛错）。
		var pickup_value: Variant = _pickups.get(pickup_id)
		var pickup: Node2D = (pickup_value as Node2D) if is_instance_valid(pickup_value) else null
		var scene_path := str(packet.get("scene_path", ""))
		if not is_instance_valid(pickup):
			# 首选客户端启动时缓存的预置节点。直接按路径查找不足以保证清理时
			# 能识别旧节点，特别是在掉落物被重挂父节点或动态替换之后。
			var preplaced_value: Variant = _client_preplaced_pickups_by_path.get(scene_path)
			pickup = (preplaced_value as Node2D) if is_instance_valid(preplaced_value) else null
			pickup = _reject_claimed(pickup, pickup_id, claimed)
			if not is_instance_valid(pickup) and not scene_path.is_empty():
				pickup = get_tree().current_scene.get_node_or_null(NodePath(scene_path)) as Node2D
				pickup = _reject_claimed(pickup, pickup_id, claimed)
			if not is_instance_valid(pickup):
				pickup = (HEALING_PICKUP_SCENE if pickup_kind == "throwable" else PICKUP_SCENE).instantiate() as Node2D
				# ★ 必须改成唯一名（2026-09-23 审计实测）：镜像若沿用场景根名（WeaponPickup /
				# HealingPickup）直接挂进 GroundLayer，就会**占用与地图节点相同的 scene_path
				# 命名空间** —— 随后另一个 pickup_id 的包带着真正的地图路径（如
				# "GroundLayer/WeaponPickup"）过来时，get_node_or_null 命中的是**先建的那个
				# 镜像**，于是两个 id 指向同一节点、后写者覆盖前者（实测：id9 的手雷被 id12
				# 的喷雾覆盖 → 客户端找不到投掷物源；id1 的霰弹被 id13 的手枪覆盖）。
				pickup.name = "NetPickup%d" % pickup_id
				# 镜像节点生命周期归 NetworkWorld 所有：必须在 add_child **之前**置位 ——
				# weapon_pickup/healing_pickup._ready() 据此跳过 GroundItemCap.register()。
				# 否则客户端会按本地「地面物上限 8」淘汰镜像节点（queue_free 且不通知这里）
				# → _pickups[id] 悬垂 → 下个可靠快照按同一 id 重建 → 再淘汰 …… 形成
				# 2 秒周期的「消失↔重建」无限轮转。★Host 才是地面物集合的唯一真源。
				pickup.set("cap_exempt", true)
				var parent := get_tree().current_scene.find_child("GroundLayer", true, false)
				(parent if parent else get_tree().current_scene).add_child(pickup)
			_pickups[pickup_id] = pickup
		claimed[pickup.get_instance_id()] = pickup_id
		if pickup_kind == "throwable":
			var throwable := _get_network_throwable_data_by_id(str(packet.get("item_id", "")))
			if not throwable:
				continue
			pickup.set("weapon_data", null)
			pickup.set("item", throwable)
		elif pickup_kind == "healing":
			# D2 实测修复：治疗品镜像重建（与投掷物同款白名单解析）。
			var healing := NETWORK_HEALINGS.get(str(packet.get("item_id", ""))) as ItemData
			if not healing:
				continue
			pickup.set("weapon_data", null)
			pickup.set("item", healing)
		else:
			var weapon := _get_network_weapon_data_by_id(str(packet.get("weapon_id", "")))
			if not weapon:
				continue
			pickup.set("item", null)
			# 地面显示参数统一走 WeaponData（与 Host 生成侧同款，2026-09-13 约定）：
			# 旧实现只设 texture/char_idx/direction，pickup_animated / step_frames /
			# step_duration 留默认 → Client 踏步动画与武器数据配置不一致。
			PICKUP_SCRIPT.apply_weapon_ground_display(pickup, weapon)
			pickup.set("pickup_reserve_ammo", int(packet.get("reserve_ammo", 0)))
			pickup.set("pickup_magazine_ammo", int(packet.get("magazine_ammo", -1)))
		pickup.global_position = _packet_position(packet)
		pickup.call("_refresh_sprite")
		# 武器拾取由 WeaponPickup 的客户端交互逻辑处理；投掷物与治疗品必须允许本地
		# 节点向 Host 提交拾取请求。最终距离、物品和替换均仍由 _try_host_pickup() 权威校验。
		pickup.call("configure_network_pickup", pickup_id, pickup_kind == "weapon")
		pickup.visible = true
		pickup.call("reset_network_pickup_request")
	for old_id: Variant in _pickups.keys().duplicate():
		var id: int = int(old_id)
		if not seen.has(id):
			var stale_value: Variant = _pickups[id]
			var stale: Node = (stale_value as Node) if is_instance_valid(stale_value) else null
			_pickups.erase(id)
			if is_instance_valid(stale):
				for path_value: Variant in _client_preplaced_pickups_by_path.keys().duplicate():
					if _client_preplaced_pickups_by_path[path_value] == stale:
						_client_preplaced_pickups_by_path.erase(path_value)
				if stale.has_method("disable_network_pickup"):
					stale.call("disable_network_pickup")
				else:
					stale.hide()
				stale.queue_free()

# ---------------------------------------------------------------- Host-authoritative safe doors

func request_safe_door_ready(door_key: String) -> void:
	if door_key.is_empty():
		return
	if net.is_host:
		_try_host_safe_door_ready(int(net.my_peer_id), door_key)
	elif _initial_world_received:
		safe_door_ready_request.rpc_id(1, door_key)


@rpc("any_peer", "call_remote", "reliable")
func safe_door_ready_request(door_key: String) -> void:
	if not net.is_host or _scene_transitioning or not is_inside_tree() or multiplayer == null:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 1:
		_try_host_safe_door_ready(sender, door_key)


func _try_host_safe_door_ready(peer_id: int, door_key: String) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	# 倒地/死亡玩家不能确认安全门（L4D2 规则：必须站立状态交互）；
	# 他们仍可爬到门边被计入到门人数，由站立的队友执行确认。
	var entry: Dictionary = _players[peer_id]
	var requester := entry.get("node") as CharacterBody2D
	if is_instance_valid(requester) and requester.is_network_dead():
		return
	var door := _find_safe_door(door_key)
	# 任何请求都必须来自实际站在门边的玩家，不能信任客户端提交的门路径。
	if not is_instance_valid(door) or not _is_host_player_at_safe_door(peer_id, door):
		return
	# 一次确认只针对一扇门；移除旧门状态，避免多个门的 UI 留下过期人数。
	for key: Variant in _safe_door_ready.keys().duplicate():
		var previous_key := str(key)
		if previous_key != door_key:
			_safe_door_ready.erase(key)
			_broadcast_safe_door_ready_status(previous_key, true)
	_safe_door_ready[door_key] = true
	_broadcast_safe_door_ready_status(door_key, true)
	# 规则：全员到同一扇门附近后，任意一名到门玩家按确认即可统一转场。
	if _are_all_players_at_safe_door(door):
		door.call("commit_host_network_entry")


func _find_safe_door(door_key: String) -> Node2D:
	if door_key.is_empty() or not get_tree().current_scene:
		return null
	var node := get_tree().current_scene.get_node_or_null(NodePath(door_key)) as Node2D
	if not is_instance_valid(node) or not node.has_method("commit_host_network_entry"):
		return null
	return node


func _is_host_player_at_safe_door(peer_id: int, door: Node2D) -> bool:
	if not _players.has(peer_id) or not is_instance_valid(door):
		return false
	var player := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if not is_instance_valid(player):
		return false
	return player.global_position.distance_to(door.global_position) <= float(door.get("interact_range"))


## 全员到门检查（Host 权威转场条件）。
## 【死亡豁免】真死亡（流血耗尽）的玩家不再计入 —— 否则一人死亡全队就永远
## 无法过门（软锁）。他们将在下一章开头由 spawn 满血复活兜底归队。
## 倒地玩家仍计入：他们可以爬行到门边等待，但确认门本身必须由站立玩家执行。
func _are_all_players_at_safe_door(door: Node2D) -> bool:
	var peer_ids: Array[int] = net.get_peer_ids()
	if peer_ids.is_empty():
		return false
	for peer_id: int in peer_ids:
		var entry: Dictionary = _players.get(peer_id, {})
		var node := entry.get("node") as CharacterBody2D
		if is_instance_valid(node) and node.is_network_dead() and not bool(entry.get("downed", false)):
			continue
		if not _is_host_player_at_safe_door(peer_id, door):
			return false
	return true


func _get_safe_door_arrival_count(door: Node2D) -> int:
	if not is_instance_valid(door):
		return 0
	var count := 0
	for peer_id: int in net.get_peer_ids():
		if _is_host_player_at_safe_door(peer_id, door):
			count += 1
	return count


func _clear_host_safe_door_ready_for_peer(_peer_id: int) -> void:
	# 断线会改变总人数；保留当前门的确认意图，仅刷新 Host 权威的人数显示。
	if net.is_host:
		_refresh_host_safe_door_readiness()


func _refresh_host_safe_door_readiness() -> void:
	if not net.is_host or _safe_door_ready.is_empty():
		return
	for key: Variant in _safe_door_ready.keys().duplicate():
		var door_key := str(key)
		var door := _find_safe_door(door_key)
		if not is_instance_valid(door):
			_safe_door_ready.erase(key)
			_broadcast_safe_door_ready_status(door_key, true)
			continue
		# 仅在到门人数或总人数变化时可靠广播，避免每帧网络噪声。
		_broadcast_safe_door_ready_status(door_key)


func _broadcast_safe_door_ready_status(door_key: String, force: bool = false) -> void:
	var door := _find_safe_door(door_key)
	var arrived_count := _get_safe_door_arrival_count(door)
	var total_count: int = net.get_peer_ids().size()
	var previous: Dictionary = _door_ready_status.get(door_key, {}) as Dictionary
	if not force and int(previous.get("ready_count", -1)) == arrived_count and int(previous.get("total_count", -1)) == total_count:
		return
	_apply_safe_door_ready_status(door_key, arrived_count, total_count)
	safe_door_ready_status.rpc(door_key, arrived_count, total_count)


func _apply_safe_door_ready_status(door_key: String, ready_count: int, total_count: int) -> void:
	_door_ready_status[door_key] = {"ready_count": ready_count, "total_count": total_count}
	var door := _find_safe_door(door_key)
	if is_instance_valid(door) and door.has_method("apply_network_ready_status"):
		door.call("apply_network_ready_status", ready_count, total_count, false)


@rpc("authority", "call_remote", "reliable")
func safe_door_ready_status(door_key: String, ready_count: int, total_count: int) -> void:
	if net.is_host:
		return
	_apply_safe_door_ready_status(door_key, ready_count, total_count)


# ---------------------------------------------------------------- Host-authoritative holdout countdown

## Host 机器每帧调用：保存权威快照 + 限速（≈2Hz）可靠广播到所有 Client。
## force=true（阶段切换/结束）时立即发送，保证客户端阶段切换及时、不过渡滞后。
## 单机模式下 NetworkWorld 不存在，机器不会调用本方法，本地 HUD 由机器直接驱动（行为不变）。
func broadcast_holdout_state(phase: int, remaining: float, total: float, token: int, force: bool = false) -> void:
	if not net or not net.is_host:
		return
	if phase <= 0:
		_holdout_state.clear()
	else:
		_holdout_state = {"phase": phase, "remaining": remaining, "total": total, "token": token}
	var now := Time.get_ticks_msec()
	if not force and now - _holdout_last_broadcast_msec < 500:
		return
	_holdout_last_broadcast_msec = now
	holdout_state_sync.rpc(phase, remaining, total, token)


@rpc("authority", "call_remote", "reliable")
func holdout_state_sync(phase: int, remaining: float, total: float, token: int) -> void:
	if net.is_host or not is_inside_tree() or _scene_transitioning:
		return
	# 场景切换静默期收到的包直接丢弃；其余交给机器自身按 token 校验（含结束哨兵），
	# 避免误杀"中途加入补发"等合法包，也避免在新场景弹出旧场景残留的幽灵 HUD。
	_apply_holdout_state(phase, remaining, total, token)


## 找到场景内所有防守战机器并驱动其本地 HUD。仅 Client 收到 RPC 时调用：
## Host 在 broadcast 里不再本地 _apply，避免与机器自身 _process 的驱动重复叠加。
func _apply_holdout_state(phase: int, remaining: float, total: float, token: int) -> void:
	var scene := get_tree().current_scene if get_tree() else null
	if not scene:
		return
	for machine: Node in scene.find_children("*", "HoldoutMachine", true, false):
		if machine.has_method("apply_remote_holdout_state"):
			machine.apply_remote_holdout_state(phase, remaining, total, token)


## 防守战完成事件的可靠广播：让 Client 也执行节点显隐（传送点仅 Host 创建，避免重复生成）。
func broadcast_holdout_completed(token: int) -> void:
	if not net or not net.is_host:
		return
	holdout_completed.rpc(int(token))


@rpc("authority", "call_remote", "reliable")
func holdout_completed(token: int) -> void:
	if net.is_host or not is_inside_tree() or _scene_transitioning:
		return
	var scene := get_tree().current_scene if get_tree() else null
	if not scene:
		return
	for machine: Node in scene.find_children("*", "HoldoutMachine", true, false):
		if machine.has_method("apply_remote_completion"):
			machine.apply_remote_completion(token)


# ---------------------------------------------------------------- Automated smoke input

## 受控双端回归：生产安全门仍只接受真实本地按键请求；此逻辑只在显式无头测试参数下运行。
func _is_auto_multi_disconnect_test() -> bool:
	return "--net-test-multi-disconnect" in OS.get_cmdline_user_args()


func _get_auto_client_role() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-client-role="):
			return argument.trim_prefix("--net-test-client-role=").strip_edges().to_lower()
	return ""


func _are_network_seats_reconciled(expected_peer_ids: Array[int]) -> bool:
	if Players.seat_count() != expected_peer_ids.size():
		return false
	var expected := expected_peer_ids.duplicate()
	expected.sort()
	var owners: Array[int] = []
	for seat_index: int in range(Players.seat_count()):
		var state := Players.get_seat(seat_index)
		if not state:
			return false
		owners.append(state.owner_peer_id)
	return owners == expected


@rpc("authority", "call_remote", "reliable")
func multi_disconnect_complete() -> void:
	if not net.is_host:
		_auto_multi_disconnect_complete = true


@rpc("any_peer", "call_remote", "reliable")
func multi_disconnect_ack() -> void:
	if not net.is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if peer_id > 1 and peer_id in net.get_peer_ids():
		_auto_multi_disconnect_acks[peer_id] = true


@rpc("authority", "call_remote", "reliable")
func multi_disconnect_release() -> void:
	if not net.is_host:
		_auto_multi_disconnect_release = true


func _get_auto_expected_player_count() -> int:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-players="):
			return clampi(int(argument.trim_prefix("--net-test-players=")), 3, 4)
	return 3


func _run_auto_host_multi_disconnect_test() -> void:
	var initial_count := _get_auto_expected_player_count()
	var remaining_count := initial_count - 1
	var deadline := Time.get_ticks_msec() + 12000
	while (net.get_peer_ids().size() < initial_count or _players.size() < initial_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host:
		return
	if net.get_peer_ids().size() != initial_count or _players.size() != initial_count:
		printerr("[NetworkWorld] AUTO_MULTI_HOST_SETUP_FAILED peers=%d players=%d seats=%d expected=%d" % [net.get_peer_ids().size(), _players.size(), Players.seat_count(), initial_count])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_HOST_READY peers=%d players=%d seats=%d" % [initial_count, initial_count, initial_count])
	deadline = Time.get_ticks_msec() + 12000
	while (net.get_peer_ids().size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host:
		return
	if net.get_peer_ids().size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(net.get_peer_ids()):
		printerr("[NetworkWorld] AUTO_MULTI_HOST_DISCONNECT_FAILED peers=%d players=%d seats=%d expected=%d" % [net.get_peer_ids().size(), _players.size(), Players.seat_count(), remaining_count])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_HOST_DISCONNECT_COMPLETE peers=%d players=%d seats=%d" % [remaining_count, remaining_count, remaining_count])
	_auto_multi_disconnect_acks.clear()
	multi_disconnect_complete.rpc()
	deadline = Time.get_ticks_msec() + 12000
	while _auto_multi_disconnect_acks.size() < remaining_count - 1 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host:
		return
	if _auto_multi_disconnect_acks.size() != remaining_count - 1:
		printerr("[NetworkWorld] AUTO_MULTI_HOST_ACK_FAILED received=%d expected=%d" % [_auto_multi_disconnect_acks.size(), remaining_count - 1])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_HOST_ACK_COMPLETE clients=%d" % _auto_multi_disconnect_acks.size())
	multi_disconnect_release.rpc()
	await get_tree().create_timer(0.75).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


func _run_auto_client_multi_disconnect_test() -> void:
	var role := _get_auto_client_role()
	var initial_count := _get_auto_expected_player_count()
	var remaining_count := initial_count - 1
	var deadline := Time.get_ticks_msec() + 12000
	while (_players.size() < initial_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or net.is_host:
		return
	if _players.size() != initial_count or Players.seat_count() != initial_count:
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_SETUP_FAILED role=%s peers=%d players=%d seats=%d expected=%d" % [role, net.get_peer_ids().size(), _players.size(), Players.seat_count(), initial_count])
		net.leave()
		get_tree().quit(1)
		return
	if role == "drop":
		print("[NetworkWorld] AUTO_MULTI_CLIENT_DROP_READY peers=%d players=%d seats=%d" % [initial_count, initial_count, initial_count])
		await get_tree().create_timer(0.50).timeout
		net.leave()
		get_tree().quit()
		return
	if role != "stay":
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_ROLE_FAILED role=%s" % role)
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_CLIENT_STAY_READY peers=%d players=%d seats=%d" % [initial_count, initial_count, initial_count])
	deadline = Time.get_ticks_msec() + 12000
	while (not _auto_multi_disconnect_complete or net.get_peer_ids().size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var expected_peer_ids: Array[int] = net.get_peer_ids()
	if not _auto_multi_disconnect_complete or expected_peer_ids.size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(expected_peer_ids):
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_STAY_FAILED complete=%s peers=%d players=%d seats=%d expected=%d" % [_auto_multi_disconnect_complete, expected_peer_ids.size(), _players.size(), Players.seat_count(), remaining_count])
		net.leave()
		get_tree().quit(1)
		return
	multi_disconnect_ack.rpc_id(1)
	deadline = Time.get_ticks_msec() + 12000
	while not _auto_multi_disconnect_release and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _auto_multi_disconnect_release:
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_RELEASE_FAILED role=%s" % role)
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_CLIENT_STAY_COMPLETE peers=%d players=%d seats=%d" % [remaining_count, remaining_count, remaining_count])
	net.leave()
	get_tree().quit()

## --net-test=slow-host-ready 专用：回归"Client 的 scene-ready 报告先于 Host 场景
## 就绪到达"的竞态。必须让 Host 进程同时携带 --net-test-host-scene-delay-ms=N
## （由 game_init.gd 延迟创建 NetworkWorld），否则 Client 的 ready 不会落入缓冲窗口。
## 修复前该竞态会吞掉 ready 记录：_ready_client_peers 永远为空、世界快照永不发出，
## Client 画面永久卡死 —— 正是手工对局中"客户端卡住"的根因。
func _is_auto_slow_host_ready_test() -> bool:
	return "--net-test=slow-host-ready" in OS.get_cmdline_user_args()


## Host 端断言：竞态发生后，Client 仍被纳入 _ready_client_peers 且可靠世界快照
## 最终被补发（计数 > 0）。
func _run_auto_host_slow_host_ready_test() -> void:
	var deadline := Time.get_ticks_msec() + 12000
	while _ready_client_peers.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _ready_client_peers.is_empty():
		printerr("[NetworkWorld] AUTO_SLOWHOST_HOST_FAILED ready_peers_empty")
		get_tree().quit(1)
		return
	deadline = Time.get_ticks_msec() + 4000
	while _auto_world_snapshot_sent_count <= 0 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _auto_world_snapshot_sent_count <= 0:
		printerr("[NetworkWorld] AUTO_SLOWHOST_HOST_FAILED no_world_snapshot_sent")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_SLOWHOST_HOST_COMPLETE snapshots=%d ready_peers=%d" % [_auto_world_snapshot_sent_count, _ready_client_peers.size()])
	await get_tree().create_timer(0.30).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


## Client 端断言：收到可靠世界快照（_initial_world_received）、Host 实体已在本端
## 重建 —— 即"Client 先就绪"的会话里远端精灵能够正常刷出。
func _run_auto_client_slow_host_ready_test() -> void:
	var deadline := Time.get_ticks_msec() + 12000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var host_node := (_players.get(1, {}) as Dictionary).get("node") as CharacterBody2D
	if not _initial_world_received or _players.size() < 2 or not is_instance_valid(host_node):
		printerr("[NetworkWorld] AUTO_SLOWHOST_CLIENT_FAILED world=%s players=%d host_node=%s" % [
			str(_initial_world_received), _players.size(), str(is_instance_valid(host_node))])
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_SLOWHOST_CLIENT_COMPLETE players=%d" % _players.size())
	await get_tree().create_timer(0.40).timeout
	if is_inside_tree() and not net.is_host:
		net.leave()
		get_tree().quit()


## --net-test=downed-wipe 专用：验证倒地流血 → 真死亡 → 团灭黑屏 → 重载本章收敛。
## 团灭会触发一次真实换图，因此用 Engine meta（跨场景存活、随进程结束）区分两次进图：
## 第一次进图执行"双端倒地 → 加速流血 → 团灭触发"，第二次进图只做恢复验证后退出。
## 正式游戏绝不会进入这些分支。
func _is_auto_team_wipe_test() -> bool:
	return "--net-test=downed-wipe" in OS.get_cmdline_user_args()


## 第一次进图的 Host 场景：等 Client 就位后，用与真实敌人完全一致的生产伤害链路
## （CharacterBody2D.take_damage → network_damage_applied 信号）把双端同时打到 0 ——
## 双端同时倒地 → 无站立玩家 → 满足团灭条件。真实流血需 20 秒，测试把权威流血池
## 压到 0.4 令其在下一帧耗尽。触发后场景由 _update_host_wipe 走切图协议重载，
## 本协程到此结束 —— 绝不能在这里 leave()/quit()，否则切图协议中断。
func _run_auto_host_team_wipe_test() -> void:
	if Engine.has_meta("l3d_auto_team_wipe_stage"):
		_run_auto_host_team_wipe_verify()
		return
	Engine.set_meta("l3d_auto_team_wipe_stage", 1)
	var deadline := Time.get_ticks_msec() + 8000
	while (_players.size() < 2 or net.get_peer_ids().size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var client_id := 0
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			client_id = peer_id
			break
	var host_node := (_players.get(int(net.my_peer_id), {}) as Dictionary).get("node") as CharacterBody2D
	var client_node := (_players.get(client_id, {}) as Dictionary).get("node") as CharacterBody2D
	if client_id <= 1 or not is_instance_valid(host_node) or not is_instance_valid(client_node):
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_SETUP_FAILED client=%d" % client_id)
		get_tree().quit(1)
		return
	# 生产伤害入口：伤害信号同步把玩家登记为权威倒地（_handle_host_player_downed）。
	# ガッツ（HP≥2 保底 1 HP）会拦下 max_hp+1 的致死伤 → 永远不倒地（DOWN_FAILED 假红），
	# 先压 HP=1 再打（take_damage 链路原样保留）。
	_force_auto_test_player_low_hp(client_node)
	_force_auto_test_player_low_hp(host_node)
	client_node.take_damage(client_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998900)
	host_node.take_damage(host_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998901)
	deadline = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		var host_entry_now := _players.get(int(net.my_peer_id), {}) as Dictionary
		var client_entry_now := _players.get(client_id, {}) as Dictionary
		if bool(host_entry_now.get("downed", false)) and bool(client_entry_now.get("downed", false)):
			break
		await get_tree().create_timer(0.05).timeout
	var host_entry := _players.get(int(net.my_peer_id), {}) as Dictionary
	var client_entry := _players.get(client_id, {}) as Dictionary
	if not (bool(host_entry.get("downed", false)) and bool(client_entry.get("downed", false))):
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_DOWN_FAILED host=%s client=%s" % [
			str(bool(host_entry.get("downed", false))), str(bool(client_entry.get("downed", false)))])
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_DOWNED_OK")
	# 加速流血：直接改写权威流血池（Host 是唯一写入者），下一帧 _update_host_downed
	# 就会耗尽转真死亡，随后 _check_host_team_wipe 立即命中"全员非站立"。
	host_entry["downed_hp"] = 0.4
	_players[int(net.my_peer_id)] = host_entry
	client_entry["downed_hp"] = 0.4
	_players[client_id] = client_entry
	deadline = Time.get_ticks_msec() + 4000
	while not _wipe_active and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _wipe_active:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_TRIGGER_FAILED")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_TRIGGERED scene=%s" % _scene_path)
	# 黑屏淡出 + 停留结束后自动换图；本实例的职责到此为止。


## 第一次进图的 Client 场景。验证两点：
## 1) 快照把 downed=true 同步到本地 entry（救援筛选与生命三态判定的数据来源）；
## 2) team_wipe_presentation 广播把本地 _wipe_active 置位（黑屏 + 输入冻结）。
## 之后等待换图，不主动退出。
func _run_auto_client_team_wipe_test() -> void:
	if Engine.has_meta("l3d_auto_team_wipe_stage"):
		_run_auto_client_team_wipe_verify()
		return
	Engine.set_meta("l3d_auto_team_wipe_stage", 1)
	var deadline := Time.get_ticks_msec() + 8000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received or _players.size() < 2:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_SETUP_FAILED world=%s players=%d" % [str(_initial_world_received), _players.size()])
		get_tree().quit(1)
		return
	var local_entry := _players.get(int(net.my_peer_id), {}) as Dictionary
	deadline = Time.get_ticks_msec() + 4000
	while not bool(local_entry.get("downed", false)) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		local_entry = _players.get(int(net.my_peer_id), {}) as Dictionary
	if not bool(local_entry.get("downed", false)):
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_DOWN_FLAG_FAILED")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_DOWNED_OK")
	deadline = Time.get_ticks_msec() + 4000
	while not _wipe_active and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _wipe_active:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_FADE_FAILED")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_FADE_OK")


## 第二次进图（团灭重载后）的 Host 验证：客户端已回到场景，所有会话状态满血
## （团灭重置 + spawn 兜底），且没有任何玩家带着倒地/死亡 entry 标记。
func _run_auto_host_team_wipe_verify() -> void:
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_VERIFY_STAGE scene=%s" % _scene_path)
	var deadline := Time.get_ticks_msec() + 10000
	while (_players.size() < 2 or _ready_client_peers.is_empty()) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _players.size() < 2 or _ready_client_peers.is_empty():
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_VERIFY_FAILED players=%d ready=%d" % [_players.size(), _ready_client_peers.size()])
		get_tree().quit(1)
		return
	var ok := true
	for value: Variant in _players.keys():
		var entry := _players[int(value)] as Dictionary
		var state := entry.get("state") as PlayerState
		if not state or state.current_hp <= 0.0:
			ok = false
		if bool(entry.get("downed", false)) or bool(entry.get("dead", false)):
			ok = false
	if not ok:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_VERIFY_FAILED hp_or_state")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_RECOVERY_COMPLETE players=%d" % _players.size())
	await get_tree().create_timer(0.30).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


## 第二次进图（团灭重载后）的 Client 验证：收到可靠世界快照，本地玩家站立且 HP>0。
func _run_auto_client_team_wipe_verify() -> void:
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_VERIFY_STAGE scene=%s" % _scene_path)
	var deadline := Time.get_ticks_msec() + 10000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received or _players.size() < 2:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_VERIFY_FAILED no_world")
		get_tree().quit(1)
		return
	var local_node := (_players.get(int(net.my_peer_id), {}) as Dictionary).get("node") as CharacterBody2D
	if not is_instance_valid(local_node) or local_node.is_network_dead() or local_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_VERIFY_FAILED not_standing")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_RECOVERY_COMPLETE hp=%.1f" % local_node.current_hp)
	await get_tree().create_timer(0.80).timeout
	if is_inside_tree() and not net.is_host:
		net.leave()
		get_tree().quit()


func _is_auto_network_feature_test() -> bool:
	return "--net-test-features" in OS.get_cmdline_user_args()


func _is_auto_character_select_test() -> bool:
	return "--net-test-character-select" in OS.get_cmdline_user_args()


func _run_auto_host_character_select_world_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	var client_id := 0
	while Time.get_ticks_msec() < deadline:
		for peer_id: int in net.get_peer_ids():
			if peer_id > 1:
				client_id = peer_id
				break
		var host_state := (_players.get(int(net.my_peer_id), {}).get("state") as PlayerState)
		var client_state := (_players.get(client_id, {}).get("state") as PlayerState)
		if client_id > 1 and host_state and client_state:
			break
		await get_tree().create_timer(0.05).timeout
	var host_state := (_players.get(int(net.my_peer_id), {}).get("state") as PlayerState)
	var client_state := (_players.get(client_id, {}).get("state") as PlayerState)
	var host_expected := str(net.get_player_character_path(int(net.my_peer_id)))
	var client_expected := str(net.get_player_character_path(client_id))
	if client_id <= 1 or not host_state or not client_state or host_state.character_path != host_expected or client_state.character_path != client_expected:
		printerr("[NetworkWorld] AUTO_CHARACTER_HOST_WORLD_FAILED host=%s/%s client=%s/%s" % [host_state.character_path if host_state else "<none>", host_expected, client_state.character_path if client_state else "<none>", client_expected])
		get_tree().quit(1)
		return
	deadline = Time.get_ticks_msec() + 6000
	while not _auto_character_world_acks.has(client_id) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _auto_character_world_acks.has(client_id):
		printerr("[NetworkWorld] AUTO_CHARACTER_HOST_WORLD_FAILED missing_client_ack peer=%d" % client_id)
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_CHARACTER_HOST_WORLD_COMPLETE host=%s client=%s" % [host_state.character_path.get_file(), client_state.character_path.get_file()])
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


func _run_auto_client_character_select_world_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var local_id := int(net.my_peer_id)
	var host_state := (_players.get(1, {}).get("state") as PlayerState)
	var local_state := (_players.get(local_id, {}).get("state") as PlayerState)
	var host_expected := str(net.get_player_character_path(1))
	var local_expected := str(net.get_player_character_path(local_id))
	if not _initial_world_received or not host_state or not local_state or host_state.character_path != host_expected or local_state.character_path != local_expected:
		printerr("[NetworkWorld] AUTO_CHARACTER_CLIENT_WORLD_FAILED host=%s/%s local=%s/%s" % [host_state.character_path if host_state else "<none>", host_expected, local_state.character_path if local_state else "<none>", local_expected])
		get_tree().quit(1)
		return
	auto_character_world_ack.rpc_id(1)
	print("[NetworkWorld] AUTO_CHARACTER_CLIENT_WORLD_COMPLETE host=%s local=%s" % [host_state.character_path.get_file(), local_state.character_path.get_file()])
	await get_tree().create_timer(0.80).timeout
	if is_inside_tree():
		net.leave()
		get_tree().quit()


## 不等待完整 world_snapshot 的首图输入回归：Client 预置 Player 接管后立刻上传输入，
## Host 只以自身收到的 submit_input 作为通过依据。正式游戏不会进入此分支。
func _is_auto_client_ready_input_test() -> bool:
	return "--net-test-client-ready-input" in OS.get_cmdline_user_args()


func _run_auto_host_ready_input_test() -> void:
	var deadline := Time.get_ticks_msec() + 6000
	var client_id := 0
	while Time.get_ticks_msec() < deadline:
		for peer_id: int in net.get_peer_ids():
			if peer_id > 1:
				client_id = peer_id
				break
		if client_id > 1 and _auto_client_ready_input_seen_by_host:
			print("[NetworkWorld] AUTO_CLIENT_READY_INPUT_HOST_COMPLETE peer=%d" % client_id)
			await get_tree().create_timer(0.30).timeout
			if is_inside_tree() and net.is_host:
				net.leave()
				get_tree().quit()
			return
		await get_tree().create_timer(0.05).timeout
	printerr("[NetworkWorld] AUTO_CLIENT_READY_INPUT_HOST_FAILED peer=%d" % client_id)
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit(1)


func _run_auto_client_ready_input_test() -> void:
	if not _client_local_ready:
		printerr("[NetworkWorld] AUTO_CLIENT_READY_INPUT_CLIENT_FAILED local_ready=false")
		return
	# 输入已在 _ready() 中、scene-ready 上报前发出；短暂保持按键以避免网络帧恰好错过，
	# 再等待 Host 对该输入的权威接收。
	await get_tree().create_timer(0.35).timeout
	Input.action_release("右")
	await get_tree().create_timer(1.00).timeout
	if is_inside_tree() and not net.is_host:
		net.leave()
		get_tree().quit()


## 单一双端回归覆盖：客户端投掷物输入、Host 权威消费、死亡救援与举放武器过渡。
## 测试只在明确 --net-test-features 下运行，正式游戏完全不会进入此分支。
func _run_auto_host_feature_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while net.get_peer_ids().size() < 2 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host or net.get_peer_ids().size() < 2:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_SETUP_FAILED missing_client")
		return
	var client_id := 0
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			client_id = peer_id
			break
	var client_entry: Dictionary = _players.get(client_id, {})
	var client_state := client_entry.get("state") as PlayerState
	if client_id <= 1 or not client_state:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_SETUP_FAILED missing_client_state")
		return
	# 此测试不依赖常规回归启动参数：明确配置白名单内的有效主/副武器，
	# 这样后续真实 toggle RPC 一定有可验证的 Host 权威武器状态。
	client_state.equipment["primary"] = NETWORK_PISTOL
	client_state.equipment["secondary"] = NETWORK_KNIFE
	client_state.active_weapon_slot = "primary"
	client_state.set_magazine_ammo(NETWORK_PISTOL.item_id, NETWORK_PISTOL.magazine_capacity)
	client_state.throwable = NETWORK_GRENADE
	world_snapshot.rpc_id(client_id, _build_snapshot(), _build_enemy_snapshot(false), _build_pickup_snapshot())
	deadline = Time.get_ticks_msec() + 6000
	while client_state.throwable != null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if client_state.throwable != null:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_THROWABLE_FAILED not_consumed")
		return
	var host_entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var host_node := host_entry.get("node") as CharacterBody2D
	var client_node := client_entry.get("node") as CharacterBody2D
	if not is_instance_valid(host_node) or not is_instance_valid(client_node):
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_REVIVE_SETUP_FAILED missing_node")
		return
	_set_auto_test_player_position(client_id, host_node.global_position + Vector2(12.0, 0.0))
	# 真实 Host 伤害链路必须在 Client 产生受伤闪烁、数字和音效；
	# 先给一名敌人和 Host 各造成非致命伤，再进行后续倒地/救援回归。
	var feedback_enemy: CharacterBody2D = null
	for enemy_entry_value: Variant in _enemies.values():
		var candidate := _resolve_enemy_entry(enemy_entry_value as Dictionary)
		if is_instance_valid(candidate) and not candidate.is_network_dead():
			feedback_enemy = candidate
			break
	if not is_instance_valid(feedback_enemy):
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_HURT_SETUP_FAILED missing_enemy")
		return
	feedback_enemy.take_damage(1.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 998800)
	host_node.take_damage(1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998801)
	print("[NetworkWorld] AUTO_FEATURE_HOST_HURT_APPLIED enemy=%s player=%d" % [feedback_enemy.name, int(net.my_peer_id)])
	await get_tree().create_timer(0.35).timeout
	_force_auto_test_player_low_hp(host_node)  # ガッツ拦致死伤，先压 HP=1（见 helper 注释）
	host_node.take_damage(host_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998802)
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 4000
	while host_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if host_node.is_network_dead() or host_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_REVIVE_FAILED hp=%.1f" % host_node.current_hp)
		return
	# 接着验证 Client 自身倒地：Host 必须清空其陈旧输入，客户端必须冻结死亡位置。
	_force_auto_test_player_low_hp(client_node)  # ガッツ拦致死伤，先压 HP=1
	client_node.take_damage(client_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998803)
	deadline = Time.get_ticks_msec() + 2000
	while not client_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not client_node.is_network_dead():
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DEATH_SETUP_FAILED")
		return
	await get_tree().create_timer(0.90).timeout
	var client_entry_after_death: Dictionary = _players.get(client_id, {})
	var client_input: Vector2 = client_entry_after_death.get("input", Vector2.ZERO)
	var client_marked_stopped := not bool(client_entry_after_death.get("moving", false)) and client_input.is_zero_approx()
	# 倒地回归点：Client 倒地必须登记为权威 entry 标记（而不只是节点躺地表现），
	# 否则 _find_revive_target_for 与快照 downed 字段都会失效。
	if not bool(client_entry_after_death.get("downed", false)):
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DOWNED_FLAG_FAILED")
		return
	_try_host_start_revive(int(net.my_peer_id), client_id)
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 2500
	while client_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if client_node.is_network_dead() or client_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_REVIVE_FAILED hp=%.1f" % client_node.current_hp)
		return
	print("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DEATH_COMPLETE stopped=%s revived_hp=%.1f" % [client_marked_stopped, client_node.current_hp])
	if not client_marked_stopped:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DEATH_FAILED stopped=false")
		return
	print("[NetworkWorld] AUTO_FEATURE_HOST_COMPLETE revived_hp=%.1f" % host_node.current_hp)
	# Client 接下来还要完成武器举放与固定朝向回归；Host 必须持续在线直到请求已被权威处理。
	await get_tree().create_timer(15.0).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


func _run_auto_client_feature_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var local_id := int(net.my_peer_id)
	var entry: Dictionary = _players.get(local_id, {})
	var state := entry.get("state") as PlayerState
	while (not state or state.throwable == null) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		entry = _players.get(local_id, {})
		state = entry.get("state") as PlayerState
	if not state or state.throwable != NETWORK_GRENADE:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_THROWABLE_SETUP_FAILED item=%s" % [state.throwable.item_id if state and state.throwable else "<none>"])
		return
	throwable_hold_request.rpc_id(1, true)
	await get_tree().create_timer(0.15).timeout
	throwable_aim_request.rpc_id(1, true)
	await get_tree().create_timer(0.15).timeout
	throwable_range_request.rpc_id(1, 1)
	await get_tree().create_timer(0.15).timeout
	throwable_throw_request.rpc_id(1)
	deadline = Time.get_ticks_msec() + 3500
	while state.throwable != null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if state.throwable != null:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_THROWABLE_FAILED not_consumed")
		return
	# Host 会通过真实 take_damage() 广播敌人和玩家受伤表现；Client 只验证收到的表现 RPC，
	# 不在本地扣血或驱动敌人状态机。
	deadline = Time.get_ticks_msec() + 3500
	while (
		_auto_client_player_hurt_presentations < 1
		or _auto_client_enemy_hurt_presentations < 1
	) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var hurt_presentation_ok := _auto_client_player_hurt_presentations >= 1 and _auto_client_enemy_hurt_presentations >= 1
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_HURT_COMPLETE player_events=%d enemy_events=%d" % [
		_auto_client_player_hurt_presentations,
		_auto_client_enemy_hurt_presentations,
	])
	if not hurt_presentation_ok:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_HURT_FAILED player_events=%d enemy_events=%d" % [
			_auto_client_player_hurt_presentations,
			_auto_client_enemy_hurt_presentations,
		])
		return
	# Host 在投掷校验及受伤表现回归结束后会令自己倒地；客户端必须以真实 RPC 请求救援。
	var host_entry: Dictionary = _players.get(1, {})
	var host_node := host_entry.get("node") as CharacterBody2D
	deadline = Time.get_ticks_msec() + 4000
	while (not is_instance_valid(host_node) or not host_node.is_network_dead()) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		host_entry = _players.get(1, {})
		host_node = host_entry.get("node") as CharacterBody2D
	if not is_instance_valid(host_node) or not host_node.is_network_dead():
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_REVIVE_SETUP_FAILED host_dead=%s" % [is_instance_valid(host_node) and host_node.is_network_dead()])
		return
	# 倒地回归点：Host 的 downed 标记必须经快照同步到 Client entry ——
	# 它是救援目标筛选（_find_revive_target_for）与生命三态判定的数据来源；
	# 只有节点躺地表现而缺少该标记时，Client 将无法发起救援。
	if not bool((_players.get(1, {}) as Dictionary).get("downed", false)):
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DOWNED_FLAG_FAILED")
		return
	revive_start_request.rpc_id(1, 1)
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 2500
	while host_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if host_node.is_network_dead() or host_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_REVIVE_FAILED hp=%.1f" % [host_node.current_hp if is_instance_valid(host_node) else -1.0])
		return
	entry = _players.get(local_id, {})
	state = entry.get("state") as PlayerState
	var local_node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(local_node):
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_SETUP_FAILED missing_local_node")
		return
	deadline = Time.get_ticks_msec() + 4000
	while not local_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not local_node.is_network_dead():
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_SETUP_FAILED local_dead=false")
		return
	await get_tree().process_frame
	var collision_shape := local_node.get_node_or_null("CollisionShape2D") as CollisionShape2D
	# 倒地语义回归点：碰撞体在倒地期间必须重新启用（倒地爬行不能穿墙），
	# 取代旧的"死亡=碰撞关闭"断言；复活后同样保持启用。
	var collision_enabled_while_downed := is_instance_valid(collision_shape) and not collision_shape.disabled
	# 直接提交死亡后的移动意图；Host 入口必须忽略它，客户端的位置也不能继续漂移。
	await get_tree().create_timer(0.20).timeout
	var death_position := local_node.global_position
	submit_input.rpc_id(1, Vector2.RIGHT, false)
	await get_tree().create_timer(0.40).timeout
	var frozen := local_node.global_position.distance_to(death_position) <= 0.5
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 3500
	while local_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if local_node.is_network_dead() or local_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_REVIVE_FAILED hp=%.1f" % local_node.current_hp)
		return
	await get_tree().process_frame
	var collision_restored := is_instance_valid(collision_shape) and not collision_shape.disabled
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_COMPLETE frozen=%s collision_enabled_while_downed=%s collision_restored=%s revived=true" % [frozen, collision_enabled_while_downed, collision_restored])
	if not frozen or not collision_enabled_while_downed or not collision_restored:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_FAILED frozen=%s collision_enabled_while_downed=%s collision_restored=%s" % [frozen, collision_enabled_while_downed, collision_restored])
		return
	var active_weapon: WeaponData = state.get_active_weapon() if state else null
	if not is_instance_valid(local_node) or not active_weapon:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_TRANSITION_SETUP_FAILED node=%s weapon=%s" % [is_instance_valid(local_node), active_weapon != null])
		return
	var transition_wait := _get_network_weapon_transition_duration(active_weapon) + 0.30
	# 先统一到放下状态；不假设客户端初始表现是否已由场景/快照切换为举起。
	if local_node.is_weapon_mode_active():
		weapon_toggle_request.rpc_id(1)
		await get_tree().create_timer(transition_wait).timeout
	weapon_toggle_request.rpc_id(1)
	await get_tree().create_timer(transition_wait).timeout
	var raised: bool = local_node.is_weapon_mode_active()
	weapon_toggle_request.rpc_id(1)
	await get_tree().create_timer(transition_wait).timeout
	var lowered: bool = not local_node.is_weapon_mode_active()
	if not raised or not lowered:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_TRANSITION_FAILED raised=%s lowered=%s" % [raised, lowered])
		return
	# 固定朝向回归：Client 只能请求 Host 加锁；Host 在锁定时收到移动输入也不得改变 facing，
	# 解锁后下一次移动则必须恢复正常转向。
	weapon_toggle_request.rpc_id(1)
	await get_tree().create_timer(transition_wait).timeout
	if not local_node.is_weapon_mode_active():
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_FACING_SETUP_FAILED weapon_not_raised")
		return
	# Player.facing is an integer enum; use the vector accessor here so the
	# regression verifies direction without duplicating Player.FaceDir values.
	var locked_facing: Vector2 = local_node.get_facing_vector()
	var test_direction := Vector2.RIGHT if locked_facing != Vector2.RIGHT else Vector2.LEFT
	# The test uses explicit state requests rather than toggle so an inherited
	# scene/animation lock state cannot invert the assertion.
	facing_lock_request.rpc_id(1, false, true)
	await get_tree().create_timer(0.12).timeout
	submit_input.rpc_id(1, test_direction, false)
	await get_tree().create_timer(0.20).timeout
	var facing_after_lock: Vector2 = local_node.get_facing_vector()
	var stayed_locked: bool = facing_after_lock.is_equal_approx(locked_facing)
	var lock_state_synced: bool = local_node.is_facing_locked()
	facing_lock_request.rpc_id(1, false, false)
	await get_tree().create_timer(0.12).timeout
	submit_input.rpc_id(1, test_direction, false)
	await get_tree().create_timer(0.20).timeout
	var facing_after_unlock: Vector2 = local_node.get_facing_vector()
	var unlocked_turns: bool = facing_after_unlock.is_equal_approx(test_direction)
	var unlock_state_synced: bool = not local_node.is_facing_locked()
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_FACING_COMPLETE locked=%s unlocked=%s lock_state=%s unlock_state=%s" % [stayed_locked, unlocked_turns, lock_state_synced, unlock_state_synced])
	if not stayed_locked or not unlocked_turns or not lock_state_synced or not unlock_state_synced:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_FACING_FAILED locked=%s unlocked=%s expected=(%.0f,%.0f) locked_actual=(%.0f,%.0f) unlocked_actual=(%.0f,%.0f)" % [
			stayed_locked,
			unlocked_turns,
			test_direction.x,
			test_direction.y,
			facing_after_lock.x,
			facing_after_lock.y,
			facing_after_unlock.x,
			facing_after_unlock.y,
		])
		return
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_COMPLETE throwable=true revive=true transition=true facing_lock=true")
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


func _is_auto_enemy_test_scene() -> bool:
	return "--net-test-enemies" in OS.get_cmdline_user_args() and "突袭-第一关-街道" in _scene_path


func _run_auto_host_enemy_test() -> void:
	## Director 由 Host 运行。这里只验证它确实将动态敌人收编到网络实体表，
	## Client 的独立断言会验证可靠 spawn 包创建了表现实体。
	var deadline := Time.get_ticks_msec() + 30000
	while _enemies.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning or not net.is_host:
		return
	if _enemies.is_empty():
		printerr("[NetworkWorld] AUTO_ENEMY_HOST_FAILED no_registered_enemy")
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_ENEMY_HOST_COMPLETE registered=%d" % _enemies.size())
	# 死亡广播回归：等 Client 建立表现实体后击杀一名敌人。
	# Client 侧断言会验证可靠 enemy_death_presentation 已被应用（而非等 2s 重同步）。
	deadline = Time.get_ticks_msec() + 8000
	while _ready_client_peers.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	await get_tree().create_timer(1.00).timeout
	var victim := _find_first_alive_host_enemy()
	if not is_instance_valid(victim):
		printerr("[NetworkWorld] AUTO_ENEMY_HOST_DEATH_FAILED no_victim")
		net.leave()
		get_tree().quit(1)
		return
	victim.take_damage(victim.current_hp + 1.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 998801)
	deadline = Time.get_ticks_msec() + 4000
	while not victim.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	print("[NetworkWorld] AUTO_ENEMY_HOST_DEATH_COMPLETE victim=%s dead=%s" % [victim.name, victim.is_network_dead()])
	# 留出 Client 完成死亡断言并自行退出；Host 随后走 _on_peer_left 的常规收束。
	await get_tree().create_timer(4.0).timeout


func _find_first_alive_host_enemy() -> CharacterBody2D:
	for entry_value: Variant in _enemies.values():
		var enemy := _resolve_enemy_entry(entry_value as Dictionary)
		if is_instance_valid(enemy) and not enemy.is_network_dead():
			return enemy
	return null


func _run_auto_client_enemy_test() -> void:
	var deadline := Time.get_ticks_msec() + 35000
	while (not _initial_world_received or _enemies.is_empty()) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning:
		return
	var has_network_enemy := false
	for entry_value: Variant in _enemies.values():
		var enemy := _resolve_enemy_entry(entry_value as Dictionary)
		if is_instance_valid(enemy) and int(enemy.get("network_entity_id")) > 0:
			has_network_enemy = true
			break
	if not _initial_world_received or not has_network_enemy:
		printerr("[NetworkWorld] AUTO_ENEMY_CLIENT_FAILED local_ready=%s enemies=%d network_enemy=%s" % [_initial_world_received, _enemies.size(), has_network_enemy])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_ENEMY_CLIENT_COMPLETE received=%d" % _enemies.size())
	# 死亡广播回归：Host 会击杀一名敌人；Client 必须收到可靠死亡表现并立即变尸体。
	deadline = Time.get_ticks_msec() + 8000
	while _auto_client_enemy_death_presentations < 1 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _auto_client_enemy_death_presentations < 1:
		printerr("[NetworkWorld] AUTO_ENEMY_CLIENT_DEATH_FAILED presentations=%d" % _auto_client_enemy_death_presentations)
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_ENEMY_CLIENT_DEATH_COMPLETE")
	# Give the Host smoke coroutine one network tick to record its own assertion before teardown.
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


## ── D2 外观/难度一致性回归（--net-test-appearance，第一关街道图）──
## Host：定向刷 1 特感（ブレインディモス，Director.spawn_special_enemy 生产路径）
## + 1 变体丧尸（中年ゾンビ，与 spawn_enemy 同字段注入），等收编后周期性广播吐酸
## 表现（镜像弹纯视觉，多次广播幂等无害）。Client 断言四件套：
##   A1 特感 spawn 外观注入 / A5 变体行走图重建 / A2 酸弹镜像 / B1 难度覆写
##   （Host --net-test-difficulty=2，Client 预置 1，进图后必须被同步覆写为 2）。
func _is_auto_appearance_test() -> bool:
	return "--net-test-appearance" in OS.get_cmdline_user_args() and "突袭-第一关-街道" in _scene_path


func _run_auto_host_appearance_test() -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while _ready_client_peers.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning or not net.is_host:
		return
	var decor := get_tree().current_scene.find_child("DecorLayer", true, false) as Node2D
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if decor == null or player == null:
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED missing_decor_or_player")
		net.leave()
		get_tree().quit(1)
		return
	# 特感：走 Director 生产路径（注入 special_data → 快照携带 special_id）。
	var special_data := load("res://tres/specials/ブレインディモス.tres") as SpecialEnemyData
	var director := get_node_or_null("/root/Director")
	if special_data == null or director == null or not director.has_method("spawn_special_enemy"):
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED missing_special_pipeline")
		net.leave()
		get_tree().quit(1)
		return
	var sp: Node2D = director.spawn_special_enemy(player.global_position + Vector2(140.0, 0.0), special_data, decor)
	# 变体：与 spawn_enemy 同字段注入（apply_to_enemy + variant_data → 快照携带 variant_id）。
	var variant := load("res://tres/zombies/中年ゾンビ.tres") as ZombieVariant
	if variant == null:
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED missing_variant_tres")
		net.leave()
		get_tree().quit(1)
		return
	var zombie := ENEMY_SCENE.instantiate() as CharacterBody2D
	zombie.global_position = player.global_position + Vector2(-140.0, 0.0)
	variant.apply_to_enemy(zombie)
	zombie.variant_data = variant
	decor.add_child(zombie)
	# 等收编（_register_untracked_host_enemies 周期扫描）。
	deadline = Time.get_ticks_msec() + 8000
	var registered := false
	while Time.get_ticks_msec() < deadline and not registered:
		registered = _find_entity_id_by_filter(func(e: CharacterBody2D) -> bool: return e.get_network_special_id() == "brain_demos") > 0 \
			and _find_entity_id_by_filter(func(e: CharacterBody2D) -> bool: return e.get_network_variant_id() == "chunen") > 0
		if not registered:
			await get_tree().create_timer(0.10).timeout
	if not registered:
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED not_registered")
		net.leave()
		get_tree().quit(1)
		return
	# ⚠ 标记必须先于吐酸广播：net-test 下 Client 一断开 Host 即被
	# _finish_auto_host_after_client_leave 收束，挂起协程不再恢复——若把
	# COMPLETE 放在广播循环之后，Client 先退出时标记永远打不出来。
	print("[NetworkWorld] AUTO_APPEARANCE_HOST_COMPLETE special=brain_demos variant=chunen")
	# 吐酸表现广播 ×6（镜像弹纯视觉即焚，重复广播幂等），收尾尽力执行。
	for i: int in 6:
		var sp_node := _resolve_enemy_entry(_enemies.get(_find_entity_id_by_filter(func(e: CharacterBody2D) -> bool: return e.get_network_special_id() == "brain_demos"), {}) as Dictionary)
		if is_instance_valid(sp_node):
			announce_enemy_acid_spit(sp_node, sp_node.global_position, Vector2.RIGHT)
		await get_tree().create_timer(0.50).timeout
	await get_tree().create_timer(3.0).timeout


func _find_entity_id_by_filter(filter: Callable) -> int:
	for key: Variant in _enemies.keys():
		var enemy := _resolve_enemy_entry(_enemies[key] as Dictionary)
		if is_instance_valid(enemy) and int(enemy.get("network_entity_id")) > 0 and filter.call(enemy):
			return int(key)
	return 0


func _run_auto_client_appearance_test() -> void:
	# 与 network_world 白名单同一份 tres：Client 重建用 preload 常量，断言用 load()
	# 取回的是同一缓存实例，纹理按引用相等比较成立。
	var special_res := load("res://tres/specials/ブレインディモス.tres") as SpecialEnemyData
	var variant_res := load("res://tres/zombies/中年ゾンビ.tres") as ZombieVariant
	var deadline := Time.get_ticks_msec() + 35000
	var special_hit := false
	var variant_hit := false
	while Time.get_ticks_msec() < deadline and not (special_hit and variant_hit):
		special_hit = false
		variant_hit = false
		for key: Variant in _enemies.keys():
			var enemy := _resolve_enemy_entry(_enemies[key] as Dictionary)
			if not is_instance_valid(enemy):
				continue
			if not special_hit and enemy.get("walk_texture") == special_res.texture \
					and enemy.get("spit_enabled") == true:
				special_hit = true
			if not variant_hit and enemy.get("walk_texture") == variant_res.normal_texture:
				variant_hit = true
		if special_hit and variant_hit:
			break
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning:
		return
	if not (special_hit and variant_hit):
		printerr("[NetworkWorld] AUTO_APPEARANCE_CLIENT_FAILED special=%s variant=%s enemies=%d" % [special_hit, variant_hit, _enemies.size()])
		net.leave()
		get_tree().quit(1)
		return
	# 酸弹镜像（A2）：Host 周期广播，任意时刻场景里出现非权威镜像弹即通过。
	deadline = Time.get_ticks_msec() + 12000
	var mirror_seen := false
	while Time.get_ticks_msec() < deadline and not mirror_seen:
		for child: Node in get_tree().current_scene.get_children():
			if child is EnemyAcidSpit and child.get("_authoritative") == false:
				mirror_seen = true
				break
		if not mirror_seen:
			await get_tree().create_timer(0.05).timeout
	# 难度一致性（B1）：Client 预置 1、Host 固定 2 —— 进图后必须被 start_game 覆写。
	var difficulty_ok: bool = Global.selected_difficulty == 2
	if not mirror_seen or not difficulty_ok:
		printerr("[NetworkWorld] AUTO_APPEARANCE_CLIENT_FAILED mirror=%s difficulty=%d (expected 2)" % [mirror_seen, Global.selected_difficulty])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_APPEARANCE_CLIENT_COMPLETE mirror=true difficulty=2")
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


func _is_auto_safe_door_test_scene() -> bool:
	return "--net-test-safe-door" in OS.get_cmdline_user_args() and "突袭-第一关-街道" in _scene_path


func _get_auto_safe_door() -> Node2D:
	if not get_tree().current_scene:
		return null
	var door := get_tree().current_scene.find_child("SafeDoor", true, false) as Node2D
	return door if is_instance_valid(door) and door.has_method("get_network_door_key") else null


func _set_auto_test_player_position(peer_id: int, position: Vector2) -> void:
	var entry: Dictionary = _players.get(peer_id, {})
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node):
		return
	node.global_position = position
	if state:
		state.position = position
	_players[peer_id] = entry


func _run_auto_host_safe_door_test() -> void:
	## 先让 Host 单独确认。Client 保持在远处，因此绝不能触发切图。
	await get_tree().create_timer(0.75).timeout
	if not is_instance_valid(self) or _scene_transitioning or not net.is_host:
		return
	var door := _get_auto_safe_door()
	if not is_instance_valid(door):
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_SETUP_FAILED missing_door")
		return
	var host_id := int(net.my_peer_id)
	_set_auto_test_player_position(host_id, door.global_position + Vector2(-8.0, 0.0))
	request_safe_door_ready(str(door.call("get_network_door_key")))
	await get_tree().create_timer(0.30).timeout
	if _scene_transitioning:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_HOST_SOLO_FAILED transitioned=true")
		return
	print("[NetworkWorld] AUTO_SAFE_DOOR_HOST_SOLO_BLOCKED")
	## 再由 Host 把 Client 的权威实体移到门旁。全员到门后无需 Client 再确认。
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			_set_auto_test_player_position(peer_id, door.global_position + Vector2(8.0, 0.0))
	print("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_STAGED")
	await get_tree().create_timer(0.30).timeout
	# 验证此时只由 Host 再次确认也可统一切图。切图静默信号会立即发出，
	# 不能 await 后再断言，因为旧 NetworkWorld 随后会随场景释放。
	request_safe_door_ready(str(door.call("get_network_door_key")))
	if not _scene_transitioning:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_ALL_ARRIVED_FAILED transitioned=false")
		return
	print("[NetworkWorld] AUTO_SAFE_DOOR_HOST_CONFIRM_TRANSITIONED")


func _run_auto_client_safe_door_test() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_SETUP_FAILED world=false")
		return
	while is_instance_valid(self) and not _scene_transitioning and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _scene_transitioning:
		print("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_HOST_CONFIRM_TRANSITIONED")
	else:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_TRANSITION_TIMEOUT")


func _run_auto_client_input_test() -> void:
	# world_snapshot 到达时，_initial_world_received 只表示本地实体已经创建；装备字段仍可能
	# 在同帧稍后才由 Host 快照写入。等待本地状态真正拥有主武器，避免回归测试将启动时序
	# 误判为拾取/掉落物同步故障。
	var primary_weapon := await _wait_for_auto_client_primary_weapon(5000)
	if not primary_weapon:
		return
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var state := entry.get("state") as PlayerState
	var initial_ammo := state.get_magazine_ammo(primary_weapon.item_id) if state else -1
	if initial_ammo != primary_weapon.magazine_capacity:
		printerr("[NetworkWorld] AUTO_CLIENT_INITIAL_AMMO_FAILED weapon=%s ammo=%d expected=%d" % [primary_weapon.item_id, initial_ammo, primary_weapon.magazine_capacity])


	# 拾取回归只验证掉落物事务；不要先跑战斗/近战路径，避免经过相邻物品时
	# 自动拾取改变测试前置状态。
	if "--net-test-throwable-pickup" in OS.get_cmdline_user_args():
		await _run_auto_client_throwable_pickup_test()
		net.leave()
		get_tree().quit()
		return
	if "--net-test-pickup" in OS.get_cmdline_user_args():
		await _run_auto_client_pickup_test()
		net.leave()
		get_tree().quit()
		return

	Input.action_press("右")
	var animation_frames: Dictionary = {}
	for _sample: int in range(8):
		await get_tree().create_timer(0.08).timeout
		var sample_entry: Dictionary = _players.get(int(net.my_peer_id), {})
		var sample_node := sample_entry.get("node") as CharacterBody2D
		if is_instance_valid(sample_node):
			var sample_sprite := sample_node.get_node_or_null("Sprite2D") as Sprite2D
			if sample_sprite:
				animation_frames[sample_sprite.region_rect.position.x] = true
	Input.action_release("右")
	await get_tree().create_timer(0.35).timeout
	entry = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	var animation_advanced := animation_frames.size() > 1
	print("[NetworkWorld] AUTO_CLIENT_INPUT_COMPLETE pos=%s animation_advanced=%s frames=%d" % [
		node.global_position if is_instance_valid(node) else Vector2.ZERO,
		animation_advanced,
		animation_frames.size(),
	])
	if not animation_advanced:
		printerr("[NetworkWorld] AUTO_CLIENT_ANIMATION_FAILED")

	_auto_client_fire_confirmed = false
	_auto_client_bullet_seen = false
	_auto_client_bullets_seen = 0
	_auto_client_attack_weapon_id = ""
	# HOLD 武器（如冲锋枪）必须在同一次连续按住中产生多次 Host 权威攻击，
	# 不能仅验证一次按键会开火，否则会漏掉冲锋枪无法连发的回归。
	var hold_fire_test := primary_weapon.fire_mode == WeaponData.FireMode.HOLD
	var required_attack_count := 3 if hold_fire_test else 1
	var required_visual_bullets := primary_weapon.bullet_list.size() * required_attack_count
	var fire_hold_duration := 0.75 if hold_fire_test else 0.12
	Input.action_press("确定键")
	await get_tree().create_timer(fire_hold_duration).timeout
	Input.action_release("确定键")
	var deadline := Time.get_ticks_msec() + 3000
	while (
		(not _auto_client_fire_confirmed or _auto_client_bullets_seen < required_visual_bullets)
		and Time.get_ticks_msec() < deadline
	):
		await get_tree().create_timer(0.05).timeout
	entry = _players.get(int(net.my_peer_id), {})
	state = entry.get("state") as PlayerState
	var final_ammo := state.get_magazine_ammo(primary_weapon.item_id) if state else -1
	var fire_ok := (
		_auto_client_fire_confirmed
		and _auto_client_attack_weapon_id == primary_weapon.item_id
		and _auto_client_bullets_seen >= required_visual_bullets
		and final_ammo <= primary_weapon.magazine_capacity - required_attack_count
	)
	print("[NetworkWorld] AUTO_CLIENT_FIRE_COMPLETE weapon=%s hold_mode=%s confirmed=%s bullets_seen=%d required_bullets=%d ammo=%d" % [
		_auto_client_attack_weapon_id,
		hold_fire_test,
		_auto_client_fire_confirmed,
		_auto_client_bullets_seen,
		required_visual_bullets,
		final_ammo,
	])
	if not fire_ok:
		printerr("[NetworkWorld] AUTO_CLIENT_FIRE_FAILED expected_weapon=%s hold_mode=%s weapon=%s confirmed=%s bullets_seen=%d required_bullets=%d ammo=%d" % [
			primary_weapon.item_id,
			hold_fire_test,
			_auto_client_attack_weapon_id,
			_auto_client_fire_confirmed,
			_auto_client_bullets_seen,
			required_visual_bullets,
			final_ammo,
		])
	# 第二段：先通过正常的客户端输入移动到 Enemy2 的近战距离内。
	# 不传送客户端坐标，确保本回归仍覆盖「Client 输入 → Host 模拟移动 → Host 判定」完整链路。
	Input.action_press("右")
	await get_tree().create_timer(0.72).timeout
	Input.action_release("右")
	await get_tree().create_timer(0.35).timeout
	entry = _players.get(int(net.my_peer_id), {})
	node = entry.get("node") as CharacterBody2D
	print("[NetworkWorld] AUTO_CLIENT_KNIFE_POSITION pos=%s" % [node.global_position if is_instance_valid(node) else Vector2.ZERO])

	# 第三段：验证客户端只提交切换/攻击意图，而 Host 以固定副武器（小刀）确认表现与伤害。
	Input.action_press("副武器键")
	await get_tree().create_timer(0.12).timeout
	Input.action_release("副武器键")
	deadline = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		entry = _players.get(int(net.my_peer_id), {})
		state = entry.get("state") as PlayerState
		if state and state.active_weapon_slot == "secondary" and state.get_active_weapon() == NETWORK_KNIFE:
			break
		await get_tree().create_timer(0.05).timeout
	entry = _players.get(int(net.my_peer_id), {})
	state = entry.get("state") as PlayerState
	var knife_switched := state != null and state.active_weapon_slot == "secondary" and state.get_active_weapon() == NETWORK_KNIFE
	if not knife_switched:
		printerr("[NetworkWorld] AUTO_CLIENT_KNIFE_SWITCH_FAILED slot=%s" % [state.active_weapon_slot if state else "<none>"])

	# 小刀命中必须通过 Host 的物理查询和敌人权威 take_damage() 产生；客户端只通过敌人快照观察 HP 变化。
	# 按 entity_id 跟踪同一只敌人的 hp——总和分析会被 Director scatter 新刷的敌人抬高（假红）。
	var enemy_hp_map_before := _get_client_enemy_hp_map()
	var enemy_hp_before: float = _get_client_live_enemy_hp_total()
	_auto_client_fire_confirmed = false
	_auto_client_bullet_seen = false
	_auto_client_bullets_seen = 0
	_auto_client_attack_weapon_id = ""
	Input.action_press("确定键")
	await get_tree().create_timer(0.12).timeout
	Input.action_release("确定键")
	deadline = Time.get_ticks_msec() + 3000
	var melee_damage_seen := false
	var enemy_hp_after := enemy_hp_before
	while Time.get_ticks_msec() < deadline:
		enemy_hp_after = _get_client_live_enemy_hp_total()
		var hp_map_after := _get_client_enemy_hp_map()
		for enemy_key: int in enemy_hp_map_before.keys():
			if hp_map_after.has(enemy_key) and hp_map_after[enemy_key] <= float(enemy_hp_map_before[enemy_key]) - NETWORK_KNIFE.get_effective_damage() + 0.1:
				melee_damage_seen = true
				break
		if _auto_client_fire_confirmed and melee_damage_seen:
			break
		await get_tree().create_timer(0.05).timeout
	var knife_ok := knife_switched and _auto_client_fire_confirmed and _auto_client_attack_weapon_id == NETWORK_KNIFE.item_id and not _auto_client_bullet_seen and melee_damage_seen
	print("[NetworkWorld] AUTO_CLIENT_KNIFE_COMPLETE switched=%s confirmed=%s weapon=%s bullet_seen=%s melee_damage_seen=%s enemy_hp_before=%.1f enemy_hp_after=%.1f" % [
		knife_switched,
		_auto_client_fire_confirmed,
		_auto_client_attack_weapon_id,
		_auto_client_bullet_seen,
		melee_damage_seen,
		enemy_hp_before,
		enemy_hp_after,
	])
	if not knife_ok:
		printerr("[NetworkWorld] AUTO_CLIENT_KNIFE_FAILED switched=%s confirmed=%s weapon=%s bullet_seen=%s melee_damage_seen=%s enemy_hp_before=%.1f enemy_hp_after=%.1f" % [
			knife_switched,
			_auto_client_fire_confirmed,
			_auto_client_attack_weapon_id,
			_auto_client_bullet_seen,
			melee_damage_seen,
			enemy_hp_before,
			enemy_hp_after,
		])
	net.leave()
	get_tree().quit()

## 等待可靠 world_snapshot 已把 Host 权威主武器写入本地 PlayerState。
## --net-test-weapon 指定时仍校验它，未指定时则直接使用 Host 已同步的 primary 装备，
## 使测试不会依赖客户端本地命令行去猜测 Host 的初始配置。
func _wait_for_auto_client_primary_weapon(timeout_msec: int) -> WeaponData:
	var deadline := Time.get_ticks_msec() + timeout_msec
	var expected_weapon := _get_network_primary_loadout_weapon()
	while Time.get_ticks_msec() < deadline:
		if _initial_world_received:
			var entry: Dictionary = _players.get(int(net.my_peer_id), {})
			var state := entry.get("state") as PlayerState
			var primary := state.get_equipped_weapon("primary") if state else null
			if primary and (not expected_weapon or primary.item_id == expected_weapon.item_id):
				return primary
		await get_tree().create_timer(0.05).timeout
	var expected_id := expected_weapon.item_id if expected_weapon else "<host-snapshot-primary>"
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var state := entry.get("state") as PlayerState
	var actual := state.get_equipped_weapon("primary") if state else null
	printerr("[NetworkWorld] AUTO_CLIENT_PRIMARY_WEAPON_TIMEOUT expected=%s actual=%s world=%s" % [
		expected_id,
		actual.item_id if actual else "<none>",
		_initial_world_received,
	])
	return null


## 回归 Client 按住确认键拾取武器：Host 替换装备、删除源掉落物、生成旧武器掉落物，再由可靠快照回写客户端。
func _run_auto_client_pickup_test() -> void:
	var primary_weapon := await _wait_for_auto_client_primary_weapon(5000)
	if not primary_weapon:
		return
	var deadline := Time.get_ticks_msec() + 5000
	var source := _find_client_pickup_by_weapon_id(NETWORK_PISTOL.item_id)
	while not is_instance_valid(source) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		source = _find_client_pickup_by_weapon_id(NETWORK_PISTOL.item_id)
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(source) or not is_instance_valid(node) or not state:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_SETUP_FAILED source=%s node=%s state=%s primary=%s" % [is_instance_valid(source), is_instance_valid(node), state != null, primary_weapon.item_id])
		return
	var target_weapon := NETWORK_PISTOL
	var target_slot := target_weapon.get_slot_key()
	var old_weapon := state.get_equipped_weapon(target_slot)
	if not old_weapon or old_weapon.item_id == target_weapon.item_id:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_SETUP_FAILED slot=%s old_weapon=%s" % [target_slot, old_weapon.item_id if old_weapon else "<none>"])
		return
	# 先用正常客户端输入移动到测试图里的手枪范围内，使 Host 仍会执行距离校验。
	# 随后按确定的 network_pickup_id 精确提交一次请求：测试图内相邻的多个掉落物都会监听同一个“确定键”，
	# 长按自动化有概率先命中路过的另一个物品，导致回归用例误报；正式的按住交互仍由 weapon_pickup.gd 覆盖。
	var travel_delta := source.global_position - node.global_position
	var move_action := "右" if absf(travel_delta.x) >= absf(travel_delta.y) and travel_delta.x > 0.0 else "左"
	if absf(travel_delta.y) > absf(travel_delta.x):
		move_action = "下" if travel_delta.y > 0.0 else "上"
	Input.action_press(move_action)
	deadline = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and node.global_position.distance_to(source.global_position) > 18.0:
		await get_tree().create_timer(0.05).timeout
	Input.action_release(move_action)
	await get_tree().create_timer(0.08).timeout
	var in_range := node.global_position.distance_to(source.global_position) <= 28.0
	if not in_range:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_MOVE_FAILED player=%s source=%s" % [node.global_position, source.global_position])
		return
	request_pickup(source.network_pickup_id)
	deadline = Time.get_ticks_msec() + 3000
	var primary_swapped := false
	var dropped_old_seen := false
	while Time.get_ticks_msec() < deadline:
		entry = _players.get(int(net.my_peer_id), {})
		state = entry.get("state") as PlayerState
		primary_swapped = state != null and state.get_equipped_weapon(target_slot) == target_weapon
		dropped_old_seen = _has_client_pickup_weapon_near(old_weapon.item_id, node.global_position, 64.0)
		if primary_swapped and dropped_old_seen:
			break
		await get_tree().create_timer(0.05).timeout
	print("[NetworkWorld] AUTO_CLIENT_PICKUP_COMPLETE slot=%s old=%s equipped=%s swapped=%s dropped_old_seen=%s pickups=%d" % [
		target_slot,
		old_weapon.item_id,
		state.get_equipped_weapon(target_slot).item_id if state and state.get_equipped_weapon(target_slot) else "<none>",
		primary_swapped,
		dropped_old_seen,
		_pickups.size(),
	])
	if not primary_swapped or not dropped_old_seen:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_FAILED slot=%s old=%s swapped=%s dropped_old_seen=%s" % [target_slot, old_weapon.item_id, primary_swapped, dropped_old_seen])



## 回归 Client 拾取投掷物：客户端节点必须可提交请求，Host 再权威写入 throwable 并删除掉落物。
func _run_auto_client_throwable_pickup_test() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	## 安全屋开局随机掉落表的投掷物是混合概率（grenade/molotov/flash 只会刷出其一或都不出），
	## 用例若只找手雷会随掉落随机性摆烂（2026-09-18 连续两轮 SETUP_FAILED，Host 该局刷的是
	## 燃烧瓶）——泛化为「任一白名单投掷物掉落」，消除 setup 的运气依赖。
	var td: ThrowableData = null
	var source: Node2D = null
	## 09-22：random_pickup 在联机 Client 侧已禁用本地随机刷（两端各自 roll 不同步），
	## 投掷物源改由 Host 下发 —— 既可能是安全屋预摆掉落的快照，也可能是 Host
	## 收编扫描（≤0.5s）补发的动态掉落物。因此这里必须**轮询等待**而不是一次性查找。
	deadline = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		for throwable_id: String in NETWORK_THROWABLES.keys():
			source = _find_client_pickup_by_throwable_id(throwable_id)
			if is_instance_valid(source):
				td = NETWORK_THROWABLES[throwable_id] as ThrowableData
				break
		if is_instance_valid(source) and td != null:
			break
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(node) or not is_instance_valid(source) or td == null:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_SETUP_FAILED player=%s source=%s td=%s" % [is_instance_valid(node), is_instance_valid(source), td != null])
		return
	var source_id := int(source.get("network_pickup_id"))
	var source_position := source.global_position
	var request_enabled := source_id > 0 and not bool(source.get("network_presentation_only"))
	if not request_enabled:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_REQUEST_DISABLED pickup=%d presentation_only=%s" % [source_id, source.get("network_presentation_only")])
		return
	# 通过生产输入移动，让 Host 的距离校验覆盖真实 Client -> Host 路径。
	var travel_delta := source_position - node.global_position
	if absf(travel_delta.x) > 8.0:
		Input.action_press("右" if travel_delta.x > 0.0 else "左")
		deadline = Time.get_ticks_msec() + 5000
		while Time.get_ticks_msec() < deadline and absf(source_position.x - node.global_position.x) > 16.0:
			await get_tree().create_timer(0.05).timeout
		Input.action_release("右" if travel_delta.x > 0.0 else "左")
	travel_delta = source_position - node.global_position
	if absf(travel_delta.y) > 8.0:
		Input.action_press("下" if travel_delta.y > 0.0 else "上")
		deadline = Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < deadline and absf(source_position.y - node.global_position.y) > 16.0:
			await get_tree().create_timer(0.05).timeout
		Input.action_release("下" if travel_delta.y > 0.0 else "上")
	await get_tree().create_timer(0.08).timeout
	var in_range := node.global_position.distance_to(source_position) <= 28.0
	if not in_range:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_MOVE_FAILED player=%s source=%s" % [node.global_position, source_position])
		return
	# 进入范围时 HealingPickup 可能已通过生产逻辑自动提交请求；仍在场时再显式提交一次，
	# 覆盖 request_pickup() 路径但避免访问已释放的源节点。
	if _pickups.has(source_id):
		request_pickup(source_id)
	deadline = Time.get_ticks_msec() + 3000
	var acquired := false
	var removed := false
	while Time.get_ticks_msec() < deadline:
		entry = _players.get(int(net.my_peer_id), {})
		var state := entry.get("state") as PlayerState
		acquired = state != null and state.throwable == td
		removed = not _pickups.has(source_id)
		if acquired and removed:
			break
		await get_tree().create_timer(0.05).timeout
	print("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_COMPLETE pickup=%d acquired=%s removed=%s" % [source_id, acquired, removed])
	if not acquired or not removed:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_FAILED pickup=%d acquired=%s removed=%s" % [source_id, acquired, removed])


## ⚠ 掉落物查找助手必须**先判 is_instance_valid(value) 再 as Node2D**：
## 对已释放对象做 `as Node2D` 会抛 "Trying to cast a freed object" 运行时错，
## 静默中止整个查找函数（2026-09-22 实测：Client 端 _pickups 残留已 queue_free
## 条目 → 查找恒返回 null → 投掷物拾取用例 SETUP_FAILED）。
func _find_client_pickup_by_throwable_id(item_id: String) -> Node2D:
	for value: Variant in _pickups.values():
		if not is_instance_valid(value):
			continue
		var pickup := value as Node2D
		if not is_instance_valid(pickup):
			continue
		var throwable := pickup.get("item") as ThrowableData
		if throwable and throwable.item_id == item_id:
			return pickup
	return null


func _find_client_pickup_by_weapon_id(weapon_id: String) -> Node2D:
	for value: Variant in _pickups.values():
		if not is_instance_valid(value):
			continue
		var pickup := value as Node2D
		if not is_instance_valid(pickup):
			continue
		var weapon := pickup.get("weapon_data") as WeaponData
		if weapon and weapon.item_id == weapon_id:
			return pickup
	return null


func _has_client_pickup_weapon_near(weapon_id: String, position: Vector2, max_distance: float) -> bool:
	for value: Variant in _pickups.values():
		if not is_instance_valid(value):
			continue
		var pickup := value as Node2D
		if not is_instance_valid(pickup):
			continue
		var weapon := pickup.get("weapon_data") as WeaponData
		if weapon and weapon.item_id == weapon_id and pickup.global_position.distance_to(position) <= max_distance:
			return true
	return false


## 自动双端烟测只从客户端已接收的 Host 敌人快照累计生命值；不读取或伪造 Host 命中结果。
## --net-test harness 专用：把玩家 HP 压到 1 再吃致死伤。
## ガッツ（HP≥2 保底 1 HP，player.gd）会拦下 harness 的 max_hp+1 致死伤
## （2026-09 加的机制没同步测试，features/downed-wipe 双双 setup 失败）。
## 压 HP=1 后 take_damage 链路原样保留（信号/倒地登记不变），只绕开保底语义。
func _force_auto_test_player_low_hp(node: CharacterBody2D) -> void:
	var state := Players.get_state_for_entity(node)
	if state:
		state.current_hp = 1.0
	node.current_hp = 1.0


## --net-test harness 专用：Client 视角各活敌的 hp 快照（entity_id → hp）。
## 判定近战伤害必须跟踪**同一只**敌人——Director 持续 scatter 刷新敌人，
## 用 hp 总和比较会被新入场敌人抬高（weapon 场景 140→280 假红的根因）。
func _get_client_enemy_hp_map() -> Dictionary:
	var map := {}
	for key: Variant in _enemies.keys():
		var enemy := _resolve_enemy_entry(_enemies[key])
		if is_instance_valid(enemy) and not enemy.is_network_dead():
			map[int(key)] = enemy.current_hp
	return map


func _get_client_live_enemy_hp_total() -> float:
	var total := 0.0
	for enemy_entry: Dictionary in _enemies.values():
		var enemy := _resolve_enemy_entry(enemy_entry)
		if is_instance_valid(enemy) and not enemy.is_network_dead():
			total += enemy.current_hp
	return total


# ---------------------------------------------------------------- State serialisation / scene helpers

# ---------------------------------------------------------------- Enemy state serialisation / scene helpers

func _register_initial_host_enemies() -> void:
	_enemies.clear()
	_next_enemy_id = 1
	var candidates: Array[CharacterBody2D] = []
	for value: Node in get_tree().get_nodes_in_group("enemy"):
		if value is CharacterBody2D:
			candidates.append(value as CharacterBody2D)
	var scene := get_tree().current_scene
	candidates.sort_custom(func(a: CharacterBody2D, b: CharacterBody2D) -> bool:
		var path_a := str(scene.get_path_to(a)) if scene else str(a.get_path())
		var path_b := str(scene.get_path_to(b)) if scene else str(b.get_path())
		return path_a < path_b
	)
	for enemy: CharacterBody2D in candidates:
		var entity_id := _next_enemy_id
		_next_enemy_id += 1
		var scene_path := str(scene.get_path_to(enemy)) if scene else ""
		enemy.configure_network_entity(entity_id, false)
		_enemies[entity_id] = {"node_id": enemy.get_instance_id(), "scene_path": scene_path}
		_connect_host_enemy_damage_signal(entity_id, enemy)
	print("[NetworkWorld] HOST_ENEMIES_REGISTERED count=%d" % _enemies.size())


func _register_untracked_host_enemies() -> void:
	## Director 可以在地图运行后动态生成感染者。新节点进入 enemy group 后在此被 Host 收编。
	if not net.is_host:
		return
	_prune_invalid_host_enemies()
	var tracked_nodes: Dictionary = {}
	for entry_value: Variant in _enemies.values():
		var tracked := _resolve_enemy_entry(entry_value as Dictionary)
		if tracked:
			tracked_nodes[tracked.get_instance_id()] = true
	var scene := get_tree().current_scene
	for value: Node in get_tree().get_nodes_in_group("enemy"):
		var enemy := value as CharacterBody2D
		if not is_instance_valid(enemy) or tracked_nodes.has(enemy.get_instance_id()):
			continue
		var entity_id := _next_enemy_id
		_next_enemy_id += 1
		var scene_path := str(scene.get_path_to(enemy)) if scene else ""
		enemy.configure_network_entity(entity_id, false)
		_enemies[entity_id] = {"node_id": enemy.get_instance_id(), "scene_path": scene_path}
		_connect_host_enemy_damage_signal(entity_id, enemy)
		var public_state := _public_enemy_state(entity_id)
		var ready_client_count := 0
		for peer_id: int in net.get_peer_ids():
			# 只向已完成本场景 world_snapshot 的 Client 发场景节点 RPC，
			# 避免 Client 尚在切图时出现 "NetworkWorld not found" 在途包错误。
			if peer_id > 1 and _players.has(peer_id):
				spawn_network_enemy.rpc_id(peer_id, public_state)
				ready_client_count += 1
		print("[NetworkWorld] HOST_ENEMY_REGISTERED id=%d path=%s clients=%d" % [entity_id, scene_path, ready_client_count])

func _prepare_client_preplaced_enemies() -> void:
	for value: Node in get_tree().get_nodes_in_group("enemy"):
		if value is CharacterBody2D:
			(value as CharacterBody2D).configure_network_entity(0, true)


func _build_enemy_snapshot(compact: bool = false) -> Array:
	if compact:
		_prune_invalid_host_enemies()
	var states: Array = []
	for key: Variant in _enemies.keys():
		var entity_id := int(key)
		var public_state := _public_enemy_state(entity_id)
		if public_state.is_empty():
			continue
		if compact and bool(public_state.get("dead", false)):
			continue
		if compact:
			# 高频 ENet 包：只发送客户端表现必需的数据；场景路径只在可靠 world_snapshot 中发送。
			states.append([
				entity_id,
				public_state["position"],
				public_state["facing"],
				public_state["hp"],
				public_state["moving"],
				public_state["visual_char_index"],
				public_state["dead"],
				public_state["headshot"],
				public_state["element_state"],  # P0-B3：元素染色 3bit（炎/氷/雷）
			])
		else:
			states.append(public_state)
	if compact:
		states.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	else:
		states.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["entity_id"]) < int(b["entity_id"]))
	return states


func _public_enemy_state(entity_id: int) -> Dictionary:
	if not _enemies.has(entity_id):
		return {}
	var entry: Dictionary = _enemies[entity_id]
	var enemy := _resolve_enemy_entry(entry)
	if not enemy:
		return {}
	return {
		"entity_id": entity_id,
		"scene_path": str(entry.get("scene_path", "")),
		"position": enemy.global_position,
		"facing": enemy.get_network_facing(),
		"hp": enemy.current_hp,
		"moving": enemy.is_moving_for_network(),
		"ai_state": enemy.get_network_ai_state(),
		"visual_char_index": enemy.get_network_visual_char_index(),
		"dead": enemy.is_network_dead(),
		"headshot": enemy.is_network_headshot_dead(),
		"element_state": enemy.get_network_element_state(),  # P0-B3
		# A1 特感复制：非特感为空串；Client 只在可靠通道（spawn RPC / world_snapshot）
		# 建实体时消费本字段，紧凑快照不带（_normalize_enemy_snapshot 会剥掉）。
		"special_id": enemy.get_network_special_id(),
		# A5 僵尸变体：同 special_id 语义，普通丧尸的差异化行走图靠它重建；
		# 狂暴换皮不在此 —— 随 element_state bit3 实时同步。
		"variant_id": enemy.get_network_variant_id(),
	}


func _prune_invalid_host_enemies() -> void:
	if not net.is_host:
		return
	for key: Variant in _enemies.keys():
		var entry: Dictionary = _enemies[key]
		if not _resolve_enemy_entry(entry):
			_enemies.erase(key)


func _resolve_enemy_entry(entry: Dictionary) -> CharacterBody2D:
	var enemy_id := int(entry.get("node_id", 0))
	if enemy_id <= 0:
		return null
	var enemy_value: Object = instance_from_id(enemy_id)
	if not is_instance_valid(enemy_value) or not enemy_value is CharacterBody2D:
		return null
	return enemy_value as CharacterBody2D


## 已被认领的敌人镜像（instance_id → entity_id）。★ 一个节点只能被一个 entity_id
## 认领；否则后写的一方会覆盖前者的位置/血量/动作（错乱家族）。
func _claimed_enemy_nodes() -> Dictionary:
	var claimed: Dictionary = {}
	for key: Variant in _enemies.keys():
		var entry_value: Variant = _enemies[key]
		var node := _resolve_enemy_entry(entry_value as Dictionary) if entry_value is Dictionary else null
		if is_instance_valid(node):
			claimed[node.get_instance_id()] = int(key)
	return claimed


## 候选敌人节点若已被**别的** entity_id 认领则作废（返回 null，调用方转而新建镜像）。
func _reject_claimed_enemy(candidate: CharacterBody2D, entity_id: int, claimed: Dictionary) -> CharacterBody2D:
	if not is_instance_valid(candidate):
		return null
	var owner_id: int = int(claimed.get(candidate.get_instance_id(), 0))
	if owner_id != 0 and owner_id != entity_id:
		return null
	return candidate


func _build_snapshot() -> Array:
	var states: Array = []
	for key: Variant in _players.keys():
		states.append(_public_state(int(key)))
	states.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["peer_id"]) < int(b["peer_id"]))
	return states


func _build_compact_player_snapshot() -> Array:
	var states: Array = []
	for key: Variant in _players.keys():
		var state := _public_state(int(key))
		states.append([
			state["peer_id"], state["name"], state["character_path"], state["hp"], state["position"],
			state["facing"], state["moving"], state["walking"], state["weapon_id"],
			state["primary_weapon_id"], state["secondary_weapon_id"], state["active_weapon_slot"],
			state["weapon_magazines"], state["weapon_raised"], state["weapon_transition"],
			state["throwable_id"], state["throwable_held"], state["throwable_aiming"],
			state["throw_range"], state["dead"], state["magazine_ammo"],
			# 倒地扩展字段（尾部追加；_normalize_player_snapshot 对旧长度包向后兼容）。
			state["downed"], state["bleed_ratio"], state["revive_progress"],
			state["facing_locked"], state["locked_facing"],
			# D2 备弹同步（尾部追加）：ammo_item_id → count。
			state["ammo_counts"],
		])
	states.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	return states


func _public_state(peer_id: int) -> Dictionary:
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var weapon: WeaponData = state.get_active_weapon() if state else null
	return {
		"peer_id": peer_id,
		"name": net.get_player_name(peer_id),
		"character_path": state.character_path if state else "",
		"hp": state.current_hp if state else node.current_hp,
		"position": node.global_position,
		"facing": node.facing,
		"moving": bool(entry.get("moving", false)),
		"walking": bool(entry.get("walking", false)),
		"weapon_id": weapon.item_id if weapon else "",
		"primary_weapon_id": _weapon_id_for_slot(state, "primary"),
		"secondary_weapon_id": _weapon_id_for_slot(state, "secondary"),
		"active_weapon_slot": state.active_weapon_slot if state else "primary",
		"weapon_magazines": state.weapon_magazines.duplicate() if state else {},
		"weapon_raised": node.is_weapon_mode_active() if is_instance_valid(node) else false,
		"weapon_transition": str(_weapon_transition_state.get(peer_id, "")),
		"throwable_id": state.throwable.item_id if state and state.throwable else "",
		"throwable_held": bool(_get_host_throwable_state(peer_id).get("held", false)),
		"throwable_aiming": bool(_get_host_throwable_state(peer_id).get("aiming", false)),
		"throw_range": int(_get_host_throwable_state(peer_id).get("range", 3)),
		"dead": node.is_network_dead() if is_instance_valid(node) else true,
		"magazine_ammo": state.get_magazine_ammo(weapon.item_id) if state and weapon else 0,
		# 倒地扩展字段（追加在尾部，旧字段顺序保持不变）：
		# downed = 可救援的倒地状态；bleed_ratio = 流血池剩余比（未倒地为 -1）；
		# revive_progress = 被救援进度（0 表示当前无人施救）。
		"downed": bool(entry.get("downed", false)),
		"bleed_ratio": (float(entry.get("downed_hp", 0.0)) / DOWNED_BLEED_HP) if bool(entry.get("downed", false)) else -1.0,
		"revive_progress": _get_host_revive_progress_for(peer_id),
		"facing_locked": node.is_facing_locked() if is_instance_valid(node) else false,
		"locked_facing": node.get_locked_facing() if is_instance_valid(node) else -1,
		# D2 备弹同步（尾部追加）：两槽武器对应的弹药库存计数（ammo_item_id → count）。
		# 备弹此前从不同步 → Client HUD 备弹恒 0、与 Host 域脱钩。
		"ammo_counts": _ammo_counts_for(state),
	}


func _ammo_counts_for(state: PlayerState) -> Dictionary:
	var counts: Dictionary = {}
	if not state:
		return counts
	for slot: String in ["primary", "secondary"]:
		var wd: WeaponData = state.equipment.get(slot) as WeaponData
		if wd and not wd.ammo_item_id.is_empty():
			counts[wd.ammo_item_id] = state.count_ammo_item(wd.ammo_item_id)
	return counts


func _weapon_id_for_slot(state: PlayerState, slot: String) -> String:
	var wd: WeaponData = state.get_equipped_weapon(slot) if state else null
	return wd.item_id if wd else ""


## Net 每次 host/join 会清空 session cache；把角色选择/上一场景的本地座位接管回来，
## 避免联机开始或切图时重新创建默认的手枪+小刀状态。
func _claim_local_network_state() -> void:
	if not net or not net.has_method("get_session_player_state"):
		return
	var local_id := int(net.my_peer_id)
	if local_id <= 0 or net.get_session_player_state(local_id):
		return
	## 大厅已有权威选择时，不接管单人模式留下的活动座位；首次进图应按大厅角色创建。
	if net.has_method("get_player_character_path") and not str(net.get_player_character_path(local_id)).is_empty():
		return
	var state := Players.claim_active_seat_for_peer(local_id)
	if state and net.has_method("set_session_player_state"):
		net.set_session_player_state(local_id, state)


## 根据权威 peer 列表收敛座位，并重建实体到座位的映射。
func _reconcile_network_seats(peer_ids: Array[int]) -> void:
	var states_by_peer: Dictionary = {}
	for peer_id: int in peer_ids:
		var entry: Dictionary = _players.get(peer_id, {})
		var state := entry.get("state") as PlayerState
		if state:
			states_by_peer[peer_id] = state
	Players.clear_entity_bindings()
	Players.rebuild_network_seats(peer_ids, states_by_peer)
	for peer_id: int in peer_ids:
		if not _players.has(peer_id):
			continue
		var entry: Dictionary = _players[peer_id]
		var node := entry.get("node") as Node2D
		var seat_index := Players.find_seat_by_owner_peer_id(peer_id)
		if is_instance_valid(node) and seat_index >= 0:
			Players.register_entity(node, seat_index)
			_attach_player_nameplate(node as CharacterBody2D, peer_id, seat_index)
			if peer_id == int(net.my_peer_id):
				_set_local_player(node, seat_index)
	var owners: Array[int] = []
	for seat_index: int in range(Players.seat_count()):
		var state := Players.get_seat(seat_index)
		if state:
			owners.append(state.owner_peer_id)
	print("[NetworkWorld] NETWORK_SEATS expected=%d actual=%d owners=%s" % [peer_ids.size(), Players.seat_count(), str(owners)])


## 给联机玩家挂头顶名牌（座位编号 + 昵称 + 正式 HUD 血条）。
## Host 与 Client 走同一入口；幂等 —— 已挂载时只刷新文字（座位重排后编号会变）。
func _attach_player_nameplate(node: CharacterBody2D, peer_id: int, seat_index: int) -> void:
	if not is_instance_valid(node):
		return
	var plate := node.get_node_or_null("NetworkNameplate") as Node2D
	if not plate:
		plate = Node2D.new()
		plate.name = "NetworkNameplate"
		plate.set_script(NAMEPLATE_SCRIPT)
		node.add_child(plate)
	plate.call("set_nameplate_info", seat_index, net.get_player_name(peer_id))


func _find_or_create_player_state(peer_id: int, character_path: String, hp: float) -> PlayerState:
	## 角色表仅由大厅 Host 写入；进图时优先采用这份权威选择，避免回退为默认大雄。
	var resolved_character_path: String = character_path
	if resolved_character_path.is_empty() and net and net.has_method("get_player_character_path"):
		resolved_character_path = str(net.get_player_character_path(peer_id))
	var state: PlayerState = net.get_session_player_state(peer_id) if net and net.has_method("get_session_player_state") else null
	if not state:
		for index: int in range(Players.seat_count()):
			var candidate := Players.get_seat(index)
			if candidate and candidate.owner_peer_id == peer_id:
				state = candidate
				break
	if not state:
		state = _make_player_state(resolved_character_path, hp)
		state.owner_peer_id = peer_id
	if net and net.has_method("set_session_player_state"):
		net.set_session_player_state(peer_id, state)
	return state


func _ensure_player_state_seat(state: PlayerState) -> int:
	for index: int in range(Players.seat_count()):
		if Players.get_seat(index) == state:
			state.seat_index = index
			return index
	if state.owner_peer_id > 0:
		var owned_index := Players.find_seat_by_owner_peer_id(state.owner_peer_id)
		if owned_index >= 0:
			Players.replace_seat(owned_index, state)
			return owned_index
	return Players.add_seat(state)


func _make_player_state(character_path: String, hp: float) -> PlayerState:
	var path := character_path if not character_path.is_empty() else Players.DEFAULT_CHARACTER_PATH
	var character := _load_character(path)
	var state := PlayerState.new()
	state.init_from_character(character, path)
	state.current_hp = hp if hp > 0.0 else state.get_max_hp()
	return state


func _load_character(path: String) -> CharacterData:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var resource := load(path)
	if resource is CharacterData:
		return (resource as CharacterData).duplicate() as CharacterData
	return null


func _packet_position(packet: Dictionary) -> Vector2:
	var position_value: Variant = packet.get("position", Vector2.ZERO)
	if position_value is Vector2:
		return position_value as Vector2
	if position_value is Dictionary:
		var dict := position_value as Dictionary
		return Vector2(float(dict.get("x", 0.0)), float(dict.get("y", 0.0)))
	return Vector2.ZERO


func _apply_arrival_to_preplaced_player(player: CharacterBody2D) -> void:
	if not is_instance_valid(player):
		return
	var arrival_id: String = str(net.active_arrival_id)
	var arrival_position: Variant = ArrivalResolver.resolve(
		get_tree().current_scene, arrival_id, net.active_arrival_position
	)
	if not arrival_position is Vector2:
		return
	player.global_position = arrival_position as Vector2
	print("[NetworkWorld] 已应用入口 ID=%s position=%s" % [arrival_id, player.global_position])


func _find_players_parent() -> Node:
	var preplaced := _find_preplaced_player()
	return preplaced.get_parent() if is_instance_valid(preplaced) else null


func _find_preplaced_player() -> CharacterBody2D:
	var scene := get_tree().current_scene
	if not scene:
		return null
	for node: Node in scene.get_tree().get_nodes_in_group("player"):
		if node is CharacterBody2D:
			return node as CharacterBody2D
	return null


func _instantiate_player(position: Vector2, peer_id: int = 0) -> CharacterBody2D:
	var node := PLAYER_SCENE.instantiate() as CharacterBody2D
	# Player._ready() 会在 add_child() 时执行，必须预先关闭单机状态机和自动座位注册。
	if peer_id > 0:
		node.configure_network_entity(peer_id, peer_id)
	node.global_position = position
	_players_parent.add_child(node)
	return node


func _spawn_position(index: int) -> Vector2:
	var anchor := _find_preplaced_player()
	var origin := anchor.global_position if is_instance_valid(anchor) else Vector2.ZERO
	return origin + Vector2(SPAWN_SEPARATION * index, 0.0)


func _set_local_player(node: Node2D, seat_index: int) -> void:
	Players.active_seat_index = seat_index
	Players.set_local_entity(node)
	if _camera_bound_local_node == node:
		return
	var camera := get_tree().current_scene.find_child("Camera2D", true, false)
	if camera and camera.has_method("set_follow_target"):
		camera.set_follow_target(node)
	_camera_bound_local_node = node


# ---------------------------------------------------------------- 剧情机关 flag 同步（Host 权威）

## 玩法节点统一入口：单机/Host 立即生效并广播；Client 转交 Host 复核。
## 返回 true = 本次调用已本地生效；false = 已提交请求，等 Host 回包。
func submit_quest_flag(flag_name: String, value: bool = true) -> bool:
	if flag_name.is_empty():
		return false
	if not net.is_online_session():
		Global.apply_quest_flag(flag_name, value)
		return true
	if net.is_host:
		# call_local：Host 本地与 Client 一次性同步生效
		apply_quest_flag_rpc.rpc(flag_name, value)
		return true
	quest_flag_request.rpc_id(1, flag_name, value)
	return false


@rpc("any_peer", "call_remote", "reliable")
func quest_flag_request(flag_name: String, value: bool) -> void:
	## Client → Host 的 flag 请求。LAN 合作场景，与拾取请求同级信任，不再二次校验。
	if not net.is_host:
		return
	apply_quest_flag_rpc.rpc(flag_name, value)


@rpc("authority", "call_local", "reliable")
func apply_quest_flag_rpc(flag_name: String, value: bool) -> void:
	Global.apply_quest_flag(flag_name, value)


# ---------------------------------------------------------------- 关键道具拾取点（Host 权威事务）

## 关键道具拾取点统一入口：单机/Host 直接走节点上的 host_commit_pickup；
## Client 提交请求，由 Host 校验距离与状态后代为结算。
func request_quest_pickup(node_path: NodePath) -> void:
	if net.is_host:
		_try_host_quest_pickup(int(net.my_peer_id), node_path)
	else:
		quest_pickup_request.rpc_id(1, node_path)


@rpc("any_peer", "call_remote", "reliable")
func quest_pickup_request(node_path: NodePath) -> void:
	if not net.is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 1:
		_try_host_quest_pickup(sender, node_path)


func _try_host_quest_pickup(peer_id: int, node_path: NodePath) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var scene := get_tree().current_scene
	var pickup := (scene.get_node_or_null(node_path) if scene else null) as Node2D
	if not is_instance_valid(pickup) or not pickup.has_method("host_commit_pickup"):
		return
	var entry: Dictionary = _players[peer_id]
	var player := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(player) or player.global_position.distance_to(pickup.global_position) > 96.0:
		print("[NetworkWorld] QUEST_PICKUP 拒绝: peer=%d 距离过远 path=%s" % [peer_id, node_path])
		return
	pickup.call("host_commit_pickup", state)


## ── 爆破墙放置炸药请求（Client → Host；距离/资格由墙内 host_commit_place 校验）──
func request_wall_place(node_path: NodePath) -> void:
	if net.is_host:
		_try_host_wall_place(int(net.my_peer_id), node_path)
	else:
		wall_place_request.rpc_id(1, node_path)


@rpc("any_peer", "call_remote", "reliable")
func wall_place_request(node_path: NodePath) -> void:
	if not net.is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 1:
		_try_host_wall_place(sender, node_path)


func _try_host_wall_place(peer_id: int, node_path: NodePath) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var scene := get_tree().current_scene
	var wall := (scene.get_node_or_null(node_path) if scene else null) as Node2D
	if not is_instance_valid(wall) or not wall.has_method("host_commit_place"):
		return
	var entry: Dictionary = _players[peer_id]
	var player := entry.get("node") as CharacterBody2D
	if not is_instance_valid(player):
		return
	## 不在这里做距离校验：墙的层原点可能在地图角落，最近格距离由墙自己算
	wall.call("host_commit_place", player)
