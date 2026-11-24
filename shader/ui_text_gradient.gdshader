shader_type canvas_item;

// ── 界面文字渐变（2026-11-17）──
// 参考《索尼克》风格 UI：文字顶部纯白、底部转淡蓝，外圈黑色描边。
//
// 【为什么用「乘顶点色」而不是判断描边】
// Godot 的 Label 把填充与描边分成两次绘制：填充用 font_color、描边用 font_outline_color。
// 因此本 shader 只做 `渐变 × 顶点色`：
//   · 填充层顶点色 = 白 → 完整渐变；
//   · 描边层顶点色 = 黑 → 乘出来仍是纯黑，描边不会被渐变染色。
// 这样无需任何分支判断，也不会因为「深色文字」被误判成描边。
//
// 【渐变坐标】VERTEX 是 Label 的本地坐标（左上为原点、y 向下），
// 除以 text_height 得到 0~1 的纵向比例；每个字形四边形的顶点都落在真实高度上，
// 所以跨字形的插值是连续的（不是每个字各渐变一次）。
//
// ★2026-11-24：多行文本改为**每行各自一段渐变** —— `line_height > 0` 时用
//   `mod(VERTEX.y, line_height)` 把每行重新映射到 0~1，第一行白→蓝、第二行又从白开始。
//   旧做法（2026-11-23）是整段归一化（第一行白、最后一行全蓝），当时干脆给多行撤了材质；
//   用户要的是每行单独渐变，所以这里补上行内归一化。单行传 line_height=0，行为不变。

uniform vec4 top_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.58, 0.76, 1.0, 1.0);
// 文本块高度（像素）：由调用方按字号 × 行数传入，用于把 VERTEX.y 归一化。
uniform float text_height = 32.0;
// 单行高度（像素）：>0 = 每行各自一段渐变（多行文本）；0 = 整段一段渐变（单行）。
uniform float line_height = 0.0;
// 从多少比例开始往底部颜色过渡（0 = 一开头就渐变，1 = 全白）。
uniform float pivot : hint_range(0.0, 1.0) = 0.35;

varying float v_t;

void vertex() {
	float y = VERTEX.y;
	float span = text_height;
	if (line_height > 0.5) {
		span = line_height;
		// 负值（描边扩出去的上缘）与行内下缘都夹到本行 0~1。
		y = mod(max(y, 0.0), line_height);
	}
	v_t = clamp(y / max(span, 1.0), 0.0, 1.0);
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float k = smoothstep(pivot, 1.0, v_t);
	vec3 grad = mix(top_color.rgb, bottom_color.rgb, k);
	// 与默认 canvas_item 着色一致：rgb 乘纹理再乘顶点色，a 同样相乘。
	COLOR = vec4(grad * tex.rgb * COLOR.rgb, tex.a * COLOR.a);
}
