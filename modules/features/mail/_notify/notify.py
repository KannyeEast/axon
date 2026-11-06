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
LOG_LINES = 40
FULL_PERCENT = 85  # the same line as the DiskFull alert
MUTED = "#6b7280"
LINE = "#e6e8ee"
TRACK = "#eef0f4"

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
        self.text += [f"  {line}" for line in lines]
        body = html.escape("\n".join(lines))
        self.markup.append(
            '<pre style="margin:0;padding:12px 14px;background:#14161b;color:#e6e8ee;border-radius:6px;'
            "font-family:ui-monospace,'JetBrains Mono',Menlo,Consolas,monospace;font-size:12px;"
            f'line-height:1.5;white-space:pre-wrap;word-break:break-word;">{body}</pre>'
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


def unit_state(unit):
    wanted = "Description,Result,ActiveState,SubState,ExecMainStatus,NRestarts,StateChangeTimestamp"
    pairs = run("systemctl", "show", f"--property={wanted}", unit).splitlines()
    return dict(pair.split("=", 1) for pair in pairs if "=" in pair)


def describe(mail, unit, state):
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
    # status only shows the log of the unit's current run; once it has restarted, the failed run's
    # lines are only in the journal
    log = run(
        "journalctl", f"--unit={unit}", "--boot", f"--lines={LOG_LINES}", "--no-pager", "--no-hostname"
    )
    mail.section(f"Log of {unit}")
    mail.log(log.splitlines() or ["(nothing in the journal)"])


def alert(recipient, unit):
    # systemd triggers this before its own message about the failure reaches the journal
    time.sleep(2)
    run("journalctl", "--sync")

    state = unit_state(unit)
    mail = Mail()
    describe(mail, unit, state)
    # a "dependency" failure has its error in the unit it depends on
    needed = run("systemctl", "show", "--property=Requires,Requisite,BindsTo", "--value", unit)
    for dependency in needed.split():
        if subprocess.run(["systemctl", "--quiet", "is-failed", dependency]).returncode == 0:
            mail.section(f"It needs {dependency}, which failed too")
            describe(mail, dependency, unit_state(dependency))

    send(
        recipient,
        subject=f"[{host}] {unit} failed",
        level="fail",
        label="Failed",
        title=f"<b>{html.escape(unit)}</b> failed",
        plain_title=f"{unit} failed",
        subtitle=f'{state.get("Description", unit)}, on {host}',
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
