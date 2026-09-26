class_name DirectorConfig extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：配置（Node）
## 联机：仅单机/Host 生效
## 职责：关卡级导演参数覆盖：放在场景中即可为该地图单独配置生成与节奏参数。
## 依赖：被 Director 在场景切换后读取

## 导演系统参数覆盖 — 放置在关卡场景中即可独立配置该地图的生成参数
##
## Director autoload 检测到场景切换后，自动从此节点读取参数
## 不放置则使用 Director 子模块的默认值

@export_group("启用")
@export var spawn_enabled: bool = true           ## 该地图是否启用敌人生成（关掉后完全不刷怪，适合安全屋/对话场景）

## 章节总结章名（2026-09-16 用户需求）：本图的章节名（如"第四章 · 列车台"）。
## 章节总结节点（chapter_title 留空时）与 ED 前结算页都从这里取；
## 取值链：总结节点场景值 > 本字段 > 兜底默认。
@export var chapter_title: String = ""

@export_group("节奏 — Build-up（压力爬升）")
@export var build_min: float = 36.0              ## 压力爬升阶段最短持续秒数。这个阶段每15~30s生成1~3个散兵，给玩家"敌人越来越多"的感觉
@export var build_max: float = 108.0             ## 压力爬升阶段最长持续秒数。超过这个时间自动进入尸潮，即使玩家状态很好

@export_group("节奏 — Peak（尸潮爆发）")
@export var peak_timeout: float = 60.0           ## 尸潮最多持续秒数。超时后即使还有活着的敌人也强制结束，防止玩家卡关
@export var peak_intensity_threshold: float = 0.7  ## 紧张度触发线（0.0~1.0）。爬升阶段紧张度超过此值立即进入尸潮，无视时间。设1.0=靠时间触发，设0.5=玩家残血或没子弹马上尸潮

@export_group("节奏 — Cooldown（喘息）")
@export var cooldown_min: float = 0.0            ## 尸潮结束后最短喘息秒数。这期间不生成敌人，让玩家捡东西、推图、回状态。地图小就设短些
@export var cooldown_max: float = 10.0           ## 喘息阶段最长秒数。超过这个时间自动进入下一轮爬升。设0=喘息结束立刻开始下一轮
@export var cooldown_intensity_threshold: float = 0.3  ## 提前结束喘息的紧张度触发线。玩家在喘息期主动撞怪→紧张度升高→提前结束喘息进入爬升

@export_group("生成 — 散兵（爬升阶段零星敌人）")
@export var scatter_min: int = 2                 ## 每次生成散兵的最少个数。爬升阶段定时触发，紧张度低时取此值
@export var scatter_max: int = 5                 ## 每次生成散兵的最多个数。紧张度越高越接近此值
## ⚠ 2026-09-26 用户实测「普通刷怪频率太快，保持击杀节奏可以无限刷下去」：
## 旧的 1.0s 就是"一秒左右又来几只"的直接来源（散兵是普通补位的主供怪路径）。
## 现在收到 4.0s：站着对枪时不再连绵不断，但也不会长时间空场。
@export var scatter_interval_min: float = 4.0   ## 两次散兵生成之间最少隔几秒。设短=敌人连绵不断，设长=玩家有大段空闲
@export var scatter_interval_max: float = 10.0  ## 两次散兵生成之间最多隔几秒。实际间隔在此范围内随机，避免节奏感太机械

@export_group("生成 — 尸潮（Peak 阶段大量敌人）")
@export var horde_total_min: int = 5            ## 一波尸潮最少一共出几个敌人。实际数量在此范围内随机
@export var horde_total_max: int = 25            ## 一波尸潮最多一共出几个敌人。地图大可以多设，地图小设少点
@export var horde_batch_size: int = 8            ## 尸潮每批同时生成几个。不会一次性刷出全部，而是分批来，模拟"从四面八方涌来"的感觉（2026-09-17：5→8）
@export var horde_batch_interval: float = 5.0    ## 尸潮批次之间的基础间隔秒数。设短=连续涌出，设长=一波一波有节奏（2026-09-17：3→5，慢刷）

@export_group("附近闸")
## 附近（半径内）存活敌人达到该数量且玩家静止 → 暂停普通补位与散兵/事件批，
## 玩家开始移动立即恢复。防守战不受此闸影响。0 = 关闭。（2026-09-17 用户需求）
@export var nearby_gate_count: int = 10
## 附近闸判定半径（px，以玩家为圆心）。
@export var nearby_gate_radius: float = 600.0

