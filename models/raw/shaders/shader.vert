#version 460

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_uv;

// layout(location = 0) out vec3 out_color;

void main() {
    gl_Position = vec4(in_position, 1.0);
}

