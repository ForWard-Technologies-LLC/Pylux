// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import androidx.appcompat.app.AlertDialog
import com.metallic.chiaki.common.ext.alertDialogBuilder
import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.graphics.Matrix
import android.os.*
import android.util.Log
import android.util.Rational
import android.view.*
import android.widget.EditText
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isGone
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import androidx.lifecycle.*

import com.pylux.stream.R
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.common.ext.viewModelFactory
import com.pylux.stream.databinding.ActivityStreamBinding
import com.metallic.chiaki.lib.ConnectInfo
import com.metallic.chiaki.lib.ConnectVideoProfile
import com.metallic.chiaki.session.*
import com.metallic.chiaki.touchcontrols.DefaultTouchControlsFragment
import com.metallic.chiaki.touchcontrols.TouchControlsFragment
import com.metallic.chiaki.touchcontrols.TouchpadOnlyFragment
import io.reactivex.disposables.CompositeDisposable
import io.reactivex.rxkotlin.addTo
import kotlin.math.min

private sealed class DialogContents
private object StreamQuitDialog: DialogContents()
private object CreateErrorDialog: DialogContents()
private object PinRequestDialog: DialogContents()

class StreamActivity : AppCompatActivity(), View.OnSystemUiVisibilityChangeListener
{
	companion object
	{
		const val EXTRA_CONNECT_INFO = "connect_info"
		private const val HIDE_UI_TIMEOUT_MS = 4000L
	}

	private lateinit var viewModel: StreamViewModel
	private lateinit var binding: ActivityStreamBinding

	private val uiVisibilityHandler = Handler()

	/** Tracks whether the activity is in the stopped state (between onStop and onStart).
	 *  Used to detect PiP dismissal: onStop fires while pip=true (so cleanup is skipped),
	 *  then onPictureInPictureModeChanged(false) fires — at that point we check this
	 *  flag to know we need to shut down the session. */
	private var activityStopped = false