@export_group("生成 — 前方屏外定点刷怪（FrontSpawner）")
## 是否启用"前方屏外定点刷怪"。这是当前默认的补怪方式：
## 敌人只出现在玩家**前方**（按移动方向 ±front_half_angle 的扇区）、**屏幕之外**
## （相机可视矩形外再留 front_offscreen_margin 像素），且前方带内数量够了就不刷。
## 关掉后回到旧的"定时随机撒点"行为。
@export var front_spawn_enabled: bool = true
## 前方带内维持的目标数量（**平常**阶段）。前方这个范围里已经有这么多活着的敌人时，**一只都不刷**。
## 2026-09-16 用户反馈「平常刷怪量已经跟尸潮差不多、尸潮不突出」→ 默认 6 → 3。
@export var front_target_ahead: int = 6
## 【尸潮（peak）阶段】前方带内维持的目标数量 —— 用户要的"附近达到指定数量（如 20）就停止刷怪"。
@export var front_target_ahead_peak: int = 30
## 每次补位最多补几只（平常；不会一次补满，避免瞬间一片）。
@export var front_batch: int = 1
## 【尸潮（peak）阶段】每次补位最多补几只。
@export var front_batch_peak: int = 2
## 【尸潮（peak）阶段】两批之间的最短间隔（秒）。尸潮要比平常快得多。
@export var front_interval_min_peak: float = 1.2
## 前方扇区半角（度）：90 = 只刷正前方一条线，60 = 正前方 ±60°。
@export var front_half_angle: float = 60.0
## 生成距离下限（像素）。同时还要满足"屏幕外"，实际下限取两者较大值。
@export var front_min_dist: float = 360.0
## 生成距离上限（像素）。太大 = 敌人要跑很久才到；太小 = 容易一眼看见。
## 2026-09-15 校准：摄像机 2× 放大后实际可视仅 640×480（半宽 320），屏外下限≈384px；
## 上限 560 ≈ 出屏后半个多屏宽，怪刷完很快就能接敌。旧值 900 是 zoom 1× 时代的直觉，
## 会导致怪全刷在 1~2 个屏宽外、普通丧尸（视野 200px）长时间不激活 → 玩家一路空场。
@export var front_max_dist: float = 560.0
## 至少离开相机可视边缘这么多像素才算"屏幕外"。嫌"眼睁睁看着刷新"就调大。
@export var front_offscreen_margin: float = 64.0
## 玩家累计前进这么多像素才允许补下一批 —— 走得快就补得快（修"走得快时前方空窗"）。
@export var front_advance_step: float = 160.0
## 两批之间的最短间隔（秒），防止一帧内连补。
@export var front_interval_min: float = 2.0
## 原地不动时是否也补怪。false（默认）= 站着不动不会刷怪，避免"脸上刷怪"。
@export var front_spawn_when_idle: bool = true

@export_group("生成 — 僵尸变体池（ZombieVariant）")
## 本关可刷的僵尸池：刷出时按 weight 随机选一种。**留空 = 用内置默认池**（男性/女性/学生）。
## 狂暴形态 = 尸潮（peak 阶段）期间，行走图切换为该外观对应的クリムゾンヘッド并加速加攻；
## 没有对应クリムゾンヘッド图的外观（如中年ゾンビ）不会狂暴。
## tres/zombies/ 下已建好现成变体（学生/女子学生/訓練生/職員/研究員/士官/実験体/中年…），
## 在 Inspector 里把 .tres 拖进本数组即可按关卡定制。
@export var zombie_pool: Array[ZombieVariant] = []

@export_group("生成 — 特感（SpecialEnemyData：ハンター 等）")
## 本关可刷的特感池：按 weight 随机选一种，独立于普通僵尸池编排。
## **留空 = 本关不刷特感**（现有地图行为不变；想启用就把 tres/specials/ 下的
## .tres 拖进本数组）。同屏互斥由 special_max_alive 控制。
@export var special_pool: Array[SpecialEnemyData] = []
## 开场后到第一只特感出现的最短延迟秒数。先给玩家一段普通战斗再上强度。
@export var special_first_delay_min: float = 10.0
## 第一只特感的最长延迟秒数。
@export var special_first_delay_max: float = 50.0
## 两只特感之间的最短冷却秒数（自上一只刷出起算）。
## 2026-09-16 用户反馈「很少有特感出现」→ 50/90 下调到 30/50。
@export var special_cooldown_min: float = 30.0
## 两只特感之间的最长冷却秒数。
@export var special_cooldown_max: float = 50.0
## 同屏最多存活几只特感（含濒死/倒地中的）。默认 1 = 互斥。
## ⚠ 2026-09-16 起本值才真正生效：此前 _update_specials 写死「有任意存活特感就不刷」，
## 地图 Inspector 配 2/3 全被无视（叠加"打不死的特感长期占位"→ 特感绝迹）。
@export var special_max_alive: int = 1
## 紧张度门槛（0.0~1.0）：低于此值不刷特感。特感是压力放大器，玩家闲逛时不出现。
@export var special_intensity_threshold: float = 0.25

@export_group("夜间视界（Night Hunter）")
## 黑暗强度 0~1。0=白天（不生成 NightOverlay，默认，现有关卡行为不变）。
## >0 时 Director 在场景根挂 NightOverlay：全屏压暗，动态光源（火海/闪光弹等）挖亮。
## 原作 Night Hunter：夜間のため視界の悪いステージが続く。参考值 0.75（黑但可玩）~0.88。
@export var night_darkness: float = 0.0

