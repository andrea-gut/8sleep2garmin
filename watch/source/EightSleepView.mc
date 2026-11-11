using Toybox.Application;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Timer;
using Toybox.System;

// Shows the bed's target level and sends UP/DOWN nudges to the relay.
// Several quick presses are combined into one request.
class EightSleepView extends WatchUi.View {

    var level = null;          // last target level reported by the relay
    var state = null;          // "smart" or "off"
    var side = "";
    var pendingDelta = 0;      // presses not yet sent
    var busy = false;
    var status = "Connecting";
    var statusIsError = false;
    var closedNote = null;     // "closed 22:01 3:20" until the first button press

    var sendTimer;
    var refreshTimer;
    var clockTimer;

    function initialize() {
        View.initialize();
        sendTimer = new Timer.Timer();
        refreshTimer = new Timer.Timer();
        clockTimer = new Timer.Timer();
        var times = Application.getApp().closedTimes;
        if (times != null) {
            closedNote = "closed";
            for (var i = 0; i < times.size(); i++) {
                closedNote = closedNote + " " + times[i];
            }
            System.println(closedNote);
        }
    }

    function onShow() {
        refresh();
        refreshTimer.start(method(:onRefreshTimer), Config.REFRESH_MS, true);
        clockTimer.start(method(:onClockTimer), 30 * 1000, true);
    }

    function onHide() {
        refreshTimer.stop();
        sendTimer.stop();
        clockTimer.stop();
    }

    function onClockTimer() {
        WatchUi.requestUpdate();
    }

    // "11:42" or "23:42" following the watch's own time format setting.
    function clockText() {
        var t = System.getClockTime();
        var hour = t.hour;
        var settings = System.getDeviceSettings();
        if (settings != null && !settings.is24Hour) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        return hour.format("%d") + ":" + t.min.format("%02d");
    }

    // ---- actions ----

    function adjust(delta) {
        System.println("adjust " + delta);
        closedNote = null;
        pendingDelta += delta;
        status = (pendingDelta > 0 ? "Warmer +" : "Cooler ") + toAppScale(pendingDelta);
        statusIsError = false;
        sendTimer.stop();
        sendTimer.start(method(:onSendTimer), Config.COALESCE_MS, false);
        WatchUi.requestUpdate();
    }

    function refresh() {
        if (busy) { return; }
        if (!Relay.phoneConnected()) {
            setError("No phone");
            return;
        }
        busy = true;
        Relay.getJson("/status", method(:onStatusResponse));
    }

    function onSendTimer() {
        if (pendingDelta == 0) { return; }
        if (busy) {
            // a request is in flight; try again shortly
            sendTimer.start(method(:onSendTimer), 400, false);
            return;
        }
        if (!Relay.phoneConnected()) {
            pendingDelta = 0;
            setError("No phone");
            return;
        }
        var delta = pendingDelta;
        pendingDelta = 0;
        busy = true;
        status = "Sending";
        statusIsError = false;
        WatchUi.requestUpdate();
        Relay.postJson("/adjust", { "delta" => delta }, method(:onAdjustResponse));
    }

    function onRefreshTimer() {
        refresh();
    }

    // ---- responses ----

    function onStatusResponse(code, data) {
        busy = false;
        applyResponse(code, data);
    }

    function onAdjustResponse(code, data) {
        busy = false;
        applyResponse(code, data);
        if (pendingDelta != 0) {
            // presses arrived while we were sending
            sendTimer.start(method(:onSendTimer), 100, false);
        }
    }

    function applyResponse(code, data) {
        System.println("response " + code);
        if (code == 200 && data instanceof Toybox.Lang.Dictionary) {
            if (data["level"] != null) { level = data["level"]; }
            if (data["state"] != null) { state = data["state"]; }
            if (data["side"] != null) { side = data["side"]; }
            // Eight Sleep reports "off", or a phase such as "smart:bedtime" when on.
            status = (state != null && state.equals("off")) ? "Side is off" : "Ready";
            statusIsError = false;
        } else {
            setError(Relay.describe(code));
        }
        WatchUi.requestUpdate();
    }

    function setError(text) {
        status = text;
        statusIsError = true;
        WatchUi.requestUpdate();
    }

    // ---- drawing ----

    function onUpdate(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // clock
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.22).toNumber(), Graphics.FONT_NUMBER_MEDIUM, clockText(),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // side label
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var sideText = side.equals("") ? "Bed" : (side.equals("me") ? "My side" : side + " side");
        if (closedNote != null) { sideText = closedNote; }
        dc.drawText(cx, (h * 0.39).toNumber(), Graphics.FONT_XTINY, sideText,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // big level number (shows the pending target while presses are queued)
        var shown = level;
        if (shown != null && pendingDelta != 0) {
            shown = clamp(shown + pendingDelta);
        }
        var levelText = (shown == null) ? "--" : formatLevel(shown);
        var color = Graphics.COLOR_WHITE;
        if (shown != null) {
            color = shown > 0 ? Graphics.COLOR_ORANGE : (shown < 0 ? Graphics.COLOR_BLUE : Graphics.COLOR_WHITE);
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.57).toNumber(), Graphics.FONT_NUMBER_HOT, levelText,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // status line
        dc.setColor(statusIsError ? Graphics.COLOR_RED : Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.78).toNumber(), Graphics.FONT_SMALL, status,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // The Eight Sleep app shows -10..+10; the API works in -100..+100.
    // Show the app's scale so the watch and the phone agree.
    function formatLevel(raw) {
        var n = toAppScale(raw);
        if (n > 0) { return "+" + n; }
        return "" + n;
    }

    function toAppScale(raw) {
        if (raw >= 0) { return (raw + 5) / 10; }
        return -((-raw + 5) / 10);
    }

    function clamp(n) {
        if (n > 100) { return 100; }
        if (n < -100) { return -100; }
        return n;
    }

}
