"""Mails why a unit failed, and how this machine is doing, as HTML with a plain text copy.

notify.py <config> alert <recipient> <unit>
notify.py <config> report <recipient>

The config names the page around the content (page.html), its colours and sendmail.
"""
import html
import json
import platform
import re
import subprocess
import sys
import time
from email.message import EmailMessage
from pathlib import Path

VERSION = Path("/run/current-system/nixos-version")
PROFILE = Path("/nix/var/nix/profiles/system")
UPTIME = Path("/proc/uptime")
LOG_LINES = 30  # shown; more are read, as repeats and systemd's own lines fall away
LOG_READ = 300
LONGEST_LINE = 300
FULL_PERCENT = 85  # the same line as the DiskFull alert
MUTED = "#6b7280"
LINE = "#e6e8ee"
TRACK = "#eef0f4"
# on the dark log block
LOG_TEXT = "#e6e8ee"
LOG_TIME = "#8b93a1"
LOG_LEVELS = {"fail": "#ff9aa8", "warn": "#f1c27d"}

# systemd's lines that only repeat the facts above the log
NOISE = re.compile(
    r"(^|: )(Started|Starting|Stopped|Stopping|Deactivated|Scheduled restart|Consumed"
    r"|Triggering OnFailure|Failed with result|Main process exited)"
)
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
LOGFMT = re.compile(r"""(\w+)=("(?:[^"\\]|\\.)*"|\S+)""")

config = {}
host = platform.node()


def run(*command):
    """Returns a command's stdout, whatever its exit code: a sick machine is the point of asking."""
    return subprocess.run(command, capture_output=True, text=True).stdout


class Cell:
    """A table cell: what the plain text copy shows, and what the page shows."""

    def __init__(self, text, markup=None):
        self.text = text
        self.markup = html.escape(text) if markup is None else markup


def badge(text, level):
    colours = config["levels"][level]
    return Cell(
        text,
        f'<span style="padding:1px 8px;border-radius:999px;background:{colours["tint"]};'
        f'color:{colours["color"]};font-size:12px;font-weight:600;">{html.escape(text)}</span>',
    )


def meter(percent):
    level = "fail" if percent > FULL_PERCENT else "ok"
    colour = config["levels"][level]["color"]
    return Cell(
        f"{percent}%",
        f'<div style="width:90px;height:6px;background:{TRACK};border-radius:3px;">'
        f'<div style="width:{percent}%;height:6px;background:{colour};border-radius:3px;"></div></div>'
        f'<div style="margin-top:2px;color:{MUTED};font-size:12px;">{percent}%</div>',
    )


class Mail:
    """The content of a mail, built as plain text and page side by side."""

    def __init__(self):
        self.text = []
        self.markup = []

    def section(self, title):
        self.text += ["", f"== {title}"]
        self.markup.append(
            f'<h2 style="margin:24px 0 10px;padding-top:18px;border-top:1px solid {LINE};'
            f'font-size:13px;font-weight:600;color:{MUTED};">{html.escape(title)}</h2>'
        )

    def line(self, text):
        self.text.append(text)
        self.markup.append(f'<p style="margin:0 0 6px;">{html.escape(text)}</p>')

    def facts(self, rows):
        self.table(None, rows)

    def table(self, head, rows):
        cells = "padding:6px 12px 6px 0;vertical-align:top;font-size:14px;"
        markup = '<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;">'
        if head:
            self.text.append("  ".join(head))
            titles = "".join(
                f'<td style="{cells}color:{MUTED};font-size:12px;">{html.escape(title)}</td>'
                for title in head
            )
            markup += f"<tr>{titles}</tr>"
        for row in rows:
            row = [cell if isinstance(cell, Cell) else Cell(str(cell)) for cell in row]
            self.text.append("  " + "  ".join(cell.text for cell in row))
            # without a head the first column names the row
            first = f"width:1%;padding-right:28px;color:{MUTED};white-space:nowrap;" if head is None else "word-break:break-word;"
            columns = [f'<td style="{cells}{first}">{row[0].markup}</td>']
            columns += [f'<td style="{cells}word-break:break-word;">{cell.markup}</td>' for cell in row[1:]]
            markup += f'<tr>{"".join(columns)}</tr>'
        self.markup.append(markup + "</table>")

    def log(self, lines):
        self.text += [f"  {line.when}  {line.shown()}" for line in lines]
        rows = []
        for line in lines:
            colour = LOG_LEVELS.get(line.level, LOG_TEXT)
            rows.append(
                f'<span style="color:{LOG_TIME};">{html.escape(line.when)}</span>  '
                f'<span style="color:{colour};">{html.escape(line.shown())}</span>'
            )
        body = "\n".join(rows)
        self.markup.append(
            f'<pre style="margin:0;padding:12px 14px;background:#14161b;color:{LOG_TEXT};border-radius:6px;'
            "font-family:ui-monospace,'JetBrains Mono',Menlo,Consolas,monospace;font-size:12px;"
            f'line-height:1.6;white-space:pre-wrap;word-break:break-word;">{body}</pre>'
        )


