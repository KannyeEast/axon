"""Passes Seerr through, minus the Jellyfin links to items the asking person can't see.

scope-filter.py <port> <seerr url> <jellyfin url> [<sync url>]

Listens on 127.0.0.1:<port> and hands every request to Seerr and every answer back as it came,
except a JSON answer to a GET whose `mediaInfo` names Jellyfin items: those the person (found by
their Seerr session cookie) can't see in Jellyfin lose their id and link, and a movie among them is
marked unknown again, so the app offers a request instead of a Jellyfin page that fails. Series keep
their status. If anything in that goes wrong, the answer goes back unchanged. A request from a
scoped user (a Jellyfin user whose "Allow items with tags" holds `scoped`) also puts the title on
their Seerr watchlist: Seerr stores no request for a series whose seasons it already knows, and the
watchlist is what n8n's Scope tags then shows them. After any request or watchlist change it POSTs
to <sync url>, so the title shows up within seconds rather than at the next scheduled run.

The Jellyfin API key comes from the unit's credential `jellyfin`.
"""
import http.client
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# id key -> (status key, link key) in Seerr's Media
LINKS = {
    "jellyfinMediaId": ("status", "mediaUrl"),
    "jellyfinMediaId4k": ("status4k", "mediaUrl4k"),
}
UNKNOWN = 1  # Seerr's MediaStatus.UNKNOWN
# hop-by-hop, or set anew by this proxy
DROPPED = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade", "host", "content-length", "accept-encoding", "expect",
}
SESSION = "connect.sid"
MARKER = "scoped"
CACHED = 300
TIMEOUT = 60
LOOKUP_TIMEOUT = 5


def plain(item_id):
    """Jellyfin ids with or without dashes, the way Jellyfin's API writes them."""
    return item_id.replace("-", "").lower()


def candidates(node, found):
    """(result, mediaInfo) for every result whose mediaInfo names a Jellyfin item."""
    if isinstance(node, dict):
        media = node.get("mediaInfo")
        if isinstance(media, dict) and any(isinstance(media.get(key), str) for key in LINKS):
            found.append((node, media))
        for value in node.values():
            candidates(value, found)
    elif isinstance(node, list):
        for value in node:
            candidates(value, found)
    return found


