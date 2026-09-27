// hiku-device: the agent for a hiku004 barcode scanner, running in Electric Imp's cloud.
//
// The device (device.nut) sends each barcode it reads. This agent passes it on to the app
// at APP_URL, which decides what the scan does and answers with the sound to play, as
// steps. The agent turns those steps into audio and sends it to the device to play.
//
// ============================================================================
// Replace these two lines with the ones the app shows you when you add a scanner
// (hiku.j-tools.net > Settings > Scanners > Add a scanner). Never commit a real token.
const APP_URL = "https://hiku.j-tools.net/api/device.php";
const DEVICE_TOKEN = "paste-your-token-here";
// ============================================================================

// ---- sounds ----------------------------------------------------------------

// A sound is a list of steps, each two characters: a pitch -- H(igh), M(edium), L(ow),
// V(ery low), or - for a pause -- and a length, S(hort) or L(ong). The app's Sounds page
// previews them with these same numbers, so the two must agree.
PITCHES <- {H = 2093, M = 1568, L = 1047, V = 494};
LENGTHS <- {S = 0.08, L = 0.2};
const STEP_GAP = 0.02;      // silence between steps, so two equal notes stay two notes
const MAX_STEPS = 20;
const SAMPLE_RATE = 16000;

// Played when the app cannot be reached or answers something unusable, so the scanner is
// never simply silent.
FAILURE_STEPS <- ["VL"];

// G.711 A-law encoding of one 16-bit sample, which is what the device's DAC decodes.
ALAW_SEGMENT_ENDS <- [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF];

function alawEncode(sample) {
  local value = sample >> 3;
  local mask = 0xD5;
  if (value < 0) {
    mask = 0x55;
    value = -value - 1;
  }
  local segment = 0;
  while (segment < 8 && value > ALAW_SEGMENT_ENDS[segment]) {
    segment++;
  }
  if (segment >= 8) {
    return 0x7F ^ mask;
  }
  local encoded = segment << 4;
  if (segment < 2) {
    encoded = encoded | ((value >> 1) & 0x0F);
  } else {
    encoded = encoded | ((value >> segment) & 0x0F);
  }
  return encoded ^ mask;
}

function validSteps(steps) {
  if (typeof steps != "array" || steps.len() == 0 || steps.len() > MAX_STEPS) return false;
  foreach (step in steps) {
    if (typeof step != "string" || step.len() != 2) return false;
    local pitch = step.slice(0, 1);
    if (pitch != "-" && !(pitch in PITCHES)) return false;
    if (!(step.slice(1, 2) in LENGTHS)) return false;
  }
  return true;
}

// Sine notes with a 5 ms fade in and out, so they do not click.
function renderSteps(steps) {
  local samples = blob();
  local fadeSamples = (SAMPLE_RATE * 0.005).tointeger();
  local gapSamples = (SAMPLE_RATE * STEP_GAP).tointeger();
  foreach (step in steps) {
    local pitch = step.slice(0, 1);
    local frequency = pitch == "-" ? 0 : PITCHES[pitch];
    local count = (SAMPLE_RATE * LENGTHS[step.slice(1, 2)]).tointeger();
    for (local i = 0; i < count + gapSamples; i++) {
      local amplitude = 0.0;
      if (frequency > 0 && i < count) {
        local envelope = 1.0;
        if (i < fadeSamples) {
          envelope = i.tofloat() / fadeSamples;
        } else if (i > count - fadeSamples) {
          envelope = (count - i).tofloat() / fadeSamples;
        }
        amplitude = 30000 * envelope * math.sin(2 * PI * frequency * i / SAMPLE_RATE);
      }
      samples.writen(alawEncode(amplitude.tointeger()), 'b');
    }
  }
  return samples;
}

// Rendering takes a moment, and the same few sounds come back all the time.
renderedSounds <- {};

// Seconds since the epoch, with fractions -- when the sound playing now will have ended.
function now() {
  local moment = date();
  return moment.time + moment.usec / 1000000.0;
}
soundEndsAt <- 0.0;

// Plays after whatever is still playing, never over it: waking up ("ready") and a scan can
// answer within a second of each other, and the device cuts a sound off when the next one
// arrives -- which would swallow "back to your default mode" before it was heard.
function playSteps(steps) {
  local key = "";
  foreach (step in steps) key += step;
  if (!(key in renderedSounds)) {
    renderedSounds[key] <- renderSteps(steps);
  }
  local samples = renderedSounds[key];
  local delay = soundEndsAt - now();
  if (delay < 0) delay = 0;
  soundEndsAt = now() + delay + samples.len().tofloat() / SAMPLE_RATE;
  imp.wakeup(delay, function() {
    device.send("playAudio", {rate = SAMPLE_RATE, samples = samples});
  });
}

// ---- talking to the app ----------------------------------------------------

// Seconds with milliseconds, so the log shows how far apart events are.
function timestamp() {
  local now = date();
  return format("%d.%03d", now.time, now.usec / 1000);
}

// Sends one event to the app and plays the steps it answers with.
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
    playSteps(steps);
  });
}

device.on("uploadBeep", function(data) {
  server.log("EVENT " + timestamp() + " uploadBeep BARCODE: " + data.scandata);
  sendToApp({event = "scan", code = data.scandata});
});

// The device has woken up and is online. The app answers with "ready", or with the default
// mode's sound when the scanner has just gone back to it.
device.on("deviceReady", function(data) {
  server.log("EVENT " + timestamp() + " deviceReady");
  sendToApp({event = "ready"});
});

// ---- everything else the device sends --------------------------------------

// Only logged for now, so a test with the button shows which events a short, a double and
// a long press produce -- the base for switching mode with a double press.
function logEvent(name, data) {
  local detail = "";
  if (typeof data == "string") {
    detail = data;
  } else if (typeof data == "table" && "scansize" in data) {
    detail = "scansize=" + data.scansize;
  }
  server.log("EVENT " + timestamp() + " " + name + " " + detail);
}

// Audio arrives in many small chunks; logging each one would flood the log.
device.on("uploadAudioChunk", function(data) {});

// A function per registration, so each handler keeps its own event name.
function registerLogger(name) {
  device.on(name, function(data) { logEvent(name, data); });
}

foreach (eventName in ["startAudioUpload", "endAudioUpload", "abortAudioUpload",
                       "buttonTimeout", "batteryStatus", "chargeStatus", "scan_start", "scan_line",
                       "set_version", "set_id", "pull", "batteryLevel", "button", "chargerState",
                       "deviceLog", "init_status", "shutdownRequestReason", "usbState"]) {
  registerLogger(eventName);
}

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
  playSteps(steps);
  response.send(200, "OK");
});

server.log("hiku agent started");
