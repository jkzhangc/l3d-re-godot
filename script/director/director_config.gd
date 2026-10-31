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
## ⚠ 2026-10-29 起这两个字段**不再生效**：Build 时长改由「尸潮间隔（难度表 /
## `horde_interval_override_*`）」反推。保留字段只为旧场景不报错，请勿再调。
@export var build_min: float = 36.0              ## [已停用] 旧：压力爬升阶段最短秒数
@export var build_max: float = 108.0             ## [已停用] 旧：压力爬升阶段最长秒数
## ★尸潮间隔覆盖（2026-10-31 重标定）：两次「峰值开始」之间的目标秒数（**无击杀时的基线**）。
## **0 = 用难度表**（简单 125~170 / 普通 100~140 / 困难 80~112 / 最高 65~95）；
## 两个值都 > 0 时由本图决定。Director 会自动扣掉峰值时长与喘息，换算成 Build 时长，
## 所以这里填的是「玩家实际感到的间隔」，不是 Build 本身的长度。
## ⚠ 击杀会按 `smart_horde_per_kill_sec` 把实际间隔**提前**，这里只是基线。
@export var horde_interval_override_min: float = 0.0
@export var horde_interval_override_max: float = 0.0

@export_group("节奏 — Peak（尸潮爆发）")
@export var peak_timeout: float = 60.0           ## 尸潮最多持续秒数。超时后即使还有活着的敌人也强制结束，防止玩家卡关
@export var peak_intensity_threshold: float = 0.7  ## 紧张度触发线（0.0~1.0）。爬升阶段紧张度超过此值立即进入尸潮，无视时间。设1.0=靠时间触发，设0.5=玩家残血或没子弹马上尸潮

@export_group("节奏 — Cooldown（喘息）")
@export var cooldown_min: float = 0.0            ## 尸潮结束后最短喘息秒数。这期间不生成敌人，让玩家捡东西、推图、回状态。地图小就设短些
@export var cooldown_max: float = 10.0           ## 喘息阶段最长秒数。超过这个时间自动进入下一轮爬升。设0=喘息结束立刻开始下一轮
@export var cooldown_intensity_threshold: float = 0.3  ## 提前结束喘息的紧张度触发线。玩家在喘息期主动撞怪→紧张度升高→提前结束喘息进入爬升

@export_group("L4D 节奏模型（2026-10-24）")
## ★核心开关：开启后改用求生之路式「消耗型预算 + 峰值停手 + 余韵 + 喘息」模型。
## 关掉 = 完全回到旧三阶段（Build 零星补位 / Peak 持续供怪 / Cooldown 照常补位）。
## 旧模型的根本问题：补位是「维持数量」，击杀立刻腾出名额 → 原地打永远打不完。
@export var l4d_pacing: bool = true
## ★节奏时长缩放（2026-10-24）：本作地图比 L4D 小得多、窄得多 —— 一章跑几分钟就到终点，
## 而下面 build_min/max、peak_timeout、cooldown_min/max 的秒数是按 L4D「十几分钟一章、
## 反复起落 4~6 次」标定的。不缩放的话，一张 3 分钟的图只够跑 1~2 个循环，
## 整局会变成「一次高潮 + 长时间无事」，这跟 L4D 的观感差得最远。
## 0.55 ≈ 每 60~85 秒一个完整循环 → 3~5 分钟的图能跑到 3~4 个循环。
## 地图特别短可再降到 0.4；将来若做长图可提到 0.8~1.0。
@export_range(0.2, 2.0, 0.05) var pacing_time_scale: float = 0.55
## 峰值最短停留秒数（对应 L4D 的 Sustain Peak）：进峰值后至少撑这么久才允许结束，
## 保证尸潮有「砸下来」的存在感，不会被一两秒清空就跳过。
@export var peak_sustain: float = 4.0
## 余韵（Peak Fade）判定：场上**没有敌人交战**持续这么多秒，才允许进入喘息。
## 这段时间不生成任何敌人，用来让残余战斗自然打完 —— 这就是「打完还有余韵」。
@export var fade_quiet_sec: float = 2.5
## 余韵最长秒数（兜底）：残兵躲在角落时不会让节奏永远卡在 fade。
@export var fade_timeout: float = 12.0
## 喘息期队伍累计前进这么多像素 → 提前结束喘息（走得快就走得快，对应 L4D Relax 的"走远即结束"）。
@export var relax_advance: float = 700.0

