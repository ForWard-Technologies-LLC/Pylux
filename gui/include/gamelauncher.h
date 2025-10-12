// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_GAMELAUNCHER_H
#define CHIAKI_GAMELAUNCHER_H

#include <QObject>
#include <QTimer>
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
	StreamSession *session;
	QString game_name;
	int step;
	int sub_step;
	ChiakiLog *log;

	void executeNextStep();
	void pressButton(ChiakiControllerButton button, int duration_ms);
	void releaseAllButtons();
	void scheduleNext(int delay_ms);
	void logAction(const char *action);

private slots:
	void onConnectedChanged();

public:
	explicit GameLauncher(StreamSession *session, const QString &game_name, QObject *parent = nullptr);
	~GameLauncher();

	void start();
};

#endif // CHIAKI_GAMELAUNCHER_H

