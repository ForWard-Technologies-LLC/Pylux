// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "gamelauncher.h"
#include "streamsession.h"

#include <chiaki/session.h>
#include <chiaki/ctrl.h>
#include <chiaki/controller.h>
#include <QDateTime>

// Timing constants - adjust these to change all timings at once
static constexpr int INITIAL_DELAY = 1000;           // Initial delay before starting automation
static constexpr int BUTTON_PRESS_DURATION = 100;     // Standard button press duration
static constexpr int LONG_PRESS_DURATION = 500;     // Long press (PS button)
static constexpr int PAUSE_BETWEEN_ACTIONS = 300;    // Pause between each action
static constexpr int KEYBOARD_WAIT = 500;            // Wait for keyboard to open
static constexpr int KEYBOARD_TEXT_PAUSE = 1000;     // Pause after sending text before accepting
static constexpr int CLEANUP_DELAY = 1000;           // Delay before cleanup
static constexpr int ANALOG_STICK_HOLD_DURATION = 2000; // Hold analog stick for 2 seconds

GameLauncher::GameLauncher(StreamSession *session, const QString &game_name, QObject *parent)
	: QObject(parent)
	, session(session)
	, game_name(game_name)
	, log(nullptr)
	, start_timestamp(0)
	, current_action_index(0)
	, is_shutting_down(std::make_shared<bool>(false))
{
	if (session) {
		log = session->GetChiakiLog();
		connect(session, &StreamSession::ConnectedChanged, this, &GameLauncher::onConnectedChanged);
	}
}

GameLauncher::~GameLauncher()
{
	// Set shutdown flag to prevent any pending callbacks from running
	*is_shutting_down = true;
	
	if (log) {
		CHIAKI_LOGI(log, "GameLauncher: Destroyed");
	}
	
	// Disconnect all signals to prevent accessing destroyed objects
	disconnect();
	
	// Null out session pointer to catch any accidental use after destruction
	session = nullptr;
	log = nullptr;
}

void GameLauncher::scheduleSafe(int msec, std::function<void()> callback)
{
	auto shutdown = is_shutting_down;
	QTimer::singleShot(msec, this, [shutdown, callback]() {
		if (*shutdown) return;
		callback();
	});
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
	start_timestamp = QDateTime::currentMSecsSinceEpoch();
	logAction("Starting automation");
	CHIAKI_LOGI(log, "GameLauncher: [T+0 ms] Starting automation");
	CHIAKI_LOGI(log, "GameLauncher: Game name: '%s'", game_name.toUtf8().constData());

	// Build the list of actions to execute
	std::vector<Action> action_list;
	
	// Initial delay
	action_list.push_back({[this](auto next) { 
		scheduleSafe(INITIAL_DELAY, next);
	}});
	
	// Action 1: Long press PS button
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_PS, "Long press PS button", LONG_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Action 2: Nav UP/LEFT/ENTER - Ensures on games tab
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_DPAD_UP, "Navigate up", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT, "Navigate left", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_CROSS, "Press Cross to select", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});

	// Action 3: Navigate left to reset partial searches
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT, "Navigate left", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});

	// Action 4: Hold left stick right for 2 seconds to navigate to search
	action_list.push_back({[this](auto next) {
		holdAnalogStickAndContinue(0x7fff, 0, "Hold left stick right", ANALOG_STICK_HOLD_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Action 5: Press Cross to select
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_CROSS, "Press Cross to select", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Action 6: Navigate left
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT, "Navigate left", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Action 7: Press Cross to open search
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_CROSS, "Press Cross to open search", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Action 8: Wait for keyboard to open
	action_list.push_back({[this](auto next) { 
		scheduleSafe(KEYBOARD_WAIT, next);
	}});
	
	// Action 9: Send keyboard text
	action_list.push_back({[this](auto next) {
		sendKeyboardTextAndContinue(game_name, KEYBOARD_TEXT_PAUSE, next);
	}});
	
	// Action 10: Go down to select game
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN, "Go down to select game", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Action 11: Press Cross to confirm (1)
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_CROSS, "Press Cross to confirm (1)", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Action 12: Wait 1 second before final select
	action_list.push_back({[this](auto next) { 
		scheduleSafe(1000, next);
	}});
	
	// Action 13: Press Cross to confirm (2)
	action_list.push_back({[this](auto next) {
		pressButtonAndContinue(CHIAKI_CONTROLLER_BUTTON_CROSS, "Press Cross to confirm (2)", BUTTON_PRESS_DURATION, PAUSE_BETWEEN_ACTIONS, next);
	}});
	
	// Start executing the action chain
	runAll(action_list);
}

void GameLauncher::pressButtonAndContinue(ChiakiControllerButton button, const char *action_name, int press_duration, int pause_after, std::function<void()> next)
{
	if (shouldAbort() || !session || !session->GetConnected())
		return;
	
	qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - start_timestamp;
	logAction(action_name);
	CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] %s", elapsed, action_name);
	
	// Press the button
	session->keyboard_state.buttons |= button;
	session->SendFeedbackState();
	
	// Release after press_duration, then pause, then continue
	scheduleSafe(press_duration, [this, pause_after, next]() {
		if (!session || !session->GetConnected())
			return;
		
		qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - start_timestamp;
		CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] Releasing all buttons", elapsed);
		
		session->keyboard_state.buttons = 0;
		session->SendFeedbackState();
		
		// Pause after release, then call next
		scheduleSafe(pause_after, next);
	});
}

void GameLauncher::holdAnalogStickAndContinue(int16_t left_x, int16_t left_y, const char *action_name, int hold_duration, int pause_after, std::function<void()> next)
{
	if (shouldAbort() || !session || !session->GetConnected())
		return;
	
	qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - start_timestamp;
	logAction(action_name);
	CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] %s (x=%d, y=%d)", elapsed, action_name, left_x, left_y);
	
	// Set analog stick position
	session->keyboard_state.left_x = left_x;
	session->keyboard_state.left_y = left_y;
	session->SendFeedbackState();
	
	// Release after hold_duration, then pause, then continue
	scheduleSafe(hold_duration, [this, pause_after, next]() {
		if (!session || !session->GetConnected())
			return;
		
		qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - start_timestamp;
		CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] Centering analog sticks", elapsed);
		
		// Center the analog sticks
		session->keyboard_state.left_x = 0;
		session->keyboard_state.left_y = 0;
		session->SendFeedbackState();
		
		// Pause after release, then call next
		scheduleSafe(pause_after, next);
	});
}

