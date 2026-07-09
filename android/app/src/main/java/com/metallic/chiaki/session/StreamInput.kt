package com.metallic.chiaki.session

import android.content.Context
import android.hardware.*
import android.os.Handler
import android.os.Looper
import android.view.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.OnLifecycleEvent
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.lib.ControllerState
import com.metallic.chiaki.lib.OrientationTracker

class StreamInput(val context: Context, val preferences: Preferences)
{
	var controllerStateChangedCallback: ((ControllerState) -> Unit)? = null

	val controllerState: ControllerState get()
	{
		var controllerState = sensorControllerState or keyControllerState or motionControllerState

		// Screen-rotation correction applies only to PHONE motion (the sensor frame
		// is fixed to the device's portrait orientation); a controller's sensors are
		// in the controller's own frame, independent of the display.
		if(!controllerMotionActive)
		{
			val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
			@Suppress("DEPRECATION")
			when(windowManager.defaultDisplay.rotation)
			{
				Surface.ROTATION_90 -> {
					controllerState.accelX *= -1.0f
					controllerState.accelZ *= -1.0f
					controllerState.gyroX *= -1.0f
					controllerState.gyroZ *= -1.0f
					controllerState.orientX *= -1.0f
					controllerState.orientZ *= -1.0f
				}
				else -> {}
			}
		}

		// prioritize motion controller's l2 and r2 over key
		// (some controllers send only key, others both but key earlier than full press)
		if(motionControllerState.l2State > 0U)
			controllerState.l2State = motionControllerState.l2State
		if(motionControllerState.r2State > 0U)
			controllerState.r2State = motionControllerState.r2State

		if(dpadTouchEnabled && !dpadRegular && dpadTouchIncrement > 0)
		{
			if(controllerState.buttons and DPAD_BUTTON_MASK != 0U)
				controllerState = controllerState.copy(buttons = controllerState.buttons and DPAD_BUTTON_MASK.inv())
			controllerState = controllerState or dpadTouchControllerState
		}

		return controllerState or touchControllerState or capturedTouchpadControllerState
	}

	private val sensorControllerState = ControllerState() // from Motion Sensors
	private val keyControllerState = ControllerState() // from KeyEvents
	private val motionControllerState = ControllerState() // from MotionEvents
	private val dpadTouchControllerState = ControllerState()
	var touchControllerState = ControllerState()
		set(value)
		{
			field = value
			controllerStateUpdated()
		}
	// Physical controller touchpad (DualSense/DS4) delivered via pointer capture
	// (StreamActivity requests capture on the stream view, API 26+).
	private val capturedTouchpadControllerState = ControllerState()
	private val capturedTouchIds = mutableMapOf<Int, UByte>() // MotionEvent pointerId -> chiaki touch id

	private val swapCrossMoon = preferences.swapCrossMoon
	private val mapSelectToTouchpad = preferences.mapSelectToTouchpad
	private val dpadTouchEnabled = preferences.dpadTouchEnabled
	private val dpadTouchIncrement = if(dpadTouchEnabled) preferences.dpadTouchIncrement else 0
	private val dpadTouchShortcut1 = shortcutMask(preferences.dpadTouchShortcut1)
	private val dpadTouchShortcut2 = shortcutMask(preferences.dpadTouchShortcut2)
	private val dpadTouchShortcut3 = shortcutMask(preferences.dpadTouchShortcut3)
	private val dpadTouchShortcut4 = shortcutMask(preferences.dpadTouchShortcut4)

	private val handler = Handler(Looper.getMainLooper())
	private var dpadRegular = true
	private var dpadRegularTouchSwitched = false
	private var dpadTouchId = -1
	private var dpadTouchX: UShort = 0U
	private var dpadTouchY: UShort = 0U

	private val touchpadMaxX = (ControllerState.TOUCHPAD_WIDTH - 1u).toUShort()
	private val touchpadMaxY = (ControllerState.TOUCHPAD_HEIGHT - 1u).toUShort()
	private val touchpadMidX = (ControllerState.TOUCHPAD_WIDTH / 2u).toUShort()
	private val touchpadMidY = (ControllerState.TOUCHPAD_HEIGHT / 2u).toUShort()

