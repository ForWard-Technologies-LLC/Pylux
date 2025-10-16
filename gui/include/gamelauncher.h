// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_GAMELAUNCHER_H
#define CHIAKI_GAMELAUNCHER_H

#include <QObject>
#include <QTimer>
#include <QString>
#include <functional>
#include <vector>
#include <chiaki/session.h>

class StreamSession;

/**
 * GameLauncher - Automated PS5 UI navigation to launch a specific game
 * 
 * This class handles the automated button sequence to navigate the PS5 UI
 * and launch a game by name after the stream session connects.
 * 
 * Sequence:
 * 1. Wait for session to connect
 * 2. Long press PS button (1500ms)
 * 3. Navigate right 5 times
 * 4. Press Cross/A
 * 5. Navigate left once
 * 6. Press Cross/A
 * 7. Send keyboard text with game name
 * 8. Press Cross/A to confirm
 * 
 * The class self-destructs after completing the sequence.
 */
class GameLauncher : public QObject
{
	Q_OBJECT

private:
	// Action represents a single step in the automation sequence
	struct Action {
		std::function<void(std::function<void()>)> execute; // Function that takes a 'next' callback
	};

	StreamSession *session;
	QString game_name;
	ChiakiLog *log;
	qint64 start_timestamp;
	std::vector<Action> actions;
	size_t current_action_index;

	// Helper methods
	void pressButtonAndContinue(ChiakiControllerButton button, const char *action_name, int press_duration, int pause_after, std::function<void()> next);
	void holdAnalogStickAndContinue(int16_t left_x, int16_t left_y, const char *action_name, int hold_duration, int pause_after, std::function<void()> next);
	void sendKeyboardTextAndContinue(const QString &text, int pause_after, std::function<void()> next);
	void logAction(const char *action);
	
	// Action execution
	void runAll(std::vector<Action> action_list);
	void runNextAction();
	void onComplete();

private slots:
	void onConnectedChanged();

public:
	explicit GameLauncher(StreamSession *session, const QString &game_name, QObject *parent = nullptr);
	~GameLauncher();

	void start();
};

#endif // CHIAKI_GAMELAUNCHER_H

