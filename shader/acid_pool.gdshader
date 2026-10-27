shader_type canvas_item;

// ── 架构定位 ──
// 系统：投掷物表现 ｜ 层：着色器（canvas_item）
// 职责：**纯程序化**强酸液面 —— 没有酸池美术素材时用它模拟"地上一滩强酸"。
// 依赖：script/fx/acid_pool_visual.gd（一个正方形 ColorRect 承载本材质）
//
// 【为什么是着色器而不是贴图（2026-10-27 用户定稿）】
// 项目里现成的酸动画（art/Animations/酸だー！.png / Acid！.png）是**命中特效**，
// 不是"地上一滩液体"的素材，直接铺在地面不像酸池。着色器可以按 UV 生成
// 不规则液面轮廓 + 表面流动 + 冒泡 + 泛光，且尺寸/半径随投掷物参数缩放，零素材成本。
//
// 【坐标】UV 0..1 覆盖正方形；液体边界在 d≈1（内切圆）。四角恒为全透明。
// 所有 uniform 由 acid_pool_visual.gd 注入；不直接暴露给 .tres。

uniform vec4 acid_core : source_color = vec4(0.26, 0.92, 0.16, 1.0);   // 液面主色
uniform vec4 acid_deep : source_color = vec4(0.06, 0.42, 0.05, 1.0);   // 液面暗部（厚处）
uniform vec4 acid_rim : source_color = vec4(0.78, 1.0, 0.42, 1.0);     // 边缘高光 / 气泡
uniform vec4 acid_glow : source_color = vec4(0.34, 1.0, 0.24, 1.0);    // 外圈光晕
uniform float pool_scale : hint_range(0.5, 1.0) = 0.84;                // 液面半径（相对内切圆）
uniform float seed : hint_range(0.0, 100.0) = 0.0;                     // 每个酸池的随机相位
uniform float glow_strength : hint_range(0.0, 1.0) = 0.35;             // 外圈光晕强度
uniform float opacity : hint_range(0.0, 1.0) = 0.75;                   // 整体不透明度

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(p);
		p *= 2.03;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 uv = UV - 0.5;
	float d = length(uv) * 2.0;   // 0 = 中心，1 = 内切圆边缘

	// ① 不规则轮廓：低频噪声让边缘缓慢"呼吸/蠕动"，避免完美圆。
	float wobble = (fbm(uv * 3.2 + vec2(seed, TIME * 0.07)) - 0.5) * 0.18;
	float edge = pool_scale + wobble;

	// ② 液面遮罩（软边）。四角恒为全透明。
	float inside = smoothstep(edge, edge - 0.06, d);
	float halo = smoothstep(edge + 0.18, edge - 0.02, d) * (1.0 - inside);

	// ⚠ Godot 4 的 shader 语言**不允许 fragment 里 return**（实测：
	// "Using 'return' in the 'fragment' processor function is incorrect."）
	// → 液面内外用 if/else 分段着色。
	if (inside > 0.001) {
		// ③ 表面流动：两层不同速度的噪声 → 腐蚀斑驳 + 缓慢翻滚
		float flow_a = fbm(uv * 5.5 + vec2(TIME * 0.11, -TIME * 0.08) + seed);
		float flow_b = fbm(uv * 11.0 - vec2(TIME * 0.07, TIME * 0.13) + seed * 1.7);
		float surface = clamp(flow_a * 0.65 + flow_b * 0.35, 0.0, 1.0);
		// 拉开对比：fbm 的均值集中在 0.5 附近，直接 mix 会显得死平；
		// 用 smoothstep 把中间调压成"亮块 / 暗块"，才像液体在翻。
		float mottle = smoothstep(0.30, 0.76, surface);

		// ④ 液面配色：噪声直接驱动"亮酸 ↔ 暗酸"，做出肉眼可见的斑驳（不能只做微调，
		//    否则整滩会是一块死平的绿色贴片）。
		vec3 liquid = mix(acid_deep.rgb * 1.35, acid_core.rgb, 0.12 + mottle * 0.88);
		// 越靠中心越"厚"（略暗），边缘被光穿透更亮 —— 别压太狠，否则中间像挖了个洞
		float depth_light = mix(0.86, 1.10, smoothstep(0.0, edge, d));
		liquid *= depth_light;
		// 细碎腐蚀点：高频噪声阈值 → 一小粒一小粒的暗斑
		float specks = smoothstep(0.74, 0.92, fbm(uv * 26.0 + vec2(TIME * 0.05, seed)));
		liquid = mix(liquid, acid_deep.rgb * 0.55, specks * 0.55);

		// ⑤ 边缘结构：内侧阴影带（液体厚度）→ 亮边（表面张力）→ 外侧湿边
		float inner_shadow = smoothstep(edge - 0.20, edge - 0.05, d)
			* (1.0 - smoothstep(edge - 0.05, edge - 0.01, d));
		float rim = smoothstep(edge - 0.055, edge - 0.022, d)
			* (1.0 - smoothstep(edge - 0.018, edge + 0.004, d));
		float wet_edge = (1.0 - smoothstep(edge, edge + 0.05, d)) * smoothstep(edge + 0.02, edge, d);
		liquid = mix(liquid, acid_deep.rgb * 0.45, inner_shadow * 0.65);
		liquid = mix(liquid, acid_rim.rgb * 1.25, rim * 0.95);
		liquid = mix(liquid, acid_deep.rgb * 0.6, wet_edge * 0.4);

		// ⑥ 气泡：8 个固定位置的气泡周期性膨胀→破裂；越接近破裂越淡
		float bubbles = 0.0;
		float bubble_cores = 0.0;
		for (int i = 0; i < 8; i++) {
			float fi = float(i);
			vec2 c = (vec2(hash21(vec2(fi, seed + 1.7)), hash21(vec2(fi + 5.3, seed + 9.1))) - 0.5)
				* (edge * 1.1);
			float rate = 0.20 + 0.18 * hash21(vec2(fi + 2.9, seed));
			float phase = fract(TIME * rate + hash21(vec2(fi + 7.7, seed)));
			float r = mix(0.010, 0.070, phase);
			float bd = length(uv - c);
			float ring = smoothstep(r, r - 0.009, bd) - smoothstep(r * 0.62, r * 0.62 - 0.009, bd);
			float core = smoothstep(r * 0.55, r * 0.2, bd);
			float pop = 1.0 - smoothstep(0.72, 1.0, phase);   // 破裂瞬间淡出
			// 只在液面内可见
			float mask = smoothstep(edge, edge - 0.05, length(c) * 2.0 + r);
			bubbles += ring * pop * mask;
			bubble_cores += core * pop * mask;
		}
		bubbles = clamp(bubbles, 0.0, 1.0);
		bubble_cores = clamp(bubble_cores, 0.0, 1.0);
		liquid = mix(liquid, acid_rim.rgb * 1.35, bubbles * 0.85);
		liquid = mix(liquid, acid_deep.rgb * 0.5, bubble_cores * 0.35);

		float alpha = (inside * 0.62 + rim * 0.35 + bubbles * 0.45 + halo * glow_strength * 0.5)
			* opacity;
		vec3 out_col = mix(acid_glow.rgb, liquid, inside);
		COLOR = vec4(out_col, clamp(alpha, 0.0, 0.96));
	} else {
		// 液面外：只留一圈很淡的荧光。
		COLOR = vec4(acid_glow.rgb, clamp(halo * glow_strength * 0.35 * opacity, 0.0, 0.5));
	}
}
