"""Tags what each person asked for in Seerr, so Jellyfin can show a friend just that.

friend-tags.py <seerr url> <jellyfin url> [--dry-run]

Started by a timer, or by a call on its systemd socket (friend-filter, on a request or watchlist
change): the calls are answered first, and a burst of them makes one run.

The API keys come from the unit's credentials, seerr and jellyfin. A person's tag is
f-<first 8 hex of their Jellyfin user id>; it goes on every movie and series they asked for and on
the collections those are in. Tags of that shape belong to this script, every other tag stays. A
Jellyfin user whose "Allow items with tags" holds `friend` gets their own tag added there. Each run
sets everything anew; --dry-run prints the changes and makes none.
"""
import json
import os
import re
import socket
import sys
import urllib.parse
import urllib.request
from pathlib import Path

MARKER = "friend"
OURS = re.compile(r"f-[0-9a-f]{8}", re.IGNORECASE)
# a request the owner declined grants nothing (Seerr's MediaRequestStatus)
DECLINED = 3
PAGE = 100
TIMEOUT = 120
# a burst of calls is over once none came for this long
QUIET = 10
# The fields POST /Items/{id} reads (Jellyfin's ItemUpdateController.UpdateItem). It overwrites each
# scalar with what it is sent, null too, and fails on the whole item as GET returns it (trickplay),
# so these go back as they came. People stays out: sent, it rewrites the cast and crew.
EDITABLE = (
    "AirDays", "AirTime", "AirsAfterSeasonNumber", "AirsBeforeEpisodeNumber",
    "AirsBeforeSeasonNumber", "Album", "AlbumArtists", "ArtistItems", "AspectRatio",
    "CommunityRating", "CriticRating", "CustomRating", "DateCreated", "DisplayOrder", "EndDate",
    "ForcedSortName", "Genres", "Height", "IndexNumber", "LockData", "LockedFields", "Name",
    "OfficialRating", "OriginalLanguage", "OriginalTitle", "Overview", "ParentIndexNumber",
    "PreferredMetadataCountryCode", "PreferredMetadataLanguage", "PremiereDate",
    "ProductionLocations", "ProductionYear", "ProviderIds", "RunTimeTicks", "SeriesName", "Status",
    "Studios", "Taglines", "Tags", "Video3DFormat",
)


