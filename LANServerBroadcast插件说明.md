# LANServerBroadcast 插件

来源：Godot Asset Library（Godot 3 版本），用户手动下载放入 `未安装的插件/`，已迁移适配 Godot 4.6。

## 功能

局域网游戏发现：
- **ServerAdvertiser** — Host 端 UDP 广播房间信息（名称、端口、人数）
- **ServerListener** — Client 端监听局域网内游戏广播，自动发现/移除

## 文件

| 文件 | 说明 |
|------|------|
| `addons/LANServerBroadcast/server_advertiser/ServerAdvertiser.gd` | 广播端（✅ 已适配 4.6） |
| `addons/LANServerBroadcast/server_listener/ServerListener.gd` | 监听端（✅ 已适配 4.6） |
| `addons/LANServerBroadcast/lan_server_broadcast_plugin.gd` | 插件注册（✅ 已适配 4.6） |
| `addons/LANServerBroadcast/plugin.cfg` | 插件元数据 |

## 所有适配改动（Godot 3 → 4.6）

### 已修复的 API 变更

| # | 旧 API（Godot 3） | 新 API（Godot 4.6） | 原因 |
|---|-------------------|---------------------|------|
| 1 | `tool` | `@tool` | Godot 4 注解语法 |
| 2 | `export (float) var x` | `@export var x: float` | 类型声明方式变更 |
| 3 | `export (int) var x` | `@export var x: int` | 同上 |
| 4 | `get_tree().is_network_server()` | `multiplayer.is_server()` | 网络 API 重构 |
| 5 | `to_json(data)` | `JSON.stringify(data)` | JSON 模块独立 |
| 6 | `parse_json(str)` | `JSON.parse_string(str)` | 同上 |
| 7 | `str.to_ascii()` | `str.to_utf8_buffer()` | 编码方法重命名 |
| 8 | `bytes.get_string_from_ascii()` | `bytes.get_string_from_utf8()` | 同上 |
| 9 | `emit_signal(name, arg1, arg2)` | `signal.emit(arg1, arg2)` | 信号 emit 语法变更 |
| 10 | `OS.get_unix_time()` | `Time.get_unix_time_from_system()` | OS 类拆分 |
| 11 | `timer.connect("timeout", self, "method")` | `timer.timeout.connect(callable)` | 信号连接语法变更 |
| 12 | `socket.listen(port)` | `socket.bind(port)` | PacketPeerUDP 方法重命名 |

### 已修复的 Godot 4 严格类型推断

| # | 错误 | 修复 |
|---|------|------|
| 13 | `Cannot infer the type of "err" variable` | `var err := ...` → `var err: Error = ...` |

### 遇到的每个具体错误及修复

1. **`Identifier "LocalPlayerInput" not declared`** → 内部类不能跨文件引用 → 移到独立文件 `script/player/local_player_input.gd` + `class_name LocalPlayerInput`

2. **`Cannot find member "is_action_just_pressed" in base "Callable"`** → `_input` 与 Godot 内置 `Node._input(event)` 方法冲突 → 改名 `_player_input`

3. **`Cannot find member "get_move_vector" in base "Callable"`** → `State.gd` 中 `character: CharacterBody2D` 类型太严格，静态检查找不到动态添加的属性 → 去掉类型标注 `var character`

4. **`Cannot infer the type of "tree" variable`** → `character` 无类型后 `:=` 推断失败 → `var tree := character.get_tree()` → `var tree: SceneTree = character.get_tree()`

5. **`Cannot infer the type of "err" variable` (ServerListener)** → 同上 → `var err: Error = ...`

6. **`Nonexistent function 'listen' in base 'PacketPeerUDP'`** → Godot 4 中 `listen()` 改名为 `bind()` → `_socket.listen(port)` → `_socket.bind(port)`

7. **`Node not found: Panel/StatusLabel`** → tscn 有 VBoxContainer 嵌套但 script 用 `$Panel/StatusLabel` → 改为 `$Panel/VBox/StatusLabel`

## 如何避免 Godot 3 → 4 迁移问题

### 安装插件前先检查

1. **看 `plugin.cfg` 的 `script=` 行引用的 `.gd` 文件** → 打开看第一行是 `tool` 还是 `@tool`。`tool` = Godot 3，需要迁移。
2. **看 `project.godot` 内容** → `config_version=5` 是 Godot 4，`config_version=4` 是 Godot 3。
3. **看脚本中是否有这些 Godot 3 特征**：
   - `export (float)` / `export (int)` 带括号类型 → Godot 3
   - `onready var` 无 `@` → Godot 3
   - `connect("signal", self, "method")` 字符串连接 → Godot 3
   - `OS.get_unix_time()` → Godot 3
   - `parse_json()` / `to_json()` 小写 → Godot 3
   - 任何以 `.to_ascii()` / `.get_string_from_ascii()` 结尾 → Godot 3

### 迁移速查表

```
tool                    → @tool
export (float) var x    → @export var x: float
export (int) var x      → @export var x: int
is_network_server()     → multiplayer.is_server()
to_json(d)              → JSON.stringify(d)
parse_json(s)           → JSON.parse_string(s)
.to_ascii()             → .to_utf8_buffer()
.get_string_from_ascii()→ .get_string_from_utf8()
emit_signal(n, a, b)    → signal_name.emit(a, b)
OS.get_unix_time()      → Time.get_unix_time_from_system()
.connect("s", self, "m")→ .signal.connect(callable)
.listen(port)           → .bind(port)           # PacketPeerUDP
```

### GDScript 严格类型（Godot 4 特有）

```gdscript
# ❌ Godot 4 不让用 := 推导非明确类型的返回值
var err := some_func()    # 如果函数返回类型不明确 → 解析错误
# ✅ 显式标注类型
var err: Error = some_func()
var tree: SceneTree = node.get_tree()

# ❌ typed variable 不能访问脚本动态添加的属性
var character: CharacterBody2D
character._player_input   # CharacterBody2D 没有 _player_input → 报错
# ✅ 去掉类型标注
var character             # 动态分发
```

### 最佳的验证方式

安装第三方插件后，**立即在 Godot 编辑器中打开项目**，看 Output 面板是否有红色 ERROR。如果一个插件生成 3+ 个解析错误，基本可以判定是 Godot 3 版本需要迁移。

## 集成方式

- **Host 端**：Lobby 场景中创建 `ServerAdvertiser` 节点，设置 `server_info` 字典
- **Client 端**：Lobby 场景中创建 `ServerListener` 节点，连接 `new_server` / `remove_server` 信号
- 详见 `script/lobby.gd` 中的 `_setup_server_browser()` 和 `_on_host_pressed()`
