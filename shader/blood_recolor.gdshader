shader_type canvas_item;

// ── 血效色相替换（2026-11-10，直播和谐用）─────────────────────────────
// 只挂在「血」类特效（VXAnimSprite 里文件名带「血」的动画）上，不动枪口/爆炸/酸液。
// 做法：RGB → HSV，旋转色相 + 可选去饱和 —— 纯乘法做不到红→绿（红 × 绿 = 黑）。
//
// ★为什么用 varying 传 modulate：canvas_item 的 `COLOR` 在 fragment 入口**已经乘过
//   TEXTURE**（Godot 文档：COLOR = 顶点色 × 纹理色）。这里要自己采样纹理再换色，
//   若继续乘 `COLOR` 会把纹理乘两遍 → 整片发黑（实测踩过）。
//   正确做法：vertex 里把顶点色（modulate）存进 varying，fragment 用 v_modulate。
//
// 参数由 `script/vx_anim_sprite.gd::_apply_blood_censor()` 按 Global 设置写入：
//   绿 = hue +1/3，紫 = hue +0.78，灰 = saturation 0。

uniform float hue_shift : hint_range(-1.0, 1.0) = 0.0;
uniform float saturation_scale : hint_range(0.0, 2.0) = 1.0;
uniform float value_scale : hint_range(0.0, 2.0) = 1.0;

varying vec4 v_modulate;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 rgb = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return c.z * mix(vec3(1.0), rgb, c.y);
}

void vertex() {
	v_modulate = COLOR;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec3 hsv = rgb2hsv(tex.rgb);
	hsv.x = fract(hsv.x + hue_shift);
	hsv.y = clamp(hsv.y * saturation_scale, 0.0, 1.0);
	hsv.z = clamp(hsv.z * value_scale, 0.0, 1.0);
	COLOR = vec4(hsv2rgb(hsv), tex.a) * v_modulate;
}