void GameLauncher::sendKeyboardTextAndContinue(const QString &text, int pause_after, std::function<void()> next)
{
	if (shouldAbort() || !session || !session->GetConnected())
		return;
	
	qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - start_timestamp;
	logAction("Sending game name via keyboard");
	CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] Sending game name via keyboard", elapsed);
	CHIAKI_LOGI(log, "GameLauncher: Keyboard input: '%s'", text.toUtf8().constData());
	
	ChiakiSession *chiaki_session = session->GetChiakiSession();
	if (chiaki_session) {
		ChiakiErrorCode err = chiaki_ctrl_keyboard_set_text(&chiaki_session->ctrl, text.toUtf8().constData());
		if (err == CHIAKI_ERR_SUCCESS) {
			CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] Keyboard text sent successfully", 
			            QDateTime::currentMSecsSinceEpoch() - start_timestamp);
		} else {
			CHIAKI_LOGE(log, "GameLauncher: [T+%lld ms] Failed to send keyboard text, error: %d", 
			            QDateTime::currentMSecsSinceEpoch() - start_timestamp, err);
		}
	} else {
		CHIAKI_LOGE(log, "GameLauncher: Failed to get ChiakiSession");
	}
	
	// Wait for text to appear, then accept keyboard
	scheduleSafe(pause_after, [this, pause_after, next]() {
		if (!session || !session->GetConnected())
			return;
		
		ChiakiSession *chiaki_session = session->GetChiakiSession();
		if (chiaki_session) {
			ChiakiErrorCode err = chiaki_ctrl_keyboard_accept(&chiaki_session->ctrl);
			if (err == CHIAKI_ERR_SUCCESS) {
				CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] Keyboard accepted", 
				            QDateTime::currentMSecsSinceEpoch() - start_timestamp);
			} else {
				CHIAKI_LOGE(log, "GameLauncher: [T+%lld ms] Failed to accept keyboard, error: %d", 
				            QDateTime::currentMSecsSinceEpoch() - start_timestamp, err);
			}
		}
		
		// Pause again, then continue
		scheduleSafe(pause_after, next);
	});
}

void GameLauncher::runAll(std::vector<Action> action_list)
{
	actions = std::move(action_list);
	current_action_index = 0;
	runNextAction();
}

void GameLauncher::runNextAction()
{
	if (shouldAbort())
		return;
		
	if (current_action_index >= actions.size()) {
		onComplete();
		return;
	}
	
	// Execute current action with a callback to run the next one
	Action &current = actions[current_action_index];
	current_action_index++;
	
	current.execute([this]() {
		if (shouldAbort()) return;
		runNextAction();
	});
}

void GameLauncher::onComplete()
{
	if (shouldAbort())
		return;
		
	qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - start_timestamp;
	logAction("Automation complete");
	CHIAKI_LOGI(log, "GameLauncher: [T+%lld ms] Automation complete", elapsed);
	
	// Only emit signal if session is still valid
	if (session)
		emit automationCompleted();
	
	scheduleSafe(CLEANUP_DELAY, [this]() {
		deleteLater();
	});
}

void GameLauncher::logAction(const char *action)
{
	if (log) {
		CHIAKI_LOGI(log, "GameLauncher: %s", action);
	}
}