	private val dpadTouchUpdateRunnable = object: Runnable {
		override fun run()
		{
			if(!dpadTouchEnabled || dpadRegular || dpadTouchIncrement <= 0 || dpadTouchId < 0)
				return
			val dpadHeld = (keyControllerState.buttons or motionControllerState.buttons) and DPAD_BUTTON_MASK
			if(dpadHeld == 0U)
				return
			handleDpadTouchEvent(dpadHeld, placeholder = true)
			controllerStateUpdated()
			handler.postDelayed(this, DPAD_TOUCH_UPDATE_INTERVAL_MS)
		}
	}

	private var dpadTouchStopScheduled = false
	private val dpadTouchStopRunnable = Runnable {
		dpadTouchStopScheduled = false
		cancelDpadTouchUpdate()
		stopDpadTouch()
		controllerStateUpdated()
	}

	fun release()
	{
		cancelDpadTouchTimers()
		stopDpadTouch()
		releaseCapturedTouchpad()
	}

	/**
	 * Drop all captured-touchpad state (touches + click). Called when pointer
	 * capture is lost/released so no finger stays "stuck" on the virtual pad.
	 */
	fun releaseCapturedTouchpad()
	{
		var changed = capturedTouchIds.isNotEmpty()
			|| capturedTouchpadControllerState.buttons and ControllerState.BUTTON_TOUCHPAD != 0U
		capturedTouchIds.values.forEach { capturedTouchpadControllerState.stopTouch(it) }
		capturedTouchIds.clear()
		capturedTouchpadControllerState.buttons =
			capturedTouchpadControllerState.buttons and ControllerState.BUTTON_TOUCHPAD.inv()
		if(changed)
			controllerStateUpdated()
	}

	/**
	 * Events delivered while the stream view holds pointer capture. Under capture
	 * a physical controller touchpad (DualSense/DS4) reports ABSOLUTE per-finger
	 * positions with SOURCE_TOUCHPAD; positions are scaled to the PS touchpad
	 * coordinate space. The pad's physical click arrives as BUTTON_PRIMARY (also
	 * when the pad is presented as a mouse on some Android versions, which is why
	 * the click is handled for every captured source).
	 */
	fun onCapturedPointerEvent(event: MotionEvent): Boolean
	{
		var changed = false

		val clicked = event.buttonState and MotionEvent.BUTTON_PRIMARY != 0
		val hadClick = capturedTouchpadControllerState.buttons and ControllerState.BUTTON_TOUCHPAD != 0U
		if(clicked != hadClick)
		{
			capturedTouchpadControllerState.buttons =
				if(clicked) capturedTouchpadControllerState.buttons or ControllerState.BUTTON_TOUCHPAD
				else capturedTouchpadControllerState.buttons and ControllerState.BUTTON_TOUCHPAD.inv()
			changed = true
		}

		if(event.source and InputDevice.SOURCE_TOUCHPAD == InputDevice.SOURCE_TOUCHPAD)
		{
			val xRange = event.device?.getMotionRange(MotionEvent.AXIS_X, event.source)
			val yRange = event.device?.getMotionRange(MotionEvent.AXIS_Y, event.source)
			fun scale(v: Float, min: Float, max: Float, target: UShort): UShort
			{
				val norm = if(max > min) ((v - min) / (max - min)).coerceIn(0f, 1f) else 0f
				return (norm * (target.toInt() - 1).toFloat()).toInt().toUShort()
			}
			fun scaledX(i: Int) = scale(event.getX(i), xRange?.min ?: 0f, xRange?.max ?: 1f, ControllerState.TOUCHPAD_WIDTH)
			fun scaledY(i: Int) = scale(event.getY(i), yRange?.min ?: 0f, yRange?.max ?: 1f, ControllerState.TOUCHPAD_HEIGHT)

			when(event.actionMasked)
			{
				MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
				{
					val idx = event.actionIndex
					val pid = event.getPointerId(idx)
					// If this pointer id is somehow already mapped (e.g. a missed UP
					// after a capture blip), release the stale chiaki touch first so
					// we don't leak a touch slot / leave a finger stuck.
					capturedTouchIds.remove(pid)?.let {
						capturedTouchpadControllerState.stopTouch(it)
						changed = true
					}
					capturedTouchpadControllerState.startTouch(scaledX(idx), scaledY(idx))?.let {
						capturedTouchIds[pid] = it
						changed = true
					}
				}
				MotionEvent.ACTION_MOVE ->
					for(i in 0 until event.pointerCount)
						capturedTouchIds[event.getPointerId(i)]?.let {
							if(capturedTouchpadControllerState.setTouchPos(it, scaledX(i), scaledY(i)))
								changed = true
						}
				MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP ->
				{
					capturedTouchIds.remove(event.getPointerId(event.actionIndex))?.let {
						capturedTouchpadControllerState.stopTouch(it)
						changed = true
					}
				}
				MotionEvent.ACTION_CANCEL ->
				{
					if(capturedTouchIds.isNotEmpty())
					{
						capturedTouchIds.values.forEach { capturedTouchpadControllerState.stopTouch(it) }
						capturedTouchIds.clear()
						changed = true
					}
				}
			}
		}

		if(changed)
			controllerStateUpdated()
		return true
	}