@export_group("节奏 — 智能尸潮（2026-10-31：击杀驱动的压力表）")
## ★BUILD 段累计一个「压力进度」，填满即进尸潮。三个来源叠加：
##   ① 基线：每帧 +dt（纯时间，无论打不打都在涨）；
##   ② **击杀：每杀 +`smart_horde_per_kill_sec` 秒 → 杀得越多越容易触发**（用户 2026-10-31 定）；
##   ③ 安静：无交战时填充倍率 ×`smart_horde_idle_mult`（躲着不打也会被摸上门）。
## 目标时长由「尸潮间隔（难度表 / `horde_interval_override_*`）」反推成 Build 时长，
## 所以**难度依然决定基准时间**，击杀只是把它提前。
## 只统计 BUILD 段的击杀 —— 峰值/余韵/喘息里杀的怪属于这一波本身，不会直接喂下一波。
## 关掉 = 回到难度间隔表的纯定时节奏（强度只在 BUILD 后段可提前）。
@export var smart_horde_enabled: bool = true
## 每击杀相当于「提前多少秒」。2.0 = 30 杀提前 1 分钟。设 0 = 击杀不参与（纯时间）。
@export var smart_horde_per_kill_sec: float = 2.0
## 无交战时的进度填充倍率（1.5 = 安静时比交战快 50%）。设 1.0 = 交战与否等价。
@export var smart_horde_idle_mult: float = 1.5
## 本段 BUILD 的**最短时长**（秒）：尸潮不会早于它触发。
@export var smart_horde_min_sec: float = 30.0
## ★两波尸潮之间的**硬间隔**（秒，从上一波峰值**开始**算）。
## **0 = 自动**（= 间隔下限 × 0.9，随难度缩放：简单 112 / 普通 99 / 困难 72 / 最高 58）。
## 与阶段长短、`force_build()` 强推、击杀爆发都无关 —— 这是「刚结束又立刻来一波」的最后一道兜底。
## 实际最小间隔 = max(本值, 峰值时长 + 余韵 + 喘息 + `smart_horde_min_sec`) ≈ 72s。
@export var smart_horde_gap_sec: float = 0.0
## ★**首波时长倍率**：乘在「尸潮**间隔**」上，得到**第一段 BUILD 的时长**。
## 1.0 = 首波在难度基线间隔到来 → 普通档 110~145s（约 2 分钟，用户 2026-10-31 要求）；
## <1 = 开场更快来；>1 = 更长的暖场。
## ⚠ 首波**不扣 overhead**（开场没有峰值/余韵/喘息要还），所以本值直接等于「进图到第一波」的秒数。
@export_range(0.2, 2.0, 0.05) var smart_horde_first_scale: float = 1.0
## [已停用] 旧「0 杀无交战阈值」。2026-10-31 起目标时长由难度间隔表反推，本值不再读取。
@export var smart_horde_base_sec: float = 120.0
## [已停用] 旧「阈值上限」。同上，不再读取。
@export var smart_horde_max_sec: float = 360.0

@export_group("进度（紧张度因子 / Boss 路程闸，2026-10-25）")
## 启用真实关卡进度估计（0~1）。关掉 = 回到旧行为（进度因子恒定 0.3），仅用于对照/回退。
## 进度来源优先级：出口节点（SafeDoor/TeleportPoint）的"距离收敛" → 行进里程 / 参考路程。
## 它同时决定 `tank_spawn_pos_min/max` 这道 Boss 路程闸是否真正生效。
@export var progress_enabled: bool = true
## 参考总路程（像素）。**0 = 自动**（进图时按"起点 → 出口"的直线距离 × 1.6 估）。
## 只在没有出口节点（竞技图/测试图）或想手动校准里程口径时才需要填。
@export var progress_length_px: float = 0.0

