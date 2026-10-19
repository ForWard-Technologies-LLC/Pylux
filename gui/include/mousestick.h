// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_MOUSESTICK_H
#define CHIAKI_MOUSESTICK_H

#include <QList>
#include <QPoint>
#include <QPointF>

#include <stdint.h>

class QWindow;

/**
 * Turns mouse motion into right analog stick deflection ("mouse look").
 *
 * While the stream window is focused the cursor is hidden and warped back to the window
 * center before it can leave the window. The stick is tilted proportionally to mouse speed,
 * starting from a minimum deflection that overcomes the game's own stick dead zone.
 *
 * Mouse moves often arrive in bursts (once per rendered frame), so speed is measured between
 * the actual times motion was reported instead of over a fixed window, which would alias
 * with the burst rate and make the camera stutter.
 */
class MouseStick
{
	public:
		MouseStick() = default;
		void SetParameters(float sensitivity, float deadzone_compensation);

		/**
		 * Feed a mouse move in global (screen) coordinates.
		 * @return true if the move produced stick motion
		 */
		bool Move(QWindow *window, const QPointF &global_pos, qint64 now_ns);

		/**
		 * Feed relative mouse motion, as Move() does after tracking the cursor.
		 */
		void AddMotion(const QPointF &delta, qint64 now_ns);

		/**
		 * Compute the current stick deflection. Changes too small for the game to notice keep the
		 * previous value, so the caller only has to send a new controller state when it changes.
		 * @return false once the mouse stopped, i.e. the stick is back at rest
		 */
		bool Update(qint64 now_ns, int16_t *x, int16_t *y);

	private:
		struct Sample
		{
			qint64 time_ns;
			QPointF motion;
		};

		float sensitivity = 1.0f;
		float deadzone_compensation = 0.15f;

		// speed measurement
		QList<Sample> history;
		QPointF motion; // accumulated since the mouse started moving
		QPointF target_velocity; // pixels per second
		QPointF velocity; // smoothed
		qint64 last_motion_ns = 0;
		qint64 stop_after_ns = 0;
		qint64 last_update_ns = 0;
		bool moving = false;
		int16_t output_x = 0;
		int16_t output_y = 0;

		// cursor capture
		bool tracking = false;
		QPointF last_pos;
		qint64 last_move_ns = 0;
		bool warp_pending = false;
		QPoint warp_target;
};

#endif // CHIAKI_MOUSESTICK_H
