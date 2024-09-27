#version 460

layout(location = 0) in vec3 in_normal;

layout(location = 0) out vec4 out_color;

void main() {
    float angle = dot(in_normal, vec3(0.0, 1.0, 0.0));
    out_color = vec4(0.0, 1.0, angle, 1.0);
}
