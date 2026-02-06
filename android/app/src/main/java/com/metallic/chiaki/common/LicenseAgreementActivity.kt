// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.content.Intent
import android.os.Bundle
import android.text.method.ScrollingMovementMethod
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import com.pylux.stream.R

class LicenseAgreementActivity : AppCompatActivity()
{
	companion object {
		const val EXTRA_VIEW_ONLY = "view_only"
	}
	
	private lateinit var preferences: Preferences
	private lateinit var agreeCheckbox: CheckBox
	private lateinit var acceptButton: Button
	private lateinit var declineButton: Button
	private lateinit var buttonContainer: LinearLayout
	private lateinit var closeButton: Button
	private var isViewOnly = false
	
	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		setContentView(R.layout.activity_license_agreement)
		
		preferences = Preferences(this)
		isViewOnly = intent.getBooleanExtra(EXTRA_VIEW_ONLY, false)
		
		val licenseTextView = findViewById<TextView>(R.id.licenseTextView)
		agreeCheckbox = findViewById(R.id.agreeCheckbox)
		acceptButton = findViewById(R.id.acceptButton)
		declineButton = findViewById(R.id.declineButton)
		buttonContainer = findViewById(R.id.buttonContainer)
		closeButton = findViewById(R.id.closeButton)
		
		// Make license text scrollable
		licenseTextView.movementMethod = ScrollingMovementMethod()
		
		// Set license text
		licenseTextView.text = getLicenseText()
		
		if (isViewOnly) {
			// Viewing from settings - hide checkbox and accept/decline buttons, show close button
			agreeCheckbox.visibility = View.GONE
			buttonContainer.visibility = View.GONE
			closeButton.visibility = View.VISIBLE
			
			closeButton.setOnClickListener {
				finish()
			}
		} else {
			// First launch - show accept/decline
			acceptButton.isEnabled = false
			
			// Enable accept button when checkbox is checked
			agreeCheckbox.setOnCheckedChangeListener { _, isChecked ->
				acceptButton.isEnabled = isChecked
			}
			
			acceptButton.setOnClickListener {
				preferences.setLicenseAgreed(true)
				// Return to MainActivity
				val intent = Intent(this, com.metallic.chiaki.main.MainActivity::class.java)
				intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
				startActivity(intent)
				finish()
			}
			
			declineButton.setOnClickListener {
				// User declined - close the app
				finishAffinity()
			}
			
			// Prevent back button on first launch
			onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
				override fun handleOnBackPressed() {
					// Don't allow back press on first launch
				}
			})
		}
	}
	
	private fun getLicenseText(): String
	{
		val licenseInputStream = resources.openRawResource(R.raw.agpl_license)
		val disclaimerInputStream = resources.openRawResource(R.raw.disclaimer)
		
		val licenseText = licenseInputStream.bufferedReader().use { it.readText() }
		val disclaimerText = disclaimerInputStream.bufferedReader().use { it.readText() }
		
		return licenseText + "\n\n" + disclaimerText
	}
}
