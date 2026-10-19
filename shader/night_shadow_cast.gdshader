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
uniform float fade_near : hint_range(0.0, 1.0) = 0.45;
uniform float fade_far : hint_range(0.0, 1.0) = 0.0;
uniform float sprite_height : hint_range(1.0, 256.0) = 64.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	// 脚底（y=0）→ 1，头顶/远端（y=-h）→ 0
	float t = clamp(VERTEX.y / max(sprite_height, 1.0) + 1.0, 0.0, 1.0);
	// 二次方让"靠近脚底"的一段更实，远端收得更快，像被拉长的影子而不是模糊块。
	c.a *= mix(fade_far, fade_near, t * t * (3.0 - 2.0 * t));
	COLOR = c;
}
