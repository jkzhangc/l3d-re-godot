shader_type canvas_item;

// ── 夜间视界 · 黑幕（采样光照缓冲） ──
// 原工程在 @viewport2 用 light.png 挖黑暗；这里等价：先把所有灯的可见范围
// 画进 SubViewport（加法累加），再用本 pass 把"亮度"翻成"不透明度"。
//
// light_tex: 光照缓冲。rgb = 光色 × 强度 × 径向衰减（可能 >1，HDR）。
uniform sampler2D light_tex : filter_linear, repeat_disable;
uniform float darkness : hint_range(0.0, 1.0) = 0.85;
uniform float flash_strength : hint_range(0.0, 1.0) = 0.0;
// 阴影柔化半径（单位 = 光照缓冲的 texel）。缓冲本身是半分辨率，再叠 4 个偏移采样。
uniform float softness : hint_range(0.0, 4.0) = 1.0;

float sample_lit(vec2 uv) {
	vec3 c = texture(light_tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
	return clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0);
}

void fragment() {
	float lit = sample_lit(UV);
	if (softness > 0.01) {
		vec2 o = SCREEN_PIXEL_SIZE * 2.0 * softness;
		lit += sample_lit(UV + vec2(o.x, 0.0));
		lit += sample_lit(UV - vec2(o.x, 0.0));
		lit += sample_lit(UV + vec2(0.0, o.y));
		lit += sample_lit(UV - vec2(0.0, o.y));
		lit /= 5.0;
	}
	float a = darkness * (1.0 - lit) - flash_strength;
	COLOR = vec4(0.015, 0.015, 0.04, clamp(a, 0.0, 1.0));
}
