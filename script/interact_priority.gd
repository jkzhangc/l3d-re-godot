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
