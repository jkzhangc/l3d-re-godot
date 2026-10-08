extends RefCounted

## ── 架构定位 ──
## 系统：输入意图 ｜ 层：工具类（RefCounted，无 class_name）
## 联机：单机/Host 本地键盘读取用；Client 的输入由 NetworkWorld 采集后经 RPC 提交。
## 职责：玩家输入动作名的**唯一真源**（与 project.godot [input] 一一对应），
##       并提供语义化意图查询，替代散落各处的 `Input.is_action_*("魔法字符串")`。
## 依赖：Global（移动闸门 + Ctrl 子集屏蔽）
##
## 【为什么无 class_name】见 spawn_spot_resolver.gd 同款说明：新建 class_name 在 headless
## 下可能因 global_script_class_cache 过期而 Parse Error。统一用 preload 常量引用。
##
## 【为什么需要它（2026-10-08）】地面状态机 Idle/Walk/Run 三处逐字重复了同一段
## 「武器/消耗品/投掷」输入轮询，动作名是裸字符串——加一个键要改多份文件，且拼错只在
## 运行时暴露。集中到此：动作名一次定义，意图查询一处维护；后续想做输入重映射/回放
## 也只需改这里。
##
## ⚠ 这些常量**必须**与 project.godot `[input]` 的动作名逐字一致（含中文名）。
##   改 project.godot 的绑定值时，动作名不变则此处无需改动。

# ── 动作名（= project.godot [input] 的键名）──
const ACTION_MOVE_LEFT := &"左"
const ACTION_MOVE_RIGHT := &"右"
const ACTION_MOVE_UP := &"上"
const ACTION_MOVE_DOWN := &"下"
const ACTION_WALK := &"行走键"                 ## 按住 = 慢走（默认跑步）
const ACTION_RAISE_WEAPON := &"举起放下武器键"   ## 举起 / 放下武器
const ACTION_PRIMARY_WEAPON := &"主武器键"
const ACTION_SECONDARY_WEAPON := &"副武器键"
const ACTION_HEALING_ITEM := &"治疗品键"
const ACTION_SUPPORT_ITEM := &"辅助品键"
const ACTION_THROWABLE := &"投掷物键"
const ACTION_CONFIRM := &"确定键"
const ACTION_CANCEL := &"取消键"
const ACTION_RELOAD := &"装填键"
const ACTION_SHOVE := &"推击键"
const ACTION_SA := &"SA键"
const ACTION_AWAKEN := &"覚醒键"
const ACTION_DROP_WEAPON := &"丢弃武器键"
const ACTION_SWITCH_CHARACTER := &"切换角色键"


# ── 意图查询（薄封装，语义集中）──

## 「举起/放下武器」键按下（边沿）。地面状态用它进入武器状态。
static func pressed_raise_weapon() -> bool:
	return Input.is_action_just_pressed(ACTION_RAISE_WEAPON)


## 慢走键是否按住（决定 Walk / Run）。
static func is_walk_held() -> bool:
	return Input.is_action_pressed(ACTION_WALK)


## 物品热键（主/副武器、治疗、辅助、投掷）的边沿读取。
## 走 Global.item_key_just_pressed —— 它在 Ctrl 按住时统一忽略 1~5，让位给「选择队员N键」
## （见 Global 注释）；直接读 Input 会漏掉这条屏蔽规则。
static func pressed_item_key(action: StringName) -> bool:
	return Global.item_key_just_pressed(action)


## 移动向量（已过 Global 的移动闸门）。
static func move_vector() -> Vector2:
	return Global.move_input()