@export_group("L4D — 加压预算（Build 阶段的可消耗总量）")
## 每个 Build 阶段发放的普通感染者预算：用完就停手，直到进入下一阶段。
## 这就是「消耗型预算」—— 它替换掉旧的「维持目标数量」，是空窗的来源。
## ⚠ 2026-10-24 用户实测「丧尸实在太少」：本项目地图狭窄紧凑、没有大空地，
## 与 L4D 的 3D 开阔地图不可比 → 预算按"每 10 秒能看到 2~3 只"重新标定（原 6~12 太低）。
@export var build_budget_min: int = 7            ## 预算下限（按人数放大；2026-10-29 全体 ×0.6）
@export var build_budget_max: int = 12           ## 预算上限（×0.6）
@export var build_batch_min: int = 1             ## 每批最少几只（×0.6）
@export var build_batch_max: int = 2             ## 每批最多几只（×0.6）
@export var build_interval_min: float = 5.0      ## 两批之间最短秒数
@export var build_interval_max: float = 9.0      ## 两批之间最长秒数

@export_group("L4D — 尸潮（Peak 入场一次性爆发）")
## 进入峰值时**一次性**发出的尸潮规模。峰值期间不再补怪（L4D：强度到顶就停手）。
@export var mob_size_min: int = 8                ## 尸潮规模下限（×0.6）
@export var mob_size_max: int = 13               ## 尸潮规模上限（×0.6）
## 尸潮从「背后」来的比例（L4D 原版是 75%）。0 = 全从前方来，1 = 全从背后来。
@export_range(0.0, 1.0, 0.05) var mob_behind_ratio: float = 0.75
## ★尸潮规模**下限**（2026-10-31 用户定）：缩放后不足此值时补到此值。
## 简单难度 `spawn_scale`=0.5 会把 8~13 只砍成 4~6 只 —— 玩家体感是「来了，但没感觉」。
## 低难度应该靠**血量/伤害**降，不靠把尸潮砍到看不见。峰值维持数按它的一半兜底。
@export var mob_size_floor: int = 8

@export_group("L4D — 喘息（Relax 阶段低人口维持）")
## 喘息期维持多少只。**0 = 完全不生成**（最接近 L4D 原版 Relax）。
## 2026-10-24 用户实测「走两步就穿过去了、一路没怪」→ 默认 2：
## 保留"路上零星还有丧尸"的观感（L4D2 的 Relax 同样允许游荡者出现）。
## ⚠ 2026-10-29 起：补怪总开关打开后，本项被 `offscreen_refill_min/max` 取代（这里不再生效）。
@export var relax_target: int = 2
## 喘息期补位的最短间隔（秒）。只在 relax_target > 0 时生效。
@export var relax_interval: float = 7.0
## 「威胁圈」半径（像素）：这个圈内的存活敌人（**含已经贴脸的**）都算占名额。
## 旧实现只数 360~560px 环带，敌人走近就"离开名额" → 贴脸的敌人为下一只腾位。
@export var threat_radius: float = 600.0

@export_group("L4D — 区域游荡者（Wanderers）")
## ★进入一张地图时，先在玩家四周（屏外、360° 整圈）铺多少只"徘徊的丧尸"。
## 对应 L4D 的 wanderers：一片区域里本来就有丧尸在晃，而不是等你走过去才从前方刷出来。
## ⚠ 2026-10-29 起受 `offscreen_refill_enabled` 总开关约束：总开关关闭（默认）时本组不生效。
@export var wander_seed_min: int = 4
@export var wander_seed_max: int = 5
## 队伍累计前进这么多像素，就在新区域再补一轮游荡者（模拟 L4D 的 Active Area Set 换区）。
## 0 = 只在进图时铺一次。
@export var wander_seed_step: float = 900.0
## 每次换区补几只（按难度/人数放大）。
@export var wander_seed_refill: int = 2
## ★附近希望维持的游荡者总数（威胁圈内）。补层时**只补差额**：够就不补、不足才补。
## 2026-10-24 用户提议的"根据附近数量增减"即此项。学校/街道某些角落一直空 → 补到目标；
## 已经一堆 → 一只不加。嫌稀就抬到 12~14，嫌密就降到 6~8。
@export var wander_target_near: int = 6

## ⚠ **旧模型专用**：`l4d_pacing = true`（默认）时，BUILD 阶段由「加压预算」供货，
## 本组（散兵）与下面「尸潮」组都走不到。只有关掉 l4d_pacing 做 A/B 时才需要调。
@export_group("生成 — 散兵（爬升阶段零星敌人）")
@export var scatter_min: int = 2                 ## 每次生成散兵的最少个数。爬升阶段定时触发，紧张度低时取此值
@export var scatter_max: int = 5                 ## 每次生成散兵的最多个数。紧张度越高越接近此值
## ⚠ 2026-09-26 用户实测「普通刷怪频率太快，保持击杀节奏可以无限刷下去」：
## 旧的 1.0s 就是"一秒左右又来几只"的直接来源（散兵是普通补位的主供怪路径）。
## 现在收到 4.0s：站着对枪时不再连绵不断，但也不会长时间空场。
@export var scatter_interval_min: float = 4.0   ## 两次散兵生成之间最少隔几秒。设短=敌人连绵不断，设长=玩家有大段空闲
@export var scatter_interval_max: float = 10.0  ## 两次散兵生成之间最多隔几秒。实际间隔在此范围内随机，避免节奏感太机械