def send(recipient, subject, level, label, title, plain_title, subtitle, mail):
    colours = config["levels"][level]
    page = Path(config["page"]).read_text()
    for marker, value in {
        "@label@": html.escape(label),
        "@color@": colours["color"],
        "@tint@": colours["tint"],
        "@title@": title,
        "@subtitle@": html.escape(subtitle),
        "@footer@": html.escape(f"Sent by {host}"),
    }.items():
        page = page.replace(marker, value)
    # last, so that nothing in a log is taken for a marker
    page = page.replace("@body@", "".join(mail.markup))

    message = EmailMessage()
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content("\n".join([plain_title, subtitle, *mail.text]) + "\n")
    message.add_alternative(page, subtype="html")
    subprocess.run([config["sendmail"], "-t"], input=message.as_bytes(), check=True)


class Line:
    """One log line, as a person wants to read it."""

    def __init__(self, stamp, text, level):
        self.when = time.strftime("%b %d %H:%M:%S", time.localtime(stamp))
        self.text = text
        self.level = level
        self.count = 1

    def shown(self):
        text = self.text
        if len(text) > LONGEST_LINE:
            text = text[:LONGEST_LINE] + "…"
        return f"{text}  (×{self.count})" if self.count > 1 else text


def level_of(name):
    name = str(name).lower()
    if name.startswith(("err", "fatal", "panic", "crit", "alert", "emerg")):
        return "fail"
    return "warn" if name.startswith("warn") else None


def readable(fields):
    """The part of a structured line a person reads: its message, its error and what it was about."""
    text = str(fields.get("msg") or fields.get("message") or "")
    for key in ("error", "err"):
        detail = fields.get(key)
        if detail and str(detail) not in text:
            text = f"{text}: {detail}" if text else str(detail)
    request = fields.get("request")
    if isinstance(request, dict):
        text += f' ({request.get("method", "")} {request.get("host", "")}{request.get("uri", "")})'
    return text


def simplify(message):
    """Returns (text, level) for a log message, which may be JSON or key=value pairs."""
    message = ANSI.sub("", message).strip()
    fields = None
    if message.startswith("{"):
        try:
            fields = json.loads(message)
        except ValueError:
            pass
    elif "msg=" in message and "level=" in message:
        fields = {key: value.strip('"') for key, value in LOGFMT.findall(message)}
    if isinstance(fields, dict):
        text = readable(fields)
        if text:
            return text, level_of(fields.get("level") or fields.get("lvl") or "")
    return message, None


def read_log(unit, state):
    """The lines of the run that failed, most recent last, without repeats and systemd's small talk."""
    run_id = state.get("InvocationID")
    wanted = [f"_SYSTEMD_INVOCATION_ID={run_id}", "+", f"INVOCATION_ID={run_id}"] if run_id else [f"--unit={unit}"]
    output = run("journalctl", "--boot", f"--lines={LOG_READ}", "--output=json", "--no-pager", *wanted)
    lines = {}
    for raw in output.splitlines():
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        message = entry.get("MESSAGE") or ""
        if isinstance(message, list):  # journald's way of saying it isn't valid text
            message = bytes(message).decode("utf-8", "replace")
        if entry.get("SYSLOG_IDENTIFIER") == "systemd" and NOISE.search(message):
            continue
        text, level = simplify(message)
        priority = int(entry.get("PRIORITY", 6))
        level = level or ("fail" if priority <= 3 else "warn" if priority == 4 else None)
        line = Line(int(entry.get("__REALTIME_TIMESTAMP", 0)) / 1e6, text, level)
        if text in lines:
            line.count += lines.pop(text).count
        lines[text] = line
    return list(lines.values())[-LOG_LINES:]


def unit_state(unit):
    wanted = "Description,Result,ActiveState,SubState,ExecMainStatus,NRestarts,StateChangeTimestamp,InvocationID"
    pairs = run("systemctl", "show", f"--property={wanted}", unit).splitlines()
    return dict(pair.split("=", 1) for pair in pairs if "=" in pair)


def describe(mail, unit, state, lines):
    active, sub = state.get("ActiveState", "?"), state.get("SubState", "?")
    rows = [("State", active if active == sub else f"{active} ({sub})")]
    rows.append(("Result", state.get("Result", "?")))
    if state.get("ExecMainStatus", "0") != "0":
        rows.append(("Exit status", state["ExecMainStatus"]))
    if state.get("NRestarts", "0") != "0":
        rows.append(("Restarts", state["NRestarts"]))
    if state.get("StateChangeTimestamp"):
        rows.append(("Since", state["StateChangeTimestamp"]))
    mail.facts(rows)
    mail.section(f"Log of {unit}")
    if lines:
        mail.log(lines)
    else:
        mail.line("Nothing in the journal.")


