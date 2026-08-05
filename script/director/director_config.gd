class_name DirectorConfig extends Node
## 导演系统参数覆盖 — 放置在关卡场景中即可独立配置该地图的生成参数
##
## Director autoload 检测到场景切换后，自动从此节点读取参数
## 不放置则使用 Director 子模块的默认值

@export_group("启用")
@export var spawn_enabled: bool = true           ## 该地图是否启用敌人生成（关掉后完全不刷怪，适合安全屋/对话场景）

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
@export var scatter_min: int = 1                 ## 每次生成散兵的最少个数。爬升阶段定时触发，紧张度低时取此值
@export var scatter_max: int = 3                 ## 每次生成散兵的最多个数。紧张度越高越接近此值
@export var scatter_interval_min: float = 15.0   ## 两次散兵生成之间最少隔几秒。设短=敌人连绵不断，设长=玩家有大段空闲
@export var scatter_interval_max: float = 30.0   ## 两次散兵生成之间最多隔几秒。实际间隔在此范围内随机，避免节奏感太机械

@export_group("生成 — 尸潮（Peak 阶段大量敌人）")
@export var horde_total_min: int = 10            ## 一波尸潮最少一共出几个敌人。实际数量在此范围内随机
@export var horde_total_max: int = 30            ## 一波尸潮最多一共出几个敌人。地图大可以多设，地图小设少点
@export var horde_batch_size: int = 4            ## 尸潮每批同时生成几个。不会一次性刷出全部，而是分批来，模拟"从四面八方涌来"的感觉
@export var horde_batch_interval: float = 3.0    ## 尸潮批次之间的基础间隔秒数。实际间隔在2~5s随机。设短=连续涌出，设长=一波一波有节奏

@export_group("生成 — 限制")
@export var max_active_common: int = 15          ## 地图上同时最多存活多少个普通感染者。超过此值暂停生成，等玩家杀到低于此值再继续。防止满屏敌人卡死
@export var spawn_min_dist: float = 400.0        ## 敌人生成位置离玩家至少多少像素。防止敌人在玩家脸上刷出来。设大=更有"从远处跑来"的感觉，但需要地图够大