	private val sensorEventListener = object: SensorEventListener {
		override fun onSensorChanged(event: SensorEvent)
		{
			when(event.sensor.type)
			{
				Sensor.TYPE_ACCELEROMETER -> {
					sensorControllerState.accelX = event.values[1] / SensorManager.GRAVITY_EARTH
					sensorControllerState.accelY = event.values[2] / SensorManager.GRAVITY_EARTH
					sensorControllerState.accelZ = event.values[0] / SensorManager.GRAVITY_EARTH
				}
				Sensor.TYPE_GYROSCOPE -> {
					sensorControllerState.gyroX = event.values[1]
					sensorControllerState.gyroY = event.values[2]
					sensorControllerState.gyroZ = event.values[0]
				}
				Sensor.TYPE_ROTATION_VECTOR -> {
					val q = floatArrayOf(0f, 0f, 0f, 0f)
					SensorManager.getQuaternionFromVector(q, event.values)
					sensorControllerState.orientX = q[2]
					sensorControllerState.orientY = q[3]
					sensorControllerState.orientZ = q[1]
					sensorControllerState.orientW = q[0]
				}
				else -> return
			}
			controllerStateUpdated()
		}

		override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
	}

	// --- Controller motion (Android 12+: InputDevice.getSensorManager) ---
	// DualSense/DS4 expose gyro+accel through the input device's own SensorManager.
	// The sensors report in the controller's frame (x right, y up, z toward the
	// player — the PS convention, same as SDL on desktop), so values map directly:
	// no phone-style axis remap and no display-rotation correction. Orientation is
	// computed by the shared C Madgwick tracker (input devices have no
	// rotation-vector sensor).

	/** True while motion comes from the controller — gates the display-rotation fix. */
	private var controllerMotionActive = false
	private var controllerSensorManager: SensorManager? = null
	private var orientationTracker: OrientationTracker? = null
	private val orientationTrackerOut = FloatArray(10)
	private var controllerGyro = floatArrayOf(0f, 0f, 0f)
	private var controllerAccel = floatArrayOf(0f, 1f, 0f)

