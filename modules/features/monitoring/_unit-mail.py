"""Alertmanager's webhook for UnitFailed: mails each failed unit with the last lines of its log
from Loki and a link to the rest in Logs Drilldown, on the page every mail of ours uses.

unit-mail.py <config>   (SMTP login in $MAIL_FROM and $MAIL_TOKEN)
"""
import html
import json
import os
import re
import smtplib
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

LINES = 30  # shown; more are read, as repeats and systemd's own lines fall away
READ = 300
LONGEST = 300
MUTED = "#6b7280"
LOG_TEXT = "#e6e8ee"
LOG_TIME = "#8b93a1"
LOG_LEVELS = {"fail": "#ff9aa8", "warn": "#f1c27d"}
# systemd's lines about the unit that only repeat what the mail already says
NOISE = r": (Deactivated|Scheduled restart|Consumed|Failed with result|Main process exited)"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

config = json.loads(Path(sys.argv[1]).read_text())


def moment(stamp):
    # Go writes up to nine digits of a second, Python reads six
    return datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", stamp))


def level_of(name):
    if name.startswith(("err", "crit", "alert", "emerg")):
        return "fail"
    return "warn" if name.startswith("warn") else None


def read_log(host, unit, fired):
    """The unit's last lines up to a minute after it failed, oldest first, without repeats."""
    query = f'{{host="{host}",unit="{unit}"}}'
    end = fired + timedelta(minutes=1)
    params = urllib.parse.urlencode(
        {
            "query": query,
            "start": int((end - timedelta(hours=1)).timestamp() * 1e9),
            "end": int(end.timestamp() * 1e9),
            "limit": READ,
            "direction": "backward",
        }
    )
    with urllib.request.urlopen(f'{config["loki"]}/loki/api/v1/query_range?{params}', timeout=10) as answer:
        streams = json.load(answer)["data"]["result"]
    entries = sorted(
        (int(stamp), text, level_of(stream["stream"].get("level", "")))
        for stream in streams
        for stamp, text in stream["values"]
    )
    noise = re.compile(re.escape(unit) + NOISE)
    lines = {}
    for stamp, text, level in entries:
        text = ANSI.sub("", text).strip()
        if noise.match(text):
            continue
        count = lines.pop(text, (0, 0, None))[1] + 1
        lines[text] = (stamp, count, level)
    return [(stamp, text, count, level) for text, (stamp, count, level) in lines.items()][-LINES:]


def drilldown(host, unit, fired):
    if not config["grafana"]:
        return None
    filters = [f"unit|=|{unit}", f"host|=|{host}"]
    query = urllib.parse.urlencode(
        [("var-filters", f) for f in filters]
        + [("from", int((fired - timedelta(hours=1)).timestamp() * 1000)), ("to", "now")]
    )
    path = urllib.parse.quote(unit, safe="")
    return f'{config["grafana"]}/a/grafana-lokiexplore-app/explore/unit/{path}/logs?{query}'


def section(alert):
    """One failed unit as (plain text, markup)."""
    labels = alert["labels"]
    host, unit = labels.get("host", "?"), labels.get("unit", "?")
    fired = moment(alert["startsAt"])
    since = fired.astimezone().strftime("%a %d.%m. %H:%M")
    text = [f"{unit} on {host}, since {since}"]
    markup = [
        f'<p style="margin:0 0 2px;font-weight:600;">{html.escape(unit)}</p>'
        f'<p style="margin:0 0 10px;color:{MUTED};font-size:14px;">since {since}</p>'
    ]
    if alert["status"] == "resolved":
        return text, markup
    lines = read_log(host, unit, fired)
    rows = []
    for stamp, line, count, level in lines:
        when = time.strftime("%H:%M:%S", time.localtime(stamp / 1e9))
        shown = line if len(line) <= LONGEST else line[:LONGEST] + "…"
        if count > 1:
            shown += f"  (×{count})"
        text.append(f"  {when}  {shown}")
        colour = LOG_LEVELS.get(level, LOG_TEXT)
        rows.append(
            f'<span style="color:{LOG_TIME};">{when}</span>  '
            f'<span style="color:{colour};">{html.escape(shown)}</span>'
        )
    if rows:
        body = "\n".join(rows)
        markup.append(
            f'<pre style="margin:0 0 8px;padding:12px 14px;background:#14161b;color:{LOG_TEXT};'
            "border-radius:6px;font-family:ui-monospace,'JetBrains Mono',Menlo,Consolas,monospace;"
            f'font-size:12px;line-height:1.6;white-space:pre-wrap;word-break:break-word;">{body}</pre>'
        )
    else:
        text.append("  nothing in the log")
        markup.append(f'<p style="margin:0 0 8px;color:{MUTED};font-size:14px;">nothing in the log</p>')
    link = drilldown(host, unit, fired)
    if link:
        text.append(f"  {link}")
        markup.append(f'<p style="margin:0 0 18px;font-size:14px;"><a href="{html.escape(link)}">Full log</a></p>')
    return text, markup


def send(payload):
    alerts = payload["alerts"]
    resolved = payload["status"] == "resolved"
    host = payload["commonLabels"].get("host", "?")
    units = [alert["labels"].get("unit", "?") for alert in alerts]
    what = units[0] if len(units) == 1 else f"{len(units)} units"
    text, markup = [], []
    for alert in alerts:
        part = section(alert)
        text += part[0]
        markup += part[1]

    colours = config["levels"]["ok" if resolved else "fail"]
    page = Path(config["page"]).read_text()
    for marker, value in {
        "@label@": "Resolved" if resolved else "Failed",
        "@color@": colours["color"],
        "@tint@": colours["tint"],
        "@title@": f"<b>{html.escape(what)}</b> failed",
        "@subtitle@": f"on {html.escape(host)}",
        "@footer@": html.escape(f'Sent by {config["sender"]}'),
    }.items():
        page = page.replace(marker, value)
    # last, so that nothing in a log is taken for a marker
    page = page.replace("@body@", "".join(markup))

    message = EmailMessage()
    message["From"] = os.environ["MAIL_FROM"]
    message["To"] = config["to"]
    message["Subject"] = f"[{host}] {what} failed" + (" (resolved)" if resolved else "")
    message.set_content("\n".join(text) + "\n")
    message.add_alternative(page, subtype="html")
    with smtplib.SMTP(config["smtp"], config["port"], timeout=30) as smtp:
        smtp.starttls()
        smtp.login(os.environ["MAIL_FROM"], os.environ["MAIL_TOKEN"])
        smtp.send_message(message)


class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            send(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            self.send_response(200)
        except Exception as error:  # Alertmanager tries again on an error
            print(f"unit-mail: {error!r}", file=sys.stderr)
            self.send_response(500)
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", config["listen"]), Hook).serve_forever()
