// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class GlShadersTest
{
	private val raw: String = File("src/main/assets/shaders/sgsr1_shader_mobile.frag").readText()
	private val rawEdge: String = File("src/main/assets/shaders/sgsr1_shader_mobile_edge_direction.frag").readText()

	@Test
	fun patchedSourceTargetsEs310()
	{
		val patched = GlShaders.patchSgsr1Source(raw)
		assertTrue(patched.startsWith("#version 310 es"))
		assertFalse(patched.contains("#version 300 es"))
	}

	@Test
	fun patchedSourceDropsLocationQualifier()
	{
		val patched = GlShaders.patchSgsr1Source(raw)
		assertTrue(patched.contains("in highp vec4 in_TEXCOORD0;"))
		assertTrue(patched.contains("const int mode = OperationMode;"))
		assertFalse(patched.contains("highp vec2("))
		assertFalse(patched.contains("layout(location=0) in "))
		// the fragment output keeps its location
		assertTrue(patched.contains("layout(location=0) out vec4 out_Target0;"))
	}

	@Test
	fun assetKeepsQualcommLicenseHeader()
	{
		assertTrue(raw.contains("SPDX-License-Identifier: BSD-3-Clause"))
		assertTrue(raw.contains("Qualcomm"))
	}

	@Test
	fun assetDeclaresExpectedUniforms()
	{
		assertTrue(raw.contains("uniform highp vec4 ViewportInfo[1];"))
		assertTrue(raw.contains("uniform mediump sampler2D ps0;"))
	}

	@Test
	fun patchedSourceKeepsSgsrDefaultsUnlessTuned()
	{
		val defaults = GlShaders.patchSgsr1Source(raw)
		assertTrue(defaults.contains("#define EdgeSharpness 2.00"))
		assertTrue(defaults.contains("#define EdgeThreshold 8.0/255.0"))
		val tuned = GlShaders.patchSgsr1Source(raw, edgeSharpness = 3.5f, edgeThreshold255 = 12)
		assertTrue(tuned.contains("#define EdgeSharpness 3.50"))
		assertTrue(tuned.contains("#define EdgeThreshold 12.0/255.0"))
		assertFalse(tuned.contains("#define EdgeSharpness 2.0\n"))
	}

	@Test
	fun edgeDirectionAssetPatchesAndEnablesTheDefine()
	{
		val off = GlShaders.patchSgsr1Source(rawEdge)
		assertTrue(off.startsWith("#version 310 es"))
		assertTrue(off.contains("// #define UseEdgeDirection"))
		assertFalse(off.contains("highp vec2("))
		val on = GlShaders.patchSgsr1Source(rawEdge, edgeDirection = true)
		assertTrue(on.contains("\n#define UseEdgeDirection"))
		assertFalse(on.contains("// #define UseEdgeDirection"))
		assertTrue(on.contains("#define EdgeSharpness 2.00"))
		assertTrue(rawEdge.contains("SPDX-License-Identifier: BSD-3-Clause"))
	}

	@Test(expected = ShaderCompileException::class)
	fun edgeDirectionNeedsTheEdgeDirectionAsset()
	{
		GlShaders.patchSgsr1Source(raw, edgeDirection = true)
	}

	@Test(expected = ShaderCompileException::class)
	fun missingPatternThrows()
	{
		GlShaders.patchSgsr1Source("#version 300 es\n")
	}

	@Test
	fun hdrCopyShaderReadsRawYuvAndWritesOpaque()
	{
		val src = GlShaders.OES_COPY_HDR_FRAG_SRC
		assertTrue(src.contains("#extension GL_EXT_YUV_target : require"))
		assertTrue(src.contains("__samplerExternal2DY2YEXT uTex"))
		assertTrue(src.contains("precision highp float;"))
		// same uniform names as the SDR copy, so the renderer binds both alike
		assertTrue(src.contains("uniform highp mat4 uTransform;"))
	}

	private fun findGlslang(): String?
	{
		val dirs = (System.getenv("PATH") ?: "").split(File.pathSeparator)
		for(name in listOf("glslang", "glslangValidator"))
		{
			for(dir in dirs)
			{
				val f = File(dir, name)
				if(f.isFile && f.canExecute())
					return f.absolutePath
			}
		}
		return null
	}

	@Test
	fun shadersCompileWithGlslangWhenAvailable()
	{
		val glslang = findGlslang()
		assumeTrue("glslang not on PATH", glslang != null)
		val dir = createTempDir("glslang")
		try
		{
			val vert = File(dir, "full.vert").also { it.writeText(GlShaders.VERTEX_SRC) }
			val frags = mapOf(
				"oes" to GlShaders.OES_COPY_FRAG_SRC,
				"oes-hdr" to GlShaders.OES_COPY_HDR_FRAG_SRC,
				"blit" to GlShaders.BLIT_FRAG_SRC,
				"luma" to GlShaders.LUMA_FRAG_SRC,
				"warp" to GlShaders.WARP_FRAG_SRC,
				"sgsr1" to GlShaders.patchSgsr1Source(raw),
				"sgsr1-tuned" to GlShaders.patchSgsr1Source(raw, edgeSharpness = 0.5f, edgeThreshold255 = 32),
				"sgsr1-edge-off" to GlShaders.patchSgsr1Source(rawEdge),
				"sgsr1-edge-on" to GlShaders.patchSgsr1Source(rawEdge, edgeDirection = true))
			for((name, src) in frags)
			{
				val frag = File(dir, "$name.frag").also { it.writeText(src) }
				val proc = ProcessBuilder(glslang, "-l", vert.path, frag.path).redirectErrorStream(true).start()
				val out = proc.inputStream.bufferedReader().readText()
				val code = proc.waitFor()
				println("glslang $name: exit $code\n$out")
				assertEquals("glslang rejected $name:\n$out", 0, code)
			}
		}
		finally
		{
			dir.deleteRecursively()
		}
	}
}
