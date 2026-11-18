"""2026-11-18 — TestFlight status via the App Store Connect API (key from the repo secrets, never printed).

Prints the app, its newest builds (version, build number, processing state, export compliance), and makes sure
an internal TestFlight group «Intern» exists with the Account Holder in it. Emails are only used to talk back to
Apple's own API and are never printed (only the role and whether it worked).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

BUNDLE_ID = "com.linocappuccino.subshot.Subshot"
GROUP_NAME = "Intern"
API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        os.environ["ASC_KEY_P8"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read())
            msg = "; ".join(f"{x.get('code')}: {x.get('detail')}" for x in detail.get("errors", []))
        except Exception:  # noqa: BLE001
            msg = str(e)
        return e.code, {"error": msg}


def main() -> int:
    st, apps = call("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    if st != 200 or not apps.get("data"):
        print(f"app not found ({st}) {apps.get('error', '')}")
        return 1
    app = apps["data"][0]
    app_id = app["id"]
    print(f"app: {app['attributes'].get('name')} ({app['attributes'].get('bundleId')})")

    st, builds = call("GET", f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5&include=preReleaseVersion")
    versions = {x["id"]: x["attributes"].get("version") for x in builds.get("included", []) if x["type"] == "preReleaseVersions"}
    for b in builds.get("data", []):
        a = b["attributes"]
        pv = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        print(f"build {versions.get(pv, '?')} ({a.get('version')}): processingState={a.get('processingState')} "
              f"usesNonExemptEncryption={a.get('usesNonExemptEncryption')} expired={a.get('expired')} uploaded={a.get('uploadedDate')}")
    if not builds.get("data"):
        print(f"no builds yet ({st}) {builds.get('error', '')}")

    # internal group «Intern»
    st, groups = call("GET", f"/betaGroups?filter[app]={app_id}&limit=50")
    group = next((g for g in groups.get("data", []) if g["attributes"].get("isInternalGroup")), None)
    if group is None:
        st, made = call("POST", "/betaGroups", {"data": {"type": "betaGroups", "attributes": {
            "name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        if st not in (200, 201):
            print(f"internal group not created ({st}) {made.get('error', '')}")
            return 0
        group = made["data"]
        print(f"internal group created: {GROUP_NAME}")
    else:
        print(f"internal group exists: {group['attributes'].get('name')} (all builds: {group['attributes'].get('hasAccessToAllBuilds')})")
    gid = group["id"]

    # Account Holder → tester in that group
    st, users = call("GET", "/users?limit=50")
    holder = next((u for u in users.get("data", []) if "ACCOUNT_HOLDER" in (u["attributes"].get("roles") or [])), None)
    if holder is None:
        print(f"account holder not found among users ({st}) {users.get('error', '')}")
        return 0
    email = holder["attributes"].get("username")
    st, testers = call("GET", f"/betaGroups/{gid}/betaTesters?limit=200")
    if any((t["attributes"].get("email") or "").lower() == (email or "").lower() for t in testers.get("data", [])):
        print("account holder is already a tester in the internal group")
        return 0
    st, added = call("POST", "/betaTesters", {"data": {"type": "betaTesters", "attributes": {
        "email": email, "firstName": holder["attributes"].get("firstName") or "", "lastName": holder["attributes"].get("lastName") or ""},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}})
    print("account holder added as internal tester" if st in (200, 201) else f"adding the account holder failed ({st}) {added.get('error', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
