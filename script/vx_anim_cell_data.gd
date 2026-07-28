class_name VXAnimCellData extends Resource
## VX Ace 动画单格数据 — 定义某一帧中显示的一个精灵
##
## 在 VXAnimSprite 的 cell_data 数组中添加多个即可实现同帧多精灵。
## 同一 frame_idx 的所有 cell 会同时显示。


## 所属帧序号（0=第一帧，对应 frame_sequence[0] 或格子0）
@export var frame_idx: int = 0
## 精灵表中的格子索引（0-based，左→右，上→下）
@export var pattern: int = 0
## 相对动画中心的偏移（像素）
@export var offset: Vector2 = Vector2.ZERO
## 缩放
@export var scale: Vector2 = Vector2(1, 1)
## 旋转（度）
@export var rotation_deg: float = 0.0
## 透明度（0=全透明, 1=不透明）
@export var opacity: float = 1.0
## 混合模式：0=Normal, 1=Additive, 2=Subtractive
@export var blend_mode: int = 0
## 水平翻转
@export var flip_h: bool = false
