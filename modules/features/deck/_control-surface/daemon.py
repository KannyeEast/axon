"""Turns a Stream Deck into a control surface.

~/.config/control-surface/layout.toml says what each dial and key runs. The strip
shows each dial's state and a key can show live state of its own, both polled so
changes made elsewhere appear too. The layout reloads when saved, and the deck can
come and go while this runs.
"""
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import tomllib
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from StreamDeck.DeviceManager import DeviceManager
from StreamDeck.Devices.StreamDeck import DialEventType
from StreamDeck.ImageHelpers import PILHelper
from StreamDeck.Transport.Transport import TransportError

CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
LAYOUT = CONFIG / "control-surface" / "layout.toml"
POLL_SECONDS = 1
RETRY_SECONDS = 5
COMMAND_TIMEOUT = 2
KEY_INTERVAL = 5

ZONE_WIDTH = 200
ZONE_HEIGHT = 100
BACKGROUND = "#14161b"
FOREGROUND = "#f2f4f8"
MUTED = "#9aa3b2"
ACCENT = "#3fa7d6"
TRACK = "#2a2f3a"
KEY_IDLE = "#20242c"
KEY_HELD = "#3a4150"
# what a key's read command can report, and the key's colour for it
LEVELS = {"on": "#1f6f8b", "off": KEY_IDLE, "warn": "#a8741a", "alert": "#b3362f"}

label_font = ImageFont.load_default(size=18)
key_font = ImageFont.load_default(size=22)
value_font = ImageFont.load_default(size=34)
last_message = None


def log(message):
    """Prints a message, unless it repeats the last one: a failing read fails every poll."""
    global last_message
    if message != last_message:
        print(message, flush=True)
    last_message = message


def layout_mtime():
    try:
        return LAYOUT.stat().st_mtime
    except OSError:
        return None


def load_slots(data, name, count):
    entries = data.get(name, [])
    if not isinstance(entries, list):
        raise ValueError(f"{LAYOUT}: {name}s are written [[{name}]], not [{name}]")
    if entries and not count:
        raise ValueError(f"{LAYOUT}: this deck has no {name}s")
    slots = {}
    for entry in entries:
        slot = entry.get("slot")
        if slot not in range(count):
            raise ValueError(f"{LAYOUT}: {name} slot must be 0 to {count - 1}, got {slot!r}")
        if slot in slots:
            raise ValueError(f"{LAYOUT}: {name} slot {slot} is set twice")
        slots[slot] = entry
    return slots


def load_layout(deck):
    """Returns (brightness, dials, keys); raises ValueError on a bad layout."""
    try:
        with LAYOUT.open("rb") as file:
            data = tomllib.load(file)
    except OSError as error:
        raise ValueError(f"{LAYOUT}: cannot read it: {error}")
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f"{LAYOUT}: invalid TOML: {error}")

    brightness = data.get("brightness", 60)
    if not isinstance(brightness, int):
        raise ValueError(f"{LAYOUT}: brightness must be a number from 0 to 100")
    return brightness, load_slots(data, "dial", deck.dial_count()), load_slots(data, "key", deck.key_count())


