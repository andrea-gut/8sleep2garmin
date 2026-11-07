using Toybox.WatchUi;
using Toybox.System;

// UP = warmer, DOWN = cooler, START/ENTER = re-read status.
// BACK must be pressed twice within 2 s to exit, so a sleepy mis-press
// doesn't close the app in the middle of the night.
class EightSleepDelegate extends WatchUi.BehaviorDelegate {

    var view;
    var lastBackMs = 0;

    function initialize(v) {
        BehaviorDelegate.initialize();
        view = v;
    }

    // On fenix the system turns UP into onPreviousPage, DOWN into onNextPage
    // and START into onSelect before onKey is consulted, so the work lives here.
    function onPreviousPage() {
        System.println("onPreviousPage (UP)");
        view.adjust(Config.STEP);
        return true;
    }

    function onNextPage() {
        System.println("onNextPage (DOWN)");
        view.adjust(-Config.STEP);
        return true;
    }

    function onSelect() {
        System.println("onSelect (START)");
        view.refresh();
        return true;
    }

    // Fallback for any device that delivers raw keys without a behaviour mapping.
    function onKey(keyEvent) {
        var key = keyEvent.getKey();
        System.println("onKey " + key);
        if (key == WatchUi.KEY_UP) {
            view.adjust(Config.STEP);
            return true;
        }
        if (key == WatchUi.KEY_DOWN) {
            view.adjust(-Config.STEP);
            return true;
        }
        if (key == WatchUi.KEY_ENTER || key == WatchUi.KEY_START) {
            view.refresh();
            return true;
        }
        return false;
    }

    function onBack() {
        var now = System.getTimer();
        if (now - lastBackMs < 2000) {
            return false;            // second press: let the system exit the app
        }
        lastBackMs = now;
        view.status = "BACK again to exit";
        view.statusIsError = false;
        WatchUi.requestUpdate();
        return true;
    }
}