class Filter:
    def __init__(self, seerr, jellyfin, key):
        self.seerr = seerr.rstrip("/")
        self.jellyfin = jellyfin.rstrip("/")
        self.key = key
        self.users = {}
        self.marked = {}
        self.lock = threading.Lock()

    def lookup(self, url, headers):
        request = urllib.request.Request(url, headers={**headers, "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=LOOKUP_TIMEOUT) as response:
            return json.loads(response.read())

    def jellyfin_user(self, cookie):
        """The Jellyfin user id behind a Seerr session, or None; remembered for CACHED s."""
        now = time.monotonic()
        with self.lock:
            user, until = self.users.get(cookie, (None, 0))
        if until > now:
            return user
        me = self.lookup(f"{self.seerr}/api/v1/auth/me", {"Cookie": f"{SESSION}={cookie}"})
        user = me.get("jellyfinUserId")
        with self.lock:
            self.users = {k: v for k, v in self.users.items() if v[1] > now}
            self.users[cookie] = (user, now + CACHED)
        return user

    def is_scoped(self, user):
        """Whether the Jellyfin user carries the scope marker; remembered for CACHED s."""
        now = time.monotonic()
        with self.lock:
            scoped, until = self.marked.get(user, (False, 0))
        if until > now:
            return scoped
        auth = {"Authorization": f'MediaBrowser Token="{self.key}"'}
        policy = self.lookup(f"{self.jellyfin}/Users/{user}", auth)["Policy"]
        scoped = MARKER in {tag.lower() for tag in policy.get("AllowedTags") or []}
        with self.lock:
            self.marked = {k: v for k, v in self.marked.items() if v[1] > now}
            self.marked[user] = (scoped, now + CACHED)
        return scoped

    def claim(self, body, headers, cookie):
        """Puts a scoped user's requested title on their watchlist, with their own session; a title
        already there (409) is fine."""
        user = self.jellyfin_user(cookie)
        if not user or not self.is_scoped(user):
            return
        asked = json.loads(body)
        watch = {"tmdbId": asked["mediaId"], "mediaType": asked["mediaType"]}
        # their whole cookie and CSRF header, as Seerr checks the token against its cookie
        sent = {"Cookie": headers["Cookie"], "Content-Type": "application/json"}
        if headers.get("X-XSRF-TOKEN"):
            sent["X-XSRF-TOKEN"] = headers["X-XSRF-TOKEN"]
        request = urllib.request.Request(
            f"{self.seerr}/api/v1/watchlist", data=json.dumps(watch).encode(), headers=sent,
            method="POST",
        )
        try:
            urllib.request.urlopen(request, timeout=LOOKUP_TIMEOUT).close()
        except urllib.error.HTTPError as error:
            if error.code != 409:
                raise

    def visible(self, user, ids):
        """Which of ids the user can see: Jellyfin's /Items with ids answers only those."""
        query = urllib.parse.urlencode({
            "userId": user, "ids": ",".join(sorted(ids)), "fields": "",
            "enableImages": "false", "enableUserData": "false",
        })
        auth = {"Authorization": f'MediaBrowser Token="{self.key}"'}
        answer = self.lookup(f"{self.jellyfin}/Items?{query}", auth)
        return {plain(item["Id"]) for item in answer["Items"]}

    def apply(self, body, cookie):
        """The body with hidden items unlinked, or None when nothing changes."""
        data = json.loads(body)
        found = candidates(data, [])
        if not found or not cookie:
            return None
        user = self.jellyfin_user(cookie)
        if not user:
            return None
        ids = {plain(m[key]) for _, m in found for key in LINKS if isinstance(m.get(key), str)}
        seen = self.visible(user, ids)
        changed = False
        for result, media in found:
            movie = "movie" in (media.get("mediaType"), result.get("mediaType"), result.get("type"))
            for key, (status, link) in LINKS.items():
                if not isinstance(media.get(key), str) or plain(media[key]) in seen:
                    continue
                media[key] = None
                if link in media:
                    media[link] = None
                if movie:
                    media[status] = UNKNOWN
                changed = True
        if not changed:
            return None
        return json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode()


# a successful change here calls the sync
CLAIMS = ("/api/v1/request", "/api/v1/watchlist")


def sync(url):
    """Calls the sync; when it doesn't answer, its schedule catches up."""
    try:
        urllib.request.urlopen(
            urllib.request.Request(url, data=b"", method="POST"), timeout=LOOKUP_TIMEOUT
        ).close()
    except OSError as error:
        print(f"scope-filter: {url} not called: {error!r}", flush=True)


class Proxy(BaseHTTPRequestHandler):
    scope = None
    upstream = None
    sync_url = None

    def log_request(self, code="-", size="-"):
        pass

    def read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            body = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return body
                body += self.rfile.read(size)
                self.rfile.readline()
        length = self.headers.get("Content-Length")
        return self.rfile.read(int(length)) if length else None

    def forward(self):
        body = self.read_body()
        named = {t.strip().lower() for t in self.headers.get("Connection", "").split(",")}
        dropped = DROPPED | named
        scheme, netloc = self.upstream
        connection = (
            http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
        )(netloc, timeout=TIMEOUT)
        # http.client, not urllib: urllib follows redirects, raises on 4xx and adds a Content-Type
        try:
            connection.putrequest(self.command, self.path, skip_accept_encoding=True)
            for name, value in self.headers.items():
                if name.lower() not in dropped:
                    connection.putheader(name, value)
            # identity, so the body can be read and rewritten
            connection.putheader("Accept-Encoding", "identity")
            if body is not None:
                connection.putheader("Content-Length", str(len(body)))
            connection.endheaders(body)
            response = connection.getresponse()
            payload = response.read()
        except (OSError, http.client.HTTPException) as error:
            print(f"scope-filter: {self.command} {self.path}: Seerr: {error!r}", flush=True)
            self.answer(502, b'{"error":"Seerr unreachable"}')
            return
        finally:
            connection.close()

        if (
            self.command == "POST"
            and urllib.parse.urlsplit(self.path).path.rstrip("/") == "/api/v1/request"
            and response.status in (201, 202)
            and body
        ):
            try:
                cookie = self.cookies().get(SESSION)
                if cookie:
                    self.scope.claim(body, self.headers, cookie)
            except Exception as error:
                print(f"scope-filter: {self.path}: no watchlist entry: {error!r}", flush=True)

        if (
            self.command in ("POST", "DELETE")
            and urllib.parse.urlsplit(self.path).path.startswith(CLAIMS)
            and 200 <= response.status < 300
            and self.sync_url
        ):
            threading.Thread(target=sync, args=(self.sync_url,), daemon=True).start()

        if (
            self.command == "GET"
            and response.status == 200
            and "json" in (response.getheader("Content-Type") or "").lower()
        ):
            try:
                cookie = self.cookies().get(SESSION)
                payload = self.scope.apply(payload, cookie) or payload
            except Exception as error:
                print(f"scope-filter: {self.path}: passed unchanged: {error!r}", flush=True)

        self.send_response_only(response.status, response.reason)
        for name, value in response.getheaders():
            if name.lower() not in DROPPED:
                self.send_header(name, value)
        if self.command == "HEAD":
            if response.getheader("Content-Length") is not None:
                self.send_header("Content-Length", response.getheader("Content-Length"))
        elif response.status not in (204, 304) and response.status >= 200:
            self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def answer(self, status, body):
        self.send_response_only(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def cookies(self):
        found = {}
        for header in self.headers.get_all("Cookie") or []:
            for part in header.split(";"):
                name, _, value = part.strip().partition("=")
                found.setdefault(name, value)
        return found

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = forward


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit("usage: scope-filter.py <port> <seerr url> <jellyfin url> [<sync url>]")
    port, seerr, jellyfin, *rest = sys.argv[1:]
    credentials = os.environ.get("CREDENTIALS_DIRECTORY")
    if not credentials:
        sys.exit("scope-filter.py: no credentials; run it as scope-filter.service")
    key = (Path(credentials) / "jellyfin").read_text().strip()
    target = urllib.parse.urlsplit(seerr)
    Proxy.upstream = (target.scheme, target.netloc)
    Proxy.sync_url = rest[0] if rest else None
    Proxy.scope = Filter(seerr, jellyfin, key)
    server = ThreadingHTTPServer(("127.0.0.1", int(port)), Proxy)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
