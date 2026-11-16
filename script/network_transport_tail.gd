extends Node

## ── 架构定位 ──
## 系统：联机传输 ｜ 层：Net内部阶段收尾节点（不新增autoload）
## 职责：在业务物理/渲染回调之后flush ENet并排空隧道回包；不模拟、不派发业务RPC。
## @trace NET-LAT-P1
var _manager: Node = null

func setup(manager: Node) -> void:
	_manager = manager
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 10000
	process_physics_priority = 10000

func _process(_delta: float) -> void:
	if is_instance_valid(_manager):
		_manager.flush_transport()

func _physics_process(_delta: float) -> void:
	if is_instance_valid(_manager):
		_manager.flush_transport()