	/** Saved control state before entering PiP, so we can restore when exiting PiP */
	private var savedOnScreenControlsEnabled = false
	private var savedTouchpadOnlyEnabled = false

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)

		val connectInfo = intent.getParcelableExtra<ConnectInfo>(EXTRA_CONNECT_INFO)
		if(connectInfo == null)
		{
			finish()
			return
		}

		viewModel = ViewModelProvider(this, viewModelFactory {
			StreamViewModel(application, connectInfo)
		})[StreamViewModel::class.java]

		viewModel.input.observe(this)

		binding = ActivityStreamBinding.inflate(layoutInflater)
		setContentView(binding.root)
		window.decorView.setOnSystemUiVisibilityChangeListener(this)

		viewModel.onScreenControlsEnabled.observe(this, Observer {
			if(binding.onScreenControlsSwitch.isChecked != it)
				binding.onScreenControlsSwitch.isChecked = it
			if(binding.onScreenControlsSwitch.isChecked)
				binding.touchpadOnlySwitch.isChecked = false
		})
		binding.onScreenControlsSwitch.setOnCheckedChangeListener { _, isChecked ->
			viewModel.setOnScreenControlsEnabled(isChecked)
			showOverlay()
		}

		viewModel.touchpadOnlyEnabled.observe(this, Observer {
			if(binding.touchpadOnlySwitch.isChecked != it)
				binding.touchpadOnlySwitch.isChecked = it
			if(binding.touchpadOnlySwitch.isChecked)
				binding.onScreenControlsSwitch.isChecked = false
		})
		binding.touchpadOnlySwitch.setOnCheckedChangeListener { _, isChecked ->
			viewModel.setTouchpadOnlyEnabled(isChecked)
			showOverlay()
		}

		binding.displayModeToggle.addOnButtonCheckedListener { _, _, _ ->
			adjustStreamViewAspect()
			showOverlay()
		}

		// Disconnect button to exit stream
		binding.disconnectButton.setOnClickListener {
			finish()
		}

		// Handle back button - show overlay instead of exiting
		onBackPressedDispatcher.addCallback(this, object : androidx.activity.OnBackPressedCallback(true) {
			override fun handleOnBackPressed() {
				showOverlay()
			}
		})

		//viewModel.session.attachToTextureView(textureView)
		viewModel.session.attachToSurfaceView(binding.surfaceView)
		viewModel.session.state.observe(this, Observer { this.stateChanged(it) })
		adjustStreamViewAspect()

		if(Preferences(this).rumbleEnabled)
		{
			val vibrator = getSystemService(VIBRATOR_SERVICE) as Vibrator
			viewModel.session.rumbleState.observe(this, Observer {
				val amplitude = min(255, (it.left.toInt() + it.right.toInt()) / 2)
				vibrator.cancel()
				if(amplitude == 0)
					return@Observer
				if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
					vibrator.vibrate(VibrationEffect.createOneShot(1000, amplitude))
				else
					vibrator.vibrate(1000)
			})
		}
	}

	private val controlsDisposable = CompositeDisposable()

	override fun onAttachFragment(fragment: Fragment)
	{
		super.onAttachFragment(fragment)
		if(fragment is TouchControlsFragment)
		{
			fragment.controllerState
				.subscribe { viewModel.input.touchControllerState = it }
				.addTo(controlsDisposable)
			fragment.onScreenControlsEnabled = viewModel.onScreenControlsEnabled
			if(fragment is TouchpadOnlyFragment)
				fragment.touchpadOnlyEnabled = viewModel.touchpadOnlyEnabled
		}
	}

	override fun onResume()
	{
		super.onResume()
		activityStopped = false
		Log.i("StreamActivity", "onResume: pip=$isInPictureInPictureMode session=${viewModel.session.session != null}")
		hideSystemUI()
		// resume() is safe to call even if session is already running -
		// it returns immediately when session != null
		viewModel.session.resume()
	}

	override fun onPause()
	{
		super.onPause()
		Log.i("StreamActivity", "onPause: pip=$isInPictureInPictureMode finishing=$isFinishing")
		// In PiP mode the stream should keep running, so skip pause.
		// isInPictureInPictureMode is the built-in Activity property.
		if (!isInPictureInPictureMode)
		{
			viewModel.session.skipNativeSurfaceCleanup = false
			viewModel.session.pause()
		}
	}

	override fun onStop()
	{
		super.onStop()
		activityStopped = true
		Log.i("StreamActivity", "onStop: pip=$isInPictureInPictureMode finishing=$isFinishing")
		// When not in PiP, ensure the session is properly shut down.
		// This handles the normal exit path (redundant with onPause, but safe).
		// When in PiP, onStop fires with pip=true (cleanup deferred to handlePipChanged).
		if (!isInPictureInPictureMode)
		{
			viewModel.session.skipNativeSurfaceCleanup = false
			viewModel.session.pause()
		}
	}

	override fun onDestroy()
	{
		super.onDestroy()
		Log.i("StreamActivity", "onDestroy: finishing=$isFinishing")
		controlsDisposable.dispose()
		uiVisibilityHandler.removeCallbacksAndMessages(null)
	}

	override fun onConfigurationChanged(newConfig: Configuration)
	{
		super.onConfigurationChanged(newConfig)
		Log.i("StreamActivity", "onConfigurationChanged: pip=$isInPictureInPictureMode")
	}

	// --- Picture-in-Picture support ---

	override fun onUserLeaveHint()
	{
		super.onUserLeaveHint()
		Log.i("StreamActivity", "onUserLeaveHint")
		enterPipModeIfEnabled()
	}

	private fun enterPipModeIfEnabled()
	{
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O)
		{
			Log.i("StreamActivity", "PiP: not supported (API ${Build.VERSION.SDK_INT})")
			return
		}

		if (!Preferences(this).pipEnabled)
		{
			Log.i("StreamActivity", "PiP: disabled in preferences")
			return
		}

		try {
			// Skip native setSurface(null) during the PiP surface transition -
			// it blocks the decoder. The surface will be recreated at PiP size.
			viewModel.session.skipNativeSurfaceCleanup = true
			val result = enterPictureInPictureMode(
				PictureInPictureParams.Builder()
					.setAspectRatio(Rational(16, 9))
					.build()
			)
			Log.i("StreamActivity", "PiP: enterPictureInPictureMode returned $result")
			if (!result) {
				viewModel.session.skipNativeSurfaceCleanup = false
			}
		} catch (e: Exception) {
			Log.w("StreamActivity", "PiP: failed to enter - ${e.message}")
			viewModel.session.skipNativeSurfaceCleanup = false
		}
	}

	@Suppress("DEPRECATION")
	override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean)
	{
		super.onPictureInPictureModeChanged(isInPictureInPictureMode)
		Log.i("StreamActivity", "onPipChanged(1-param): pip=$isInPictureInPictureMode finishing=$isFinishing")
		handlePipChanged(isInPictureInPictureMode)
	}

	override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration)
	{
		super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
		Log.i("StreamActivity", "onPipChanged(2-param): pip=$isInPictureInPictureMode finishing=$isFinishing")
		// Don't call handlePipChanged here - the 2-param version calls the 1-param version internally
	}

	private fun handlePipChanged(isInPictureInPictureMode: Boolean)
	{
		if (isInPictureInPictureMode)
		{
			// Save current control state before hiding
			savedOnScreenControlsEnabled = viewModel.onScreenControlsEnabled.value ?: false
			savedTouchpadOnlyEnabled = viewModel.touchpadOnlyEnabled.value ?: false

			// Hide all UI elements — PiP window should only show the video
			hideOverlay()
			viewModel.setOnScreenControlsEnabled(false)
			viewModel.setTouchpadOnlyEnabled(false)
			binding.progressBar.isGone = true
		}
		else
		{
			// Exiting PiP - restore normal surface cleanup behavior
			viewModel.session.skipNativeSurfaceCleanup = false

			if (activityStopped)
			{
				// PiP was dismissed (swiped away). onStop already fired with
				// pip=true so it couldn't clean up. Do it now.
				Log.i("StreamActivity", "handlePipChanged: PiP dismissed while stopped, shutting down session")
				viewModel.session.pause()
			}
			else if (!isFinishing)
			{
				// Returning to fullscreen from PiP - restore UI elements
				viewModel.setOnScreenControlsEnabled(savedOnScreenControlsEnabled)
				viewModel.setTouchpadOnlyEnabled(savedTouchpadOnlyEnabled)
				hideOverlay()
				hideSystemUI()
			}
		}
	}

	// --- end PiP ---

	private fun reconnect()
	{
		viewModel.session.shutdown()
		viewModel.session.resume()
	}

	private val hideSystemUIRunnable = Runnable { hideSystemUI() }

	override fun onSystemUiVisibilityChange(visibility: Int)
	{
		if(visibility and View.SYSTEM_UI_FLAG_FULLSCREEN == 0)
			showOverlay()
		else
			hideOverlay()
	}

	private fun showOverlay()
	{
		binding.overlay.isVisible = true
		binding.overlay.animate()
			.alpha(1.0f)
			.setListener(object: AnimatorListenerAdapter()
			{
				override fun onAnimationEnd(animation: Animator)
				{
					binding.overlay.alpha = 1.0f
				}
			})
		uiVisibilityHandler.removeCallbacks(hideSystemUIRunnable)
		uiVisibilityHandler.postDelayed(hideSystemUIRunnable, HIDE_UI_TIMEOUT_MS)
	}

	private fun hideOverlay()
	{
		binding.overlay.animate()
			.alpha(0.0f)
			.setListener(object: AnimatorListenerAdapter()
			{
				override fun onAnimationEnd(animation: Animator)
				{
					binding.overlay.isGone = true
				}
			})
	}

	override fun onWindowFocusChanged(hasFocus: Boolean)
	{
		super.onWindowFocusChanged(hasFocus)
		if(hasFocus)
			hideSystemUI()
	}

	private fun hideSystemUI()
	{
		window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE
				or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
				or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
				or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
				or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
				or View.SYSTEM_UI_FLAG_FULLSCREEN)
	}

	private var dialogContents: DialogContents? = null
	private var dialog: AlertDialog? = null
		set(value)
		{
			field = value
			if(value == null)
				dialogContents = null
		}

	private fun stateChanged(state: StreamState)
	{
		Log.i("StreamActivity", "stateChanged: $state pip=$isInPictureInPictureMode")
		binding.progressBar.visibility = if(state == StreamStateConnecting) View.VISIBLE else View.GONE

		when(state)
		{
			is StreamStateQuit ->
			{
				if(dialogContents != StreamQuitDialog)
				{
					if(state.reason.isError)
					{
						dialog?.dismiss()
						val reasonStr = state.reasonString
						val dialog = alertDialogBuilder()
							.setMessage(getString(R.string.alert_message_session_quit, state.reason.toString())
									+ (if(reasonStr != null) "\n$reasonStr" else ""))
							.setPositiveButton(R.string.action_reconnect) { _, _ ->
								dialog = null
								reconnect()
							}
							.setOnCancelListener {
								dialog = null
								finish()
							}
							.setNegativeButton(R.string.action_quit_session) { _, _ ->
								dialog = null
								finish()
							}
							.create()
						dialogContents = StreamQuitDialog
						dialog.show()
					}
					else
						finish()
				}
			}

			is StreamStateCreateError ->
			{
				if(dialogContents != CreateErrorDialog)
				{
					dialog?.dismiss()
					val dialog = alertDialogBuilder()
						.setMessage(getString(R.string.alert_message_session_create_error, state.error.errorCode.toString()))
						.setOnDismissListener {
							dialog = null
							finish()
						}
						.setNegativeButton(R.string.action_quit_session) { _, _ -> }
						.create()
					dialogContents = CreateErrorDialog
					dialog.show()
				}
			}

			is StreamStateLoginPinRequest ->
			{
				if(dialogContents != PinRequestDialog)
				{
					dialog?.dismiss()

					val view = layoutInflater.inflate(R.layout.dialog_login_pin, null)
					val pinEditText = view.findViewById<EditText>(R.id.pinEditText)

					val dialog = alertDialogBuilder()
						.setMessage(
							if(state.pinIncorrect)
								R.string.alert_message_login_pin_request_incorrect
							else
								R.string.alert_message_login_pin_request)
						.setView(view)
						.setPositiveButton(R.string.action_login_pin_connect) { _, _ ->
							dialog = null
							viewModel.session.setLoginPin(pinEditText.text.toString())
						}
						.setOnCancelListener {
							dialog = null
							finish()
						}
						.setNegativeButton(R.string.action_quit_session) { _, _ ->
							dialog = null
							finish()
						}
						.create()
					dialogContents = PinRequestDialog
					dialog.show()
				}
			}
			else -> {
				// Other states don't require special handling
			}
		}
	}

	private fun adjustTextureViewAspect(textureView: TextureView)
	{
		val trans = TextureViewTransform(viewModel.session.connectInfo.videoProfile, textureView)
		val resolution = trans.resolutionFor(TransformMode.fromButton(binding.displayModeToggle.checkedButtonId))
		Matrix().also {
			textureView.getTransform(it)
			it.setScale(resolution.width / trans.viewWidth, resolution.height / trans.viewHeight)
			it.postTranslate((trans.viewWidth - resolution.width) * 0.5f, (trans.viewHeight - resolution.height) * 0.5f)
			textureView.setTransform(it)
		}
	}

	private fun adjustSurfaceViewAspect()
	{
		val videoProfile = viewModel.session.connectInfo.videoProfile
		binding.aspectRatioLayout.aspectRatio = videoProfile.width.toFloat() / videoProfile.height.toFloat()
		binding.aspectRatioLayout.mode = TransformMode.fromButton(binding.displayModeToggle.checkedButtonId)
	}

	private fun adjustStreamViewAspect() = adjustSurfaceViewAspect()

	override fun dispatchKeyEvent(event: KeyEvent) = viewModel.input.dispatchKeyEvent(event) || super.dispatchKeyEvent(event)
	override fun onGenericMotionEvent(event: MotionEvent) = viewModel.input.onGenericMotionEvent(event) || super.onGenericMotionEvent(event)
}

