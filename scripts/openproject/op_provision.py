#!/usr/bin/env python3
"""op-provision — apply the standard OpenProject layout to any project.

The "BezaForge standard": a consistent dashboard (Description · Status ·
open-work table grouped by category · status chart), an "Active Work" Kanban
board (New -> In progress), and four saved views (by Category, by Status,
Bugs, Epics). Idempotent — safe to re-run.

PREREQUISITE (run once per project on forge-ops, categories+types are
UI/Rails-only in OpenProject's REST API):
  docker exec openproject bundle exec rails runner '<see op_provision_rails.rb>'

Usage:  op_provision.py <identifier>
Config: projects.local.json beside this script (or $OP_PROJECTS_FILE), key
        "projects": description/status/milestones per project. It is private
        and untracked; projects.example.json shows the shape. Everything else
        is identical across projects.
"""
import base64, json, os, sys, urllib.parse, urllib.request, urllib.error

BASE = "https://pm.bezaforge.dev/api/v3"
TOKEN = open(os.path.expanduser("~/.op-token")).read().strip()
AUTH = "Basic " + base64.b64encode(f"apikey:{TOKEN}".encode()).decode()
S_NEW, S_INPROGRESS = 1, 7        # global status ids
T_BUG, T_EPIC = 7, 5              # global type ids

