"""Turns a Stream Deck into a control surface.

~/.config/control-surface/layout.toml says what each dial and key runs. The strip
shows each dial's state and a key can show live state of its own, both polled so
changes made elsewhere appear too. Two groups of keys fill themselves from the files
Claude Code's hooks write: one key per running session, one per running subagent.
The layout reloads when saved, and the deck can come and go while this runs.
"""
import json
import os
import queue
import re
import shlex
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
DIAL_INTERVAL = 1
STALE_SECONDS = 600
# a session or subagent killed without its end hook leaves its file; after this long it goes
FORGET_SECONDS = {"sessions": 24 * 3600, "agents": 2 * 3600}

ZONE_WIDTH = 200
ZONE_HEIGHT = 100
BACKGROUND = "#14161b"
FOREGROUND = "#f2f4f8"
MUTED = "#9aa3b2"
ACCENT = "#3fa7d6"
TRACK = "#2a2f3a"
KEY_IDLE = "#20242c"
KEY_HELD = "#3a4150"
# what a read command can report: the key's colour for it, and a zone's text colour
LEVELS = {"on": "#1f6f8b", "off": KEY_IDLE, "ready": "#2e7d4f", "warn": "#a8741a", "alert": "#b3362f"}
TONES = {"on": ACCENT, "off": MUTED, "ready": "#4cc38a", "warn": "#e0a43a", "alert": "#e5534b"}

# a Claude session's state, as signal.sh writes it: the key's level and its short text
SESSION_STATES = {
    "working": ("on", "work"),
    "needs": ("alert", "you"),
    "waiting": ("ready", "done"),
    "error": ("warn", "error"),
}

label_font = ImageFont.load_default(size=18)
key_font = ImageFont.load_default(size=22)
text_font = ImageFont.load_default(size=26)
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
        if not isinstance(entry, dict):
            raise ValueError(f"{LAYOUT}: each [[{name}]] must be a table")
        for field in ("step", "every", "timeout"):
            if field in entry and not isinstance(entry[field], (int, float)):
                raise ValueError(f"{LAYOUT}: {name} {field} must be a number, got {entry[field]!r}")
        slot = entry.get("slot")
        if slot not in range(count):
            raise ValueError(f"{LAYOUT}: {name} slot must be 0 to {count - 1}, got {slot!r}")
        if slot in slots:
            raise ValueError(f"{LAYOUT}: {name} slot {slot} is set twice")
        slots[slot] = entry
    return slots


def load_groups(data, keys, count):
    """Returns the [sessions] and [agents] tables, checked against each other and the keys."""
    groups = {}
    taken = set(keys)
    for name in ("sessions", "agents"):
        group = data.get(name)
        if group is None:
            continue
        if not isinstance(group, dict):
            raise ValueError(f"{LAYOUT}: [{name}] must be a table")
        slots = group.get("slots")
        if not isinstance(slots, list) or not slots:
            raise ValueError(f"{LAYOUT}: [{name}] needs slots, a list of key slots")
        for slot in slots:
            if slot not in range(count):
                raise ValueError(f"{LAYOUT}: [{name}] slot must be 0 to {count - 1}, got {slot!r}")
            if slot in taken:
                raise ValueError(f"{LAYOUT}: key slot {slot} is used twice")
            taken.add(slot)
        groups[name] = group
    if groups and not isinstance(data.get("signal"), str):
        raise ValueError(f"{LAYOUT}: [sessions] and [agents] need signal, the folder Claude's hooks write")
    return groups


def load_layout(deck):
    """Returns (brightness, dials, keys, groups, signal folder); raises ValueError on a bad layout."""
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
    dials = load_slots(data, "dial", deck.dial_count())
    keys = load_slots(data, "key", deck.key_count())
    groups = load_groups(data, keys, deck.key_count())
    folder = Path(data["signal"]).expanduser() if isinstance(data.get("signal"), str) else None
    return brightness, dials, keys, groups, folder


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
    """Returns (level from 0 to 1 or None, muted, text, tone) from the dial's read command.

    A read printing a level word (on, warn, …) and text shows that text in the level's
    colour; any other output is read as a number from 0 to 1 and drawn as a bar.
    """
    output = run_command(dial["read"], dial.get("timeout", COMMAND_TIMEOUT))
    if output is None:
        return None, False, None, None
    first, _, rest = output.strip().partition(" ")
    if first in LEVELS:
        return None, False, rest.strip(), first
    number = re.search(r"\d+(?:\.\d+)?", output)
    level = min(float(number.group()), 1.0) if number else None
    return level, "MUTED" in output, None, None


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


