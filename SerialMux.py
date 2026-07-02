#!/usr/bin/env python3
import os, serial, select, logging, sys, signal, termios, tty, errno, fcntl, time, argparse

# --- Configuration ---
REAL_PORT = '/dev/serial/by-id/usb-Seeed_Studio_XIAO_nRF52840_C8A73AB0B3AB137D-if00'
BAUD = 115200
VPORTS = ['/dev/ttyV0', '/dev/ttyV1', '/dev/ttyV2']

# --- Args ---
parser = argparse.ArgumentParser(description='Serial port multiplexer')
parser.add_argument('-v', '--verbose', action='store_true', help='Enable logging output')
args = parser.parse_args()

# --- Logging ---
logging.basicConfig(
    level=logging.DEBUG if args.verbose else logging.CRITICAL,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stderr)
    ]
)
log = logging.getLogger('serial-mux')

# --- Detach stdin so PTY fds don't collide ---
devnull = os.open(os.devnull, os.O_RDONLY)
os.dup2(devnull, 0)
os.close(devnull)

# --- Module-level state for signal handler ---
_active_vports = []

# --- PTY helpers ---
def create_vport(path):
    """Create a PTY, symlink slave to path, close slave fd, set master non-blocking."""
    if os.path.islink(path):
        os.unlink(path)

    master, slave = os.openpty()

    tty.setraw(master)
    tty.setraw(slave)

    slave_name = os.ttyname(slave)
    os.chmod(slave_name, 0o666)
    os.symlink(slave_name, path)

    # Close slave fd so kernel can deliver hangup when clients disconnect (Bug 1)
    os.close(slave)

    # Set master fd to non-blocking so writes never stall the event loop (Bug 2)
    flags = fcntl.fcntl(master, fcntl.F_GETFL)
    fcntl.fcntl(master, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    log.info(f"Virtual port created: {path} -> {slave_name} (master fd={master})")
    return {'master_fd': master, 'path': path, 'slave_name': slave_name, 'alive': True, 'idle': True}


def recreate_vport(vport):
    """Tear down a dead PTY and create a fresh one."""
    path = vport['path']
    old_fd = vport['master_fd']
    try:
        os.close(old_fd)
    except OSError:
        pass
    log.info(f"Recreating virtual port {path}")
    return create_vport(path)


# --- Serial helper ---
def open_serial(port, baud):
    """Open serial port with retry loop. Returns serial.Serial instance."""
    while True:
        try:
            ser = serial.Serial(port, baud, timeout=0.1)
            log.info(f"Serial port {port} opened successfully (fd={ser.fileno()})")
            return ser
        except serial.SerialException as e:
            log.warning(f"Failed to open {port}: {e} — retrying in 2s")
            time.sleep(2)


# --- Cleanup ---
def cleanup(signum=None, frame=None):
    log.info("Shutting down...")
    for vport in _active_vports:
        try:
            os.close(vport['master_fd'])
        except OSError:
            pass
    for path in VPORTS:
        if os.path.islink(path):
            os.unlink(path)
            log.info(f"Removed symlink {path}")
    sys.exit(0)

signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)

