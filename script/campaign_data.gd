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


## ── 关卡扁平表（2026-09-27）──
## 把各战役的关卡按顺序摊平，供两个地方共用：①调试「跳转章节」（多人主机）②多人房间的
## 「选择章节」。清单与 campaign_select 保持一致；章节骨架期 level_scenes 为空的战役跳过。
const CAMPAIGN_RESOURCE_PATHS: Array[String] = [
	"res://object/campaign_assault.tres",
	"res://object/campaign_night_hunter.tres",
]


## 返回 [{campaign, chapter, label, scene}, ...]（按战役→关卡顺序）。
static func collect_chapter_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: String in CAMPAIGN_RESOURCE_PATHS:
		if not ResourceLoader.exists(p):
			continue
		var res: Resource = load(p)
		if not (res is CampaignData):
			continue
		var cd: CampaignData = res as CampaignData
		for i: int in range(cd.level_scenes.size()):
			var scene_path: String = cd.level_scenes[i]
			if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
				continue
			out.append({
				"campaign": cd.campaign_name,
				"chapter": i + 1,
				"label": "%s · %d %s" % [
					cd.campaign_name, i + 1, _chapter_title_of(scene_path)],
				"scene": scene_path,
			})
	return out


## 章节短名：取场景文件名最后一个"-"之后的部分（"突袭-第一关-街道.tscn" → "街道"）。
static func _chapter_title_of(scene_path: String) -> String:
	var base: String = scene_path.get_file().get_basename()
	var parts: PackedStringArray = base.split("-")
	if parts.is_empty():
		return base
	return parts[parts.size() - 1]