def read_signals(folder, kind):
    """Returns {id: entry} for the session or subagent files under the signal folder.

    The files come from inside the sandbox, so anything not shaped as signal.sh writes
    it is skipped rather than trusted, and so is an entry older than FORGET_SECONDS.
    """
    entries = {}
    for path in (folder / kind).glob("*.json"):
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue  # removed or replaced while reading; the next poll sees it whole
        if not isinstance(entry, dict) or not isinstance(entry.get("since"), (int, float)):
            continue
        if not isinstance(entry.get("started", 0), (int, float)):
            continue
        if time.time() - entry["since"] > FORGET_SECONDS[kind]:
            continue
        entries[path.stem] = {k: v if isinstance(v, (int, float)) else str(v) for k, v in entry.items()}
    return entries


def press_key(key, slot, poller):
    run_command(key["press"], key.get("timeout", COMMAND_TIMEOUT))
    poller.refresh("key", slot)


class Poller(threading.Thread):
    """Runs the read commands of keys and dials away from the main loop, which a slow one would stall.

    Each read runs in a thread of its own, so a slow one (an ssh, a CLI) doesn't hold up the
    rest. What it reads carries the layout generation it was started for; the main loop drops
    readings from a layout that has since been replaced.
    """

    def __init__(self, keys, dials, events, generation=0):
        super().__init__(daemon=True)
        self.entries = {("key", slot): key for slot, key in keys.items() if "read" in key}
        self.entries.update({("dial", slot): dial for slot, dial in dials.items() if "read" in dial})
        self.events = events
        self.generation = generation
        self.due = dict.fromkeys(self.entries, 0)
        self.running = set()
        self.wake = threading.Event()
        self.stopped = False

    def refresh(self, kind, slot):
        if (kind, slot) in self.due:
            self.due[(kind, slot)] = 0
            self.wake.set()

    def stop(self):
        self.stopped = True
        self.wake.set()

    def read(self, kind, slot, entry):
        try:
            value = read_key(entry) if kind == "key" else read_dial(entry)
            if not self.stopped:
                self.events.put((slot, f"{kind}-state", (self.generation, value)))
        finally:
            self.running.discard((kind, slot))

    def run(self):
        while not self.stopped:
            for (kind, slot), entry in self.entries.items():
                if (kind, slot) in self.running or self.due[(kind, slot)] > time.monotonic():
                    continue
                interval = entry.get("every", KEY_INTERVAL if kind == "key" else DIAL_INTERVAL)
                self.due[(kind, slot)] = time.monotonic() + interval
                self.running.add((kind, slot))
                threading.Thread(target=self.read, args=(kind, slot, entry), daemon=True).start()
            self.wake.wait(timeout=POLL_SECONDS)
            self.wake.clear()


def fit(draw, text, fonts, width):
    """Returns the largest of the fonts that fits text into width."""
    for font in fonts:
        if draw.textlength(text, font=font) <= width:
            return font
    return fonts[-1]