class Api:
    def __init__(self, base, headers):
        self.base = base.rstrip("/")
        self.headers = headers

    def call(self, method, path, query=None, body=None):
        url = self.base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        request = urllib.request.Request(
            url,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                **self.headers,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = response.read()
        return json.loads(payload) if payload else None


def plain(item_id):
    """Jellyfin ids with or without dashes, the way Jellyfin's API writes them."""
    return item_id.replace("-", "").lower()


def tag_of(user_id):
    return "f-" + plain(user_id)[:8]


def ours(tags):
    return {tag.lower() for tag in tags or [] if OURS.fullmatch(tag)}


def pages(seerr, path, query):
    skip = 0
    while True:
        page = seerr.call("GET", path, {**query, "take": PAGE, "skip": skip})
        yield from page["results"]
        skip += PAGE
        if skip >= page["pageInfo"]["results"]:
            return


def watchlist(seerr, user_id):
    page = 1
    while True:
        result = seerr.call("GET", f"/api/v1/user/{user_id}/watchlist", {"page": page})
        yield from result["results"]
        if page >= result["totalPages"]:
            return
        page += 1


def wanted(seerr):
    """(tag, entry) for every title each person requested or has on their watchlist."""
    for user in pages(seerr, "/api/v1/user", {}):
        if not user.get("jellyfinUserId"):
            continue
        tag = tag_of(user["jellyfinUserId"])
        requests = pages(seerr, "/api/v1/request", {"filter": "all", "requestedBy": user["id"]})
        for request in requests:
            if request.get("status") != DECLINED:
                yield tag, request
        for entry in watchlist(seerr, user["id"]):
            yield tag, entry


def provider_index(library):
    """(kind, provider, id) -> Jellyfin item id, from the ids Jellyfin keeps for each title."""
    index = {}
    for item in library:
        kind = "movie" if item.get("Type") == "Movie" else "tv"
        for provider, value in (item.get("ProviderIds") or {}).items():
            index[(kind, provider.lower(), str(value))] = plain(item["Id"])
    return index


def resolve(entry, index):
    """The Jellyfin items a Seerr request or watchlist entry stands for: Seerr's link, and the
    title's TMDb/TVDB ids found in Jellyfin, so an item counts before Seerr's scan links it."""
    media = entry.get("media") or {}
    kind = media.get("mediaType") or entry.get("mediaType")
    ids = {plain(media[key]) for key in ("jellyfinMediaId", "jellyfinMediaId4k") if media.get(key)}
    for provider in ("tmdb", "tvdb"):
        value = media.get(f"{provider}Id") or entry.get(f"{provider}Id")
        if value and (kind, provider, str(value)) in index:
            ids.add(index[(kind, provider, str(value))])
    return ids


def answer_calls():
    """Answers the calls queued on the socket systemd passes (fd 3), until none came for QUIET s.
    Started by the timer, nothing is queued and this returns at once."""
    if os.environ.get("LISTEN_FDS") != "1":
        return
    server = socket.socket(fileno=3)
    server.setblocking(False)
    try:
        connection, _ = server.accept()
    except BlockingIOError:
        return
    server.settimeout(QUIET)
    while True:
        with connection:
            connection.settimeout(5)
            try:
                read_request(connection)
                connection.sendall(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
        try:
            connection, _ = server.accept()
        except TimeoutError:
            return


def read_request(connection):
    """Reads the HTTP request to its end, so the caller gets an answer, not a reset."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(4096)
        if not chunk:
            return
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    length = re.search(rb"(?im)^content-length:\s*(\d+)", head)
    remaining = int(length.group(1)) - len(body) if length else 0
    while remaining > 0:
        chunk = connection.recv(min(remaining, 65536))
        if not chunk:
            return
        remaining -= len(chunk)


def items(jellyfin, admin, query):
    query = {
        "userId": admin,
        "fields": "Tags,ProviderIds",
        "enableImages": "false",
        "enableUserData": "false",
        **query,
    }
    return jellyfin.call("GET", "/Items", query)["Items"]


def set_tags(jellyfin, admin, item_id, tags):
    item = jellyfin.call("GET", f"/Items/{item_id}", {"userId": admin})
    body = {field: item[field] for field in EDITABLE if field in item}
    body["Tags"] = [tag for tag in item.get("Tags") or [] if not OURS.fullmatch(tag)] + sorted(tags)
    jellyfin.call("POST", f"/Items/{item_id}", body=body)


def describe(name, have, want):
    changes = [f"+{tag}" for tag in sorted(want - have)]
    changes += [f"-{tag}" for tag in sorted(have - want)]
    return f"{name}: {' '.join(changes)}"


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    args = [arg for arg in args if arg != "--dry-run"]
    if len(args) != 2:
        sys.exit("usage: friend-tags.py <seerr url> <jellyfin url> [--dry-run]")
    credentials = os.environ.get("CREDENTIALS_DIRECTORY")
    if not credentials:
        sys.exit(
            "friend-tags.py: no credentials; run it as friend-tags.service,"
            " or with systemd-run and LoadCredential=seerr: and jellyfin:"
        )
    answer_calls()
    key = {name: (Path(credentials) / name).read_text().strip() for name in ("seerr", "jellyfin")}
    seerr = Api(args[0], {"X-Api-Key": key["seerr"]})
    jellyfin = Api(args[1], {"Authorization": f'MediaBrowser Token="{key["jellyfin"]}"'})

    users = jellyfin.call("GET", "/Users")
    admin = next((user["Id"] for user in users if user["Policy"].get("IsAdministrator")), None)
    if admin is None:
        sys.exit("friend-tags.py: Jellyfin has no administrator to read the library as")

    library = items(jellyfin, admin, {"includeItemTypes": "Movie,Series", "recursive": "true"})
    index = provider_index(library)
    asked = {}
    for tag, entry in wanted(seerr):
        for item_id in resolve(entry, index):
            asked.setdefault(item_id, set()).add(tag)
    collections = items(jellyfin, admin, {"includeItemTypes": "BoxSet", "recursive": "true"})
    desired = {plain(item["Id"]): asked.get(plain(item["Id"]), set()) for item in library}
    for collection in collections:
        children = items(jellyfin, admin, {"parentId": collection["Id"]})
        tags = [asked.get(plain(child["Id"]), set()) for child in children]
        desired[plain(collection["Id"])] = set().union(*tags)

    changed = 0
    for item in library + collections:
        have, want = ours(item.get("Tags")), desired[plain(item["Id"])]
        if have == want:
            continue
        changed += 1
        print(describe(item.get("Name", item["Id"]), have, want), flush=True)
        if not dry_run:
            set_tags(jellyfin, admin, item["Id"], want)

    for user in users:
        allowed = user["Policy"].get("AllowedTags") or []
        tag = tag_of(user["Id"])
        if MARKER not in {t.lower() for t in allowed} or tag in {t.lower() for t in allowed}:
            continue
        changed += 1
        print(describe(f"user {user['Name']}", set(), {tag}), flush=True)
        if not dry_run:
            policy = jellyfin.call("GET", f"/Users/{user['Id']}")["Policy"]
            policy["AllowedTags"] = [*(policy.get("AllowedTags") or []), tag]
            jellyfin.call("POST", f"/Users/{user['Id']}/Policy", body=policy)

    print(f"changes: {changed}" + (" (dry run, none made)" if dry_run else ""))


if __name__ == "__main__":
    main()
