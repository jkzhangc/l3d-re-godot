class_name SkillData extends Resource

## ── 架构定位 ──
## 系统：技能数据 ｜ 层：数据（Resource）
## 联机：数据只读；SA 效果在拥有者实体本地执行，联机表现待接
## 职责：技能配置：类型（SA 效果分派）、TP 消耗、冷却、图标、特效场景与搓招指令。
## 依赖：无（纯数据）。消费方：player.gd（use_skill / _execute_skill_effect）。

## 技能数据 — 说明书 §6.1：SA（X 键主动技，每角色一个专属）+ 预留觉醒/被动
## skill_type 决定 use_skill() 的实际效果（player.gd::_execute_skill_effect）。

enum SkillType {
	GENERIC = 0,       ## 占位：无实际效果（旧测试技能）
	SA_SEEKER = 1,     ## 感覚向上（のび太）：持续时间内敌方近战伤害无效（完全见切）
	SA_RECITAL = 2,    ## ジャイアンリサイタル（ジャイアン）：半径内全体敌人踉跄
	SA_CROUCH = 3,     ## しゃがみ回避（静香）：一定时间无敌，按住 SA 键持续蹲（急速耗 TP）
	SA_BACKPACK = 4,   ## バックパック（スネ夫）：背包与手持互换（背包系统未实装，占位）
}

@export var skill_type: int = SkillType.GENERIC  ## 技能类型（决定实际效果）

@export_group("效果参数")
## SA_SEEKER：完全见切持续秒数；SA_CROUCH：起蹲时的基础无敌秒数。
@export var duration: float = 10.0
## SA_RECITAL：踉跄作用半径（像素）。
@export var radius: float = 400.0
## SA_RECITAL：踉跄（硬直）时长（秒）。
@export var stagger_duration: float = 2.0
## SA_CROUCH：按住 SA 键持续蹲时每秒消耗的 TP（TP 耗尽自动起身）。
@export var crouch_tp_drain: float = 15.0
## 发动音效（如 ジャイアンリサイタル 的歌声、静香_ＳＡ）。
@export var sa_sound: AudioStream = null

@export var skill_id: String = ""               ## 唯一标识
@export var skill_name: String = "新技能"        ## 显示名称
@export_multiline var description: String = ""   ## 描述
@export var tp_cost: int = 10                   ## 释放消耗的 TP
@export var cooldown: float = 5.0               ## 冷却（秒，0=无冷却）
@export var icon: Texture2D                     ## 技能图标
@export var effect_anim: PackedScene            ## 技能特效场景（预留，VXAnimSprite 场景）

@export_group("搓招")
## 触发键：输入动作名（如 "SA键"/"确定键"）。SA 技能填 "SA键"（C 键）。
@export var command_trigger: String = "确定键"
## 方向指令序列：触发前需按出的方向（上/下/左/右），如 "下右"、"右右"。空=无需方向。
@export var command_motion: String = ""
