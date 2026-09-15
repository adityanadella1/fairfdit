#include <flutter/runtime_effect.glsl>

// One Jacobi diffusion step: every pixel inside the mask becomes the
// average of its 4 neighbors from the PREVIOUS iteration; everything
// outside the mask passes through unchanged. Run many times in sequence
// (see HealEngine), this converges toward a smooth harmonic fill of the
// masked region — the classic pre-AI "heal" technique, mathematically
// equivalent to solving Laplace's equation with the surrounding pixels
// as boundary conditions.
uniform vec2 uSize;
uniform sampler2D uSource;
uniform sampler2D uMask;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float m = texture(uMask, uv).r;

  if (m < 0.5) {
    fragColor = texture(uSource, uv);
    return;
  }

  vec2 texel = 1.0 / uSize;
  vec3 sum = vec3(0.0);
  sum += texture(uSource, uv + vec2(texel.x, 0.0)).rgb;
  sum += texture(uSource, uv - vec2(texel.x, 0.0)).rgb;
  sum += texture(uSource, uv + vec2(0.0, texel.y)).rgb;
  sum += texture(uSource, uv - vec2(0.0, texel.y)).rgb;
  fragColor = vec4(sum / 4.0, 1.0);
}
