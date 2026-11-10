// hiku-device: the agent for a hiku scanner with an imp002 (the older beta3 hardware), running
// in Electric Imp's cloud.
//
// The device (device.nut) sends each barcode it reads. This agent passes it on to the app
// at APP_URL, which decides what the scan does and answers with the sound to play, as
// steps. The device's piezo plays the steps itself, so unlike the hiku004 agent there is no
// audio to render here.
//
// ============================================================================
// Replace these two lines with the ones the app shows you when you add a scanner
// (hiku.j-tools.net > Settings > Scanners > Add a scanner). Never commit a real token.
const APP_URL = "https://hiku.j-tools.net/api/device.php";
const DEVICE_TOKEN = "paste-your-token-here";
// ============================================================================

// A sound is a list of steps, each two characters: a pitch -- H(igh), M(edium), L(ow),
// V(ery low), or - for a pause -- and a length, S(hort) or L(ong). The device turns them
// into notes; the app's Sounds page previews them.
const MAX_STEPS = 20;

// Played when the app cannot be reached or answers something unusable, so the scanner is
// never simply silent.
FAILURE_STEPS <- ["VL"];

function validSteps(steps) {
  if (typeof steps != "array" || steps.len() == 0 || steps.len() > MAX_STEPS) return false;
  foreach (step in steps) {
    if (typeof step != "string" || step.len() != 2) return false;
    local pitch = step.slice(0, 1);
    if (pitch != "-" && pitch != "H" && pitch != "M" && pitch != "L" && pitch != "V") return false;
    local length = step.slice(1, 2);
    if (length != "S" && length != "L") return false;
  }
  return true;
}

// Seconds with milliseconds, so the log shows how far apart events are.
function timestamp() {
  local now = date();
  return format("%d.%03d", now.time, now.usec / 1000);
}

// Sends one event to the app and has the device play the steps it answers with.
function sendToApp(payload) {
  payload.imp_device_id <- imp.configparams.deviceid;
  payload.agent_url <- http.agenturl();
  local headers = {"Content-Type": "application/json", "X-Device-Token": DEVICE_TOKEN};
  http.post(APP_URL, headers, http.jsonencode(payload)).sendasync(function(response) {
    local steps = FAILURE_STEPS;
    if (response.statuscode == 200) {
      try {
        local answer = http.jsondecode(response.body);
        if ("steps" in answer && validSteps(answer.steps)) {
          steps = answer.steps;
          server.log("EVENT " + timestamp() + " answer " + ("sound" in answer ? answer.sound : "?"));
        }
      } catch (error) {
        server.error("Unreadable answer: " + response.body);
      }
    } else {
      server.error("The app answered " + response.statuscode + ": " + response.body);
    }
    device.send("playSteps", steps);
  });
}

device.on("uploadBeep", function(data) {
  server.log("EVENT " + timestamp() + " uploadBeep BARCODE: " + data.scandata);
  sendToApp({event = "scan", code = data.scandata});
});

// The device sends this each time it comes online after waking up. The app answers with
// "ready", or with the default mode's sound when the scanner has just gone back to it.
device.on("init_status", function(data) {
  server.log("EVENT " + timestamp() + " init_status");
  sendToApp({event = "ready"});
});

// Only logged, so a test with the button shows what a short, a double and a long press
// produce.
device.on("button", function(data) {
  server.log("EVENT " + timestamp() + " button " + data);
});
device.on("buttonTimeout", function(data) {
  server.log("EVENT " + timestamp() + " buttonTimeout");
});

// ---- playing a sound on request ----------------------------------------------

// POST /play {"steps": [...]} plays a sound now -- the app's "play on the scanner" button.
// Only with X-Play-Key set to the SHA-256 of DEVICE_TOKEN, which the app stores in place of
// the token itself, so knowing this agent's address is not enough to make the scanner beep.
function sha256Hex(text) {
  local digest = http.hash.sha256(text);
  local hex = "";
  for (local i = 0; i < digest.len(); i++) {
    hex += format("%02x", digest[i]);
  }
  return hex;
}

PLAY_KEY <- sha256Hex(DEVICE_TOKEN);

http.onrequest(function(request, response) {
  if (request.method != "POST" || request.path != "/play") {
    response.send(404, "Not found");
    return;
  }
  if (!("x-play-key" in request.headers) || request.headers["x-play-key"] != PLAY_KEY) {
    response.send(403, "Forbidden");
    return;
  }
  local steps = null;
  try {
    steps = http.jsondecode(request.body).steps;
  } catch (error) {}
  if (!validSteps(steps)) {
    response.send(400, "Invalid steps");
    return;
  }
  device.send("playSteps", steps);
  response.send(200, "OK");
});

server.log("hiku agent started");
