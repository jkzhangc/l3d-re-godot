@tool
class_name NoSpawnLayer extends TileMapLayer

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：关卡标注（TileMapLayer, @tool）
## 联机：仅单机/Host 有生成行为，本层只提供数据，联机 Client 不需要挂。
## 职责：禁刷怪图块层——本层涂过的格子，Director / FrontSpawner 一律不把敌人刷进去。
##       玩家照常可以走进来（不参与物理碰撞，纯逻辑标记）。
## 依赖：Director._is_no_spawn（运行时把本层 painted 格并入 _is_walkable 判定）。
##
## 用法：把 object/no_spawn_layer.tscn 实例进地图 → 用画笔涂格子。
##       红色斜纹标记只在编辑器可见（visible = Engine.is_editor_hint()），
##       运行时自动隐藏，不用手动改 visible。
##       适用场景：剧情点/爆破点附近不准刷怪（例：第三章爆破墙区域）、
##       安全屋门口留一块"真空带"等。

func _ready() -> void:
	## 编辑器可见（涂得见）、游戏内不可见（纯逻辑标记）
	visible = Engine.is_editor_hint()
