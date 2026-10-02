extends RefCounted

## ── 架构定位 ──
## 系统：诊断 ｜ 层：工具类（**纯静态，不是 autoload** —— 避免动 project.godot 的启动清单）
## 联机：不涉及（各端写自己的本地文件）
## 职责：把「报错 / 关键事件」落盘成**玩家可以发给群里的日志文件**，并留一份内存环形缓冲
##       供报错界面直接显示上下文。
## 依赖：无（只用 FileAccess / OS）
## 被调用：GameErrorCapture（引擎 error/warning）、Player（卡墙自救）、ErrorScreen（取上下文）
##
## 【用户需求（2026-10-02）】「报错界面左下角要写：游戏报错了！请截图或者把游戏目录下的报错文件
## 发到交流群里！（没错报错时会生成控制台日志文件）」→ 本类就是那个"报错文件"的**唯一写入入口**。
##
## 【为什么两处都写】
##   · **exe 同目录**：玩家最容易找到、直接拖进群里；⚠ 手机端该目录通常不可写 → open 失败自然跳过。
##   · **`user://`**：跨平台兜底（Windows 在 %APPDATA%\Godot\app_userdata\...），永远可写。
##
## 【为什么不写 config.json / 项目目录】`config.json` 是 git 跟踪文件，塞运行时数据会让工作区
## 每次游玩都变脏（既有教训）；日志属于"运行产物"，只写上面两处。

const FILE_NAME: String = "l3d_error_log.txt"
## 内存中保留的最近行数（报错界面显示用；不写盘，避免刷屏）
const MAX_RECENT: int = 60
## 单条消息最大长度（防止某条超长堆栈把文件撑爆）
const MAX_LINE_LEN: int = 400

## ★写入节流（2026-10-02）："每帧都报同一条错"的场景下，**每条都开/关文件**会把帧率拖垮
## （实测联机回归因此大面积超时 → 假回归）。每秒最多写这么多条，被压掉的在下一窗口补一行汇总。
const MAX_WRITES_PER_SEC: int = 20

static var _recent: Array[String] = []
static var _session_started: bool = false
static var _error_count: int = 0
## 本会话是否已经成功解析出可写的盘上路径（给报错界面显示"日志在哪儿"）
static var _resolved_paths: Array[String] = []
static var _window_start_msec: int = 0
static var _window_writes: int = 0
static var _window_suppressed: int = 0


## 会话开始：写一段分隔头（版本 / 时间 / 平台），让多次运行的日志能分辨开。
## 由 `Global._ready()` 调用一次；重复调用只写一次。
static func begin_session(version: String) -> void:
	if _session_started:
		return
	_session_started = true
	_error_count = 0
	## 每次启动**清掉旧文件**再写头 —— 否则文件会无限增长，玩家发出来的也难读。
	## 保留上一轮的内容没有意义：玩家复现后要发的是"这一次"的日志。
	_write_line("=".repeat(60), true)
	_write_line("[启动] %s  版本 %s  平台 %s" % [
		Time.get_datetime_string_from_system(), version, OS.get_name()], true)
	_write_line("[启动] 日志路径：%s" % ", ".join(_target_paths()), true)
	_write_line("=".repeat(60), true)


## 记录一条**错误**（会同时进内存缓冲与盘上文件）。
static func log_error(tag: String, msg: String) -> void:
	_error_count += 1
	_write_line("[错误][%s] %s" % [tag, msg], false)


## 记录一条**关键事件**（卡墙自救、状态异常等；不是错误但排查时最有用）。
static func log_event(tag: String, msg: String) -> void:
	_write_line("[事件][%s] %s" % [tag, msg], false)


## 最近若干行（报错界面正文用）。
static func recent_lines() -> Array[String]:
	return _recent.duplicate()


## 本会话累计错误数（弹窗节流用）。
static func error_count() -> int:
	return _error_count


## 日志文件实际路径（第一个可写的）——报错界面显示给玩家。
static func primary_path() -> String:
	var paths: Array[String] = _target_paths()
	if paths.is_empty():
		return "(无法写入)"
	## exe 目录优先（玩家最好找），没有则 user://
	return paths[0]


## 已经确认可写的路径列表。
static func resolved_paths() -> Array[String]:
	return _resolved_paths.duplicate()


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

## 日志落点：exe 同目录（PC 优先）+ user://（兜底）。
## ⚠ 编辑器里**不写 exe 目录**（那会是 Godot 可执行文件所在目录，污染工具安装位置）。
static func _target_paths() -> Array[String]:
	var paths: Array[String] = []
	if not OS.has_feature("editor"):
		var exe_dir: String = OS.get_executable_path().get_base_dir()
		if not exe_dir.is_empty():
			paths.append(exe_dir.path_join(FILE_NAME))
	paths.append("user://" + FILE_NAME)
	return paths


## 追加一行。`truncate` = 会话头，需要覆盖写（见 begin_session 的说明）且**不受节流**。
static func _write_line(line: String, truncate: bool) -> void:
	var text: String = line
	if text.length() > MAX_LINE_LEN:
		text = text.substr(0, MAX_LINE_LEN) + "…(截断)"
	_recent.append(text)
	while _recent.size() > MAX_RECENT:
		_recent.pop_front()
	if not truncate and not _allow_write():
		return
	_do_write(text, truncate)


## 节流闸门：每 1 秒最多 `MAX_WRITES_PER_SEC` 条；被压掉的在下一窗口补一行汇总。
static func _allow_write() -> bool:
	var now: int = Time.get_ticks_msec()
	if now - _window_start_msec >= 1000:
		if _window_suppressed > 0:
			var n: int = _window_suppressed
			_window_suppressed = 0
			## 汇总行走 _do_write（不再过闸门），否则又会被自己压掉
			_do_write("[事件][日志] 上一秒另有 %d 条输出被省略（写入节流）" % n)
		_window_start_msec = now
		_window_writes = 0
	if _window_writes >= MAX_WRITES_PER_SEC:
		_window_suppressed += 1
		return false
	_window_writes += 1
	return true


## 真正落盘（两处路径都试；取不到就跳过，不做任何报错 —— 日志本身绝不能成为新的错误源）。
## `truncate` = 覆盖写（只有会话头用）。
static func _do_write(text: String, truncate: bool = false) -> void:
	_resolved_paths.clear()
	for p: String in _target_paths():
		var f: FileAccess = null
		if truncate:
			f = FileAccess.open(p, FileAccess.WRITE)
		else:
			f = FileAccess.open(p, FileAccess.READ_WRITE)
			if f == null:
				f = FileAccess.open(p, FileAccess.WRITE)
		if f == null:
			continue                      ## 移动端 exe 目录不可写 → 静默跳过（有 user:// 兜底）
		if not truncate:
			f.seek_end()
		f.store_line(text)
		f.close()
		_resolved_paths.append(p)
