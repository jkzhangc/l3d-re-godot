shader_type canvas_item;
render_mode unshaded;

// ── 画面色调后处理 ──
// 采样当前屏幕内容 → 亮度/对比度/饱和度/染色 → 再画回去。
//
// ★为什么天然不含 UI：hint_screen_texture 取的是「**已经画完**的屏幕内容」，
//   而绘制顺序按 CanvasLayer.layer 从小到大。把挂了本材质的 ColorRect 放在
//   世界(layer 0)之上、UI(90+)之下（默认 50），采样时 UI 还没画 → 不会被染色。
//   UI 层不需要任何额外处理；若要排除**低于**色调层的个别层，用节点上的
//   excluded_nodes 参数把它们抬到色调层之上。

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

// 目标色调（乘法）。白 = 不变；分量 >1 提亮；alpha 参与强度计算。
uniform vec4 tone_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// 与原始画面的混合强度：0 = 完全无效果，1 = 完全套用色调。
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

uniform float brightness : hint_range(0.0, 2.0) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float contrast : hint_range(0.0, 2.0) = 1.0;

// ── 亮度保护（2026-10-21）──
// 色调层在世界之上，采样的是「已经包含 2D 灯光」的画面。夜图用蓝色调压暗时，
// 火光/路灯光也被一起乘蓝、一起压暗 —— 暖橙会变成脏蓝，亮度也会掉一截。
// 这里按「原始亮度」给色调降低权重：够亮的像素（被灯照到）少染色，暗处照常染。
//   0 = 完全不管（旧行为，默认）
//   1 = 亮部完全不吃色调，只有暗部染
uniform float light_protect : hint_range(0.0, 1.0) = 0.0;
// 保护起止亮度：低于 lo 全染，高于 hi 全保护，中间平滑过渡。
uniform float protect_lo : hint_range(0.0, 1.0) = 0.30;
uniform float protect_hi : hint_range(0.0, 1.0) = 0.70;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	// 进入任何调整前的原始亮度 —— 用它判断"这里是否被灯照亮"。
	float raw_lum = dot(c, vec3(0.299, 0.587, 0.114));
	float protect = light_protect * smoothstep(protect_lo, protect_hi, raw_lum);

	// 对比度（绕 0.5 枢轴）
	c = (c - 0.5) * contrast + 0.5;
	// 亮度
	c *= brightness;
	// 饱和度（按亮度加权）
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(lum), c, saturation);
	// 染色（乘法）并按强度与原画面混合；亮部按 protect 减少染色量
	vec3 tinted = c * tone_color.rgb;
	c = mix(c, tinted, intensity * tone_color.a * (1.0 - protect));

	COLOR = vec4(clamp(c, vec3(0.0), vec3(1.0)), 1.0);
}
