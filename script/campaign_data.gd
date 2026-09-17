class_name CampaignData extends Resource

## ── 架构定位 ──
## 系统：战役数据 ｜ 层：数据（Resource）
## 联机：不涉及
## 职责：战役定义：ID/名称/描述/图标与按顺序排列的关卡场景路径。
## 依赖：被 campaign_select 读取

## 战役数据 — 定义一组连续关卡

@export var campaign_id: String = ""           ## 唯一标识，如 "assault"
@export var campaign_name: String = ""         ## 显示名称，如 "突袭"
@export_multiline var description: String = "" ## 战役描述
@export var level_scenes: Array[String] = []   ## 关卡场景路径列表，按顺序
@export var campaign_icon: Texture2D           ## 战役选择界面图标（可选）
