# SerialMux

**Share one USB radio between two (or three) programs at the same time.**

SerialMux lets multiple programs talk to a single serial device — like a MeshCore
LoRa node plugged into a Raspberry Pi over USB — without fighting over it.

> **Node firmware:** SerialMux itself is firmware-agnostic, but the MeshCore
> programs it's designed to feed — the **bot** and the **observer** — both speak
> the MeshCore **companion serial protocol**. Your node must be running
> **Companion (USB serial) firmware**. Repeater and Room Server firmware do *not*
> answer the companion protocol and will not work with the bot or observer
> (you'll see `No response from meshcore node … Are you sure your node is a serial
> companion?`).

## The problem this solves

A USB serial device can normally only be opened by **one** program at a time. If
you try to run, say, a **MeshCore bot** and a **MeshCore observer** against the
same radio, they fight over the single USB port and you get constant disconnects.

SerialMux fixes this. It opens the real radio **once**, then creates several
**virtual** serial ports. Each program connects to its own virtual port and
behaves as if it has the radio all to itself:

```
                       ┌──────────────┐   /dev/ttyV0 ──►  observer (packet-capture)
   USB radio ──────►   │   SerialMux  │   /dev/ttyV1 ──►  your bot
 (one real port)  ◄──  │  (the muxer) │   /dev/ttyV2 ──►  (spare)
                       └──────────────┘
```

- Anything the radio sends is copied to **all** the virtual ports.
- Anything a program writes to its virtual port is forwarded to the radio.

---

## What you'll need

- A **Raspberry Pi** (or any Linux computer) with your radio plugged in over USB.
- A node running MeshCore **Companion (USB serial)** firmware.
- About 10 minutes. **No prior Linux experience required** — just copy and paste
  the commands below, one block at a time, into a terminal.

> **Opening a terminal on a Raspberry Pi:** click the black "Terminal" icon in the
> top bar, or press `Ctrl`+`Alt`+`T`. You type a command and press `Enter` to run
> it. If a command asks for your password, type it (you won't see the characters —
> that's normal) and press `Enter`.

---

## Easy install (one command) — recommended

If you just want it working, run this in a terminal and follow the prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/jjkroell/SerialMux/main/install.sh | sudo bash
```

The guided installer will:

1. Install everything it needs (git, Python, pyserial).
2. **Scan your USB devices** and let you pick your radio from a list.
3. Ask **how many virtual ports** you want (1–3).
4. Set up SerialMux as a service, start it, and **confirm it's working**.
5. Set up the **observer** ([agessaman/meshcore-packet-capture](https://github.com/agessaman/meshcore-packet-capture)) —
   leaves an already-connected one alone, or installs it and points it at a
   virtual port.
6. Optionally install the **[MeshCore bot](https://github.com/agessaman/meshcore-bot)** —
   it asks for the bot's name and location and gives it its own virtual port.
7. Optionally add a **custom MQTT broker** for the observer — type the details in,
   or paste a complete broker block copied from another node.
8. **Patch the `meshcore` library** in the bot's and observer's virtualenvs so
   they can run on a virtual port at all (see
   [Running on a virtual port](#running-on-a-virtual-port) below for why).

**Customizing the bot:** the installer only sets the bot's **name, location, and
serial port**. Everything else — which channels it monitors, its commands, weather
region, and so on — keeps the bot's defaults and is up to you. The bot's config
file lives at **`/opt/meshcore-bot/config.ini`**. To change anything:

```bash
sudo nano /opt/meshcore-bot/config.ini      # edit the bot's settings
sudo systemctl restart meshcore-bot         # apply your changes
```

(If it isn't there, run `systemctl show -p WorkingDirectory meshcore-bot` to see
where the bot runs from.) The bot's own
[configuration guide](https://github.com/agessaman/meshcore-bot/blob/main/docs/configuration.md)
lists every available option.

SerialMux, the observer, and the bot each run as a **systemd service that starts
automatically on boot** (and restarts itself on failure), and each program is
wired to its own virtual port so nothing fights over the radio. Prefer to do it
by hand? Follow the manual steps below.

### Try it first (safe, no changes)

Want to see exactly what it does before committing? Download it and run a **dry
run** — it makes no system changes, needs no `sudo`, invents a fake radio, and
even runs SerialMux against it in a throwaway sandbox (it prints the path):

```bash
curl -fsSL https://raw.githubusercontent.com/jjkroell/SerialMux/main/install.sh | bash -s -- --dry-run
```

### Adding or changing things later

Re-run the installer any time — it's safe to run again. It detects your existing
SerialMux setup and offers to keep it, leaves any already-connected program
alone, and gives a newly added one **its own virtual port** (adding a port
automatically if they're all taken). This works in **either order** — start with
an observer and add a bot later, or start with a bot and add an observer:

```bash
curl -fsSL https://raw.githubusercontent.com/jjkroell/SerialMux/main/install.sh | sudo bash
```

## Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/jjkroell/SerialMux/main/uninstall.sh | sudo bash
```

This removes SerialMux and its virtual ports, and reverts the observer's config
(so it talks to its own configured port again — set that back to the real radio
if you need to). It then *asks* whether to also fully uninstall the observer
and/or the bot via their own uninstallers — say no to keep them. Preview it with
`bash uninstall.sh --dry-run`.

---

## Setup — step by step (manual)

### 1. Install the tools

Copy this whole block, paste it into the terminal, and press `Enter`:

```bash
sudo apt update
sudo apt install -y git python3 python3-serial
```

> This installs `git` (to download SerialMux) and Python with the serial library.
> **Don't use `pip install pyserial`** — on modern Raspberry Pi OS it fails with an
> "externally-managed-environment" error. The `apt` command above is the right way.

### 2. Download SerialMux

```bash
cd ~
git clone https://github.com/jjkroell/SerialMux
cd SerialMux
```

You're now inside the SerialMux folder. Run `pwd` and note the path it prints
(something like `/home/yourname/SerialMux`) — you'll need it later.

### 3. Find your radio's serial port

With the radio plugged in, run:

```bash
ls -l /dev/serial/by-id/
```

You'll see one or more lines like:

```
usb-Nologo_ProMicro_NRF52840_C8A73AB0B3AB137D-if00 -> ../../ttyACM0
```

The important part is the long name starting with `usb-`. Your **full device path**
is `/dev/serial/by-id/` + that name, e.g.:

```
/dev/serial/by-id/usb-Nologo_ProMicro_NRF52840_C8A73AB0B3AB137D-if00
```

> **Why this and not `/dev/ttyACM0`?** The `by-id` path always points to *your*
> radio, even after a reboot or replug. The short `ttyACM0`/`ttyUSB0` name can
> change and is not reliable.
>
> If `/dev/serial/by-id/` doesn't exist or is empty, your radio isn't detected —
> check the USB cable (some are charge-only) and that the radio has power.

### 4. Configure SerialMux

Open the script in a simple text editor:

```bash
nano SerialMux.py
```

Near the top you'll see:

```python
# --- Configuration ---
REAL_PORT = '/dev/serial/by-id/usb-Nologo_ProMicro_NRF52840_...-if00'
BAUD = 115200
VPORTS = ['/dev/ttyV0', '/dev/ttyV1', '/dev/ttyV2']
```

- **`REAL_PORT`** — replace the text between the quotes with **your** device path
  from step 3. This is the one change everyone must make.
- **`BAUD`** — leave at `115200` (the MeshCore default).
- **`VPORTS`** — leave as-is. These are the virtual ports your programs will use.
  Three are provided; you can use as many or as few as you need.

Save and exit nano: press `Ctrl`+`O` then `Enter` (saves), then `Ctrl`+`X` (exits).

### 5. Test it

Run it once, by hand, to make sure it works (the `sudo` is required — SerialMux
creates the virtual ports under `/dev`, which needs administrator rights):

```bash
sudo python3 SerialMux.py -v
```

You should see lines like `Virtual port created: /dev/ttyV0 ...` and
`Serial port ... opened successfully`. That means it's working. Leave it running
and, in a **second** terminal, confirm the virtual ports exist:

```bash
ls -l /dev/ttyV*
```

Press `Ctrl`+`C` in the first terminal to stop the test.

> The `-v` flag turns on detailed logging so you can see what's happening. You can
> drop it for normal use.

### 6. Point your programs at the virtual ports

Now configure your two programs to use the **virtual** ports instead of the real
radio. For a MeshCore setup:

| Program       | Set its serial port to |
| ------------- | ---------------------- |
| Your **observer** | `/dev/ttyV0`       |
| Your **bot**      | `/dev/ttyV1`       |

Keep the baud rate at `115200`. Your programs run as your normal user (they do
**not** need sudo) — only SerialMux does.

> **Important:** both the bot and the observer use the `meshcore` Python library,
> which needs a one-line patch to run on a virtual port at all — see
> [Running on a virtual port](#running-on-a-virtual-port). The one-command
> installer does this for you; for a manual setup you must apply it yourself.

---

## Run it automatically on boot (recommended)

For a Pi that runs 24/7, set SerialMux up as a **service** so it starts on boot and
restarts itself if anything hiccups.

### 1. Create the service file

```bash
sudo nano /etc/systemd/system/serialmux.service
```

Paste this in, then **change the path** on the `ExecStart` line to the folder from
step 2 (run `pwd` inside your SerialMux folder if you're unsure):

```ini
[Unit]
Description=SerialMux virtual serial port multiplexer
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 /home/yourname/SerialMux/SerialMux.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Save and exit (`Ctrl`+`O`, `Enter`, `Ctrl`+`X`).

### 2. Enable and start it

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now serialmux
sudo systemctl status serialmux
```

The status should say **`active (running)`**. SerialMux will now start every time
the Pi boots. Start your bot and observer (pointed at the virtual ports) and you're
done.

### Managing the service

```bash
sudo systemctl status serialmux     # is it running?
sudo systemctl restart serialmux    # restart it
sudo systemctl stop serialmux       # stop it
journalctl -u serialmux -f          # watch its log live (Ctrl+C to quit)
```

> Want detailed logs in the service? Edit the service file and change the
> `ExecStart` line to end with `... /SerialMux.py -v`, then
> `sudo systemctl daemon-reload && sudo systemctl restart serialmux`.

---

## Updating SerialMux

If you used the one-command installer, just **run it again** — it keeps your
existing radio and ports and lets you add or change programs:

```bash
curl -fsSL https://raw.githubusercontent.com/jjkroell/SerialMux/main/install.sh | sudo bash
```

For a manual install:

```bash
cd ~/SerialMux
git pull
sudo systemctl restart serialmux   # if you set up the service
```

> If `git pull` complains about local changes, that's because your `REAL_PORT` /
> `VPORTS` edits live in `SerialMux.py`. Note them down, run `git stash`, `git pull`,
> then put them back (or just use the one-command installer above, which preserves
> them for you).

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| **`Permission denied`** when starting | Run it with `sudo` (or use the service, which runs as root). |
| **`could not open port ...`** | `REAL_PORT` is wrong. Re-run `ls /dev/serial/by-id/` and copy the exact path into `SerialMux.py`. |
| **`ModuleNotFoundError: No module named 'serial'`** | Run `sudo apt install -y python3-serial`. (Don't use `pip`.) |
| **`/dev/serial/by-id/` is missing or empty** | Radio not detected — try a different USB cable (some are power-only) and confirm the radio has power. |
| **Your bot/observer can't open `/dev/ttyV0`** | SerialMux must be running first — the virtual ports only exist while it runs. Check `sudo systemctl status serialmux`. |
| **Bot/observer crash-loops with `[Errno 25] Inappropriate ioctl for device`** (traceback ends in `transport.serial.rts`) | The `meshcore` library toggles the RTS/DTR hardware lines on connect, which a virtual port (a PTY) can't do. The installer patches this automatically; if you installed by hand, see [Running on a virtual port](#running-on-a-virtual-port). |
| **`No response from meshcore node … Are you sure your node is a serial companion?`** | The node isn't answering the companion protocol. Almost always the **wrong firmware** — the bot and observer need **Companion (USB serial)** firmware, not Repeater or Room Server. Reflash the node. |
| **Bot/observer connects but replies/captures nothing** | Confirm the node is a Companion build, and — if you reflashed it — that its **channels** are set up again (a reflash wipes the node's identity and channel keys, so it can't decode messages on your old channels until you re-add them). |
| **It worked, then stopped after a reboot/replug** | Use the `/dev/serial/by-id/...` path (step 3), not `/dev/ttyACM0`. And use the service so it auto-restarts. |

---

## How it works (technical)

SerialMux opens the physical serial port and creates virtual
[PTY](https://en.wikipedia.org/wiki/Pseudoterminal) devices, symlinked to the paths
in `VPORTS` (`/dev/ttyV0`, etc.):

- **Device → clients:** data from the radio is broadcast to every virtual port.
- **Clients → device:** data written to any virtual port is forwarded to the radio.

### Automatic recovery

SerialMux is built to survive the failures that cause disconnects:

- **A program disconnects:** its virtual port goes idle and is reused the moment a
  new program connects — the path stays the same.
- **The USB radio drops out:** SerialMux retries opening it every 2 seconds until it
  comes back.
- **A virtual port gets into a bad state:** it's torn down and recreated at the same
  path automatically.

### Running on a virtual port

Both the MeshCore **bot** and the **observer** use the `meshcore` Python library,
which sets the **RTS/DTR** hardware modem-control lines the moment it connects. A
real USB serial adapter supports that; a **virtual port is a PTY**, which does not
— so the library raises `OSError: [Errno 25] Inappropriate ioctl for device` and
the program exits (systemd then restart-loops it into a `start-limit-hit`).

The one-command installer patches the library automatically — in **both** the bot's
and the observer's virtualenvs — so they run fine on a `/dev/ttyV*` port. If you
installed by hand, apply the same fix. It wraps the RTS/DTR assignments so an
unsupported ioctl is harmless (change the `find` root to `/opt/meshcore-bot` for
the bot, `/opt/meshcore-packet-capture` for the observer — or run it for both):

```bash
for root in /opt/meshcore-bot /opt/meshcore-packet-capture; do
  SC="$(find "$root" -path '*/site-packages/meshcore/serial_cx.py' 2>/dev/null)"
  [ -n "$SC" ] || continue
  sudo cp "$SC" "$SC.bak"
  sudo python3 - "$SC" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if 'serialmux-rts-patch' not in s:
    s = re.sub(r'^([ \t]*)(transport\.serial\.(?:rts|dtr)\s*=.*)$',
               r"\1try:  # serialmux-rts-patch\n\1    \2\n\1except OSError:\n\1    pass",
               s, flags=re.M)
    p.write_text(s)
print("patched", sys.argv[1])
PY
done
sudo systemctl restart meshcore-bot meshcore-packet-capture 2>/dev/null
```

> A `pip install -U` of the `meshcore` package overwrites the library and undoes
> this — just re-run the SerialMux installer (or the snippet above) afterward.

### Observer configuration

The installer points the observer at a virtual port with a drop-in it owns,
`/etc/meshcore-packet-capture/config.d/zz-serialmux.toml` (it sorts last, so it
wins on load without touching your own config):

```toml
connection_type = "serial"
serial_ports = "/dev/ttyV0"
```

The observer also publishes to an MQTT broker — that's configured separately (in
its own `config.d/99-user.toml`), independent of the serial port above.

### A note on sharing a companion node

MeshCore's companion serial API is **request/response** and is happiest with a
single command-issuing client. The bot (which sends commands and replies) plus the
packet-capture observer (which is largely passive after its initial handshake)
coexist well on one radio through SerialMux. Running **two** heavily
command-issuing companion clients on the same node can interleave their traffic —
if you need that, give the second one its own radio.

### Configuration reference

Edit the constants at the top of `SerialMux.py`:

| Setting     | Meaning |
| ----------- | --- |
| `REAL_PORT` | Path to the physical serial device (use the `/dev/serial/by-id/...` form). |
| `BAUD`      | Baud rate. `115200` for MeshCore. |
| `VPORTS`    | List of virtual port paths to create — add or remove entries to match how many programs you need. |

### Running and stopping manually

```bash
sudo python3 SerialMux.py        # run
sudo python3 SerialMux.py -v     # run with detailed logging
```

Stop with `Ctrl`+`C` (or `SIGTERM`). On shutdown SerialMux closes all ports and
removes the virtual-port symlinks.

## Requirements

- Linux (uses PTYs and symlinks)
- Python 3
- [pyserial](https://pypi.org/project/pyserial/) (`python3-serial` on Debian/Raspberry Pi OS)
- A MeshCore node running **Companion (USB serial)** firmware
</content>
</invoke>