## ⚠ **旧模型专用**：L4D 模型下峰值 = 一次性 `mob_size_*` 后停手，本组不生效。
@export_group("生成 — 尸潮（Peak 阶段大量敌人）")
@export var horde_total_min: int = 3            ## 尸潮期间**同时维持**多少只存活（×0.6；缺多少补多少）
@export var horde_total_max: int = 15            ## 尸潮期间同时维持的存活数上限（×0.6）
@export var horde_batch_size: int = 5            ## 尸潮每批同时生成几个（×0.6；仍分批涌来）
@export var horde_batch_interval: float = 5.0    ## 尸潮批次之间的基础间隔秒数。设短=连续涌出，设长=一波一波有节奏（2026-09-17：3→5，慢刷）
@export var horde_duration_min: float = 25.0  ## 一波尸潮持续多久（秒）下限。尸潮结束条件 = 这个窗口走完；期间「缺多少补多少」，被击杀 / 被远处回收都会腾出名额继续补
@export var horde_duration_max: float = 40.0  ## 一波尸潮持续多久（秒）上限。实际值在此范围内随机，并被 peak_timeout 截断（尸潮不会比峰值阶段更长）

@export_group("附近闸")
## 附近（半径内）存活敌人达到该数量且玩家静止 → 暂停普通补位与散兵/事件批，
## 玩家开始移动立即恢复。防守战不受此闸影响。0 = 关闭。（2026-09-17 用户需求）
@export var nearby_gate_count: int = 10
## 附近闸判定半径（px，以玩家为圆心）。
@export var nearby_gate_radius: float = 600.0

@export_group("生成 — 画面外补怪（总开关，2026-10-29）")
## ★是否允许导演在玩家**画面之外**持续补怪。**默认开启**（2026-10-29 晚间用户改为默认开：
## 第二战役已补齐刷怪点，不开就只有尸潮/特感/作者点，路上会空）。
## 关闭后停掉的全部是"持续供水"：进图/换区游荡者、L4D 加压预算批次、喘息期补位、
## 旧模型的散兵与前方屏外补位。**尸潮事件、特感、Boss 不受影响**。
## ★2026-10-30 混合补位：地图里若有**启用中的 SpawnZone**，区域先补局部缺口；
## 屏外通道只在附近总人口低于 `offscreen_refill_min` 时补到该下限，余量交给区域。
## 没有 SpawnZone 时才按原来的迟滞带补到 `offscreen_refill_max`。
@export var offscreen_refill_enabled: bool = true
## 附近补怪人数**下限**：威胁圈（`threat_radius`，默认 600px）内活着的敌人跌到它以下才开补。
## 0 = 不补（等价于关闭总开关）。仅在 `offscreen_refill_enabled = true` 时生效。
## ★2026-10-30 密度三档：≤下限 = 空场档（补位间隔 ×0.6、每批 +1）；
## 下限~上限 = 正常档；≥上限 = 过密档（屏外通道停手，区域仍按自己的局部预算补）。
@export var offscreen_refill_min: int = 2
## 附近补怪人数**上限**：开补后一直补到它才停手（迟滞带）——
## 中间区间既不会"杀一只补一只"，也不会补到一半就撒手。尸潮/事件推高到上限以上则保持停手，
## 直到回落到下限以下才恢复。有 SpawnZone 时本值只作为「过密」判定线，不作为屏外补位目标。
@export var offscreen_refill_max: int = 6

