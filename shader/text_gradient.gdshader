shader_type canvas_item;

// RM2K3 style vertical text gradient shader.
// Maps per-glyph UV.y to a gradient texture column for
// the classic RPG Maker light-top / dark-bottom text look.

uniform sampler2D gradient_tex : source_color, filter_nearest;

void fragment() {
	// Original glyph alpha from the font atlas, vertex color (modulate / font_color)
	vec4 text = texture(TEXTURE, UV);

	// Sample gradient: UV.y=0 (glyph top) -> gradient top row
	// The gradient texture is 32x32; sample from center column (x=0.5)
	// to avoid potential transparent edges
	vec4 grad = texture(gradient_tex, vec2(0.5, UV.y));

	// Multiply gradient by vertex COLOR so font_color / modulate
	// can tint the text — keeps gradient look while allowing color control
	COLOR = vec4(grad.rgb * COLOR.rgb, text.a * COLOR.a);
}
