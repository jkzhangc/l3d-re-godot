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

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;

	// 对比度（绕 0.5 枢轴）
	c = (c - 0.5) * contrast + 0.5;
	// 亮度
	c *= brightness;
	// 饱和度（按亮度加权）
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(lum), c, saturation);
	// 染色（乘法）并按强度与原画面混合
	vec3 tinted = c * tone_color.rgb;
	c = mix(c, tinted, intensity * tone_color.a);

	COLOR = vec4(clamp(c, vec3(0.0), vec3(1.0)), 1.0);
}
