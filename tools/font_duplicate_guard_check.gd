extends Node

## 字体安全静态守卫：`script/` 下禁止「对同一份字体数据造第二个 FontFile」。
##
## 入口：godot --headless --path <项目> res://tools/font_duplicate_guard_check.tscn
## 退出码：0 = 通过；1 = 发现违规（逐条打印 `文件:行` 与命中的代码行）。
##
## 【为什么需要这道守卫（2026-11-04 玩家大面积「字体错乱」）】
## `FontFile.duplicate()` 造出的是**第二份 FontFile**：它与基字体共享字形图集，
## 却各自维护一份占用表。基字体之后栅格化的字形（菜单/剧情里的中文）会覆盖副本
## 已占用的区域，而屏幕上**已经发出的绘制指令仍指向那块 UV** ——
## 画面上数字就变成字母、字母变成数字，重绘一次还可能换成另一种。
## 可以稳定复现，不是玄学；机理与复现步骤见 `script/ui/combat_hud.gd` 顶部的 ★ 段落。
##
## 正确做法：需要「加兜底链 / 加变体」时用 `FontVariation`（只包装 `base_font`，
## 自己不持有图集），栅格化参数一律由基字体（`Global.get_ui_font()` 已过
## `make_pixel_crisp()`）决定。
##
## 【判定规则】只看**代码**，注释与字符串里的反例不会误报：
##   ① `duplicate()` 结果被当作 FontFile（`as FontFile` / 赋给 `FontFile` 类型变量）
##   ② 任意「名字里带 font」的对象上调用 `duplicate()`（`base.duplicate()` 这种写法由 ① 兜）
##   ③ `FontFile.new()` —— 运行时新建 FontFile 只能靠塞 data 才有字形，等于重造第二份
## 例外：同一行写 `font-guard-allow` 注释可豁免，需在 commit 说明理由。
##
## 只扫 `script/`（真正打进出包的部分）。`tools/` 是临时探针，允许自由试验。

const SCAN_ROOT: String = "res://script"
const ALLOW_MARKER: String = "font-guard-allow"

## 每条规则 = 名称 + 正则 + 给改动者的说明。
const RULES: Array[Dictionary] = [
	{
		"name": "duplicate→FontFile",
		"pattern": "duplicate\\s*\\(\\s*\\)\\s*as\\s+FontFile",
		"hint": "改成 FontVariation.new() + base_font = <基字体>",
	},
	{
		"name": "FontFile 变量 = *.duplicate()",
		"pattern": ":\\s*FontFile\\s*=.*\\.\\s*duplicate\\s*\\(",
		"hint": "改成 FontVariation.new() + base_font = <基字体>",
	},
	{
		"name": "字体对象.duplicate()",
		"pattern": "(?i)\\w*font\\w*\\s*\\.\\s*duplicate\\s*\\(",
		"hint": "字体不做副本；兜底链用 FontVariation.fallbacks",
	},
	{
		"name": "FontFile.new()",
		"pattern": "\\bFontFile\\s*\\.\\s*new\\s*\\(",
		"hint": "运行时不要新建 FontFile；要变体请用 FontVariation",
	},
]

var _checks: int = 0
var _failures: int = 0
var _scanned: int = 0
var _violations: Array[String] = []
## 与 RULES 同下标的已编译正则（const Dictionary 是只读的，不能把 RegEx 塞回去）。
var _regexes: Array[RegEx] = []


func _ready() -> void:
	for rule: Dictionary in RULES:
		_regexes.append(RegEx.create_from_string(rule["pattern"] as String))
	_walk(SCAN_ROOT)

	_check(_scanned > 0, "扫描到 .gd 文件 %d 个（%s）" % [_scanned, SCAN_ROOT])
	for line: String in _violations:
		printerr("[FONT_GUARD] ★ %s" % line)
	_check(_violations.is_empty(), "无「第二份 FontFile」写法（违规 %d 处）" % _violations.size())
	print("FONT_DUPLICATE_GUARD total=%d passed=%d failed=%d" % [
		_checks, _checks - _failures, _failures])
	get_tree().quit(1 if _failures > 0 or _checks == 0 else 0)


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("FONT_DUPLICATE_GUARD %s %s" % ["PASS" if ok else "FAIL", label])


func _walk(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		printerr("[FONT_GUARD] 打不开目录: %s" % dir_path)
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			_walk(full)
		elif entry.ends_with(".gd"):
			_scan_file(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _scan_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("[FONT_GUARD] 读不了: %s" % path)
		return
	_scanned += 1
	var line_no: int = 0
	while not file.eof_reached():
		var raw: String = file.get_line()
		line_no += 1
		if raw.contains(ALLOW_MARKER):
			continue
		var code: String = _strip_comment(raw)
		if code.strip_edges().is_empty():
			continue
		for i: int in range(RULES.size()):
			if _regexes[i].search(code) != null:
				var rule: Dictionary = RULES[i]
				_violations.append("%s:%d [%s] %s —— %s" % [
					path, line_no, rule["name"], raw.strip_edges(), rule["hint"]])
	file.close()


## 去掉行尾注释（认识单/双引号，字符串里的 `#` 不当注释）。
## 只需处理单行；GDScript 没有块注释。
func _strip_comment(line: String) -> String:
	var out: String = ""
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var ch: String = line[i]
		if not quote.is_empty():
			out += ch
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
			out += ch
		elif ch == "#":
			break
		else:
			out += ch
		i += 1
	return out
