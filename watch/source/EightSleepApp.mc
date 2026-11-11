using Toybox.Application;
using Toybox.Application.Storage;
using Toybox.System;
using Toybox.WatchUi;

class EightSleepApp extends Application.AppBase {

    // Set by the delegate when the user exits on purpose (BACK twice).
    var userExit = false;

    // Times at which the watch itself closed the app (most recent last),
    // e.g. ["22:01", "3:20"]. Shown once on the next launch so we can tell
    // what is closing it overnight.
    var closedTimes = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        var saved = Storage.getValue("closedTimes");
        if (saved instanceof Toybox.Lang.Array && saved.size() > 0) {
            closedTimes = saved;
        }
    }

    function onStop(state) {
        if (userExit) {
            Storage.deleteValue("closedTimes");
            return;
        }
        var t = System.getClockTime();
        var times = (closedTimes != null) ? closedTimes : [];
        times.add(t.hour.format("%d") + ":" + t.min.format("%02d"));
        if (times.size() > 3) {
            times = times.slice(times.size() - 3, null);
        }
        Storage.setValue("closedTimes", times);
    }

    function getInitialView() {
        var view = new EightSleepView();
        return [ view, new EightSleepDelegate(view) ];
    }
}