	private val controllerSensorEventListener = object: SensorEventListener {
		override fun onSensorChanged(event: SensorEvent)
		{
			when(event.sensor.type)
			{
				Sensor.TYPE_ACCELEROMETER -> {
					controllerAccel[0] = event.values[0] / SensorManager.GRAVITY_EARTH
					controllerAccel[1] = event.values[1] / SensorManager.GRAVITY_EARTH
					controllerAccel[2] = event.values[2] / SensorManager.GRAVITY_EARTH
				}
				Sensor.TYPE_GYROSCOPE -> {
					controllerGyro[0] = event.values[0]
					controllerGyro[1] = event.values[1]
					controllerGyro[2] = event.values[2]
				}
				else -> return
			}
			val tracker = orientationTracker ?: return
			tracker.update(
				controllerGyro[0], controllerGyro[1], controllerGyro[2],
				controllerAccel[0], controllerAccel[1], controllerAccel[2],
				event.timestamp / 1000, orientationTrackerOut)
			sensorControllerState.gyroX = orientationTrackerOut[0]
			sensorControllerState.gyroY = orientationTrackerOut[1]
			sensorControllerState.gyroZ = orientationTrackerOut[2]
			sensorControllerState.accelX = orientationTrackerOut[3]
			sensorControllerState.accelY = orientationTrackerOut[4]
			sensorControllerState.accelZ = orientationTrackerOut[5]
			sensorControllerState.orientX = orientationTrackerOut[6]
			sensorControllerState.orientY = orientationTrackerOut[7]
			sensorControllerState.orientZ = orientationTrackerOut[8]
			sensorControllerState.orientW = orientationTrackerOut[9]
			controllerStateUpdated()
		}

		override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
	}