@export_group("生成 — Boss / Tank（タイラント T-002）")
## 常规流程里可否刷 Tank。原作：ステージ中に遭遇した時は逃げられることもある
## （普通关卡里 Tank 是可选遭遇，不一定非打）。false = 常规不刷，只靠防守战/组件触发。
@export var tank_enabled: bool = false
## 常规刷 Tank 用的资源（留空 = 用内置默认 tres/specials/タイラントT002.tres）。
@export var tank_data: SpecialEnemyData = null
## 常规流程里的 Tank 冷却（秒）：两只 Tank 之间的最短间隔。
## 原作 Tank 是低频压迫型，频率应远低于特感 → 默认 180 秒起。
@export var tank_cooldown_min: float = 180.0
@export var tank_cooldown_max: float = 300.0
## 同屏最多几只 Tank（默认 1 = 互斥，对应原作「重点敌人互斥」var1361 机制）。
@export var tank_max_alive: int = 1
## 常规刷 Tank 的紧张度门槛。比特感更高：Tank 只在局面已经吃力时出现。
@export var tank_intensity_threshold: float = 0.6

@export_subgroup("防守战专属 Tank（HoldoutMachine 期间）")
## 防守战期间是否刷 Tank。原作 147 图防守战里 Tank 是核心压迫源，频率也与常规不同。
@export var holdout_tank_enabled: bool = true
## 防守战 Tank 资源（留空 = 复用 tank_data）。
@export var holdout_tank_data: SpecialEnemyData = null
## 防守战开始后到第一只 Tank 的延迟（秒）。
@export var holdout_tank_first_delay: float = 25.0
## 防守战期间两只 Tank 之间的冷却（秒）。比常规短：防守战节奏更快。
@export var holdout_tank_cooldown_min: float = 45.0
@export var holdout_tank_cooldown_max: float = 75.0
## 防守战期间同屏最多 Tank 数。
@export var holdout_tank_max_alive: int = 1

@export_group("生成 — 回收（离玩家太远就清除）")
## 回收总开关。开启后：存活敌人离玩家超过 recycle_dist 就直接清除（不管它有没有在追玩家）。
## 对应原作 #506「★☆敵の回収設定☆★」。没有它，被甩在身后的敌人会永久存活：
##   · 吃满 max_active_common → 前方补位被"全场存活已达上限"掐断（越走越不刷）；
##   · 它们还在继续跑 A* 追玩家 → 敌人一多就卡顿。
@export var recycle_enabled: bool = true
## 回收检查间隔（秒）。
@export var recycle_interval: float = 1.0
## 离玩家超过这个距离（像素）的存活敌人被清除。屏幕外约 400px、前方补位带上限 560px，
## 默认 1400 只会清掉"已经被甩远"的敌人，绝不会清掉玩家看得见的。
@export var recycle_dist: float = 1400.0
## 尸体（死亡后的敌人）也一并清远，防止长时间游玩后尸体无限堆积。
@export var recycle_clear_corpses: bool = true

@export_group("生成 — 限制")
@export var max_active_common: int = 40          ## 地图上同时最多存活多少个普通感染者。超过此值暂停生成，等玩家杀到低于此值再继续。防止满屏敌人卡死
@export var spawn_min_dist: float = 400.0        ## 敌人生成位置离玩家至少多少像素。防止敌人在玩家脸上刷出来。设大=更有"从远处跑来"的感觉，但需要地图够大

@export_group("投放 — 掉落池（ItemManager 随机投放）")
## 随机掉落池：Director 投放补给时从这里按权重随机抽武器/物品。
## 留空 = 按紧张度决策直接投放固定资源（喷雾/药品/弹药/副武器）。
## 池子配置方法见 DropPoolData 的文件头说明。
@export var drop_pool: DropPoolData = null

@export_group("音乐 — 尸潮（Peak 阶段 BGM）")
## 尸潮期间播放的 BGM，尸潮结束自动停止。默认 = 原作ラッシュ１（与防守战同曲）。
@export var horde_music: AudioStream = preload("res://music/ラッシュ１.mp3")
@export_range(-80.0, 12.0, 0.5) var horde_music_volume_db: float = 0.0

@export_group("音乐 — Boss（Tank/T-002 登场 BGM，优先级高于尸潮）")
## Boss（tank_enemies 组成员 / BossEncounter 定点遭遇）存活期间播放的 BGM。
## 登场即停尸潮 BGM 改播本曲（L4D2 Tank 音乐式），Boss 全灭自动停止；
## 若停止时尸潮仍在 peak，尸潮 BGM 自动接回。留空 = 不播 Boss BGM（尸潮 BGM 照常）。
## 防守战 BGM 不停播，Boss BGM 播放期间防守战 BGM 暂停（stream_paused），Boss 灭后恢复。
@export var boss_music: AudioStream = null
@export_range(-80.0, 12.0, 0.5) var boss_music_volume_db: float = 0.0
