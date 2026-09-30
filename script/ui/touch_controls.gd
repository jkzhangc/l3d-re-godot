extends CanvasLayer

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（CanvasLayer）
## 联机：不涉及（动作由既有 InputMap 承载，权威判定不变）
## 职责：手机端触摸操作层：把屏幕触摸转成既有 InputMap 动作（移动 / 攻击 / 装填 / 物品 / 系统）。
## 依赖：Global.is_mobile_platform()、Global.debug_enabled
##
## 【为什么是一个独立场景】用户要求"触摸按钮做成一个场景，每个按钮是独立节点，方便调整"：
## 全部按钮都在 `scene/ui/touch_controls.tscn` 里，位置 / 尺寸 / 贴图 / 映射动作
## 都能在编辑器里直接改，改完不必动任何脚本。
##
## 【挂载点改了（2026-09-29）】原先挂在每张地图的 `GameInit` 上 → 标题画面（= 主场景）与
## 角色选择 / 难度 / 章节选择这些**非地图场景**根本没有触摸层；而它们全是 RM2K3 光标式
##（Button 数 = 0，只认 `确定键`/`上`/`下`/`取消键`，且这些动作只绑键盘）
## → **手机上卡死在标题画面**。现在由 `Global._setup_touch_controls()` 全局创建一次，
## 本脚本按当前场景自动切「菜单模式 / 关卡模式」。

## 桌面端也显示（调布局用）。导出包（release）里 `debug_enabled` 恒 false，故不会误开。
@export var force_show_on_desktop: bool = false

## 关卡模式层级：在游戏 HUD 之上、黑幕(90)/结算页(100) 之下。
@export var control_layer: int = 80
## 菜单模式层级：**必须高于结算页**（章节总结 / 终章 ED 在 `layer = 100`）。
## ★2026-09-29 手机实测：章节总结页把触摸层整个盖住 → 手机上「按钮消失、确定键也按不了」，
## ED 流程卡死。菜单模式下抬到 110 让触摸层压在结算页之上。
@export var menu_layer: int = 110

## 判定「关卡场景」的标志节点名：每张地图都有 1 个 `GameInit`；其余（标题 / 菜单 /
## 联机大厅 / 结算页）都算菜单。
@export var gameplay_marker: String = "GameInit"

## 当前是否菜单模式（调试与用例读取）。
var _menu_mode: bool = false
var _last_scene: Node = null


func _ready() -> void:
	## ★暂停时也必须能操作（2026-09-29 用户实测「手机暂停画面里摇杆与按钮都动不了」）：
	## 触摸按钮改走 `_input()` 之后，整层一旦被 `paused` 停掉就收不到任何事件 ——
	## 而暂停菜单恰恰**只能靠虚拟按键**操作，等于功能死锁。触摸层整层设为 ALWAYS。
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = control_layer
	var g: Node = get_node_or_null("/root/Global")
	var mobile: bool = false
	if g != null and g.has_method("is_mobile_platform"):
		mobile = bool(g.call("is_mobile_platform"))
	var debug_on: bool = g != null and bool(g.get("debug_enabled"))
	visible = mobile or (force_show_on_desktop and debug_on)
	_apply_mode()
	print("[TouchControls] 移动平台=%s 调试=%s → 触摸层 visible=%s（%d 个按钮节点，菜单模式=%s）" % [
		mobile, debug_on, visible, _count_buttons(), _menu_mode])


## 场景切换时重新判定模式。每帧只做一次引用比较，开销可忽略。
##（Global 是 autoload，创建本层时主场景可能还没挂上 → 必须靠这里补一次判定。）
## 层级复查间隔（秒）。递归查找 CanvasLayer 不能每帧做，0.25s 对"菜单开关"这种
## 人眼可感知的事件足够快。
const LAYER_CHECK_INTERVAL: float = 0.25
var _layer_check_accum: float = 0.0


