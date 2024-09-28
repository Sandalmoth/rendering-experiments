#version 460

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_uv;

struct IndirectMetadata {
    mat4 mvp;
};
layout(std140, binding = 0) readonly buffer metadata {
    IndirectMetadata data[];
};

layout(location = 0) out vec3 out_normal;

void main() {
    mat4 mvp = data[gl_DrawID].mvp;
    gl_Position = mvp * vec4(in_position, 1.0);
    out_normal = in_normal;
}

