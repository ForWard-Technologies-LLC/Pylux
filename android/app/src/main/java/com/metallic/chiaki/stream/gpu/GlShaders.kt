// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

import android.content.res.AssetManager
import android.opengl.GLES31
import java.util.Locale

/** Thrown for shader compile failures, program link failures and an unexpected SGSR1 asset. */
class ShaderCompileException(message: String): RuntimeException(message)

/** Compiles the programs used by [GpuVideoRenderer]. Call on the render thread with a GLES 3.1 context current. */
object GlShaders
{
	/** Full-screen triangle from gl_VertexID; no vertex buffers needed. Output name matches SGSR1's input. */
	internal const val VERTEX_SRC = """#version 310 es
out highp vec4 in_TEXCOORD0;
void main()
{
	vec2 pos = vec2(float((gl_VertexID & 1) << 2) - 1.0, float((gl_VertexID & 2) << 1) - 1.0);
	in_TEXCOORD0 = vec4(pos * 0.5 + 0.5, 0.0, 0.0);
	gl_Position = vec4(pos, 0.0, 1.0);
}
"""

	/** Copies the decoder's external texture into a plain RGBA8 texture, honouring the SurfaceTexture transform. */
	internal const val OES_COPY_FRAG_SRC = """#version 310 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
uniform samplerExternalOES uTex;
uniform highp mat4 uTransform;
in highp vec4 in_TEXCOORD0;
out vec4 fragColor;
void main()
{
	highp vec2 tc = (uTransform * vec4(in_TEXCOORD0.xy, 0.0, 1.0)).xy;
	fragColor = vec4(texture(uTex, tc).rgb, 1.0);
}
"""

	/**
	 * HDR variant of the copy: HEVC Main10 frames arrive as 10-bit BT.2020 Y'CbCr. The implicit
	 * samplerExternalOES conversion is driver-defined for that case, so the raw Y'CbCr is read through
	 * GL_EXT_YUV_target and converted explicitly (BT.2020 non-constant luminance, limited range). The
	 * result stays PQ-encoded; it is written to an RGBA16F ring slot and later to a BT.2020 PQ window.
	 */
	internal const val OES_COPY_HDR_FRAG_SRC = """#version 310 es
#extension GL_EXT_YUV_target : require
precision highp float;
uniform __samplerExternal2DY2YEXT uTex;
uniform highp mat4 uTransform;
in highp vec4 in_TEXCOORD0;
out vec4 fragColor;
void main()
{
	highp vec2 tc = (uTransform * vec4(in_TEXCOORD0.xy, 0.0, 1.0)).xy;
	vec3 yuv = texture(uTex, tc).xyz;
	// 10-bit limited range: Y' 64..940, Cb/Cr 64..960 (of 1023), centred on 512.
	float y = (yuv.x - 64.0 / 1023.0) * (1023.0 / 876.0);
	float u = (yuv.y - 512.0 / 1023.0) * (1023.0 / 896.0);
	float v = (yuv.z - 512.0 / 1023.0) * (1023.0 / 896.0);
	vec3 rgb = vec3(y + 1.4746 * v, y - 0.164553 * u - 0.571353 * v, y + 1.8814 * u);
	fragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
"""

	/** Bilinear blit used when SGSR upscaling is off. Uniform name matches SGSR1 so the renderer treats both alike. */
	internal const val BLIT_FRAG_SRC = """#version 310 es
precision mediump float;
uniform mediump sampler2D ps0;
in highp vec4 in_TEXCOORD0;
out vec4 fragColor;
void main()
{
	fragColor = vec4(texture(ps0, in_TEXCOORD0.xy).rgb, 1.0);
}
"""

	/**
	 * Luma of a ring slot into a padded R8 texture for the motion estimator. The target may be larger
	 * than the stream (rounded up to the search block); `uScale` = stream / padded size, so the frame
	 * stays 1:1 and the padding replicates the edge through CLAMP_TO_EDGE.
	 */
	internal const val LUMA_FRAG_SRC = """#version 310 es
precision mediump float;
uniform mediump sampler2D ps0;
uniform highp vec2 uScale;
in highp vec4 in_TEXCOORD0;
out vec4 fragColor;
void main()
{
	highp vec2 uv = in_TEXCOORD0.xy / uScale;
	float y = dot(texture(ps0, uv).rgb, vec3(0.2126, 0.7152, 0.0722));
	fragColor = vec4(y, 0.0, 0.0, 1.0);
}
"""

