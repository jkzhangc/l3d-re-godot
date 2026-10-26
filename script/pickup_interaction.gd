extends RefCounted

## ── 架构定位 ──
## 系统：掉落物交互 ｜ 层：工具（RefCounted，纯判定）
## 联机：不涉及（只读设置与输入；具体事务仍由各拾取物决定单机 / 发请求）
## 职责：物品「获取 / 替换」的输入判定 —— 设置里的「点击一下（默认）」/「按住」统一走这里。
## 依赖：Global.pickup_hold_mode（设置项，持久化在 config.json）、Input

## 为什么单独抽出来：武器拾取物与药品拾取物各有「单机 / 联机」两条路径（共 4 个入口），
## 交互方式一旦分头实现，很容易出现「单机能点、联机还要按住」这类两端不一致。
## 这里只做**判定**，不碰拾取事务，调用方按原有路径执行（_do_pickup / _request_network_pickup）。

## 是否处于「按住」模式。false = 点击一下（默认，2026-10-26 用户定稿）。
static func is_hold_mode() -> bool:
	return Global.pickup_hold_mode


## 本帧是否刚按下该动作（只判输入，不判范围）。
static func tapped(action: String) -> bool:
	return Input.is_action_just_pressed(action)


## 点击模式的触发条件 —— **同一帧只放行一次**。
## 为什么需要：多个掉落物可能同时落在拾取范围内（武器有"最近者仲裁"，药品/投掷物没有），
## 一个按下事件会被每个拾取物各读一次 → 一下捡走两件。这里用帧号做闸门。
static var _tap_frame: int = -1

static func tapped_once(action: String) -> bool:
	if not Input.is_action_just_pressed(action):
		return false
	var frame: int = Engine.get_process_frames()
	if _tap_frame == frame:
		return false
	_tap_frame = frame
	return true
