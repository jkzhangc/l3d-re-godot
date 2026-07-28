shader_type canvas_item;

// Debug shader — ignores color sheet, outputs UV.y as vertical gradient.
// Top of text = red, bottom = blue. If you see flat purple, UV.y is broken.
// If you see a red→blue gradient, UV works but color sheet sampling is wrong.

void fragment() {
	vec4 glyph = texture(TEXTURE, UV);
	// Top=red (1,0,0), bottom=blue (0,0,1)
	vec3 rgb = vec3(1.0 - UV.y, 0.0, UV.y);
	COLOR = vec4(rgb * COLOR.rgb, glyph.a * COLOR.a);
}