def alert(recipient, unit):
    # systemd triggers this before its own message about the failure reaches the journal
    time.sleep(2)
    run("journalctl", "--sync")

    # a "dependency" failure has its error in the unit it depends on
    needed = run("systemctl", "show", "--property=Requires,Requisite,BindsTo", "--value", unit).split()
    causes = [name for name in needed if subprocess.run(["systemctl", "--quiet", "is-failed", name]).returncode == 0]
    states = {name: unit_state(name) for name in [unit, *causes]}
    logs = {name: read_log(name, states[name]) for name in states}

    mail = Mail()
    describe(mail, unit, states[unit], logs[unit])
    for name in causes:
        mail.section(f"It needs {name}, which failed too")
        describe(mail, name, states[name], logs[name])

    send(
        recipient,
        subject=f"[{host}] {unit} failed",
        level="fail",
        label="Failed",
        title=f"<b>{html.escape(unit)}</b> failed",
        plain_title=f"{unit} failed",
        subtitle=f'{states[unit].get("Description", unit)}, on {host}',
        mail=mail,
    )


def duration(seconds):
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    if days:
        return f"{days} days, {hours} hours"
    return f"{hours} hours, {rest // 60} minutes"


def report(recipient):
    problems = []
    mail = Mail()

    mail.section("System")
    mail.facts(
        [
            ("NixOS", VERSION.read_text().strip()),
            ("Up for", duration(float(UPTIME.read_text().split()[0]))),
            # the profile link, as /run/current-system is made anew on every boot
            ("Last switch", time.strftime("%Y-%m-%d %H:%M", time.localtime(PROFILE.lstat().st_mtime))),
        ]
    )

    failed = [line.split()[0] for line in run("systemctl", "--failed", "--no-legend", "--plain").splitlines()]
    mail.section("Failed units")
    if failed:
        mail.table(None, [(badge("failed", "fail"), unit) for unit in failed])
        problems.append("1 failed unit" if len(failed) == 1 else f"{len(failed)} failed units")
    else:
        mail.line("None.")

    space = []
    columns = "--output=target,size,used,avail,pcent"
    excluded = ["-x", "tmpfs", "-x", "devtmpfs", "-x", "efivarfs"]
    for line in run("df", "-h", columns, *excluded).splitlines()[1:]:
        target, size, used, available, percent = line.rsplit(None, 4)
        percent = int(percent.rstrip("%"))
        space.append((target, size, used, available, meter(percent)))
        if percent > FULL_PERCENT:
            problems.append(f"{target} is {percent}% full")
    mail.section("Space")
    mail.table(["Mount", "Size", "Used", "Free", "Use"], space)

    disks = []
    for disk in json.loads(run("lsblk", "-dJ", "-o", "PATH,TYPE,MODEL,SIZE"))["blockdevices"]:
        if disk["type"] != "disk":
            continue
        found = re.search(r"(?:overall-health[^:]*|SMART Health Status): *(\w+)", run("smartctl", "-H", disk["path"]))
        health = found.group(1) if found else None
        level = "warn" if health is None else "ok" if health in ("PASSED", "OK") else "fail"
        if level == "fail":
            problems.append(f'{disk["path"]} reports {health}')
        name = (disk["model"] or disk["path"]).strip()
        disks.append((name, disk["size"], badge(health or "no data", level)))
    mail.section("Disks")
    mail.table(["Disk", "Size", "SMART"], disks)

    # every subvolume and bind mount is listed; the device stats belong to the filesystem
    filesystems = {}
    for line in run("findmnt", "-rno", "SOURCE,TARGET", "-t", "btrfs").splitlines():
        source, target = line.split(None, 1)
        filesystems.setdefault(source.split("[")[0], target)
    errors = []
    for target in sorted(filesystems.values()):
        stats = run("btrfs", "device", "stats", target).splitlines()
        count = sum(int(line.split()[-1]) for line in stats if line.split())
        errors.append((target, badge(str(count), "ok" if count == 0 else "fail")))
        if count:
            problems.append(f"{target} has {count} btrfs errors")
    mail.section("Btrfs errors")
    mail.table(["Filesystem", "Errors"], errors)

    if problems:
        summary = Mail()
        summary.section("Needs a look")
        for problem in problems:
            summary.line(problem)
        mail.text = summary.text + mail.text
        mail.markup = summary.markup + mail.markup

    send(
        recipient,
        subject=f"[{host}] weekly report" + (": needs attention" if problems else ""),
        level="warn" if problems else "ok",
        label="Needs attention" if problems else "All good",
        title="<b>Weekly</b> report",
        plain_title="Weekly report",
        subtitle=f'{host}, {time.strftime("%Y-%m-%d")}',
        mail=mail,
    )


def main():
    config.update(json.loads(Path(sys.argv[1]).read_text()))
    if sys.argv[2] == "alert":
        alert(sys.argv[3], sys.argv[4])
    else:
        report(sys.argv[3])


if __name__ == "__main__":
    main()