	/**
	 * Midpoint interpolation between the older frame A and the newer frame B from two block motion
	 * fields (A→B and B→A, in pixels, sampled bilinearly). Each field gives one candidate pair: the
	 * samples half a step back and forward along its vector. Where the better pair agrees (the vector
	 * really tracked that content) its two samples are averaged, which is sharp because they match.
	 * Where neither pair agrees, the block vector is wrong or the area is being covered or revealed,
	 * and averaging would paint a double image, so the pixel is taken from the newer real frame
	 * instead: that region moves a half step unevenly, which the eye tolerates far better than a ghost.
	 * The hand-over is a smoothstep on the disagreement so there are no hard seams.
	 */
	internal const val WARP_FRAG_SRC = """#version 310 es
precision highp float;
uniform mediump sampler2D uTexA;
uniform mediump sampler2D uTexB;
uniform mediump sampler2D uMvAB;
uniform mediump sampler2D uMvBA;
uniform highp vec2 uTexel;
uniform highp vec2 uMvUvScale;
in highp vec4 in_TEXCOORD0;
out vec4 fragColor;
const float AGREE = 0.03;
float mismatch(vec3 a, vec3 b)
{
	vec3 d = abs(a - b);
	return max(d.r, max(d.g, d.b));
}
void main()
{
	vec2 uv = in_TEXCOORD0.xy;
	vec2 mvUv = uv * uMvUvScale;
	vec2 vAB = texture(uMvAB, mvUv).xy * uTexel;
	vec2 vBA = texture(uMvBA, mvUv).xy * uTexel;
	vec3 a1 = texture(uTexA, uv - 0.5 * vAB).rgb;
	vec3 b1 = texture(uTexB, uv + 0.5 * vAB).rgb;
	vec3 b2 = texture(uTexB, uv - 0.5 * vBA).rgb;
	vec3 a2 = texture(uTexA, uv + 0.5 * vBA).rgb;
	float e1 = mismatch(a1, b1);
	float e2 = mismatch(a2, b2);
	vec3 tracked = e1 <= e2 ? 0.5 * (a1 + b1) : 0.5 * (a2 + b2);
	float err = min(e1, e2);
	vec3 fallback = texture(uTexB, uv).rgb;
	fragColor = vec4(mix(tracked, fallback, smoothstep(AGREE, 2.0 * AGREE, err)), 1.0);
}
"""

	private val SGSR1_PATCHES = listOf(
		"#version 300 es" to "#version 310 es",
		"layout(location=0) in highp vec4 in_TEXCOORD0;" to "in highp vec4 in_TEXCOORD0;",
		"highp vec2(" to "vec2(")

	/** Only the original asset copies OperationMode into a variable; the edge-direction asset uses the define directly. */
	private const val SGSR1_MODE_VARIABLE = "int mode = OperationMode;"
	private const val SGSR1_EDGE_DIRECTION_OFF = "// #define UseEdgeDirection"

	/** Upstream ships two mobile shaders; the edge-direction one is a newer file that also changes the base filter slightly. */
	const val SGSR1_ASSET = "shaders/sgsr1_shader_mobile.frag"
	const val SGSR1_EDGE_DIRECTION_ASSET = "shaders/sgsr1_shader_mobile_edge_direction.frag"

	/** SGSR1 shader defaults, kept here so the settings UI and the patcher agree. */
	const val SGSR1_DEFAULT_EDGE_SHARPNESS = 2.0f
	const val SGSR1_DEFAULT_EDGE_THRESHOLD_255 = 8