enum class TransformMode
{
	FIT,
	STRETCH,
	ZOOM;

	companion object
	{
		fun fromButton(displayModeButtonId: Int)
			= when (displayModeButtonId)
			{
				R.id.display_mode_stretch_button -> STRETCH
				R.id.display_mode_zoom_button -> ZOOM
				else -> FIT
			}
	}
}

class TextureViewTransform(private val videoProfile: ConnectVideoProfile, private val textureView: TextureView)
{
	private val contentWidth : Float get() = videoProfile.width.toFloat()
	private val contentHeight : Float get() = videoProfile.height.toFloat()
	val viewWidth : Float get() = textureView.width.toFloat()
	val viewHeight : Float get() = textureView.height.toFloat()
	private val contentAspect : Float get() =  contentHeight / contentWidth

	fun resolutionFor(mode: TransformMode): Resolution
		= when(mode)
		{
			TransformMode.STRETCH -> strechedResolution
			TransformMode.ZOOM -> zoomedResolution
			TransformMode.FIT -> normalResolution
		}

	private val strechedResolution get() = Resolution(viewWidth, viewHeight)

	private val zoomedResolution get() =
		if(viewHeight > viewWidth * contentAspect)
		{
			val zoomFactor = viewHeight / contentHeight
			Resolution(contentWidth * zoomFactor, viewHeight)
		}
		else
		{
			val zoomFactor = viewWidth / contentWidth
			Resolution(viewWidth, contentHeight * zoomFactor)
		}

	private val normalResolution get() =
		if(viewHeight > viewWidth * contentAspect)
			Resolution(viewWidth, viewWidth * contentAspect)
		else
			Resolution(viewHeight / contentAspect, viewHeight)
}


data class Resolution(val width: Float, val height: Float)