@export_group("生成 — 前方屏外定点刷怪（FrontSpawner）")
## 是否启用"前方屏外定点刷怪"。这是当前默认的补怪方式：
## 敌人只出现在玩家**前方**（按移动方向 ±front_half_angle 的扇区）、**屏幕之外**
## （相机可视矩形外再留 front_offscreen_margin 像素），且前方带内数量够了就不刷。
## 关掉后回到旧的"定时随机撒点"行为。
@export var front_spawn_enabled: bool = true
## 前方带内维持的目标数量（**平常**阶段）。前方这个范围里已经有这么多活着的敌人时，**一只都不刷**。
## ⚠ **L4D 模型（l4d_pacing = true，默认）下本项不再生效**：FrontSpawner.update() 会直接早退，
## 它退化成"取点器"，补位时机与总量改由 SpawnManager 的加压预算（build_budget_*）决定。
## 只有关掉 l4d_pacing 回到旧模型时才会用到。（学校内部图里配的 9 因此目前是空转值。）
@export var front_target_ahead: int = 6
## 【尸潮（peak）阶段】前方带内维持的目标数量 —— 用户要的"附近达到指定数量（如 20）就停止刷怪"。
## ⚠ 同上：L4D 模型下峰值是「一次性 mob + 停手」，本项不生效。
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
## 2026-09-27 用户实测「3 人数量可以、频率偏快」→ 160 → 200（要走更远才补下一批）。
@export var front_advance_step: float = 200.0
## 两批之间的最短间隔（秒），防止一帧内连补。
## 2026-09-27 同上：2.0 → 2.5（只降频，不动每批数量）。
@export var front_interval_min: float = 2.5
## 原地不动时是否也补怪。false（默认）= 站着不动不会刷怪，避免"脸上刷怪"。
@export var front_spawn_when_idle: bool = true
## ★开场立即刷怪（2026-09-27 用户需求；**2026-09-28 起默认开启**）：进入本图时**不停在
## 喘息（cooldown）阶段** —— 直接切到 build 并放开前方补位的时间闸门，进图就有敌人；
## 之后回到正常节奏（间隔 / 前进距离 / 尸潮照旧生效）。
## 默认 true；安全屋 / 不想开局就开打的图，在该图 DirectorConfig 上单独取消勾选即可。
## ⚠ L4D 模型下若**正在 peak / fade / 尸潮进行中**（例如传送发生在尸潮没打完时），本项会被跳过，
## 否则「强推 build → 强度仍高 → 立刻又进峰值」= 玩家听到的"音乐刚停、预警音又响"连环尸潮。
## ⚠ 2026-10-29 起 `offscreen_refill_enabled=false`（默认）时本项**没有实际效果** ——
## 补货通道已关，只会让节奏提前进 build，路上不会因此多出敌人。
@export var spawn_immediate_on_start: bool = true

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
@export var special_first_delay_min: float = 8.0
## 第一只特感的最长延迟秒数。
@export var special_first_delay_max: float = 30.0
## 两只特感之间的最短冷却秒数（自上一只刷出起算）。
## 2026-09-16 用户反馈「很少有特感出现」→ 50/90 下调到 30/50。
## 2026-10-13 用户再反馈「特感概率太小、原作高很多」→ 大幅下调到 12/22（接近原作高频）。
## 实际间隔还会被 `Players.spawn_scale()`（单人难度 / 多人人数）再除一遍 → 更高频。
@export var special_cooldown_min: float = 12.0
## 两只特感之间的最长冷却秒数。
@export var special_cooldown_max: float = 22.0
## 同屏最多存活几只特感（含濒死/倒地中的）。默认 2。
## ⚠ 2026-09-16 起本值才真正生效：此前 _update_specials 写死「有任意存活特感就不刷」，
## 地图 Inspector 配 2/3 全被无视（叠加"打不死的特感长期占位"→ 特感绝迹）。
## ⚠ 2026-10-25 起**不再乘 `Players.spawn_scale()`**：单人 0.5 时会把 2 压成 1，
## 再被一只未惊动的女巫占位就彻底不出特感（用户实测"基本见不到其他特感"）。
## 现在名额就是作者配置值；难度只影响冷却，不影响名额与门槛。
@export var special_max_alive: int = 2
## 紧张度门槛（0.0~1.0）：低于此值不刷特感。特感是压力放大器，玩家闲逛时不出现。
## ⚠ 2026-10-25 起**不再除以 `Players.spawn_scale()`**：单人 0.5 时 0.1/0.5=0.2，
## 而平静期强度本身约 0.2 → 特感永远够不到门槛。现在直接用本值。
@export var special_intensity_threshold: float = 0.1

