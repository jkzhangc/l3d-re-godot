class_name SkillData extends Resource
## 技能数据 — 空壳子，后续技能系统填充实际逻辑

@export var skill_id: String = ""               ## 唯一标识
@export var skill_name: String = "新技能"        ## 显示名称
@export_multiline var description: String = ""   ## 描述
@export var tp_cost: int = 10                   ## 释放消耗的 TP
@export var cooldown: float = 5.0               ## 冷却（秒，0=无冷却）
@export var icon: Texture2D                     ## 技能图标
@export var effect_anim: PackedScene            ## 技能特效场景（预留，VXAnimSprite 场景）

@export_group("搓招")
## 触发键：在武器举起状态按住「技能键」后，再按下此键触发该技能。
## 填输入动作名，如 "确定键"（攻击）、"取消键"
@export var command_trigger: String = "确定键"
## 方向指令序列：触发前需按出的方向（上/下/左/右），如 "下右"、"右右"。空=无需方向。
@export var command_motion: String = ""