# ---- per-project config (the only things that vary) --------------------------
# Kept out of this public repository: it names personal projects. The file is
# untracked; projects.example.json shows the shape.
PROJECTS_FILE = os.environ.get(
    "OP_PROJECTS_FILE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "projects.local.json"))
if os.path.exists(PROJECTS_FILE):
    with open(PROJECTS_FILE) as f:
        PROJECTS = json.load(f).get("projects", {})
else:
    PROJECTS = {}

def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
        headers={"Authorization": AUTH, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}

# ---- query (saved view) builders --------------------------------------------
def col(c): return {"href": f"/api/v3/queries/columns/{c}"}
def f_open():
    return {"_links": {"filter": {"href": "/api/v3/queries/filters/status"},
            "operator": {"href": "/api/v3/queries/operators/o"}}, "values": []}
def f_type(tid):
    return {"_links": {"filter": {"href": "/api/v3/queries/filters/type"},
            "operator": {"href": "/api/v3/queries/operators/="},
            "values": [{"href": f"/api/v3/types/{tid}"}]}}

def mkquery(proj, name, columns, group_by=None, filters=None,
            sort="priority-desc", hierarchy=False):
    links = {"project": {"href": f"/api/v3/projects/{proj}"},
             "columns": [col(c) for c in columns],
             "sortBy": [{"href": f"/api/v3/queries/sort_bys/{sort}"}]}
    if group_by: links["groupBy"] = {"href": f"/api/v3/queries/group_bys/{group_by}"}
    body = {"name": name, "public": True, "showHierarchies": hierarchy, "_links": links}
    if filters is not None: body["filters"] = filters
    s, d = req("POST", "/queries", body)
    return d.get("id") if s == 201 else None

STANDARD_QUERIES = [
    ("📁 Open — by Category", ["id","type","subject","status","priority"], "category", [f_open()], "priority-desc", False),
    ("🚦 Open — by Status",   ["id","type","subject","category","priority"], "status",   [f_open()], "priority-desc", False),
    ("🐞 Bugs — incident log",["id","subject","status","category","updatedAt"], None,     [f_type(T_BUG)], "id-desc", False),
    ("🎯 Epics & Initiatives",["id","subject","status","version","category"], None,       [f_type(T_EPIC)], "id-asc", True),
]

def ensure_queries(proj):
    """delete-by-name then recreate (idempotent); return the by-category id."""
    # A query's project link carries the NUMERIC id (/api/v3/projects/32), never
    # the identifier, so matching on the identifier silently never matched and
    # the delete never fired — every re-run added four more saved views. Resolve
    # the id first and compare against that.
    _, pdata = req("GET", f"/projects/{proj}")
    proj_id = pdata.get("id")
    _, ex = req("GET", "/queries?pageSize=200")
    names = {q[0] for q in STANDARD_QUERIES}
    for q in ex.get("_embedded", {}).get("elements", []):
        href = ((q["_links"].get("project") or {}).get("href") or "")
        if q.get("name") in names and href.rsplit("/", 1)[-1] == str(proj_id):
            req("DELETE", f"/queries/{q['id']}")
    ids = {}
    for name, cols, gb, filt, sort, hier in STANDARD_QUERIES:
        qid = mkquery(proj, name, cols, gb, filt, sort, hier)
        ids[name] = qid
        print(f"    query {'OK ' if qid else 'ERR'} {name} (id {qid})")
    return ids["📁 Open — by Category"]

def ensure_milestones(proj, milestones):
    _, ex = req("GET", f"/projects/{proj}/versions/")
    have = {v["name"] for v in ex.get("_embedded", {}).get("elements", [])}
    for name, desc in milestones:
        if name in have:
            print(f"    milestone skip (exists) {name}"); continue
        s, _ = req("POST", "/versions", {"name": name, "description": {"raw": desc},
              "_links": {"definingProject": {"href": f"/api/v3/projects/{proj}"}}})
        print(f"    milestone {'OK ' if s==201 else 'ERR'} {name}")

def set_project(proj, cfg):
    body = {}
    if cfg.get("description"): body["description"] = {"raw": cfg["description"]}
    if cfg.get("status"):
        body["_links"] = {"status": {"href": f"/api/v3/project_statuses/{cfg['status']}"}}
        body["statusExplanation"] = {"raw": cfg.get("status_note", "")}
    if not body: return
    s, _ = req("PATCH", f"/projects/{proj}", body)
    print(f"    project desc/status {'OK' if s==200 else 'ERR '+str(s)}")

def configure_dashboard(proj, cat_query_id):
    """find the project's overview grid and set the standard widget layout."""
    _, g = req("GET", "/grids?pageSize=100")
    ov = next((x for x in g["_embedded"]["elements"]
               if (x["_links"].get("scope") or {}).get("href") == f"/projects/{proj}"), None)
    widgets = [
        {"identifier":"project_description","startRow":1,"endRow":2,"startColumn":1,"endColumn":2,"options":{"name":"Description"}},
        {"identifier":"project_status","startRow":1,"endRow":2,"startColumn":2,"endColumn":3,"options":{"name":"Status"}},
        {"identifier":"work_packages_table","startRow":2,"endRow":3,"startColumn":1,"endColumn":3,"options":{"name":"Open work — by category","queryId":str(cat_query_id)}},
        {"identifier":"work_packages_overview","startRow":3,"endRow":4,"startColumn":1,"endColumn":3,"options":{"name":"Work packages overview"}},
    ]
    payload = {"rowCount":3,"columnCount":2,"widgets":widgets}
    if ov:
        s, _ = req("PATCH", f"/grids/{ov['id']}", payload)
        print(f"    dashboard grid PATCH {'OK' if s==200 else 'ERR '+str(s)}")
    else:
        payload["_links"] = {"scope": {"href": f"/projects/{proj}"}}
        s, _ = req("POST", "/grids", payload)
        print(f"    dashboard grid CREATE {'OK' if s==201 else 'ERR '+str(s)}")

def ensure_board(proj):
    _, g = req("GET", "/grids?pageSize=100")
    exists = any((x["_links"].get("scope") or {}).get("href")==f"/projects/{proj}/boards"
                 and x.get("name")=="Active Work" for x in g["_embedded"]["elements"])
    if exists:
        print("    board skip (Active Work exists)"); return
    body = {"name":"Active Work","rowCount":1,"columnCount":2,
        "options":{"type":"action","attribute":"status"},
        "widgets":[
          {"identifier":"work_package_query","startRow":1,"endRow":2,"startColumn":1,"endColumn":2,
           "options":{"filters":[{"status_id":{"operator":"=","values":[str(S_NEW)]}}]}},
          {"identifier":"work_package_query","startRow":1,"endRow":2,"startColumn":2,"endColumn":3,
           "options":{"filters":[{"status_id":{"operator":"=","values":[str(S_INPROGRESS)]}}]}},
        ],
        "_links":{"scope":{"href":f"/projects/{proj}/boards"}}}
    s, _ = req("POST", "/grids", body)
    print(f"    board CREATE {'OK' if s==201 else 'ERR '+str(s)}")

def provision(proj):
    cfg = PROJECTS.get(proj, {})
    print(f"== provisioning {proj} ==")

    # An archived project 403s on queries, grids and work packages, so every
    # step below would fail one at a time and report six errors for one cause.
    # Say the cause once instead. Rails-side categories/types still apply, so an
    # archived project is fully provisioned the moment it is unarchived.
    status, proj_data = req("GET", f"/projects/{proj}")
    if status == 200 and proj_data.get("active") is False:
        print("    SKIP — project is archived; unarchive it first")
        print("== done ==")
        return

    set_project(proj, cfg)
    ensure_milestones(proj, cfg.get("milestones", []))
    cat_qid = ensure_queries(proj)
    configure_dashboard(proj, cat_qid)
    ensure_board(proj)
    print("== done ==")

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit("usage: op_provision.py <identifier>")
    if not PROJECTS:
        print(f"note: no project config at {PROJECTS_FILE}; description, status and milestones are left as they are")
    provision(sys.argv[1])
