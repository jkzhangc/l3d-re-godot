shader_type canvas_item;
render_mode unshaded;

// ── 角色投影（拖影） ──
// 参考 RGD Lighting 的 <effect> "CharacterShadow"：影子不是"深色的另一个角色"，
// 而是沿光线方向拉长、并且从脚底往远端逐渐变淡的拖影。
//
// 统一变量（每帧由 NightOverlay 写入）：
//   fade_near: 脚底端的不透明度
//   fade_far:  远端的不透明度（通常接近 0，形成自然的消隐）
//   sprite_height: 精灵单帧高度（VERTEX 是本地像素坐标，范围 -h..0）
//
// ── 距离羽化（2026-10-21）──
// 需求："越远的影子越模糊，像现实里的半影；像素小人剪影的边缘也别那么硬"。
//   blur_px  : 当前模糊半径（贴图像素），由 GDScript 按离灯距离写进来
//   tex_size : 单帧像素尺寸，用来把 blur_px 换算成 UV 偏移
//   uv_bounds: 该帧在图集里的 UV 范围；**必须夹住采样**，否则精灵是 region 切图时
//              会从相邻帧取到 alpha，影子边缘会冒出一圈杂边
// 注意：采样一律写在 fragment() 里 —— Godot 的自定义函数不保证能拿到 TEXTURE/UV。
uniform float fade_near : hint_range(0.0, 1.0) = 0.45;
uniform float fade_far : hint_range(0.0, 1.0) = 0.0;
uniform float sprite_height : hint_range(1.0, 256.0) = 64.0;
uniform float blur_px : hint_range(0.0, 6.0) = 0.0;
uniform vec2 tex_size = vec2(48.0, 64.0);
uniform vec4 uv_bounds = vec4(0.0, 0.0, 1.0, 1.0);

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;

	// 5 点、**中心权重 4/8** 的柔化：只把边缘带出不到 1px 的过渡，
	// 剪影主体保持实心。用 9 点等权均值时整块会一起发灰，看着像抹了一把脏 —— 已废弃。
	vec2 lo = uv_bounds.xy;
	vec2 hi = uv_bounds.zw;
	float a = c.a;
	if (blur_px > 0.01) {
		vec2 d = vec2(blur_px) / max(tex_size, vec2(1.0));
		float sum = c.a * 4.0;
		sum += texture(TEXTURE, clamp(UV + vec2( d.x, 0.0), lo, hi)).a;
		sum += texture(TEXTURE, clamp(UV + vec2(-d.x, 0.0), lo, hi)).a;
		sum += texture(TEXTURE, clamp(UV + vec2(0.0,  d.y), lo, hi)).a;
		sum += texture(TEXTURE, clamp(UV + vec2(0.0, -d.y), lo, hi)).a;
		a = sum / 8.0;
	}

	// 脚底（y=0）→ 1，头顶/远端（y=-h）→ 0
	float t = clamp(VERTEX.y / max(sprite_height, 1.0) + 1.0, 0.0, 1.0);
	// 二次方让"靠近脚底"的一段更实，远端收得更快，像被拉长的影子而不是模糊块。
	a *= mix(fade_far, fade_near, t * t * (3.0 - 2.0 * t));
	c.a = a;
	COLOR = c;
}
