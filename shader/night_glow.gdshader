shader_type canvas_item;
render_mode blend_add, unshaded;

// ── 夜间视界 · 发光（采样光照缓冲 + 加法合成） ──
// 对应原工程 @viewport1 的 light-illum.png：颜色直接来自缓冲，所以火是暖橙、
// 冷光偏蓝，不需要第二套每灯颜色表。
uniform sampler2D light_tex : filter_linear, repeat_disable;
uniform float glow_strength : hint_range(0.0, 2.0) = 0.5;

void fragment() {
	vec3 c = texture(light_tex, UV).rgb;
	// 指数色调映射：亮度给到 3~4 也不会爆成纯白，保留火焰的橙色。
	c = vec3(1.0) - exp(-c * glow_strength);
	COLOR = vec4(c, 1.0);
}