	/** Device id + SensorManager of the first attached gamepad that exposes a gyroscope, or null. */
	private fun controllerMotionDeviceOrNull(): Pair<Int, SensorManager>?
	{
		if(android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S)
			return null
		val inputManager = context.getSystemService(Context.INPUT_SERVICE) as android.hardware.input.InputManager
		for(deviceId in inputManager.inputDeviceIds)
		{
			val device = inputManager.getInputDevice(deviceId) ?: continue
			if(device.isVirtual)
				continue
			val isGamepad = (device.sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD)
				|| (device.sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK)
			if(!isGamepad)
				continue
			val sensorManager = device.sensorManager
			if(sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE) != null)
				return Pair(deviceId, sensorManager)
		}
		return null
	}

	private fun resetMotionState()
	{
		sensorControllerState.gyroX = 0f
		sensorControllerState.gyroY = 0f
		sensorControllerState.gyroZ = 0f
		sensorControllerState.accelX = 0f
		sensorControllerState.accelY = 1f
		sensorControllerState.accelZ = 0f
		sensorControllerState.orientX = 0f
		sensorControllerState.orientY = 0f
		sensorControllerState.orientZ = 0f
		sensorControllerState.orientW = 1f
	}

	/** (Re)register the motion source per the MotionSource preference and what is
	 * attached. Called on resume and when a controller connects/disconnects. */
	private var phoneMotionActive = false
	private var controllerMotionDeviceId = -1

	private fun registerMotionSensors()
	{
		val samplingPeriodUs = 4000
		val source = preferences.motionSource
		val controllerDevice = when(source)
		{
			Preferences.MotionSource.AUTO, Preferences.MotionSource.CONTROLLER -> controllerMotionDeviceOrNull()
			else -> null
		}
		val wantPhone = source == Preferences.MotionSource.PHONE
			|| (source == Preferences.MotionSource.AUTO && controllerDevice == null)

		// Idempotent: connect/disconnect events arrive in bursts (a Bluetooth
		// reconnect fires added + several changed); don't churn listeners when
		// nothing resolved differently.
		if(controllerDevice != null && controllerMotionActive && controllerMotionDeviceId == controllerDevice.first)
			return
		if(controllerDevice == null && wantPhone && phoneMotionActive)
			return

		unregisterMotionSensors()
		if(controllerDevice != null)
		{
			val (deviceId, sensorManager) = controllerDevice
			if(orientationTracker == null)
				orientationTracker = OrientationTracker()
			listOfNotNull(
				sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER),
				sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
			).forEach {
				sensorManager.registerListener(controllerSensorEventListener, it, samplingPeriodUs)
			}
			controllerSensorManager = sensorManager
			controllerMotionDeviceId = deviceId
			controllerMotionActive = true
			return
		}
		if(!wantPhone)
			return // OFF, or controller-only with no controller sensors
		val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
		listOfNotNull(
			sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER),
			sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE),
			sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
		).forEach {
			sensorManager.registerListener(sensorEventListener, it, samplingPeriodUs)
		}
		phoneMotionActive = true
	}

	private fun unregisterMotionSensors()
	{
		val phoneSensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
		phoneSensorManager.unregisterListener(sensorEventListener)
		controllerSensorManager?.unregisterListener(controllerSensorEventListener)
		controllerSensorManager = null
		controllerMotionActive = false
		controllerMotionDeviceId = -1
		phoneMotionActive = false
		resetMotionState()
	}

	private val motionReevaluateRunnable = Runnable { registerMotionSensors() }

	private val inputDeviceListener = object: android.hardware.input.InputManager.InputDeviceListener {
		// A Bluetooth controller is often announced before its sensors are
		// queryable; the sensors appear in a later "changed" event. React to all
		// three, plus a delayed re-check as insurance, so AUTO reliably switches
		// back to the controller after a reconnect.
		override fun onInputDeviceAdded(deviceId: Int)
		{
			registerMotionSensors()
			handler.removeCallbacks(motionReevaluateRunnable)
			handler.postDelayed(motionReevaluateRunnable, 1000)
		}
		override fun onInputDeviceRemoved(deviceId: Int) { registerMotionSensors() }
		override fun onInputDeviceChanged(deviceId: Int) { registerMotionSensors() }
	}

	private val motionLifecycleObserver = object: LifecycleObserver {
		@OnLifecycleEvent(Lifecycle.Event.ON_RESUME)
		fun onResume()
		{
			registerMotionSensors()
			// Re-evaluate the source when a controller connects or disconnects
			// (AUTO falls back to the phone and returns to the controller).
			val inputManager = context.getSystemService(Context.INPUT_SERVICE) as android.hardware.input.InputManager
			inputManager.registerInputDeviceListener(inputDeviceListener, Handler(Looper.getMainLooper()))
		}

		@OnLifecycleEvent(Lifecycle.Event.ON_PAUSE)
		fun onPause()
		{
			val inputManager = context.getSystemService(Context.INPUT_SERVICE) as android.hardware.input.InputManager
			inputManager.unregisterInputDeviceListener(inputDeviceListener)
			handler.removeCallbacks(motionReevaluateRunnable)
			unregisterMotionSensors()
			orientationTracker?.dispose()
			orientationTracker = null
		}
	}

	fun observe(lifecycleOwner: LifecycleOwner)
	{
		if(preferences.motionSource != Preferences.MotionSource.OFF)
			lifecycleOwner.lifecycle.addObserver(motionLifecycleObserver)
	}

	private fun controllerStateUpdated()
	{
		controllerStateChangedCallback?.let { it(controllerState) }
	}

	fun dispatchKeyEvent(event: KeyEvent): Boolean
	{
		//Log.i("StreamSession", "key event $event")
		if(event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP)
			return false

		when(event.keyCode)
		{
			KeyEvent.KEYCODE_BUTTON_L2 -> {
				keyControllerState.l2State = if(event.action == KeyEvent.ACTION_DOWN) UByte.MAX_VALUE else 0U
				processDpadTouch()
				controllerStateUpdated()
				return true
			}
			KeyEvent.KEYCODE_BUTTON_R2 -> {
				keyControllerState.r2State = if(event.action == KeyEvent.ACTION_DOWN) UByte.MAX_VALUE else 0U
				processDpadTouch()
				controllerStateUpdated()
				return true
			}
			KeyEvent.KEYCODE_BUTTON_SELECT -> {
				if(mapSelectToTouchpad)
				{
					if(event.action == KeyEvent.ACTION_DOWN)
						keyControllerState.buttons = keyControllerState.buttons or ControllerState.BUTTON_TOUCHPAD
					else
						keyControllerState.buttons = keyControllerState.buttons and ControllerState.BUTTON_TOUCHPAD.inv()
					processDpadTouch()
					controllerStateUpdated()
					return true
				}
			}
		}

		val buttonMask: UInt = when(event.keyCode)
		{
			// dpad handled by MotionEvents
			//KeyEvent.KEYCODE_DPAD_LEFT -> ControllerState.BUTTON_DPAD_LEFT
			//KeyEvent.KEYCODE_DPAD_RIGHT -> ControllerState.BUTTON_DPAD_RIGHT
			//KeyEvent.KEYCODE_DPAD_UP -> ControllerState.BUTTON_DPAD_UP
			//KeyEvent.KEYCODE_DPAD_DOWN -> ControllerState.BUTTON_DPAD_DOWN
			KeyEvent.KEYCODE_BUTTON_A -> if(swapCrossMoon) ControllerState.BUTTON_MOON else ControllerState.BUTTON_CROSS
			KeyEvent.KEYCODE_BUTTON_B -> if(swapCrossMoon) ControllerState.BUTTON_CROSS else ControllerState.BUTTON_MOON
			KeyEvent.KEYCODE_BUTTON_X -> if(swapCrossMoon) ControllerState.BUTTON_PYRAMID else ControllerState.BUTTON_BOX
			KeyEvent.KEYCODE_BUTTON_Y -> if(swapCrossMoon) ControllerState.BUTTON_BOX else ControllerState.BUTTON_PYRAMID
			KeyEvent.KEYCODE_BUTTON_L1 -> ControllerState.BUTTON_L1
			KeyEvent.KEYCODE_BUTTON_R1 -> ControllerState.BUTTON_R1
			KeyEvent.KEYCODE_BUTTON_THUMBL -> ControllerState.BUTTON_L3
			KeyEvent.KEYCODE_BUTTON_THUMBR -> ControllerState.BUTTON_R3
			KeyEvent.KEYCODE_BUTTON_SELECT -> ControllerState.BUTTON_SHARE
			KeyEvent.KEYCODE_BUTTON_START -> ControllerState.BUTTON_OPTIONS
			KeyEvent.KEYCODE_BUTTON_C -> ControllerState.BUTTON_PS
			KeyEvent.KEYCODE_BUTTON_MODE -> ControllerState.BUTTON_PS
			else -> return false
		}

		keyControllerState.buttons = keyControllerState.buttons.run {
			when(event.action)
			{
				KeyEvent.ACTION_DOWN -> this or buttonMask
				KeyEvent.ACTION_UP -> this and buttonMask.inv()
				else -> this
			}
		}

		processDpadTouch()
		controllerStateUpdated()
		return true
	}

	fun onGenericMotionEvent(event: MotionEvent): Boolean
	{
		if(event.source and InputDevice.SOURCE_CLASS_JOYSTICK != InputDevice.SOURCE_CLASS_JOYSTICK)
			return false
		fun Float.signedAxis() = (this * Short.MAX_VALUE).toInt().toShort()
		fun Float.unsignedAxis() = (this * UByte.MAX_VALUE.toFloat()).toUInt().toUByte()
		motionControllerState.leftX = event.getAxisValue(MotionEvent.AXIS_X).signedAxis()
		motionControllerState.leftY = event.getAxisValue(MotionEvent.AXIS_Y).signedAxis()
		motionControllerState.rightX = event.getAxisValue(MotionEvent.AXIS_Z).signedAxis()
		motionControllerState.rightY = event.getAxisValue(MotionEvent.AXIS_RZ).signedAxis()
		motionControllerState.l2State = event.getAxisValue(MotionEvent.AXIS_LTRIGGER).unsignedAxis()
		motionControllerState.r2State = event.getAxisValue(MotionEvent.AXIS_RTRIGGER).unsignedAxis()
		motionControllerState.buttons = motionControllerState.buttons.let {
			val dpadX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
			val dpadY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
			val dpadButtons =
				(if(dpadX > 0.5f) ControllerState.BUTTON_DPAD_RIGHT else 0U) or
						(if(dpadX < -0.5f) ControllerState.BUTTON_DPAD_LEFT else 0U) or
						(if(dpadY > 0.5f) ControllerState.BUTTON_DPAD_DOWN else 0U) or
						(if(dpadY < -0.5f) ControllerState.BUTTON_DPAD_UP else 0U)
			it and (ControllerState.BUTTON_DPAD_RIGHT or
					ControllerState.BUTTON_DPAD_LEFT or
					ControllerState.BUTTON_DPAD_DOWN or
					ControllerState.BUTTON_DPAD_UP).inv() or
					dpadButtons
		}
		//Log.i("StreamSession", "motionEvent => $motionControllerState")
		processDpadTouch()
		controllerStateUpdated()
		return true
	}

	private fun processDpadTouch()
	{
		if(!dpadTouchEnabled)
			return

		val rawButtons = keyControllerState.buttons or motionControllerState.buttons
		updateDpadModeToggle(rawButtons)

		if(dpadTouchIncrement <= 0 || dpadRegular)
		{
			cancelDpadTouchUpdate()
			if(dpadTouchId >= 0 && !dpadTouchStopScheduled)
				scheduleDpadTouchStop()
			return
		}

		val dpadHeld = rawButtons and DPAD_BUTTON_MASK
		if(dpadHeld != 0U)
		{
			cancelDpadTouchStop()
			handleDpadTouchEvent(dpadHeld, placeholder = false)
		}
		else
		{
			cancelDpadTouchUpdate()
			if(dpadTouchId >= 0 && !dpadTouchStopScheduled)
				scheduleDpadTouchStop()
		}
	}

	private fun updateDpadModeToggle(buttons: UInt)
	{
		val comboActive =
			(dpadTouchShortcut1 != 0U || dpadTouchShortcut2 != 0U || dpadTouchShortcut3 != 0U || dpadTouchShortcut4 != 0U) &&
			(dpadTouchShortcut1 == 0U || (buttons and dpadTouchShortcut1) != 0U) &&
			(dpadTouchShortcut2 == 0U || (buttons and dpadTouchShortcut2) != 0U) &&
			(dpadTouchShortcut3 == 0U || (buttons and dpadTouchShortcut3) != 0U) &&
			(dpadTouchShortcut4 == 0U || (buttons and dpadTouchShortcut4) != 0U)

		if(comboActive)
		{
			if(!dpadRegularTouchSwitched)
			{
				dpadRegularTouchSwitched = true
				dpadRegular = !dpadRegular
				val modeLabel = if(dpadRegular) "D-pad: Regular" else "D-pad: Touchpad"
				handler.post {
					android.widget.Toast.makeText(context, modeLabel, android.widget.Toast.LENGTH_SHORT).show()
				}
				cancelDpadTouchTimers()
				if(dpadRegular)
					stopDpadTouch()
			}
		}
		else
			dpadRegularTouchSwitched = false
	}

	private fun handleDpadTouchEvent(dpadButtons: UInt, placeholder: Boolean)
	{
		val increment = dpadTouchIncrement.toUShort()

		if(dpadButtons and ControllerState.BUTTON_DPAD_LEFT != 0U)
		{
			if(dpadTouchId < 0)
			{
				dpadTouchX = 0u.toUShort()
				dpadTouchY = touchpadMidY
				dpadTouchId = dpadTouchControllerState.startTouch(dpadTouchX, dpadTouchY)?.toInt() ?: -1
				if(!placeholder)
					scheduleDpadTouchUpdate()
				return
			}
			cancelDpadTouchStop()
			dpadTouchX = if(dpadTouchX < increment) 0u.toUShort() else (dpadTouchX - increment).toUShort()
			dpadTouchControllerState.setTouchPos(dpadTouchId.toUByte(), dpadTouchX, dpadTouchY)
			if(!placeholder)
				scheduleDpadTouchUpdate()
			return
		}

		if(dpadButtons and ControllerState.BUTTON_DPAD_RIGHT != 0U)
		{
			if(dpadTouchId < 0)
			{
				dpadTouchX = touchpadMaxX
				dpadTouchY = touchpadMidY
				dpadTouchId = dpadTouchControllerState.startTouch(dpadTouchX, dpadTouchY)?.toInt() ?: -1
				if(!placeholder)
					scheduleDpadTouchUpdate()
				return
			}
			cancelDpadTouchStop()
			dpadTouchX = if(dpadTouchX > touchpadMaxX - increment) touchpadMaxX else (dpadTouchX + increment).toUShort()
			dpadTouchControllerState.setTouchPos(dpadTouchId.toUByte(), dpadTouchX, dpadTouchY)
			if(!placeholder)
				scheduleDpadTouchUpdate()
			return
		}

		if(dpadButtons and ControllerState.BUTTON_DPAD_DOWN != 0U)
		{
			if(dpadTouchId < 0)
			{
				dpadTouchX = touchpadMidX
				dpadTouchY = touchpadMaxY
				dpadTouchId = dpadTouchControllerState.startTouch(dpadTouchX, dpadTouchY)?.toInt() ?: -1
				if(!placeholder)
					scheduleDpadTouchUpdate()
				return
			}
			cancelDpadTouchStop()
			dpadTouchY = if(dpadTouchY > touchpadMaxY - increment) touchpadMaxY else (dpadTouchY + increment).toUShort()
			dpadTouchControllerState.setTouchPos(dpadTouchId.toUByte(), dpadTouchX, dpadTouchY)
			if(!placeholder)
				scheduleDpadTouchUpdate()
			return
		}

		if(dpadButtons and ControllerState.BUTTON_DPAD_UP != 0U)
		{
			if(dpadTouchId < 0)
			{
				dpadTouchX = touchpadMidX
				dpadTouchY = 0u.toUShort()
				dpadTouchId = dpadTouchControllerState.startTouch(dpadTouchX, dpadTouchY)?.toInt() ?: -1
				if(!placeholder)
					scheduleDpadTouchUpdate()
				return
			}
			cancelDpadTouchStop()
			dpadTouchY = if(dpadTouchY < increment) 0u.toUShort() else (dpadTouchY - increment).toUShort()
			dpadTouchControllerState.setTouchPos(dpadTouchId.toUByte(), dpadTouchX, dpadTouchY)
			if(!placeholder)
				scheduleDpadTouchUpdate()
		}
	}

	private fun scheduleDpadTouchUpdate()
	{
		if(dpadTouchId < 0)
			return
		handler.removeCallbacks(dpadTouchUpdateRunnable)
		handler.postDelayed(dpadTouchUpdateRunnable, DPAD_TOUCH_UPDATE_INTERVAL_MS)
	}

	private fun cancelDpadTouchUpdate()
	{
		handler.removeCallbacks(dpadTouchUpdateRunnable)
	}

	private fun scheduleDpadTouchStop()
	{
		handler.removeCallbacks(dpadTouchStopRunnable)
		dpadTouchStopScheduled = true
		handler.postDelayed(dpadTouchStopRunnable, NEW_DPAD_TOUCH_INTERVAL_MS)
	}

	private fun cancelDpadTouchStop()
	{
		handler.removeCallbacks(dpadTouchStopRunnable)
		dpadTouchStopScheduled = false
	}

	private fun cancelDpadTouchTimers()
	{
		cancelDpadTouchUpdate()
		cancelDpadTouchStop()
	}

	private fun stopDpadTouch()
	{
		if(dpadTouchId < 0)
			return
		dpadTouchControllerState.stopTouch(dpadTouchId.toUByte())
		dpadTouchId = -1
		dpadTouchX = 0u.toUShort()
		dpadTouchY = 0u.toUShort()
	}

	companion object
	{
		private const val DPAD_TOUCH_UPDATE_INTERVAL_MS = 10L
		private const val NEW_DPAD_TOUCH_INTERVAL_MS = 500L

		private val DPAD_BUTTON_MASK = ControllerState.BUTTON_DPAD_LEFT or
			ControllerState.BUTTON_DPAD_RIGHT or
			ControllerState.BUTTON_DPAD_UP or
			ControllerState.BUTTON_DPAD_DOWN

		private fun shortcutMask(index: Int): UInt =
			if(index > 0) (1 shl (index - 1)).toUInt() else 0U
	}
}
