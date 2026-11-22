"""Alertmanager's webhook for UnitFailed: mails each failed unit with the last lines of its log
from Loki and a link to the rest in Logs Drilldown, on the page every mail of ours uses.

unit-mail.py <config>   (SMTP login in $MAIL_LOGIN and $MAIL_TOKEN)
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
TEXT = "#111827"
MUTED = "#6B7280"
LINE = "#E5E7EB"
MONO = "SFMono-Regular,Menlo,Consolas,monospace"
LOG_BACK = "#111827"
LOG_TEXT = "#E5E7EB"
LOG_TIME = "#9CA3AF"
LOG_LEVELS = {"fail": "#FCA5A5", "warn": "#FCD34D"}
SECTION = f"margin:24px 0 0;padding:20px 0 0;border-top:1px solid {LINE};"
HEADING = f"padding:0 0 14px;font-size:12px;line-height:16px;font-weight:700;letter-spacing:0.06em;color:{MUTED};"
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


def last_output(lines):
    """The last error in the log, else its last line."""
    errors = [line for _, line, _, level in lines if level == "fail"]
    return (errors or [line for _, line, _, _ in lines] or [""])[-1]


def section(alert, named):
    """One failed unit as (plain text, markup, last output, since); named puts the unit in the heading."""
    labels = alert["labels"]
    host, unit = labels.get("host", "?"), labels.get("unit", "?")
    fired = moment(alert["startsAt"])
    since = fired.astimezone().strftime("%a %d.%m. %H:%M")
    lines = read_log(host, unit, fired)
    heading = f"LOG SNAPSHOT · {unit}" if named else "LOG SNAPSHOT"
    text = [f"{unit} on {host}, since {since}"]
    markup = [f'<div style="{SECTION}"><div style="{HEADING}">{html.escape(heading)}</div>']
    rows = []
    for stamp, line, count, level in lines:
        when = time.strftime("%H:%M:%S", time.localtime(stamp / 1e9))
        shown = line if len(line) <= LONGEST else line[:LONGEST] + "…"
        if count > 1:
            shown += f"  (×{count})"
        text.append(f"  {when}  {shown}")
        colour = LOG_LEVELS.get(level, LOG_TEXT)
        weight = "font-weight:700;" if level == "fail" else ""
        rows.append(
            f'<tr><td style="width:68px;padding:0 12px 0 0;vertical-align:top;color:{LOG_TIME};white-space:nowrap;">{when}</td>'
            f'<td style="padding:0;color:{colour};{weight}word-break:break-all;">{html.escape(shown)}</td></tr>'
        )
    if rows:
        markup.append(
            f'<table role="presentation" width="100%" style="width:100%;border-collapse:separate;border-spacing:0;background:{LOG_BACK};border-radius:6px;">'
            f'<tr><td style="padding:14px 16px;"><table role="presentation" width="100%" style="width:100%;border-collapse:collapse;'
            f'font-family:{MONO};font-size:12px;line-height:20px;">{"".join(rows)}</table></td></tr></table>'
        )
    else:
        text.append("  nothing in the log")
        markup.append(f'<p style="margin:0;font-size:14px;color:{MUTED};">nothing in the log</p>')
    markup.append("</div>")
    link = drilldown(host, unit, fired)
    command = f"journalctl -u {unit}"
    markup.append(f'<div style="{SECTION}">')
    if link:
        text.append(f"  {link}")
        markup.append(
            f'<a href="{html.escape(link)}" style="display:inline-block;padding:11px 18px;border-radius:6px;'
            f'background:{TEXT};font-size:14px;line-height:18px;font-weight:600;color:#FFFFFF;text-decoration:none;">View full log</a>'
        )
    markup.append(
        f'<p style="margin:{14 if link else 0}px 0 0;font-size:13px;line-height:20px;color:#4B5563;">Or on {html.escape(host)}: '
        f'<span style="padding:2px 6px;border-radius:4px;background:#F3F4F6;color:{TEXT};font-family:{MONO};font-size:12px;">'
        f"{html.escape(command)}</span></p></div>"
    )
    return text, markup, last_output(lines), since


def send(payload):
    alerts = payload["alerts"]
    host = payload["commonLabels"].get("host", "?")
    units = [alert["labels"].get("unit", "?") for alert in alerts]
    what = units[0] if len(units) == 1 else f"{len(units)} units"
    text, markup, outputs, times = [], [], [], []
    for alert in alerts:
        part = section(alert, len(alerts) > 1)
        text += part[0]
        markup += part[1]
        outputs.append(part[2])
        times.append(part[3])

    lead = ""
    if len(alerts) == 1 and outputs[0]:
        lead = (
            f'<p style="margin:12px 0 0;font-size:15px;line-height:22px;color:{TEXT};">Last output: '
            f'<span style="font-family:{MONO};font-size:14px;color:{config["levels"]["fail"]["color"]};">'
            f"{html.escape(outputs[0])}</span></p>"
        )
    colours = config["levels"]["fail"]
    page = Path(config["page"]).read_text()
    values = {
        "@preview@": html.escape(f"{what} failed on {host}" + (f": {outputs[0]}" if len(alerts) == 1 and outputs[0] else "")),
        "@label@": "FAILED",
        "@color@": colours["color"],
        "@tint@": colours["tint"],
        "@bar@": colours["bar"],
        "@title@": f'{html.escape(what)} <span style="font-weight:400;">failed</span>',
        "@subtitle@": html.escape(f"{host} · since {times[0]}"),
        "@footer@": html.escape(f'Sent by {config["sender"]}'),
        "@body@": lead + "".join(markup),
    }
    # one pass, so that nothing in a log is taken for a marker
    page = re.sub(r"@\w+@", lambda match: values.get(match[0], match[0]), page)

    message = EmailMessage()
    message["From"] = config["from"]
    message["To"] = config["to"]
    message["Subject"] = f"[{host}] {what} failed"
    message.set_content("\n".join(text) + "\n")
    message.add_alternative(page, subtype="html")
    with smtplib.SMTP(config["smtp"], config["port"], timeout=30) as smtp:
        smtp.starttls()
        smtp.login(os.environ["MAIL_LOGIN"], os.environ["MAIL_TOKEN"])
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
