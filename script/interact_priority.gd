extends RefCounted

## ── 架构定位 ──
## 系统：交互输入仲裁 ｜ 层：工具（RefCounted，纯判定）
## 联机：不涉及（存档点在联机会话里自移除；本判定只读本机状态）
## 职责：判断「功能键」是否已被优先级更高的交互占用 —— 存档点据此让路。
## 依赖：各交互节点的约定方法 `can_use_function_key() -> bool`
##
## 【为什么需要它（2026-10-27 用户需求）】
## 存档点与掉落物 / 医疗箱 / 弹药补给 / 防守战机器 / Boss 遭遇都摆在交互距离内时，
## 同一次「功能键」按下会被多个节点各自**轮询**到 → 一边拾取或治疗，一边又弹出存档菜单。
## 用户定稿口径：**存档触发优先级最低** —— 只要还有别的「功能键」交互此刻能真正生效，
## 本次按键就归它；别的交互都不能触发时，才轮到存档点。
##
## 【约定】凡是响应「功能键」的交互节点，都实现 `can_use_function_key() -> bool`：
## 语义是「此刻按功能键，本节点会不会真的做事」—— 必须把范围、可用性、角色限制、
## 堆叠仲裁都算进去（不能只看"玩家在附近"）。
## 静态扫描而非显式注册表：新增交互物件只要照约定实现方法就自动参与仲裁，不会漏登记。
## 只在按键那一下调用（不在每帧跑），当前场景节点数量级下开销可忽略。


## 存档点等低优先级交互的让路判据：`except` 传调用者自身（不把自己算成"更高优先级"）。
static func has_priority_interaction(tree: SceneTree, except: Node) -> bool:
	if tree == null:
		return false
	## 本帧已有拾取物**消费**过功能键 → 必然存在更高优先级交互。
	## （竞态：拾取物先处理、物品已入手，此时再扫 can_use_function_key 会扫不到 → 存档点
	## 会对**同一按下**再弹菜单。帧号闸门补上这条缝。）
	if pickup_key_used_this_frame():
		return true
	var scene: Node = tree.current_scene
	if scene == null:
		return false
	## owned = false：运行时动态生成的节点（掉落物 / 刷出的机器）没有 owner，同样要参与判定。
	for node: Node in scene.find_children("*", "", true, false):
		if node == except or not is_instance_valid(node):
			continue
		if not node.has_method("can_use_function_key"):
			continue
		if bool(node.call("can_use_function_key")):
			return true
	return false


# ═══════════════════════════════════════
# 拾取优先级（2026-11-02 用户需求）
# ═══════════════════════════════════════
## 「获取物品」优先级**最高**：只要此刻有拾取物能用功能键，这次按键就归它 ——
## 存档点 / 医疗箱 / 弹药补给 / 防守战机器 / 互动开关 / Boss 遭遇全部让路。
## 用户口径：「把获取物品交互优先级放在其他交互上面，获取物品时存档那些不要被触发」。
##
## 【为什么要单独一组】原先只有存档点参与仲裁（`has_priority_interaction`），
## 医疗箱 / 补给 / 开关 / 遭遇各自轮询功能键、互不相让 —— 站在药品与补给中间按 D，
## 两边都会响应。拾取物登记进本组后，其它交互统一问一句"有没有拾取物能用键"即可。
const PICKUP_GROUP: StringName = &"key_pickup"


## 是否有拾取物此刻能用功能键（`except` 传调用者自身）。
static func pickup_can_use_function_key(tree: SceneTree, except: Node = null) -> bool:
	if tree == null:
		return false
	for node: Node in tree.get_nodes_in_group(PICKUP_GROUP):
		if node == except or not is_instance_valid(node):
			continue
		if not node.has_method("can_use_function_key"):
			continue
		if bool(node.call("can_use_function_key")):
			return true
	return false


## 同帧占用标记：防止**两个拾取物**在同一次按键里各捡一个（只给最近/先处理的那个）。
## 用帧号而不是时间窗 —— 只压同一帧，不会误伤"捡完立刻按 D 存档"。
static var _pickup_used_frame: int = -1


static func mark_pickup_key_used() -> void:
	_pickup_used_frame = Engine.get_process_frames()


static func pickup_key_used_this_frame() -> bool:
	return Engine.get_process_frames() == _pickup_used_frame


## 医疗箱 / 弹药补给 / 防守战机器 / 互动开关 / Boss 遭遇等的统一让路判据（2026-11-02）：
## 本帧已有拾取物消费过功能键，或此刻有拾取物能用功能键 → 本次按键归**拾取**。
## 用一个入口而不是各自拼两条判定，防止各节点漏一半（只查"能用"不查"已用"→ 同帧竞态照样双触发）。
static func pickup_blocks_function_key(tree: SceneTree, except: Node = null) -> bool:
	if pickup_key_used_this_frame():
		return true
	return pickup_can_use_function_key(tree, except)
