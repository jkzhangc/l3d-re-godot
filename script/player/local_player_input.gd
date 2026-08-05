class_name LocalPlayerInput extends PlayerInput
## 本地玩家输入 — 从 Input 单例读取（单机 + 联机本地玩家）
##
## 每帧调用 read() 从 Input 捕获所有按键状态。

## 所有需要捕获的输入动作
const ALL_ACTIONS: Array[String] = [
	"主武器键", "副武器键", "治疗品键", "辅助品键",
	"举起放下武器键", "确定键", "取消键", "行走键", "装填键",
]

## 每帧调用一次：从 Input 单例读取所有输入状态。
## 必须在 _physics_process 开头调用，确保所有状态在同一帧内读到一致的输入。
func read() -> void:
	tick()
	move_vector = Input.get_vector("左", "右", "上", "下")
	for action in ALL_ACTIONS:
		if Input.is_action_pressed(action):
			actions[action] = true
