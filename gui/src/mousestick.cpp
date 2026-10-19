// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "mousestick.h"

#include <QCursor>
#include <QWindow>

#include <algorithm>
#include <cmath>

// Mouse speed (logical pixels per second) that fully tilts the stick at sensitivity 1.0
#define MOUSE_STICK_FULL_TILT_SPEED 3000.0
// Speed is measured over at least this span, so high polling rate mice don't add noise
#define MOUSE_STICK_MIN_SPAN_NS (8LL * 1000 * 1000)
// The first move after rest reports motion that started earlier, assume it covers this span
#define MOUSE_STICK_START_SPAN_NS (12LL * 1000 * 1000)
// The mouse counts as stopped after this many reporting intervals without motion,
// clamped to the range below
#define MOUSE_STICK_STOP_INTERVALS 2.5
#define MOUSE_STICK_STOP_MIN_NS (25LL * 1000 * 1000)
#define MOUSE_STICK_STOP_MAX_NS (80LL * 1000 * 1000)
// Time constant smoothing the steps between bursts of mouse moves
#define MOUSE_STICK_SMOOTHING_S 0.012
// Speed (pixels per second) below which motion is treated as hand jitter
#define MOUSE_STICK_MIN_SPEED 30.0
// Smallest stick change worth sending (2% of the axis range); every controller state
// packet shares the connection with the video stream
#define MOUSE_STICK_MIN_CHANGE 655
// After a longer pause (focus change, in-stream menu, cursor re-entering the window)
// tracking restarts from the current position instead of producing a jump
#define MOUSE_STICK_RESYNC_NS (100LL * 1000 * 1000)

void MouseStick::SetParameters(float sensitivity, float deadzone_compensation)
{
	this->sensitivity = std::clamp(sensitivity, 0.01f, 100.0f);
	this->deadzone_compensation = std::clamp(deadzone_compensation, 0.0f, 0.9f);
}

bool MouseStick::Move(QWindow *window, const QPointF &global_pos, qint64 now_ns)
{
	if(!window || !window->isActive())
	{
		tracking = false;
		warp_pending = false;
		return false;
	}

	if(warp_pending)
	{
		warp_pending = false;
		// The move caused by our own warp carries no user motion
		if(std::abs(global_pos.x() - warp_target.x()) < 2.0 && std::abs(global_pos.y() - warp_target.y()) < 2.0)
		{
			last_pos = global_pos;
			last_move_ns = now_ns;
			return false;
		}
		last_pos = warp_target;
	}

	bool moved = false;
	if(tracking && now_ns - last_move_ns < MOUSE_STICK_RESYNC_NS)
	{
		QPointF delta = global_pos - last_pos;
		if(!delta.isNull())
		{
			AddMotion(delta, now_ns);
			moved = true;
		}
	}
	else
		window->setCursor(Qt::BlankCursor);
	tracking = true;
	last_pos = global_pos;
	last_move_ns = now_ns;

	// Warp back to the center well before the cursor could leave the window
	const QPoint center = window->mapToGlobal(QPoint(window->width() / 2, window->height() / 2));
	if(std::abs(global_pos.x() - center.x()) > window->width() / 4.0
			|| std::abs(global_pos.y() - center.y()) > window->height() / 4.0)
	{
		QCursor::setPos(window->screen(), center);
		warp_target = center;
		warp_pending = true;
	}
	return moved;
}

void MouseStick::AddMotion(const QPointF &delta, qint64 now_ns)
{
	if(!moving)
	{
		history.clear();
		motion = QPointF();
		history.append({now_ns - MOUSE_STICK_START_SPAN_NS, motion});
		last_update_ns = now_ns;
		moving = true;
	}
	motion += delta;
	history.append({now_ns, motion});

	// Measure from the newest sample that is at least the minimum span old. With moves arriving
	// in bursts this is the previous burst, so speed = motion of the burst / time since the last one.
	while(history.size() > 2 && now_ns - history[1].time_ns >= MOUSE_STICK_MIN_SPAN_NS)
		history.removeFirst();
	const Sample &from = history.first();
	const qint64 span_ns = std::max<qint64>(now_ns - from.time_ns, 1);
	target_velocity = (motion - from.motion) * (1e9 / span_ns);
	stop_after_ns = std::clamp<qint64>(static_cast<qint64>(span_ns * MOUSE_STICK_STOP_INTERVALS),
			MOUSE_STICK_STOP_MIN_NS, MOUSE_STICK_STOP_MAX_NS);
	last_motion_ns = now_ns;
}

bool MouseStick::Update(qint64 now_ns, int16_t *x, int16_t *y)
{
	if(!moving)
	{
		*x = output_x = 0;
		*y = output_y = 0;
		return false;
	}
	if(now_ns - last_motion_ns > stop_after_ns)
	{
		// Stop right away, easing out would make the camera overshoot
		moving = false;
		velocity = QPointF();
		*x = output_x = 0;
		*y = output_y = 0;
		return false;
	}

	const double dt = (now_ns - last_update_ns) / 1e9;
	last_update_ns = now_ns;
	velocity += (target_velocity - velocity) * (1.0 - std::exp(-dt / MOUSE_STICK_SMOOTHING_S));

	int16_t new_x = 0;
	int16_t new_y = 0;
	const double speed = std::hypot(velocity.x(), velocity.y());
	if(speed >= MOUSE_STICK_MIN_SPEED)
	{
		const double tilt = std::min(1.0, speed * sensitivity / MOUSE_STICK_FULL_TILT_SPEED);
		const double magnitude = deadzone_compensation + (1.0 - deadzone_compensation) * tilt;
		new_x = static_cast<int16_t>(std::lround(velocity.x() / speed * magnitude * INT16_MAX));
		new_y = static_cast<int16_t>(std::lround(velocity.y() / speed * magnitude * INT16_MAX));
	}

	const bool at_rest = !output_x && !output_y;
	const bool to_rest = !new_x && !new_y;
	if(at_rest != to_rest
			|| std::abs(new_x - output_x) >= MOUSE_STICK_MIN_CHANGE
			|| std::abs(new_y - output_y) >= MOUSE_STICK_MIN_CHANGE)
	{
		output_x = new_x;
		output_y = new_y;
	}
	*x = output_x;
	*y = output_y;
	return true;
}
