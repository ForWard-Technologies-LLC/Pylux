// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "gamelauncher.h"
#include "streamsession.h"

#include <chiaki/session.h>
#include <chiaki/ctrl.h>
#include <chiaki/controller.h>

GameLauncher::GameLauncher(StreamSession *session, const QString &game_name, QObject *parent)
	: QObject(parent)
	, session(session)
	, game_name(game_name)
	, step(0)
	, sub_step(0)
	, log(nullptr)
{
	if (session) {
		log = session->GetChiakiLog();
		connect(session, &StreamSession::ConnectedChanged, this, &GameLauncher::onConnectedChanged);
	}
}

GameLauncher::~GameLauncher()
{
	if (log) {
		CHIAKI_LOGI(log, "GameLauncher: Destroyed");
	}
}

void GameLauncher::start()
{
	if (!session) {
		deleteLater();
		return;
	}

	if (session->GetConnected()) {
		// Already connected, start immediately
		onConnectedChanged();
	}
	// Otherwise wait for ConnectedChanged signal
}

void GameLauncher::onConnectedChanged()
{
	if (!session || !session->GetConnected()) {
		return;
	}

	// Session is now connected, start the automation sequence
	logAction("Starting automation");
	CHIAKI_LOGI(log, "GameLauncher: Game name: '%s'", game_name.toUtf8().constData());

	// Start with step 0
	step = 0;
	sub_step = 0;
	executeNextStep();
}

void GameLauncher::executeNextStep()
{
	if (!session) {
		deleteLater();
		return;
	}

	switch (step) {
		case 0:
			// Step 0: Long press PS button
			logAction("Long press PS button (1500ms)");
			pressButton(CHIAKI_CONTROLLER_BUTTON_PS, 1500);
			scheduleNext(1600); // 1500ms press + 100ms after release
			break;

		case 1:
			// Step 1: Navigate right 5 times
			if (sub_step < 5) {
				logAction(QString("Navigate right (%1/5)").arg(sub_step + 1).toUtf8().constData());
				pressButton(CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT, 50);
				sub_step++;
				scheduleNext(100);
			} else {
				sub_step = 0;
				scheduleNext(100);
			}
			break;

		case 2:
			// Step 2: Press Cross/A
			logAction("Press Cross to select");
			pressButton(CHIAKI_CONTROLLER_BUTTON_CROSS, 50);
			scheduleNext(200); // Wait a bit longer after this press
			break;

		case 3:
			// Step 3: Navigate left once
			logAction("Navigate left (1/1)");
			pressButton(CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT, 50);
			scheduleNext(100);
			break;

		case 4:
			// Step 4: Press Cross/A to open search
			logAction("Press Cross to open search");
			pressButton(CHIAKI_CONTROLLER_BUTTON_CROSS, 50);
			scheduleNext(300); // Wait longer for keyboard to appear
			break;

		case 5:
			// Step 5: Send game name via keyboard
			logAction("Sending game name via keyboard");
			CHIAKI_LOGI(log, "GameLauncher: Keyboard input: '%s'", game_name.toUtf8().constData());
			{
				ChiakiSession *chiaki_session = session->GetChiakiSession();
				if (chiaki_session && chiaki_session->ctrl.session) {
					chiaki_ctrl_keyboard_set_text(&chiaki_session->ctrl, game_name.toUtf8().constData());
				}
			}
			scheduleNext(200);
			break;

		case 6:
			// Step 6: Press Cross/A to confirm/search
			logAction("Press Cross to confirm search");
			pressButton(CHIAKI_CONTROLLER_BUTTON_CROSS, 50);
			scheduleNext(100);
			break;

		case 7:
			// Step 7: Complete
			logAction("Automation complete");
			// Clean up after a short delay
			QTimer::singleShot(1000, this, [this]() {
				deleteLater();
			});
			return;

		default:
			// Shouldn't reach here
			logAction("Unexpected step, terminating");
			deleteLater();
			return;
	}

	step++;
}

void GameLauncher::pressButton(ChiakiControllerButton button, int duration_ms)
{
	if (!session) {
		return;
	}

	ChiakiSession *chiaki_session = session->GetChiakiSession();
	if (!chiaki_session) {
		return;
	}

	// Press the button
	ChiakiControllerState state;
	chiaki_controller_state_set_idle(&state);
	state.buttons = button;
	chiaki_session_set_controller_state(chiaki_session, &state);

	// Schedule button release
	QTimer::singleShot(duration_ms, this, [this, button, chiaki_session]() {
		if (session && chiaki_session) {
			releaseAllButtons();
		}
	});
}

void GameLauncher::releaseAllButtons()
{
	if (!session) {
		return;
	}

	ChiakiSession *chiaki_session = session->GetChiakiSession();
	if (!chiaki_session) {
		return;
	}

	ChiakiControllerState state;
	chiaki_controller_state_set_idle(&state);
	chiaki_session_set_controller_state(chiaki_session, &state);
}

void GameLauncher::scheduleNext(int delay_ms)
{
	QTimer::singleShot(delay_ms, this, [this]() {
		executeNextStep();
	});
}

void GameLauncher::logAction(const char *action)
{
	if (log) {
		CHIAKI_LOGI(log, "GameLauncher: %s", action);
	}
}