# --- Main ---
def main():
    global _active_vports

    log.info(f"Opening real serial port: {REAL_PORT} @ {BAUD} baud")
    ser = open_serial(REAL_PORT, BAUD)

    vports = [create_vport(path) for path in VPORTS]
    _active_vports = vports

    log.info("Multiplexer running. Waiting for data...")

    bytes_from_device = 0
    bytes_to_device = 0
    last_stats = time.monotonic()

    while True:
        # 1. Build watch_fds from serial fd + alive, non-idle vports (Bug 3)
        try:
            ser_fd = ser.fileno()
        except Exception:
            ser_fd = -1

        active_vports = [v for v in vports if v['alive'] and not v['idle']]
        watch_fds = [ser_fd] + [v['master_fd'] for v in active_vports] if ser_fd >= 0 else [v['master_fd'] for v in active_vports]

        # 2. select() with EINTR handling (Bug 6)
        try:
            readable, _, _ = select.select(watch_fds, [], [], 1.0)
        except (InterruptedError, OSError) as e:
            if getattr(e, 'errno', None) == errno.EINTR or isinstance(e, InterruptedError):
                continue
            raise

        # 3. Process readable fds
        for fd in readable:
            if fd == ser_fd:
                # Serial → broadcast to alive vports (including idle — they buffer writes)
                try:
                    data = os.read(ser_fd, 4096)
                    if not data:
                        raise OSError("serial port returned EOF")
                except OSError as e:
                    if e.errno == errno.EAGAIN or e.errno == errno.EINTR:
                        continue
                    log.warning(f"Serial read failed: {e} — reconnecting")
                    try:
                        ser.close()
                    except Exception:
                        pass
                    ser = open_serial(REAL_PORT, BAUD)
                    break

                bytes_from_device += len(data)
                log.debug(f"Device -> vports: {len(data)} bytes")
                for v in [v for v in vports if v['alive']]:
                    try:
                        os.write(v['master_fd'], data)
                    except OSError as e:
                        if e.errno in (errno.EAGAIN, errno.EIO):
                            log.debug(f"Write to {v['path']} skipped ({os.strerror(e.errno)})")
                        else:
                            log.warning(f"Write to {v['path']} failed: {e} — marking dead")
                            v['alive'] = False

            else:
                # vport master → serial
                v = next((v for v in active_vports if v['master_fd'] == fd), None)
                if v is None:
                    continue
                try:
                    data = os.read(fd, 4096)
                    if not data:
                        log.info(f"EOF on {v['path']} — client disconnected")
                        v['idle'] = True
                        continue
                except OSError as e:
                    if e.errno == errno.EAGAIN or e.errno == errno.EINTR:
                        continue
                    elif e.errno == errno.EIO:
                        log.info(f"EIO on read from {v['path']} — client disconnected")
                        v['idle'] = True
                        continue
                    else:
                        log.warning(f"Read from {v['path']} failed: {e} — marking dead")
                        v['alive'] = False
                        continue

                bytes_to_device += len(data)
                log.debug(f"{v['path']} -> device: {len(data)} bytes")
                try:
                    ser.write(data)
                except (serial.SerialException, OSError) as e:
                    log.warning(f"Serial write failed: {e} — reconnecting")
                    try:
                        ser.close()
                    except Exception:
                        pass
                    ser = open_serial(REAL_PORT, BAUD)
                    break

        # 4. Probe idle vports — check if a client has connected
        for v in vports:
            if v['alive'] and v['idle']:
                try:
                    # Read all buffered data, not just 1 byte. A client that
                    # connects and immediately writes — e.g. the MeshCore
                    # companion handshake — must not lose its first bytes, or
                    # the frame is corrupted and the node never replies.
                    data = os.read(v['master_fd'], 4096)
                    v['idle'] = False
                    log.info(f"Client connected to {v['path']}")
                    if data:
                        bytes_to_device += len(data)
                        log.debug(f"{v['path']} -> device (on connect): {len(data)} bytes")
                        try:
                            ser.write(data)
                        except (serial.SerialException, OSError) as e:
                            log.warning(f"Serial write failed: {e} — reconnecting")
                            try:
                                ser.close()
                            except Exception:
                                pass
                            ser = open_serial(REAL_PORT, BAUD)
                except OSError as e:
                    if e.errno == errno.EAGAIN:
                        # No data but no error — client is connected
                        v['idle'] = False
                        log.info(f"Client connected to {v['path']}")
                    elif e.errno == errno.EIO:
                        pass  # Still no client — stay idle
                    else:
                        log.warning(f"Probe of {v['path']} failed: {e} — marking dead")
                        v['alive'] = False

        # 5. Recreate dead vports (Bug 4)
        for i, v in enumerate(vports):
            if not v['alive']:
                vports[i] = recreate_vport(v)
        _active_vports = vports

        # 6. Log stats every 60s
        now = time.monotonic()
        if now - last_stats >= 60.0:
            alive_count = sum(1 for v in vports if v['alive'])
            idle_count = sum(1 for v in vports if v['alive'] and v['idle'])
            log.info(f"Stats: {bytes_from_device} bytes in, {bytes_to_device} bytes out, {alive_count}/{len(vports)} alive, {idle_count} idle")
            last_stats = now


if __name__ == '__main__':
    main()
