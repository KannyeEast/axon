"""Tags what each person asked for in Seerr, so Jellyfin can show a friend just that.

friend-tags.py <seerr url> <jellyfin url> [--dry-run]

The API keys come from the unit's credentials, seerr and jellyfin. A person's tag is
f-<first 8 hex of their Jellyfin user id>; it goes on every movie and series they asked for and on
the collections those are in. Tags of that shape belong to this script, every other tag stays. A
Jellyfin user whose "Allow items with tags" holds `friend` gets their own tag added there. Each run
sets everything anew; --dry-run prints the changes and makes none.
"""
import json
import os
import re
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
    """Jellyfin item id -> the tags of the people who requested it or have it on their watchlist."""
    wanted = {}
    for user in pages(seerr, "/api/v1/user", {}):
        if not user.get("jellyfinUserId"):
            continue
        tag = tag_of(user["jellyfinUserId"])
        requests = pages(seerr, "/api/v1/request", {"filter": "all", "requestedBy": user["id"]})
        entries = [r for r in requests if r.get("status") != DECLINED]
        entries += watchlist(seerr, user["id"])
        for entry in entries:
            media = entry.get("media") or {}
            # without a Jellyfin id it isn't in the library yet; for a show the id is the series
            for key in ("jellyfinMediaId", "jellyfinMediaId4k"):
                if media.get(key):
                    wanted.setdefault(plain(media[key]), set()).add(tag)
    return wanted


def items(jellyfin, admin, query):
    query = {
        "userId": admin,
        "fields": "Tags",
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
    key = {name: (Path(credentials) / name).read_text().strip() for name in ("seerr", "jellyfin")}
    seerr = Api(args[0], {"X-Api-Key": key["seerr"]})
    jellyfin = Api(args[1], {"Authorization": f'MediaBrowser Token="{key["jellyfin"]}"'})

    users = jellyfin.call("GET", "/Users")
    admin = next((user["Id"] for user in users if user["Policy"].get("IsAdministrator")), None)
    if admin is None:
        sys.exit("friend-tags.py: Jellyfin has no administrator to read the library as")

    asked = wanted(seerr)
    library = items(jellyfin, admin, {"includeItemTypes": "Movie,Series", "recursive": "true"})
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
