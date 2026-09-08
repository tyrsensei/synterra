shader_type spatial;
render_mode unshaded;

uniform bool use_billboard = true;
uniform vec4 color : source_color = vec4(0.1, 0.8, 0.1, 1.0);
uniform vec4 background_color : source_color = vec4(0.2, 0.0, 0.0, 1.0);
instance uniform float health : hint_range(0.0, 1.0) = 1.0;

void vertex() {
	// Called for every vertex the material is visible on.
	if (use_billboard) {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
}

void fragment() {
	// Called for every pixel the material is visible on.
	ALBEDO = UV.x < health ? color.rgb : background_color.rgb;
	ALPHA = UV.x < health ? color.a : background_color.a;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
