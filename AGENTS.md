# AGENTS.md

本文件是仓库内所有 AI 助手的精简入口。开始工作前依次读取：

1. [AI 记忆规约](docs/00-项目规范/AI记忆规约.md)：约束非 WorkBuddy 助手；WorkBuddy 使用内建等价行为。
2. [项目技术规范正文](docs/00-项目规范/CLAUDE.md)：架构、工程约束、导出发布和 Godot 工具使用。
3. 按需读取 [文档分类索引](docs/README.md) 中的专题。

设计冲突以 [游戏设计方向-L3D混合](docs/01-设计与进度/游戏设计方向-L3D混合.md) 为准；实现现状以已核实的代码为准。

2026-11-21 起，项目说明、方案、参考和开发记录统一分类存入 `docs/`，不要在项目根新增散落 Markdown。根目录只保留 README / AGENTS / CLAUDE / MEMORY 四个精简发现入口；插件、工具自带说明不因此搬迁；`.workbuddy/` 是项目数据，不得删除，记忆继续写 `.workbuddy/memory/`。