def draw_zone(deck, slot, dial, state):
    image = Image.new("RGB", (ZONE_WIDTH, ZONE_HEIGHT), BACKGROUND)
    if dial is not None:
        level, muted, text, tone = state or (None, False, None, None)
        draw = ImageDraw.Draw(image)
        draw.text((100, 18), dial.get("label", ""), font=label_font, fill=MUTED, anchor="mm")
        if text is not None:
            font = fit(draw, text, (value_font, text_font, label_font), ZONE_WIDTH - 16)
            draw.text((100, 58), text, font=font, fill=TONES.get(tone, FOREGROUND), anchor="mm")
        else:
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
        font = fit(draw, label, (label_font,), image.width)
        draw.text((middle, image.height * 0.28), label, font=font, fill=FOREGROUND, anchor="mm")
        font = fit(draw, text, (value_font, key_font, label_font), image.width - 4)
        draw.text((middle, image.height * 0.62), text, font=font, fill=FOREGROUND, anchor="mm")
    else:
        font = fit(draw, label, (key_font, label_font), image.width - 4)
        draw.text((middle, middle), label, font=font, fill=FOREGROUND, anchor="mm")
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
        self.groups = {}
        self.folder = None
        self.dial_states = {}
        self.key_states = {}
        # the key a group fills a slot with, and which session or subagent sits there
        self.filled = {}
        self.occupants = {"sessions": {}, "agents": {}}
        self.held = set()
        self.generation = 0
        self.poller = Poller({}, {}, self.events)
        self.seen = object()

    def key_at(self, slot):
        return self.keys.get(slot) or self.filled.get(slot)

    def draw_key(self, slot):
        state = self.key_states.get(slot, (None, ""))
        draw_key(self.deck, slot, self.key_at(slot), state, slot in self.held)

    def reload(self):
        """Applies a saved layout; a bad one is reported and the current one stays."""
        mtime = layout_mtime()
        if mtime == self.seen:
            return
        self.seen = mtime
        try:
            brightness, self.dials, self.keys, self.groups, self.folder = load_layout(self.deck)
        except ValueError as error:
            log(error)
            return
        with self.deck:
            self.deck.set_brightness(brightness)
        self.key_states = {}
        self.dial_states = {}
        self.filled = {}
        self.occupants = {"sessions": {}, "agents": {}}
        self.poller.stop()
        self.generation += 1
        self.poller = Poller(self.keys, self.dials, self.events, self.generation)
        self.poller.start()
        for slot in range(self.deck.key_count()):
            self.draw_key(slot)
        for slot in range(self.deck.dial_count()):
            draw_zone(self.deck, slot, self.dials.get(slot), None)

    def fill(self, name, entries, show):
        """Keeps one key per entry in the group's slots; new entries take free slots oldest first."""
        group = self.groups.get(name)
        if group is None:
            return
        occupants = self.occupants[name]
        for slot, ident in list(occupants.items()):
            if ident not in entries:
                del occupants[slot]
        placed = set(occupants.values())
        def age(ident):
            return entries[ident].get("started", entries[ident]["since"])

        waiting = sorted((ident for ident in entries if ident not in placed), key=age)
        for slot in group["slots"]:
            if slot not in occupants and waiting:
                occupants[slot] = waiting.pop(0)
        for slot in group["slots"]:
            ident = occupants.get(slot)
            if ident is None:
                key, state = None, (None, "")
            else:
                label, state = show(entries[ident])
                project = entries[ident].get("project", "")
                key = {"label": label}
                if "press" in group:
                    key["press"] = group["press"].replace("{project}", shlex.quote(project))
            if self.filled.get(slot) != key or self.key_states.get(slot) != state:
                if key is None:
                    self.filled.pop(slot, None)
                else:
                    self.filled[slot] = key
                self.key_states[slot] = state
                self.draw_key(slot)

    def update_signals(self):
        if self.folder is None:
            return
        stale = self.groups.get("sessions", {}).get("stale", STALE_SECONDS)

        def session(entry):
            level, text = SESSION_STATES.get(entry.get("state"), (None, "?"))
            # an interrupted turn sends no hook, so "working" ends by age
            if entry.get("state") == "working" and time.time() - entry.get("since", 0) > stale:
                level, text = "off", "?"
            return entry.get("project", "?"), (level, text)

        def agent(entry):
            return entry.get("type") or "agent", ("on", entry.get("project", ""))

        self.fill("sessions", read_signals(self.folder, "sessions"), session)
        self.fill("agents", read_signals(self.folder, "agents"), agent)

    def handle(self, batch):
        turns, pushes = {}, set()
        for slot, kind, value in batch:
            if kind == DialEventType.TURN:
                turns[slot] = turns.get(slot, 0) + value
            elif kind == DialEventType.PUSH:
                if value:
                    pushes.add(slot)
            elif kind in ("key-state", "dial-state"):
                generation, value = value
                if generation != self.generation:
                    continue  # read for a layout that has since been replaced
                if kind == "key-state" and self.key_states.get(slot) != value:
                    self.key_states[slot] = value
                    self.draw_key(slot)
                elif kind == "dial-state" and self.dial_states.get(slot) != value:
                    self.dial_states[slot] = value
                    draw_zone(self.deck, slot, self.dials.get(slot), value)
            elif kind == "key":
                # released before it counts as a press, also when its slot just emptied
                self.held.add(slot) if value else self.held.discard(slot)
                key = self.key_at(slot)
                if key is None:
                    continue
                self.draw_key(slot)
                if value and "press" in key:
                    args = (key, slot, self.poller)
                    threading.Thread(target=press_key, args=args, daemon=True).start()

        for slot, ticks in turns.items():
            dial = self.dials.get(slot)
            command = dial and dial.get("up" if ticks > 0 else "down")
            if command and ticks:
                amount = abs(ticks) * dial.get("step", 1)
                run_command(command.replace("{amount}", str(amount)), dial.get("timeout", COMMAND_TIMEOUT))
                self.poller.refresh("dial", slot)
        for slot in pushes:
            dial = self.dials.get(slot, {})
            if "push" in dial:
                run_command(dial["push"], dial.get("timeout", COMMAND_TIMEOUT))
                self.poller.refresh("dial", slot)


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
            surface.reload()
            surface.handle(next_events(events))
            surface.update_signals()
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
