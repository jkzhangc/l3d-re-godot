shader_type canvas_item;

// Flat text color + optional outline.
// Color is sampled on CPU from the 20-color sheet and passed via uniform.

uniform vec4 text_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool outline_enabled = false;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec4 glyph = texture(TEXTURE, UV);

	// Default
	COLOR = vec4(text_color.rgb * COLOR.rgb, glyph.a * COLOR.a);

	// Outline
	if (outline_enabled && glyph.a < 0.5) {
		vec2 ts = 1.0 / vec2(textureSize(TEXTURE, 0));
		float n = 0.0;
		n = max(n, texture(TEXTURE, UV + vec2(-1, -1) * ts).a);
		n = max(n, texture(TEXTURE, UV + vec2( 0, -1) * ts).a);
		n = max(n, texture(TEXTURE, UV + vec2( 1, -1) * ts).a);
		n = max(n, texture(TEXTURE, UV + vec2(-1,  0) * ts).a);
		n = max(n, texture(TEXTURE, UV + vec2( 1,  0) * ts).a);
		n = max(n, texture(TEXTURE, UV + vec2(-1,  1) * ts).a);
		n = max(n, texture(TEXTURE, UV + vec2( 0,  1) * ts).a);
		n = max(n, texture(TEXTURE, UV + vec2( 1,  1) * ts).a);
		if (n > 0.5) {
			COLOR = vec4(outline_color.rgb * COLOR.rgb, outline_color.a * COLOR.a);
		}
	}
}
