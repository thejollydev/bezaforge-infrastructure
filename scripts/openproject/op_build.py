#!/usr/bin/env python3
"""BezaForge OpenProject structuring batch (Platform/Ops model).

Assigns category + Phase-2 version to all 99 WPs, retypes bugs/epics,
sets light hierarchy, renames the two epic-labeled tasks, creates the
K8s epic. Idempotent-ish (safe to re-run).

Usage:
  op_build.py preflight   # only check categories + types exist; report gaps
  op_build.py apply       # do the work
"""
import base64, json, os, sys, urllib.parse, urllib.request, urllib.error

BASE = "https://pm.bezaforge.dev/api/v3"
TOKEN = open(os.path.expanduser("~/.op-token")).read().strip()
AUTH = "Basic " + base64.b64encode(f"apikey:{TOKEN}".encode()).decode()
PROJECT = "bezaforge"
V_PHASE2, V_PHASE3 = 6, 7
T_TASK, T_MILESTONE, T_FEATURE, T_EPIC, T_BUG = 1, 2, 4, 5, 7

def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
        headers={"Authorization": AUTH, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}

# --- 11 categories (exact names Joseph must create in the UI) ---
CATS = ["Backups & DR", "Networking & DNS", "Monitoring", "Storage & Files",
        "Config Management", "Provisioning", "Security & Secrets",
        "Documentation", "AI & Inference", "Platform & Tooling",
        "Services & Applications"]

# --- wp_id -> category ---
CAT = {
 41:"Backups & DR",42:"Backups & DR",43:"Networking & DNS",44:"Monitoring",
 45:"Platform & Tooling",46:"Backups & DR",47:"Provisioning",48:"AI & Inference",
 49:"Storage & Files",50:"Storage & Files",51:"Services & Applications",
 52:"Provisioning",53:"Services & Applications",54:"Platform & Tooling",
 55:"Documentation",56:"Provisioning",57:"Services & Applications",
 58:"Services & Applications",59:"Backups & DR",60:"Documentation",
 61:"Documentation",62:"Provisioning",63:"Documentation",64:"Monitoring",
 65:"Platform & Tooling",66:"Networking & DNS",67:"Services & Applications",
 68:"Services & Applications",69:"Services & Applications",70:"Config Management",
 71:"Backups & DR",72:"AI & Inference",73:"Backups & DR",74:"Backups & DR",
 75:"Backups & DR",76:"Monitoring",77:"Monitoring",78:"Monitoring",
 79:"Networking & DNS",80:"Networking & DNS",81:"Platform & Tooling",
 82:"AI & Inference",83:"Backups & DR",84:"AI & Inference",85:"Platform & Tooling",
 86:"Storage & Files",87:"AI & Inference",88:"Security & Secrets",
 89:"Config Management",90:"Config Management",91:"Backups & DR",
 92:"Storage & Files",93:"Storage & Files",94:"Platform & Tooling",
 95:"Platform & Tooling",96:"Platform & Tooling",97:"Provisioning",
 98:"Backups & DR",99:"Config Management",100:"Platform & Tooling",
 101:"Networking & DNS",102:"AI & Inference",103:"Provisioning",
 104:"AI & Inference",105:"Services & Applications",106:"Config Management",
 107:"Provisioning",108:"Provisioning",109:"Documentation",110:"Backups & DR",
 111:"Config Management",112:"AI & Inference",113:"Networking & DNS",
 114:"Security & Secrets",115:"Security & Secrets",116:"Documentation",
 117:"Documentation",118:"Documentation",119:"Services & Applications",
 120:"Documentation",121:"Security & Secrets",122:"Networking & DNS",
 123:"Provisioning",124:"Security & Secrets",125:"Platform & Tooling",
 126:"Security & Secrets",127:"AI & Inference",128:"AI & Inference",
 129:"AI & Inference",130:"AI & Inference",131:"AI & Inference",
 132:"Networking & DNS",133:"Backups & DR",134:"Services & Applications",
 451:"Platform & Tooling",452:"Platform & Tooling",453:"Platform & Tooling",
 454:"Platform & Tooling",455:"Platform & Tooling",
}
BUG   = {43,56,78,83,86,92,95,98,99,113}
EPIC  = {117,118,451}
PARENT= {55:117, 63:117, 116:118}
RENAME= {117:"Architecture diagram suite (14 diagrams)",
         118:"Service + host cheatsheets (~26 docs)"}

def categories():
    _, d = req("GET", f"/projects/{PROJECT}/categories/")
    return {e["name"]: e["id"] for e in d.get("_embedded", {}).get("elements", [])}

def enabled_types():
    _, d = req("GET", f"/projects/{PROJECT}/types/")
    return {e["name"] for e in d.get("_embedded", {}).get("elements", [])}

def preflight():
    have = categories()
    missing_cat = [c for c in CATS if c not in have]
    types = enabled_types()
    missing_typ = [t for t in ("Epic", "Feature", "Bug") if t not in types]
    print("Categories present:", len(have), "/ 11 needed")
    if missing_cat: print("  MISSING categories:", missing_cat)
    print("Types enabled:", sorted(types))
    if missing_typ: print("  MISSING types:", missing_typ)
    ok = not missing_cat and not missing_typ
    print("\nPREFLIGHT:", "READY ✅" if ok else "BLOCKED — create the above in the UI first")
    return ok

def apply():
    if not preflight():
        sys.exit("\nAborting apply — preconditions not met.")
    cid = categories()
    # bulk fetch lockVersions + current subjects
    q = urllib.parse.quote(json.dumps([{"status":{"operator":"*","values":[]}}]))
    _, d = req("GET", f"/projects/{PROJECT}/work_packages/?pageSize=200&filters={q}")
    wps = {e["id"]: e for e in d["_embedded"]["elements"]}

    # create K8s epic if absent
    have_k8s = any(e.get("subject") == "Kubernetes migration" for e in wps.values())
    if not have_k8s:
        s, r = req("POST", "/work_packages", {
            "subject": "Kubernetes migration",
            "description": {"raw": "Phase 3 initiative: migrate select services to K3s. Forward-looking epic."},
            "_links": {"type": {"href": f"/api/v3/types/{T_EPIC}"},
                       "project": {"href": f"/api/v3/projects/{PROJECT}"},
                       "version": {"href": f"/api/v3/versions/{V_PHASE3}"}}})
        print(f"K8s epic create: HTTP {s} #{r.get('id','ERR')}")

    ok = err = 0
    for wid, cat in CAT.items():
        wp = wps.get(wid)
        if not wp:
            print(f"  #{wid} SKIP (not found)"); continue
        links = {"category": {"href": f"/api/v3/categories/{cid[cat]}"},
                 "version":  {"href": f"/api/v3/versions/{V_PHASE2}"}}
        if wid in BUG:  links["type"]   = {"href": f"/api/v3/types/{T_BUG}"}
        if wid in EPIC: links["type"]   = {"href": f"/api/v3/types/{T_EPIC}"}
        if wid in PARENT: links["parent"] = {"href": f"/api/v3/work_packages/{PARENT[wid]}"}
        body = {"lockVersion": wp["lockVersion"], "_links": links}
        if wid in RENAME: body["subject"] = RENAME[wid]
        s, r = req("PATCH", f"/work_packages/{wid}", body)
        if s == 200: ok += 1
        else: err += 1; print(f"  #{wid} PATCH HTTP {s}: {r.get('error','')[:120]}")
    print(f"\nDONE: {ok} updated, {err} errors")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "preflight"
    {"preflight": preflight, "apply": apply}.get(cmd, preflight)()
