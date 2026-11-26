"""Read by alerts.nix: Alertmanager's webhook that mails every alert, a failed unit with its log."""
import html
import json
import os
import re
import smtplib
import ssl
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
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
LEAD = f"margin:12px 0 0;font-size:15px;line-height:22px;color:{TEXT};"
BUTTON = (
    f"display:inline-block;margin:0 8px 0 0;padding:11px 18px;border-radius:6px;background:{TEXT};"
    "font-size:14px;line-height:18px;font-weight:600;color:#FFFFFF;text-decoration:none;"
)
# Watchdog always fires, so its weekly mail is good news; a Reminder (from n8n) is news
LEVELS = {"Watchdog": ("ok", "WORKING"), "Reminder": ("info", "REMINDER")}
# systemd's lines about the unit that only repeat what the mail already says
NOISE = r": (Deactivated|Scheduled restart|Consumed|Failed with result|Main process exited)"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def log(text):
    print(f"<3>alert-mail: {text}", file=sys.stderr, flush=True)


sys.excepthook = lambda kind, error, trace: log(repr(error))
config = json.loads(Path(sys.argv[1]).read_text())


def moment(stamp):
    # Go writes up to nine digits of a second, Python reads six
    return datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", stamp))


def since(fired):
    return "since " + fired.astimezone().strftime("%a %d.%m. %H:%M")


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
    """The unit's log in Logs Drilldown from an hour before it fired, or None without a route to Grafana."""
    if not config["grafana"]:
        return None
    filters = [f"unit|=|{unit}", f"host|=|{host}"]
    start = (fired - timedelta(hours=1) - datetime.fromtimestamp(0, timezone.utc)) // timedelta(milliseconds=1)
    query = urllib.parse.urlencode([("var-filters", f) for f in filters] + [("from", start), ("to", "now")])
    path = urllib.parse.quote(unit, safe="")
    return f'{config["grafana"]}/a/grafana-lokiexplore-app/explore/unit/{path}/logs?{query}'


def fill(values):
    page = Path(config["page"]).read_text()
    # one pass, so that nothing in a log or summary is taken for a marker
    return re.sub(r"@\w+@", lambda match: values.get(match[0], match[0]), page)


def links(alert):
    """The alert's log in Logs Drilldown and its link, as (name, address) where it has them."""
    labels = alert.get("labels", {})
    unit = labels.get("unit")
    logs = unit and drilldown(labels.get("host", ""), unit, moment(alert.get("startsAt", "")))
    return [(kind, address) for kind, address in (("Logs", logs), ("Details", alert.get("annotations", {}).get("link"))) if address]


def generic(payload):
    """Any alert but UnitFailed, as (subject, text, html)."""
    alerts = payload.get("alerts", [])
    labels = payload.get("commonLabels", {})
    name, host = labels.get("alertname", ""), labels.get("host", "")
    summary = payload.get("commonAnnotations", {}).get("summary")
    level, label = LEVELS.get(name, ("fail", "FIRING"))
    text = []
    for alert in alerts:
        own = alert.get("labels", {})
        text.append(f'{own.get("alertname", "")} on {own.get("host", "")}: {alert.get("annotations", {}).get("summary", "")}')
        text += [f"Logs: {address}" if kind == "Logs" else address for kind, address in links(alert)]
        text += [since(moment(alert.get("startsAt", ""))), ""]

    if len(alerts) == 1:
        alert = alerts[0]
        body = f'<p style="{LEAD}">{html.escape(alert.get("annotations", {}).get("summary", ""))}</p>'
        buttons = "".join(
            f'<a href="{html.escape(address)}" style="{BUTTON}">{"View logs" if kind == "Logs" else kind}</a>'
            for kind, address in links(alert)
        )
        if buttons:
            body += f'<div style="{SECTION}">{buttons}</div>'
    else:
        rows = []
        for alert in alerts:
            small = "".join(
                f' · <a href="{html.escape(address)}" style="color:{TEXT};">{kind}</a>' for kind, address in links(alert)
            )
            rows.append(
                f'<p style="margin:0;font-size:15px;line-height:22px;color:{TEXT};">{html.escape(alert.get("annotations", {}).get("summary", ""))}</p>'
                f'<p style="margin:0 0 12px;font-size:13px;line-height:20px;color:{MUTED};">{since(moment(alert.get("startsAt", "")))}{small}</p>'
            )
        count = f'{len(alerts)} {"REMINDERS" if name == "Reminder" else "ALERTS"}'
        body = f'<div style="{SECTION}"><div style="{HEADING}">{count}</div>{"".join(rows)}</div>'

    colours = config["levels"][level]
    page = fill(
        {
            "@preview@": html.escape(f"{name} on {host}" + (f": {summary}" if summary else "")),
            "@label@": label,
            "@color@": colours["color"],
            "@tint@": colours["tint"],
            "@bar@": colours["bar"],
            "@title@": html.escape(name),
            "@subtitle@": html.escape(f"{host} · {since(moment(alerts[0].get('startsAt', '')))}"),
            "@footer@": html.escape(f'Sent by {config["sender"]}'),
            "@body@": body,
        }
    )
    return f"[{host}] {summary or name}", "\n".join(text) + "\n", page


