extends Logger

## ── 架构定位 ──
## 系统：诊断 ｜ 层：引擎钩子（Godot `Logger` 子类，由 `OS.add_logger()` 注册）
## 联机：不涉及（各端各自捕获）
## 职责：截获引擎的**错误**输出（GDScript 运行时错误 / push_error / 资源加载失败…），
##       落盘到报错文件，并把「值得给玩家看的」那条抛给报错界面。
## 依赖：GameLog（落盘）、ErrorScreen（展示，由 Global 连接本类的信号后创建）
##
## 【为什么用 Logger 而不是 try/catch】GDScript **没有异常机制** —— 脚本里的空引用、越界、
## 类型错误都由引擎直接打印到控制台，脚本层接不到。`OS.add_logger()` 是唯一能拿到这些输出的入口。
##
## 【用户需求（2026-10-02）】「正常游戏时报错 → 游戏画面暂停 + 半透明黑底报错界面 +
## 左下角提示把报错文件发到群里」。

signal error_captured(info: Dictionary)

## 不值得打扰玩家的引擎噪音（退出时的静态字符串/泄漏报告等）。
## ⚠ 加白名单要克制：宁可偶尔多弹一次，也不要把真错误吞掉。
const IGNORE_PATTERNS: Array[String] = [
	"Unreferenced static string",
	"ObjectDB instances leaked",
	"Leaked instance",
	"Object was freed",
	## 退出时的资源统计报告（与 ObjectDB 泄漏同属引擎收尾噪音；此时游戏已经在退出，
	## 弹窗没有任何意义，只会污染报错文件）。2026-10-04 跑回归用例时稳定复现。
	"resources still in use at exit",
]

## 日志落盘入口（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error —— 见 MEMORY「class_name 不跨文件」）。
const GAME_LOG := preload("res://script/game_log.gd")


## ⚠ 签名必须与引擎完全一致（Godot **4.6** 起尾部多了 `thread_id` 与 `backtrace` 两个参数；
## 少写一个就 Parse Error：`The function signature doesn't match the parent`）。
func _log_error(function: String, file: String, line: int, code: String,
		rationale: String, editor_notify: bool, thread_id: int,
		backtrace: Array[ScriptBacktrace]) -> void:
	## editor_notify 参数在导出版里恒为 false，仅供编辑器弹通知，这里不需要区分。
	_capture(function, file, line, code, rationale, backtrace)


## 普通 `print` / `printerr` 都会进这里。**只关心 error 标记的消息** ——
## 游戏本身会打印大量调试行，全写盘会把文件撑爆（用户要的是"报错文件"）。
func _log_message(message: String, error: bool) -> void:
	if not error:
		return
	_capture("", "", 0, "", message, [] as Array[ScriptBacktrace])


func _capture(function: String, file: String, line: int, code: String, rationale: String,
		backtrace: Array[ScriptBacktrace] = []) -> void:
	var text: String = rationale if not rationale.is_empty() else code
	if text.is_empty():
		return
	for pat: String in IGNORE_PATTERNS:
		if text.contains(pat):
			return
	## 位置信息（`文件:行 @ 函数`）——用户原话「比如哪里的代码错误那些」，这是他最想要的。
	var where: String = ""
	if not file.is_empty():
		where = "%s:%d" % [file.get_file(), line]
		if not function.is_empty():
			where += " @ %s" % function
	else:
		where = "(引擎消息)"
	GAME_LOG.log_error("引擎", "%s │ %s" % [text, where])
	## 调用栈（Godot 4.6 的 `_log_error` 会带 backtrace）——"哪一行调过来的"往往才是玩家
	## 最需要的信息。⚠ 用 `has_method` 探测而不是直接点方法名：各版本 API 有出入，
	## 探测失败最多是栈少几行，绝不能让"记录错误"这件事本身再抛一个错误。
	var stack_lines: Array[String] = _format_backtrace(backtrace)
	for sl: String in stack_lines:
		GAME_LOG.log_event("堆栈", sl)
	error_captured.emit({
		"message": text,
		"where": where,
		"function": function,
		"file": file,
		"line": line,
		"code": code,
		"stack": stack_lines,
	})


func _format_backtrace(backtrace: Array[ScriptBacktrace]) -> Array[String]:
	var out: Array[String] = []
	if backtrace.is_empty():
		return out
	var bt: Variant = backtrace[0]
	if bt == null or not (bt is Object) or not (bt as Object).has_method("format"):
		return out
	var formatted: String = str((bt as Object).call("format"))
	for raw: String in formatted.split("\n"):
		var trimmed: String = raw.strip_edges()
		if trimmed.is_empty():
			continue
		out.append(trimmed)
		if out.size() >= 6:
			break
	return out
