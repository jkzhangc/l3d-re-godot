# 安全门与章节总结功能交接（2026-08-19）

## 用户需求

1. 新增安全门场景实体，像传送点一样支持 VX Ace 行走图。
2. 玩家靠近安全门并按“确定键”后才进入安全屋。
3. 进入安全屋后显示类似《求生之路 2》的章节总结界面。
4. 单人模式按确定键直接跳过。
5. 多人模式需要所有玩家按确定键后才能跳过。

用户明确：视觉、摆放和是否可见由用户测试；AI 只需要确认场景/项目打开运行是否报错。

## 已保存到磁盘的实现

### 新增/重写

- `script/director/safe_door.gd`
  - 重写为 `SafeDoor extends Node2D`。
  - 支持 VX Ace 行走图、角色索引、朝向、踏步帧。
  - 靠近后显示提示，按“确定键”进入目标安全屋。
  - 传送前冻结章节统计，可选回血和导演节奏重置。
- `object/safe_door.tscn`
  - 安全门打包场景。
  - 默认使用 `res://art/misc/!オブジェクト1.png`。
- `script/chapter_stats.gd`
  - 按 Players 座位记录击杀、爆头、造成伤害、承受伤害、医疗品和章节用时。
- `script/ui/chapter_summary.gd`
  - 运行时构建 L4D2 风格章节总结 UI。
  - 单人确定键直接关闭。
  - 真正网络多人会等待所有所需座位确认，并预留 RPC 确认接口。
- `scene/ui/chapter_summary.tscn`
  - 总结界面打包场景。

### 已接入

- `project.godot`
  - 已添加 autoload：`ChapterStats="*res://script/chapter_stats.gd"`。
- `script/game_init.gd`
  - 非安全屋场景调用 `/root/ChapterStats.ensure_chapter(scene_path)`。
  - 安全屋仍执行原有 checkpoint 捕获。
- `script/player.gd`
  - 玩家实际承伤记入章节统计。
  - 成功使用治疗品记入章节统计。
- `script/bullet.gd`
  - 子弹根据命中前后 HP 记录实际伤害、击杀和爆头。
- `script/player/PlayerKnifeAttackState.gd`
  - 小刀根据命中前后 HP 记录实际伤害、击杀和爆头。
- `script/director/teleport_point.gd`
  - 已修改 `_process()`：即使 `animated=false` 也继续检测玩家接近，修复静态传送点无法互动的问题。

## 尚未完成

1. **读取最后一次 Godot scan 的编辑器日志并修复本任务新增错误。**
   - 最后操作是 `filesystem_manage(op="scan")`，尚未读取 scan 后日志。
   - 修改 TeleportPoint 时 MCP 曾返回 `GDScript reload failed with error code 43`，需要从 editor logs 获取真实原因；也可能只是自动重载时依赖尚未稳定。
2. 把安全门实例接入：
   - `scene/maps/突袭-第一关-街道.tscn`
   - 建议先放在 `DecorLayer`，临时位置可用 `Vector2(-960, -1040)`，目标场景为结尾安全屋室内。
3. 把总结界面实例接入：
   - `scene/maps/突袭-第一关-结尾安全屋-室内.tscn`
   - 增量添加 `scene/ui/chapter_summary.tscn`，不要覆盖用户已有地图内容。
4. 更新 `object/campaign_assault.tres`，把结尾安全屋室内加入 `level_scenes`。
5. 最终只做无报错测试：打开/运行安全门、总结 UI、街道、结尾安全屋场景；不做视觉验收。
6. 运行 `git diff --check`。

## 已知非本任务历史问题

- `res://script/gradient_label.gd:290`：从场景树外使用绝对路径 `get_node()`。
- 色表图片 `Image.load_from_file` 的导出警告。
- 若仍出现这些历史日志，不要擅自修改，除非明确阻断本功能。

## 工作区保护

- `scene/maps/突袭-第一关-结尾安全屋-室内.tscn` 是用户创建的重要未跟踪文件，只能增量修改，不能删除或重建。
- 仓库有大量与本任务无关的 `engine-reference/**/*.import` 删除和其他用户更改。
- 不要 reset、restore 或清理这些无关更改。

## 建议明日继续顺序

1. `logs_read(source="editor", include_details=true)` 检查最后 scan。
2. 修复新增脚本解析/API错误。
3. 接入街道安全门、结尾安全屋总结 UI、战役列表。
4. 再 scan。
5. 运行四个相关场景，只确认没有本任务新增报错。
