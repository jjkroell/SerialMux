# SerialMux

**Share one USB radio between two (or three) programs at the same time.**

SerialMux lets multiple programs talk to a single serial device — like a MeshCore
LoRa node plugged into a Raspberry Pi over USB — without fighting over it.

## The problem this solves

A USB serial device can normally only be opened by **one** program at a time. If
you try to run, say, a **MeshCore bot** and a **MeshCore observer** against the
same radio, they fight over the single USB port and you get constant disconnects.

SerialMux fixes this. It opens the real radio **once**, then creates several
**virtual** serial ports. Each program connects to its own virtual port and
behaves as if it has the radio all to itself:

```
                       ┌──────────────┐   /dev/ttyV0 ──►  your bot
   USB radio ──────►   │   SerialMux  │   /dev/ttyV1 ──►  your observer
 (one real port)  ◄──  │  (the muxer) │   /dev/ttyV2 ──►  (spare)
                       └──────────────┘
```

- Anything the radio sends is copied to **all** the virtual ports.
- Anything a program writes to its virtual port is forwarded to the radio.

---

## What you'll need

- A **Raspberry Pi** (or any Linux computer) with your radio plugged in over USB.
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
5. Offer to set up your **observer** — if it's already installed it just repoints
   it at a virtual port; otherwise it installs the right one for your node:
   - **Companion** node → [meshcore-packet-capture](https://github.com/agessaman/meshcore-packet-capture)
   - **Repeater** node → [meshcoretomqtt](https://github.com/Cisien/meshcoretomqtt)
6. Offer to install the **[MeshCore bot](https://github.com/agessaman/meshcore-bot)**
   and point it at a virtual port.
7. Let you add a **custom MQTT broker** for the observer.

Everything is set up to start automatically on boot. You can re-run the command
any time to change things. Prefer to do it by hand? Follow the manual steps below.

### Try it first (safe, no changes)

Want to see exactly what it does before committing? Download it and run a **dry
run** — it makes no system changes, needs no `sudo`, invents a fake radio, and
even runs SerialMux against it in a throwaway sandbox (it prints the path):

```bash
git clone https://github.com/jjkroell/SerialMux && bash SerialMux/install.sh --dry-run
```

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
usb-Seeed_Studio_XIAO_nRF52840_C8A73AB0B3AB137D-if00 -> ../../ttyACM0
```

The important part is the long name starting with `usb-`. Your **full device path**
is `/dev/serial/by-id/` + that name, e.g.:

```
/dev/serial/by-id/usb-Seeed_Studio_XIAO_nRF52840_C8A73AB0B3AB137D-if00
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
REAL_PORT = '/dev/serial/by-id/usb-Seeed_Studio_XIAO_nRF52840_...-if00'
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
| Your **bot**      | `/dev/ttyV0`       |
| Your **observer** | `/dev/ttyV1`       |

Keep the baud rate at `115200`. Your programs run as your normal user (they do
**not** need sudo) — only SerialMux does.

> **Tip:** if one of your programs only *reads* (like a passive observer), it's
> best to keep it on its own port and let just one program send commands. If two
> programs send commands at the exact same moment, their bytes can get interleaved.

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

```bash
cd ~/SerialMux
git pull
sudo systemctl restart serialmux   # if you set up the service
```

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| **`Permission denied`** when starting | Run it with `sudo` (or use the service, which runs as root). |
| **`could not open port ...`** | `REAL_PORT` is wrong. Re-run `ls /dev/serial/by-id/` and copy the exact path into `SerialMux.py`. |
| **`ModuleNotFoundError: No module named 'serial'`** | Run `sudo apt install -y python3-serial`. (Don't use `pip`.) |
| **`/dev/serial/by-id/` is missing or empty** | Radio not detected — try a different USB cable (some are power-only) and confirm the radio has power. |
| **Your bot/observer can't open `/dev/ttyV0`** | SerialMux must be running first — the virtual ports only exist while it runs. Check `sudo systemctl status serialmux`. |
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