@export_group("夜间视界（Night Hunter）")
## 黑暗强度 0~1。0=白天（不生成 NightOverlay，默认，现有关卡行为不变）。
## >0 时 Director 在场景根挂 NightOverlay：全屏压暗，动态光源（火海/闪光弹等）挖亮。
## 原作 Night Hunter：夜間のため視界の悪いステージが続く。参考值 0.75（黑但可玩）~0.88。
@export var night_darkness: float = 0.0

@export_group("生成 — Boss / Tank（タイラント T-002）")
## 常规流程里可否刷 Tank。原作：ステージ中に遭遇した時は逃げられることもある
## （普通关卡里 Tank 是可选遭遇，不一定非打）。false = 常规不刷，只靠防守战/组件触发。
## 2026-10-13 用户需求「最终章前也该能遇到坦克」→ 默认改为 **true**（各图可单独关）。
@export var tank_enabled: bool = true
## 常规刷 Tank 用的资源（留空 = 用内置默认 tres/specials/タイラントT002.tres）。
@export var tank_data: SpecialEnemyData = null
## 常规流程里的 Tank 冷却（秒）：两只 Tank 之间的最短间隔。
## 原作 Tank 是低频压迫型，频率应远低于特感 → 2026-10-13 用户要求提高出现率，
## 从 180~300 大幅下调到 70~130（再经 `Players.spawn_scale()` 按难度/人数除一遍）。
@export var tank_cooldown_min: float = 70.0
@export var tank_cooldown_max: float = 130.0
## 同屏最多几只 Tank（默认 1 = 互斥，对应原作「重点敌人互斥」var1361 机制）。
@export var tank_max_alive: int = 1
## 常规刷 Tank 的紧张度门槛。比特感更高：Tank 只在局面已经吃力时出现。
## 2026-10-13 从 0.6 下调到 0.35（运行时还会按 ÷`Players.spawn_scale()` 再放宽；
## 且不再排除尸潮 peak —— 旧 0.6 与「非 peak」近乎互斥导致坦克基本刷不出）。
@export var tank_intensity_threshold: float = 0.35

@export_subgroup("防守战专属 Tank（HoldoutMachine 期间）")
## 防守战期间是否刷 Tank。原作 147 图防守战里 Tank 是核心压迫源，频率也与常规不同。
@export var holdout_tank_enabled: bool = true
## 防守战 Tank 资源（留空 = 复用 tank_data）。
@export var holdout_tank_data: SpecialEnemyData = null
## 防守战开始后到第一只 Tank 的延迟（秒）。
## ★2026-10-24 用户实测「防守战 40 秒就出 Tank，打死又来，一局三四只」→ 25 提到 45。
@export var holdout_tank_first_delay: float = 45.0
## 防守战期间两只 Tank 之间的冷却（秒）。
## ★2026-10-24 同上：45~75 提到 90~150（一场 2~3 分钟的防守战最多 1~2 只）。
@export var holdout_tank_cooldown_min: float = 90.0
@export var holdout_tank_cooldown_max: float = 150.0
## 防守战期间同屏最多 Tank 数。
@export var holdout_tank_max_alive: int = 1
## ★需求模式间隔（2026-10-25）：当防守战**必须靠杀 Tank 才能推进**时
## （HoldoutMachine 的 `end_mode = KILL_COUNT` + `kill_count_filter = TANK`，如列车台「杀 2 只开门」），
## 两只 Tank 之间的冷却改用这个短间隔，而不是上面的 90~150s 环境冷却。
## 原因：那种防守战的 Tank 是**开门条件**，按"可选压力事件"冷却会让门永远开不了
## （用户实测：打死第一只后等了几分钟，第二只始终不来）。设 0 = 不启用需求模式。
@export var holdout_tank_demand_interval: float = 15.0

