"""
Albumscape bridge for Windows: links your PC to Albumscape Lock on your Mac.

It measures the sound your PC is playing (the "what you hear" loopback of the default speakers), turns it into the same
48 visualizer levels Albumscape Lock draws, and sends them to the Mac about 30 times a second over your own network.
It also receives the Mac's levels and hands them to on_mac_bands(), so a Windows visualizer can follow the Mac's sound.

Only 48 small numbers travel (UDP, port 49733), never audio. Nothing leaves your network.

    pip install numpy PyAudioWPatch zeroconf
    python albumscape_bridge.py                 # finds the Mac on its own (Bonjour)
    python albumscape_bridge.py --mac 192.168.1.20

On the Mac: Albumscape Lock > Settings > Windows PC > Link with my Windows PC.
Packet: b"ALB1", a type byte (1 = levels), then 48 bytes (0..255).
"""
import argparse
import socket
import threading
import time

import numpy as np

PORT = 49733
BANDS = 48
FFT = 4096


def on_mac_bands(levels):
    """Called with the Mac's 48 levels (floats 0..1). Replace this to draw them in a Windows visualizer."""
    pass


class Analyser:
    """The same measuring as the Mac app: a 4096-sample window, 48 log-spaced bands from 40 Hz to 14 kHz."""

    def __init__(self, rate):
        self.rate = rate
        self.window = np.hanning(FFT).astype(np.float32)
        self.ring = np.zeros(0, dtype=np.float32)
        self.smooth = np.zeros(BANDS, dtype=np.float32)
        hz = np.fft.rfftfreq(FFT, 1 / rate)
        edges = 40 * (min(14000, rate / 2 - 1) / 40) ** (np.arange(BANDS + 1) / BANDS)
        self.slices = [(max(1, int(np.searchsorted(hz, lo))), max(2, int(np.searchsorted(hz, hi)))) for lo, hi in zip(edges[:-1], edges[1:])]

    def feed(self, mono):
        self.ring = np.concatenate([self.ring, mono])
        while len(self.ring) >= FFT:
            block = self.ring[:FFT] * self.window
            self.ring = self.ring[FFT // 4:]
            mags = np.abs(np.fft.rfft(block)) ** 2
            levels = np.zeros(BANDS, dtype=np.float32)
            for b, (i0, i1) in enumerate(self.slices):
                peak = mags[i0:max(i1, i0 + 1)].max()
                db = 10 * np.log10(max(peak, 1e-12) / (FFT * FFT) * 4)
                levels[b] = min(1, max(0, (db + 78 + 5 * b / BANDS) / 56))
            up = levels > self.smooth
            self.smooth = np.where(up, self.smooth + (levels - self.smooth) * 0.7, self.smooth + (levels - self.smooth) * 0.22)
        return self.smooth


def find_mac(timeout=8):
    from zeroconf import ServiceBrowser, Zeroconf
    found = []

    class Listener:
        def add_service(self, zc, type_, name):
            info = zc.get_service_info(type_, name)
            if info and info.addresses:
                found.append(socket.inet_ntoa(info.addresses[0]))

        def update_service(self, *a): pass
        def remove_service(self, *a): pass

    zc = Zeroconf()
    ServiceBrowser(zc, "_albumscape._udp.local.", Listener())
    end = time.time() + timeout
    while not found and time.time() < end:
        time.sleep(0.2)
    zc.close()
    return found[0] if found else None


def listen_for_mac():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", PORT))
    while True:
        data, _ = sock.recvfrom(256)
        if len(data) >= 53 and data[:4] == b"ALB1" and data[4] == 1:
            on_mac_bands([v / 255 for v in data[5:53]])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", help="the Mac's address; found automatically if left out")
    args = ap.parse_args()
    mac = args.mac or find_mac()
    if not mac:
        raise SystemExit("Couldn't find the Mac. Is Albumscape Lock's link switched on? Or pass --mac <address>.")
    print("Sending to the Mac at", mac)

    import pyaudiowpatch as pyaudio  # WASAPI loopback: the sound the PC is playing
    pa = pyaudio.PyAudio()
    speakers = pa.get_default_wasapi_loopback()
    rate, channels = int(speakers["defaultSampleRate"]), int(speakers["maxInputChannels"])
    analyser = Analyser(rate)
    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    last = [0.0]

    def callback(data, frames, info, status):
        mono = np.frombuffer(data, dtype=np.float32).reshape(-1, channels).mean(axis=1)
        levels = analyser.feed(mono)
        if time.time() - last[0] >= 1 / 30:
            last[0] = time.time()
            out.sendto(b"ALB1\x01" + bytes((levels * 255).astype(np.uint8)), (mac, PORT))
        return (None, pyaudio.paContinue)

    threading.Thread(target=listen_for_mac, daemon=True).start()
    stream = pa.open(format=pyaudio.paFloat32, channels=channels, rate=rate, input=True,
                     input_device_index=speakers["index"], frames_per_buffer=1024, stream_callback=callback)
    print("Listening to the PC's sound. Press Ctrl+C to stop.")
    try:
        while stream.is_active():
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    stream.close()
    pa.terminate()


if __name__ == "__main__":
    main()