def run_command(command, timeout=COMMAND_TIMEOUT):
    """Returns the command's stdout, or None if it failed."""
    # its own session, so a timeout reaches what the shell started too
    process = subprocess.Popen(
        command,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        log(f"{LAYOUT}: `{command}` took over {timeout}s")
        return None
    if process.returncode != 0:
        log(f"{LAYOUT}: `{command}` failed: {stderr.strip()}")
        return None
    return stdout


def read_dial(dial):
    """Returns (level from 0 to 1 or None, muted) from the dial's read command."""
    output = run_command(dial["read"]) if "read" in dial else None
    if output is None:
        return None, False
    number = re.search(r"\d+(?:\.\d+)?", output)
    level = min(float(number.group()), 1.0) if number else None
    return level, "MUTED" in output


def read_key(key):
    """Returns (level, text) from the key's read command; level None means unknown."""
    output = run_command(key["read"], key.get("timeout", COMMAND_TIMEOUT))
    if output is None:
        return None, "?"
    level, _, text = output.strip().partition(" ")
    if level not in LEVELS:
        log(f"{LAYOUT}: `{key['read']}` printed {level!r}, expected one of {', '.join(LEVELS)}")
        return None, "?"
    return level, text.strip()


def press_key(key, slot, poller):
    run_command(key["press"], key.get("timeout", COMMAND_TIMEOUT))
    poller.refresh(slot)


class Poller(threading.Thread):
    """Runs the keys' read commands away from the main loop, which a slow one would stall."""

    def __init__(self, keys, events):
        super().__init__(daemon=True)
        self.keys = {slot: key for slot, key in keys.items() if "read" in key}
        self.events = events
        self.due = dict.fromkeys(self.keys, 0)
        self.wake = threading.Event()
        self.stopped = False

    def refresh(self, slot):
        if slot in self.due:
            self.due[slot] = 0
            self.wake.set()

    def stop(self):
        self.stopped = True
        self.wake.set()

    def run(self):
        while not self.stopped:
            for slot, key in self.keys.items():
                if self.due[slot] <= time.monotonic():
                    self.due[slot] = time.monotonic() + key.get("every", KEY_INTERVAL)
                    self.events.put((slot, "state", read_key(key)))
            self.wake.wait(timeout=POLL_SECONDS)
            self.wake.clear()


def draw_zone(deck, slot, dial, state):
    image = Image.new("RGB", (ZONE_WIDTH, ZONE_HEIGHT), BACKGROUND)
    if dial is not None:
        level, muted = state
        draw = ImageDraw.Draw(image)
        draw.text((100, 18), dial.get("label", ""), font=label_font, fill=MUTED, anchor="mm")
        value = "--" if level is None else f"{round(level * 100)}%"
        value = "muted" if muted else value
        draw.text((100, 52), value, font=value_font, fill=MUTED if muted else FOREGROUND, anchor="mm")
        draw.rounded_rectangle((20, 80, 180, 88), radius=4, fill=TRACK)
        if level:
            end = 20 + round(160 * level)
            draw.rounded_rectangle((20, 80, end, 88), radius=4, fill=MUTED if muted else ACCENT)
    native = PILHelper.to_native_touchscreen_format(deck, image)
    with deck:
        deck.set_touchscreen_image(native, slot * ZONE_WIDTH, 0, ZONE_WIDTH, ZONE_HEIGHT)


def draw_key(deck, slot, key, state, held):
    if key is None:
        with deck:
            deck.set_key_image(slot, None)
        return
    level, text = state
    image = PILHelper.create_key_image(deck, KEY_HELD if held else LEVELS.get(level, KEY_IDLE))
    draw = ImageDraw.Draw(image)
    middle = image.width // 2
    label = key.get("label", "")
    if text:
        draw.text((middle, image.height * 0.28), label, font=label_font, fill=FOREGROUND, anchor="mm")
        draw.text((middle, image.height * 0.62), text, font=value_font, fill=FOREGROUND, anchor="mm")
    else:
        draw.text((middle, middle), label, font=key_font, fill=FOREGROUND, anchor="mm")
    native = PILHelper.to_native_key_format(deck, image)
    with deck:
        deck.set_key_image(slot, native)


def next_events(events):
    """Waits one poll for an event, and returns all that are queued by then."""
    try:
        batch = [events.get(timeout=POLL_SECONDS)]
    except queue.Empty:
        return []
    while True:
        try:
            batch.append(events.get_nowait())
        except queue.Empty:
            return batch


class Surface:
    """What is on the deck right now; everything drawing to it runs on the main loop."""

    def __init__(self, deck):
        self.deck = deck
        self.events = queue.Queue()
        self.dials = {}
        self.keys = {}
        self.dial_states = {}
        self.key_states = {}
        self.held = set()
        self.poller = Poller({}, self.events)
        self.seen = object()

    def draw_key(self, slot):
        key = self.keys.get(slot)
        state = self.key_states.get(slot, (None, ""))
        draw_key(self.deck, slot, key, state, slot in self.held)

    def reload(self):
        """Applies a saved layout; a bad one is reported and the current one stays."""
        mtime = layout_mtime()
        if mtime == self.seen:
            return False
        self.seen = mtime
        try:
            brightness, self.dials, self.keys = load_layout(self.deck)
        except ValueError as error:
            log(error)
            return False
        with self.deck:
            self.deck.set_brightness(brightness)
        self.key_states = {}
        self.poller.stop()
        self.poller = Poller(self.keys, self.events)
        self.poller.start()
        for slot in range(self.deck.key_count()):
            self.draw_key(slot)
        return True

    def handle(self, batch):
        turns, pushes = {}, set()
        for slot, kind, value in batch:
            if kind == DialEventType.TURN:
                turns[slot] = turns.get(slot, 0) + value
            elif kind == DialEventType.PUSH:
                if value:
                    pushes.add(slot)
            elif kind == "state":
                if self.key_states.get(slot) != value:
                    self.key_states[slot] = value
                    self.draw_key(slot)
            elif slot in self.keys:
                self.held.add(slot) if value else self.held.discard(slot)
                self.draw_key(slot)
                if value and "press" in self.keys[slot]:
                    args = (self.keys[slot], slot, self.poller)
                    threading.Thread(target=press_key, args=args, daemon=True).start()

        for slot, ticks in turns.items():
            dial = self.dials.get(slot)
            command = dial and dial.get("up" if ticks > 0 else "down")
            if command and ticks:
                amount = abs(ticks) * dial.get("step", 1)
                run_command(command.replace("{amount}", str(amount)))
        for slot in pushes:
            command = self.dials.get(slot, {}).get("push")
            if command:
                run_command(command)

    def update_dials(self, redraw):
        for slot in range(self.deck.dial_count()):
            dial = self.dials.get(slot)
            state = read_dial(dial) if dial else None
            if redraw or state != self.dial_states.get(slot):
                self.dial_states[slot] = state
                draw_zone(self.deck, slot, dial, state)


def run(deck):
    surface = Surface(deck)
    deck.open()
    try:
        deck.reset()
        log(f"{deck.deck_type()} {deck.get_serial_number()} connected")
        for key in range(deck.key_count()):
            with deck:
                deck.set_key_image(key, None)
        events = surface.events
        deck.set_dial_callback(lambda _, slot, kind, value: events.put((slot, kind, value)))
        deck.set_key_callback(lambda _, slot, held: events.put((slot, "key", held)))

        while deck.is_open():
            surface.handle(next_events(events))
            surface.update_dials(surface.reload())
    finally:
        surface.poller.stop()
        try:
            with deck:
                deck.reset()
        except TransportError:
            pass
        deck.close()


def find_deck():
    for deck in DeviceManager().enumerate():
        if deck.is_visual():
            return deck
    return None


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    waiting = False
    while True:
        deck = find_deck()
        if deck is None:
            if not waiting:
                log("waiting for a Stream Deck")
            waiting = True
        else:
            waiting = False
            try:
                run(deck)
            except TransportError as error:
                log(f"deck lost: {error}")
        time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    main()