@export_group("L4D — Boss 发牌（Tank / 女巫 / 无事）")
## ★第二批（2026-10-24）：L4D 的 Tank 与 Witch **不是"打得惨才出"**，
## 而是沿逃生动线每 N 单位排布一张牌，牌堆 = Tank / 女巫 / 无事，洗牌发牌、
## 不允许连续重复。这样"这局会不会遇到 Tank"才有悬念，而且 Boss 与节奏解耦
##（高压时也会来，低压时也可能来）—— 旧的"冷却 + 紧张度门槛"是反过来的。
## 开启后，下方常规 Tank 的冷却通道自动停用（避免双通道叠加）；防守战通道不受影响。
@export var boss_deck_enabled: bool = true
## 每隔多少像素发一张牌（按队伍累计前进距离，等效 L4D 的"沿路每 N 单位排布"）。
## 本作地图紧凑：2200px ≈ 半张街道图，3~5 分钟的图约 2~4 张牌。
@export var boss_deck_step: float = 3200.0
## 第一张牌的里程下限（占 step 的比例）。太小 = 刚进图就遇 Tank。
@export_range(0.3, 1.0, 0.05) var boss_deck_first_ratio: float = 1.0
## 牌堆里"无事"的张数（默认 2 ⇒ Tank : 女巫 : 无事 = 1 : 1 : 2）。
@export var boss_deck_nothing_weight: int = 4
## ★每张图最多发几张 Tank 牌（默认 1）。2026-10-24 用户实测「一张图遇到四只坦克」：
## 光靠牌堆比例不够，必须硬上限。发完就不再发 Tank 牌（牌照样消耗，只是跳过）。
@export var boss_deck_max_tanks: int = 1
## 每张图最多发几张女巫牌（默认 1）。
@export var boss_deck_max_witches: int = 1
## 女巫资源（留空 = 用内置 tres/specials/ブレアウィッチ.tres）。
@export var witch_data: SpecialEnemyData = null

@export_group("Boss — Tank 出场路程闸（2026-10-25，对齐 L4D）")
## Tank 只允许在「已走过路程比例」落在这个窗口内时登场（0~1）。
## 取值参照 L4D2 `mission.txt` 的 `coop_boss_spawning.spawn_pos_min / spawn_pos_max`
##（社区默认 0.2~0.8，官方部分地图 0.4~0.8）。默认 0.35~0.85：
## 开局 1/3 段绝不遇 Tank（用户实测「Tank 出现太早」的直接修复），接近出口也不再放。
## ⚠ 这套闸依赖 `progress_enabled`：进度关掉（恒定 0.3）时，min 设大于 0.3 会让 Tank 永不出场。
@export_range(0.0, 0.95, 0.05) var tank_spawn_pos_min: float = 0.35
## Tank 允许登场的最晚路程比例。超过它就本图放弃 Tank（避免"安全门前糊脸一只"）。
@export_range(0.05, 1.0, 0.05) var tank_spawn_pos_max: float = 0.85
## 不允许连续两张地图都出 Tank（L4D：不存在两张图连着出、中间没有间隔）。
## 关掉 = 上一张图出过 Tank，这张图仍可能出。
@export var tank_no_repeat_maps: bool = true

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

@export_group("投放 — 位置与怜悯（2026-10-25）")
## 「可发现带」上限（像素）：补给优先投在玩家前方这个距离以内。
## 2× 缩放下半屏宽约 320px —— 投得更远，玩家不会知道那儿有东西。
@export var item_drop_visible_max: float = 320.0
## 投放点周围这个半径内有存活敌人就换点（默认 128px，设计文档 §6.2）。
@export var item_drop_threat_radius: float = 128.0
## 降级投放（Fail-Safe）的怜悯血线：任一存活玩家 HP 比例低于它并持续
## `item_fail_safe_low_hp_sec` 秒 → 一次性投「急救喷雾 + 弹药堆 + 投掷品」。设 0 = 关闭。
@export_range(0.0, 0.6, 0.01) var item_fail_safe_hp_ratio: float = 0.2
## 低于怜悯血线要持续多少秒才触发（防"擦伤一下就发货"）。
@export var item_fail_safe_low_hp_sec: float = 30.0
## 降级投放冷却（秒）。冷却期内即使再次低血也不再投放。
@export var item_fail_safe_cooldown: float = 180.0

@export_group("投放 — 敌人死亡掉落（2026-10-01：原作式「打完会掉东西」）")
## 敌人掉落的**总池**：敌人自身（ZombieVariant / SpecialEnemyData）没配 drop_pool 时回落到这里。
## 留空 = 该地图的敌人不掉落。池内可混放 WeaponData / ItemData。
@export var enemy_drop_pool: DropPoolData = null
## 普通感染者掉落概率（0~1）。用户 2026-10-01 拍板：普通 12%。
@export_range(0.0, 1.0, 0.01) var enemy_drop_chance_common: float = 0.12
## 特感（special_pool 刷出的 ハンター 等）掉落概率。用户拍板：50%。
@export_range(0.0, 1.0, 0.01) var enemy_drop_chance_special: float = 0.5
## Boss / Tank（group `tank_enemies`）掉落概率。用户拍板：必掉。
@export_range(0.0, 1.0, 0.01) var enemy_drop_chance_boss: float = 1.0

