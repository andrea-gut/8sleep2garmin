using Toybox.Application;
using Toybox.WatchUi;

class EightSleepApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
    }

    function onStop(state) {
    }

    function getInitialView() {
        var view = new EightSleepView();
        return [ view, new EightSleepDelegate(view) ];
    }
}
