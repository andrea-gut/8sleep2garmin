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

    var sendTimer;
    var refreshTimer;

    function initialize() {
        View.initialize();
        sendTimer = new Timer.Timer();
        refreshTimer = new Timer.Timer();
    }

    function onShow() {
        refresh();
        refreshTimer.start(method(:onRefreshTimer), Config.REFRESH_MS, true);
    }

    function onHide() {
        refreshTimer.stop();
        sendTimer.stop();
    }

    // ---- actions ----

    function adjust(delta) {
        System.println("adjust " + delta);
        pendingDelta += delta;
        status = (pendingDelta > 0 ? "Warmer +" : "Cooler ") + pendingDelta;
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
            status = (state != null && !state.equals("smart")) ? "Side is off" : "Ready";
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

        // side label
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var sideText = side.equals("") ? "Bed" : (side.equals("me") ? "My side" : side + " side");
        dc.drawText(cx, (h * 0.17).toNumber(), Graphics.FONT_SMALL, sideText,
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
        dc.drawText(cx, (h * 0.45).toNumber(), Graphics.FONT_NUMBER_HOT, levelText,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // approximate temperature
        if (shown != null) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.62).toNumber(), Graphics.FONT_TINY, "~" + approxF(shown) + " F",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // status line
        dc.setColor(statusIsError ? Graphics.COLOR_RED : Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.75).toNumber(), Graphics.FONT_SMALL, status,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // button hints
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.83).toNumber(), Graphics.FONT_XTINY, "UP warm   DOWN cool",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function formatLevel(n) {
        if (n > 0) { return "+" + n; }
        return "" + n;
    }

    function clamp(n) {
        if (n > 100) { return 100; }
        if (n < -100) { return -100; }
        return n;
    }

    // Rough mapping of the -100..100 level to Fahrenheit, interpolated from
    // Eight Sleep's published points (55F at -100, 81F at 0, 111F at +100).
    function approxF(n) {
        var xs = [-100, -50, -25, 0, 25, 50, 75, 100];
        var ys = [55, 70, 75, 81, 89, 97, 105, 111];
        if (n <= xs[0]) { return ys[0]; }
        for (var i = 1; i < xs.size(); i++) {
            if (n <= xs[i]) {
                var t = (n - xs[i - 1]).toFloat() / (xs[i] - xs[i - 1]);
                return (ys[i - 1] + t * (ys[i] - ys[i - 1]) + 0.5).toNumber();
            }
        }
        return ys[ys.size() - 1];
    }
}
