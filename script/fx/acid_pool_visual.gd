extends Node2D

## ── 架构定位 ──
## 系统：投掷物表现 ｜ 层：表现（Node2D）
## 联机：不涉及（各端各自播放，纯表现）
## 职责：**纯着色器**强酸液面：用一个正方形 ColorRect + shader/acid_pool.gdshader 模拟"地上一滩酸"。
## 依赖：shader/acid_pool.gdshader
##
## 【为什么不用现成美术（2026-10-27 用户定稿）】
## `art/Animations/酸だー！.png` / `Acid！.png` 是**命中特效**素材，铺在地面不像"一滩液体"；
## 项目没有酸池贴图。着色器按 UV 生成不规则液面 + 流动 + 冒泡 + 荧光，零素材成本，
## 且半径随投掷物 `fire_radius` 缩放（一个 uniform 就能改色/改强度）。
##
## 【由谁创建】`FirePatch._build_acid_pool()`：element=ACID 时不再铺火苗精灵，改挂本节点。
## 调用顺序：`setup(radius)` → `add_child` → `global_position = 落点`。
## z 层级由调用方负责（要挂在 GroundLayer 里、z=0：压在角色 z=1 之下、地面图块之上）。

const SHADER_PATH := "res://shader/acid_pool.gdshader"
## 落地"泼开"时长：没有溅射素材，用 0.7→1.0 的缩放 + 淡入做出冲击感。
const POP_IN_SEC: float = 0.22
const BASE_OPACITY: float = 0.85

var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _t: float = 0.0


## 建立液面。`radius_px` = 伤害半径（与 FirePatch 的 `radius*32+16` 同口径）。
func setup(radius_px: float) -> void:
	var side: float = maxf(24.0, radius_px * 2.0)
	_rect = ColorRect.new()
	_rect.name = "AcidSurface"
	## 纯表现：不接收鼠标（否则手机端会吃掉触摸）。
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.size = Vector2(side, side)
	_rect.position = -_rect.size * 0.5
	_rect.pivot_offset = _rect.size * 0.5
	var shader: Shader = load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("[AcidPool] 着色器缺失，酸池退化为不可见：%s" % SHADER_PATH)
		return
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	## 每个池一个随机相位：同一瓶酸炸出的多个池不会同节奏冒泡。
	_mat.set_shader_parameter("seed", randf() * 100.0)
	_mat.set_shader_parameter("pool_scale", 0.84)
	## ★不能用 modulate 做淡入：ShaderMaterial 在 fragment 里写 COLOR 会覆盖掉
	## 顶点色（modulate 就是靠顶点色下发的）→ 必须走自己的 uniform。
	_mat.set_shader_parameter("opacity", 0.0)
	_rect.material = _mat
	add_child(_rect)


func _process(delta: float) -> void:
	if _rect == null:
		return
	_t += delta
	var k: float = clampf(_t / POP_IN_SEC, 0.0, 1.0)
	## ease-out：一开始扩得快，收尾慢
	k = 1.0 - pow(1.0 - k, 3.0)
	_rect.scale = Vector2.ONE * lerpf(0.7, 1.0, k)
	if _mat != null:
		_mat.set_shader_parameter("opacity", BASE_OPACITY * k)
	if _t >= POP_IN_SEC:
		## 之后的不规则蠕动/冒泡全靠着色器里的 TIME，无需每帧脚本。
		set_process(false)
