// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream

import android.app.Application
import android.content.Context
import androidx.lifecycle.*
import com.metallic.chiaki.common.LogManager
import com.metallic.chiaki.session.GpuPipelineConfig
import com.metallic.chiaki.stream.gpu.GpuTuning
import com.metallic.chiaki.session.StreamSession
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.lib.*
import com.metallic.chiaki.session.StreamInput

class StreamViewModel(val application: Application, val connectInfo: ConnectInfo): ViewModel()
{
	val preferences = Preferences(application)
	val logManager = LogManager(application)

	val input = StreamInput(application, preferences)
	val session = StreamSession(connectInfo, logManager, preferences.logVerbose, input, application.assets,
		GpuPipelineConfig(upscaling = preferences.gpuUpscalingEnabled, frameGeneration = preferences.frameGenerationEnabled,
			tuning = GpuTuning(
				sgsrEdgeSharpness = preferences.sgsrSharpness / 10f,
				sgsrEdgeThreshold255 = preferences.sgsrEdgeThreshold,
				sgsrEdgeDirection = preferences.sgsrEdgeDirection,
				generationMode = preferences.frameGenerationMode.mode,
				extrapolationScale = preferences.frameGenerationScale / 100f)))

	private var _onScreenControlsEnabled = MutableLiveData<Boolean>(preferences.onScreenControlsEnabled)
	val onScreenControlsEnabled: LiveData<Boolean> get() = _onScreenControlsEnabled

	private var _touchpadOnlyEnabled = MutableLiveData<Boolean>(preferences.touchpadOnlyEnabled)
	val touchpadOnlyEnabled: LiveData<Boolean> get() = _touchpadOnlyEnabled

	override fun onCleared()
	{
		super.onCleared()
		input.release()
		// Safety net: ensure session is shut down when ViewModel is destroyed
		session.shutdown()
	}

	fun setOnScreenControlsEnabled(enabled: Boolean)
	{
		preferences.onScreenControlsEnabled = enabled
		_onScreenControlsEnabled.value = enabled
	}

	fun setTouchpadOnlyEnabled(enabled: Boolean)
	{
		preferences.touchpadOnlyEnabled = enabled
		_touchpadOnlyEnabled.value = enabled
	}
}