func _process(delta: float) -> void:
	var cs: Node = get_tree().current_scene if get_tree() != null else null
	if cs != _last_scene:
		_apply_mode()
	## ★关卡里暂停菜单 / 安全屋台词窗口的开关**不会**改变 `current_scene`，
	## 所以层级不能只在 `_apply_mode` 里算 —— 这里定期对一次（见 `_effective_layer`）。
	## ⚠ 该查找是**递归**的（菜单可能挂在地图场景内部），不能每帧做 → 降频到 0.25s。
	_layer_check_accum += delta
	if _layer_check_accum >= LAYER_CHECK_INTERVAL:
		_layer_check_accum = 0.0
		var want_layer: int = _effective_layer()
		if layer != want_layer:
			layer = want_layer
	## ★屏幕诊断已撤（2026-09-30 定位完成）：
	## 根因是「运行时改 `content_scale_size` 让输入坐标系与画布脱节」，已回退画布加宽解决。
	## `touch_button` / `touch_joystick` 里的 `print` 诊断保留（各限 40 条）——
	## 以后再遇到"位置对不上"可以直接看 stdout，不必再往屏幕上贴字。


## 是否菜单模式（菜单里只留摇杆 + 确定 + 取消）。
func is_menu_mode() -> bool:
	return _menu_mode


## 当前该用的层级。★2026-09-30 用户实测：**关卡里打开暂停菜单 / 安全屋开头台词时，
## 按键会被整个盖住** —— 因为那时 `current_scene` 仍是地图（有 GameInit），
## 触摸层判定为「关卡模式」留在 80，而菜单窗口是 100。
## 所以关卡模式也要动态看一眼：root 下有没有**可见且层级更高**的 CanvasLayer UI。
## （只遍历 root 的直接子节点，数量很少，每帧开销可忽略。）
func _effective_layer() -> int:
	if _menu_mode:
		return menu_layer
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return control_layer
	## ⚠ 必须**递归**找：暂停菜单 `menu.tscn` 的根虽是 CanvasLayer，但它可能是被挂到
	## 地图场景内部（不是 root 的直接子节点）—— 只扫一层会漏。所以调用方要降频。
	for node: Node in tree.root.find_children("*", "CanvasLayer", true, false):
		if node == self:
			continue
		var cl: CanvasLayer = node
		if cl.visible and cl.layer > control_layer:
			return menu_layer
	return control_layer


## 用「当前场景里有没有 GameInit」区分关卡与菜单，再把模式下发到每个按钮。
## `scene_key_override`：仅用例用 —— 直接指定「当前菜单场景的脚本名」，
## 以便在同一个测试场景里验证菜单场景白名单（见 BtnStart 的 menu_scene_filter）。
func _apply_mode(scene_key_override: String = "") -> void:
	var tree: SceneTree = get_tree()
	var cs: Node = tree.current_scene if tree != null else null
	_last_scene = cs
	## ⚠ `get_node_or_null()` 只吃 NodePath：StringName / String 都得显式转（实测 StringName 直接报 Parse Error）。
	var gameplay: bool = cs != null and cs.get_node_or_null(NodePath(gameplay_marker)) != null
	_menu_mode = not gameplay
	## 菜单里压在结算页(100)之上；关卡里平时留在黑幕(90)/结算页之下，
	## 但**只要有更高层的可见 UI（暂停菜单 / 安全屋台词）冒出来就抬上去**（见 _effective_layer）。
	layer = _effective_layer()
	_propagate(self, _menu_mode, scene_key_override if not scene_key_override.is_empty() else _current_scene_key(cs))


## 当前菜单场景的脚本文件名（不含扩展名），如 `character_select_menu`。
## 场景没挂脚本 / 取不到路径时返回空串（= 不匹配任何白名单 → 只显示无过滤的按钮）。
func _current_scene_key(cs: Node) -> String:
	if cs == null or cs.get_script() == null:
		return ""
	var path: String = (cs.get_script() as Script).resource_path
	return path.get_file().get_basename()


func _propagate(node: Node, menu_mode: bool, scene_key: String) -> void:
	for child: Node in node.get_children():
		if child.has_method("set_menu_mode"):
			child.call("set_menu_mode", menu_mode, scene_key)
		_propagate(child, menu_mode, scene_key)


func _count_buttons() -> int:
	var n: int = 0
	for node: Node in find_children("*", "Button", true, false):
		if node.get_script() != null:
			n += 1
	return n
