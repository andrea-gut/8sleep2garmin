using Toybox.Communications;
using Toybox.System;

// Thin wrapper over makeWebRequest. Requests go through the phone's
// Garmin Connect app, so the phone must be nearby with Bluetooth on.
module Relay {

    function getJson(path, callback) {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + Config.RELAY_SECRET },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(Config.RELAY_URL + path + "?side=" + Config.SIDE, null, options, callback);
    }

    function postJson(path, params, callback) {
        params.put("side", Config.SIDE);
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                "Authorization" => "Bearer " + Config.RELAY_SECRET
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(Config.RELAY_URL + path, params, options, callback);
    }

    function phoneConnected() {
        var settings = System.getDeviceSettings();
        return settings != null && settings.phoneConnected;
    }

    // Human-readable text for a makeWebRequest response code.
    function describe(code) {
        if (code == 200) { return "OK"; }
        if (code == 401) { return "Bad secret"; }
        if (code == 429) { return "Rate limited"; }
        if (code == -104) { return "No phone"; }
        if (code == -2 || code == -3 || code == -300) { return "Timeout"; }
        if (code == -1001) { return "Needs https"; }
        if (code == -400 || code == -402) { return "Bad response"; }
        return "Error " + code;
    }
}