def last_output(lines):
    """The last error in the log, else its last line."""
    errors = [line for _, line, _, level in lines if level == "fail"]
    return (errors or [line for _, line, _, _ in lines] or [""])[-1]


def section(alert, named):
    """One failed unit as (plain text, markup, last output, since); named puts the unit in the heading."""
    labels = alert.get("labels", {})
    host, unit = labels.get("host", "?"), labels.get("unit", "?")
    fired = moment(alert.get("startsAt", ""))
    try:
        lines, unread = read_log(host, unit, fired), False
    except Exception as error:  # the mail goes out without the log
        log(f"reading {unit}'s log from Loki: {error!r}")
        lines, unread = [], True
    heading = f"LOG SNAPSHOT · {unit}" if named else "LOG SNAPSHOT"
    text = [f"{unit} on {host}, {since(fired)}"]
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
        empty = "couldn't read the log from Loki" if unread else "nothing in the log"
        text.append(f"  {empty}")
        markup.append(f'<p style="margin:0;font-size:14px;color:{MUTED};">{empty}</p>')
    markup.append("</div>")
    link = drilldown(host, unit, fired)
    command = f"journalctl -u {unit}"
    markup.append(f'<div style="{SECTION}">')
    if link:
        text.append(f"  {link}")
        markup.append(f'<a href="{html.escape(link)}" style="{BUTTON}">View full log</a>')
    markup.append(
        f'<p style="margin:{14 if link else 0}px 0 0;font-size:13px;line-height:20px;color:#4B5563;">Or on {html.escape(host)}: '
        f'<span style="padding:2px 6px;border-radius:4px;background:#F3F4F6;color:{TEXT};font-family:{MONO};font-size:12px;">'
        f"{html.escape(command)}</span></p></div>"
    )
    return text, markup, last_output(lines), since(fired)


def unit_failed(payload):
    """UnitFailed, each unit with the last lines of its log, as (subject, text, html)."""
    alerts = payload.get("alerts", [])
    host = payload.get("commonLabels", {}).get("host", "?")
    units = [alert.get("labels", {}).get("unit", "?") for alert in alerts]
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
            f'<p style="{LEAD}">Last output: '
            f'<span style="font-family:{MONO};font-size:14px;color:{config["levels"]["fail"]["color"]};">'
            f"{html.escape(outputs[0])}</span></p>"
        )
    colours = config["levels"]["fail"]
    page = fill(
        {
            "@preview@": html.escape(f"{what} failed on {host}" + (f": {outputs[0]}" if len(alerts) == 1 and outputs[0] else "")),
            "@label@": "FAILED",
            "@color@": colours["color"],
            "@tint@": colours["tint"],
            "@bar@": colours["bar"],
            "@title@": f'{html.escape(what)} <span style="font-weight:400;">failed</span>',
            "@subtitle@": html.escape(f"{host} · {times[0]}"),
            "@footer@": html.escape(f'Sent by {config["sender"]}'),
            "@body@": lead + "".join(markup),
        }
    )
    return f"[{host}] {what} failed", "\n".join(text) + "\n", page


def render(payload):
    if payload.get("commonLabels", {}).get("alertname") == "UnitFailed":
        return unit_failed(payload)
    return generic(payload)


def plain(body, error):
    """A mail without layout when rendering failed: every alert's labels and annotations, and the error."""
    try:
        payload = json.loads(body)
        labels = payload.get("commonLabels", {})
        subject = f'[{labels.get("host", "?")}] {labels.get("alertname", "?")}'
        details = [
            "\n".join(f"{key}: {value}" for key, value in {**alert.get("labels", {}), **alert.get("annotations", {})}.items())
            for alert in payload.get("alerts", [])
        ]
    except Exception:  # not even the payload is readable
        subject, details = f'[{config["sender"]}] alert', [body.decode(errors="replace")]
    return subject, "\n\n".join(details + [f"Not rendered: {error!r}"]) + "\n", None


def send(subject, text, page):
    message = EmailMessage()
    message["From"] = config["from"]
    message["To"] = config["to"]
    # a header can't hold a line break, which a summary may contain
    message["Subject"] = " ".join(subject.split())
    message["Date"] = formatdate(localtime=True)
    message["Message-ID"] = make_msgid()
    message.set_content(text)
    if page:
        message.add_alternative(page, subtype="html")
    with smtplib.SMTP(config["smtp"], config["port"], timeout=30) as smtp:
        # without a context smtplib doesn't check the relay's certificate
        smtp.starttls(context=ssl.create_default_context())
        smtp.login(os.environ["MAIL_LOGIN"], os.environ["MAIL_TOKEN"])
        smtp.send_message(message)


class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            mail = render(json.loads(body))
        except Exception as error:
            log(f"rendering: {error!r}")
            mail = plain(body, error)
        try:
            send(*mail)
            self.send_response(200)
        except Exception as error:  # Alertmanager tries again
            log(f"sending: {error!r}")
            self.send_response(500)
        self.end_headers()

    def log_message(self, *args):
        pass


class Server(HTTPServer):
    def handle_error(self, request, address):
        log(repr(sys.exception()))


Server(("127.0.0.1", config["listen"]), Hook).serve_forever()
