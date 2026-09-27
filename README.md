# hiku-device

Firmware and agent code that bring a **hiku** kitchen barcode scanner (model hiku004) back to
life after hiku Labs shut down. Scan a product and it lands on your shopping list — by
default through [Hiku Scanner](https://hiku.j-tools.net), part of the J-Tools suite, which
adds it to your Bring! list or your Stock pantry and tells the scanner which sound to play.

- **`device.nut`** runs on the scanner. It is hiku's own final hiku004 firmware (2.1.20),
  which hiku open-sourced under the MIT license, with one addition: a `playAudio` handler so
  the agent can send the scanner any sound it likes.
- **`agent.nut`** runs in Electric Imp's cloud, next to the scanner. It forwards every
  barcode to the app at `APP_URL`, and turns the app's answer into the sound the scanner
  plays.

## What you need

- A **hiku004** (it runs on an Electric Imp **imp003**; impCentral shows the type).
- The scanner must be **unlocked**. Every hiku left the factory tied to hiku's own
  Electric Imp account; hiku unlocked them on request, but the company no longer exists, so
  this is only possible for a scanner that was unlocked already.
- A free [Electric Imp account](https://impcentral.electricimp.com) and the Electric Imp app
  on your phone (iOS or Android).

## Setting it up

1. **Connect the scanner.** Log in to the Electric Imp app with your account and use
   *BlinkUp* to give the scanner your Wi-Fi: the phone's screen flashes at the scanner's
   light sensor. The scanner then shows up in impCentral as a development device.
2. **Make a place for the code.** In impCentral, create a *Product*, and inside it a
   *Development Device Group*. Assign your scanner to **that** group.
3. **Paste the code.** Open the group's code editor: `device.nut` goes into the **Device**
   pane, `agent.nut` into the **Agent** pane.
4. **Replace the two lines** at the top of `agent.nut`, marked with `====` lines:

   ```squirrel
   const APP_URL = "https://hiku.j-tools.net/api/device.php";
   const DEVICE_TOKEN = "paste-your-token-here";
   ```

   Log in at [hiku.j-tools.net](https://hiku.j-tools.net), go to *Settings → Scanners →
   Add a scanner*, and it shows you both lines to paste in. The token is shown only once.
   `APP_URL` is where the agent sends every scan: leave it as it is to use Hiku Scanner, or
   point it at your own server (see *The protocol* below).
5. **Build and Force Restart.** Press the button on the scanner to wake it; its first wake
   takes a little longer while the new code downloads.
6. **Scan something.** impCentral's log shows `uploadBeep BARCODE: …` and the app's answer,
   and the scanner plays the matching sound.

Never commit a real `DEVICE_TOKEN` to a repository. If one leaks, remove the scanner in the
app's settings and add it again for a new token.

## The protocol

For anyone pointing `APP_URL` at their own server.

**Scan or event** — the agent sends:

```http
POST <APP_URL>
Content-Type: application/json
X-Device-Token: <DEVICE_TOKEN>

{"event": "scan", "code": "8710398500410",
 "imp_device_id": "…", "agent_url": "https://agent.electricimp.com/…"}
```

`event` is `scan`, `cycle` (next mode) or `ready` (the scanner just woke up and is online;
no `code`). The agent expects `200` with:

```json
{"ok": true, "sound": "bring", "steps": ["MS", "HL"]}
```

`steps` is the sound. Each step is two characters: a pitch — `H` high, `M` medium, `L` low,
`V` very low, or `-` for a pause — and a length, `S` short (80 ms) or `L` long (200 ms).
Anything else, or no answer at all, plays the built-in failure sound. `sound` is only
written to the log. Answers that arrive while a sound is still playing wait their turn, so
a wake-up sound and a scan sound never cut each other off.

**Play a sound now** — the agent itself accepts:

```http
POST <agent_url>/play
X-Play-Key: <SHA-256 of DEVICE_TOKEN, lowercase hex>

{"steps": ["HS", "-S", "HS"]}
```

The server stores only the token's SHA-256, which is exactly what this key is, so it can ask
for a sound without ever holding the token. The scanner must be awake to play it.

## Troubleshooting

- **`the index 'i2c89' does not exist`, restarting every few seconds** — the scanner is
  running hiku's old factory test code, usually because it is assigned to a different Device
  Group than the one you pasted into. Assign it to the right group and build again.
- **Compiler warnings like `imp.getbssid() is deprecated`** are harmless. They come from
  hiku's own Wi-Fi logging, and the old function names still work.
- **The button does nothing** — there is no code on the scanner yet, or it crashed at start.
  Check the log right after *Build and Force Restart*.
- **It sleeps after about 30 seconds**, and pressing the button wakes it. Pressing and holding
  wakes it and scans in one go.

## License

MIT — see `LICENSE`. `device.nut` is hiku Labs' code; their copyright notice is kept there.