	/**
	 * Adapts the verbatim SGSR1 asset to GLSL ES 3.10 in memory and applies the user's tuning:
	 * 1. `#version 300 es` becomes `310 es`, since textureGather only exists from GLSL ES 3.10 and our vertex shader is 3.10.
	 * 2. The `layout(location=0)` qualifier on the input is dropped, as the vertex shader output has no location.
	 * 3. `int mode` becomes `const int mode`, because textureGather's component argument must be a compile-time constant.
	 * 4. `highp vec2(` becomes `vec2(` (all occurrences), since a precision qualifier is not allowed on a constructor call.
	 * 5. The `EdgeSharpness` and `EdgeThreshold` defines take [edgeSharpness] and [edgeThreshold255]/255.
	 * 6. With [edgeDirection], the commented-out `UseEdgeDirection` define is enabled (edge-direction asset only).
	 * Throws [ShaderCompileException] if the asset no longer contains one of the expected patterns.
	 */
	fun patchSgsr1Source(raw: String, edgeSharpness: Float = SGSR1_DEFAULT_EDGE_SHARPNESS,
		edgeThreshold255: Int = SGSR1_DEFAULT_EDGE_THRESHOLD_255, edgeDirection: Boolean = false): String
	{
		val tuning = listOf(
			"#define EdgeSharpness 2.0" to String.format(Locale.US, "#define EdgeSharpness %.2f", edgeSharpness),
			"#define EdgeThreshold 8.0/255.0" to "#define EdgeThreshold $edgeThreshold255.0/255.0")
		val edge = if(edgeDirection) listOf(SGSR1_EDGE_DIRECTION_OFF to "#define UseEdgeDirection") else emptyList()
		var result = raw.replace(SGSR1_MODE_VARIABLE, "const $SGSR1_MODE_VARIABLE")
		for((pattern, replacement) in SGSR1_PATCHES + tuning + edge)
		{
			if(!result.contains(pattern))
				throw ShaderCompileException("SGSR1 asset missing expected pattern: $pattern")
			result = result.replace(pattern, replacement)
		}
		return result
	}

	fun loadSgsr1Source(assets: AssetManager, edgeSharpness: Float, edgeThreshold255: Int, edgeDirection: Boolean): String
	{
		val asset = if(edgeDirection) SGSR1_EDGE_DIRECTION_ASSET else SGSR1_ASSET
		val raw = assets.open(asset).bufferedReader().use { it.readText() }
		return patchSgsr1Source(raw, edgeSharpness, edgeThreshold255, edgeDirection)
	}

	/** [hdr] selects the explicit BT.2020 conversion; the caller must have checked GL_EXT_YUV_target. */
	fun buildOesCopyProgram(hdr: Boolean = false): Int =
		if(hdr) link(VERTEX_SRC, OES_COPY_HDR_FRAG_SRC, "oes-copy-hdr") else link(VERTEX_SRC, OES_COPY_FRAG_SRC, "oes-copy")
	fun buildBlitProgram(): Int = link(VERTEX_SRC, BLIT_FRAG_SRC, "blit")
	fun buildLumaProgram(): Int = link(VERTEX_SRC, LUMA_FRAG_SRC, "luma")
	fun buildWarpProgram(): Int = link(VERTEX_SRC, WARP_FRAG_SRC, "warp")
	fun buildSgsr1Program(assets: AssetManager, edgeSharpness: Float = SGSR1_DEFAULT_EDGE_SHARPNESS,
		edgeThreshold255: Int = SGSR1_DEFAULT_EDGE_THRESHOLD_255, edgeDirection: Boolean = false): Int =
		link(VERTEX_SRC, loadSgsr1Source(assets, edgeSharpness, edgeThreshold255, edgeDirection),
			if(edgeDirection) "sgsr1-edge-direction" else "sgsr1")

	private fun compile(type: Int, src: String, name: String): Int
	{
		val shader = GLES31.glCreateShader(type)
		GLES31.glShaderSource(shader, src)
		GLES31.glCompileShader(shader)
		val status = IntArray(1)
		GLES31.glGetShaderiv(shader, GLES31.GL_COMPILE_STATUS, status, 0)
		if(status[0] == 0)
		{
			val log = GLES31.glGetShaderInfoLog(shader)
			GLES31.glDeleteShader(shader)
			throw ShaderCompileException("$name shader compile failed: $log")
		}
		return shader
	}

	private fun link(vertexSrc: String, fragmentSrc: String, name: String): Int
	{
		val vs = compile(GLES31.GL_VERTEX_SHADER, vertexSrc, "$name vertex")
		val fs = try { compile(GLES31.GL_FRAGMENT_SHADER, fragmentSrc, "$name fragment") }
			catch(e: ShaderCompileException) { GLES31.glDeleteShader(vs); throw e }
		val program = GLES31.glCreateProgram()
		GLES31.glAttachShader(program, vs)
		GLES31.glAttachShader(program, fs)
		GLES31.glLinkProgram(program)
		GLES31.glDeleteShader(vs)
		GLES31.glDeleteShader(fs)
		val status = IntArray(1)
		GLES31.glGetProgramiv(program, GLES31.GL_LINK_STATUS, status, 0)
		if(status[0] == 0)
		{
			val log = GLES31.glGetProgramInfoLog(program)
			GLES31.glDeleteProgram(program)
			throw ShaderCompileException("$name program link failed: $log")
		}
		return program
	}
}