@export_group("音乐 — 尸潮（Peak 阶段 BGM）")
## 尸潮期间播放的 BGM，尸潮结束自动停止。默认 = 原作ラッシュ１（与防守战同曲）。
## ⚠ 开启 `horde_music_randomize` 后本字段只在「随机池为空」时兜底。
@export var horde_music: AudioStream = preload("res://music/ラッシュ１.mp3")
@export_range(-80.0, 12.0, 0.5) var horde_music_volume_db: float = 0.0
## 是否随机播放尸潮音乐（2026-10-29 用户需求：原作就是随机的）。
## 开启（默认）→ **每局开局抽一次**，整局所有尸潮都用同一首（池内等概率）；
## 关闭 → 完全回到旧行为，只播 `horde_music`。
@export var horde_music_randomize: bool = true
## 尸潮随机池（等概率）。**留空 = 用内置默认池**（music/ラッシュ１〜６，见
## `Director.DEFAULT_HORDE_POOL`）—— 这样不开任何配置就有随机效果，又不必把
## 6 首 mp3 全 preload 进内存（只在抽到时才 load）。
## 想按关卡限定曲目就在这里拖 AudioStream 进来（非空时**完全取代**默认池）。
@export var horde_music_pool: Array[AudioStream] = []

@export_group("音效 — 尸潮预警（Peak 开始的一次性提示音）")
## 尸潮（Peak）**开始的那一刻**播放一次的音效（2026-09-30 用户需求）。
## 默认 = 原作「ラッシュ開始」，与最终章防守战机器 HoldoutMachine.alert_sound 是同一个文件
## —— 让玩家在尸潮涌来前听到和防守战一致的预警。留空 = 不播。
## 表现层：Host/单机本地播放并经 NetworkWorld 广播，Client 同步播放（各自本地响一次）。
@export var horde_alert_sound: AudioStream = preload("res://sound/ラッシュ開始.ogg")

@export_group("音乐 — 常态铺底（Build / Relax，可听化）")
## Build 与 Relax 阶段循环播放的低张力铺底曲。**留空 = 不播**（维持现状：只有尸潮/Boss 音乐）。
## 与尸潮曲互斥：一进峰值就停；Boss 音乐优先级更高。
@export var calm_music: AudioStream = null
## 喘息/余韵阶段专用的铺底（留空 = 沿用 calm_music）。
## 建议：build 用更"空"的环境层，relax 用安全屋/隔离区那种更舒缓的。
@export var calm_music_relax: AudioStream = null
@export_range(-80.0, 12.0, 0.5) var calm_music_volume_db: float = -7.0

@export_group("音乐 — Boss（Tank/T-002 登场 BGM，优先级高于尸潮）")
## Boss（tank_enemies 组成员 / BossEncounter 定点遭遇）存活期间播放的 BGM。
## 登场即停尸潮 BGM 改播本曲（L4D2 Tank 音乐式），Boss 全灭自动停止；
## 若停止时尸潮仍在 peak，尸潮 BGM 自动接回。留空 = 不播 Boss BGM（尸潮 BGM 照常）。
## 防守战 BGM 不停播，Boss BGM 播放期间防守战 BGM 暂停（stream_paused），Boss 灭后恢复。
##
## ★默认值 = 原作「ボス１」（2026-10-19 用户实测修复）：此前默认是 **null**，而全项目只有
## 测试图与第四关列车台两张图在 DirectorConfig 里显式配了 boss_music → 其余地图
## `play_boss_music()` 第一行就 `stream == null` 早退，坦克登场/存活全程无声，
## 尸潮结束后也不会补播。原作坦克登场本来就播「ボス１」（见 147 图分析 #603 消息），
## 因此把它设为默认值，让所有地图开箱即有坦克 BGM；作者仍可逐图覆盖或清空。
@export var boss_music: AudioStream = preload("res://music/ボス１.mp3")
@export_range(-80.0, 12.0, 0.5) var boss_music_volume_db: float = 0.0
