# op_provision_rails.rb — standard taxonomies (by project CLASS) + type enablement,
# plus the BezaForge realignment. Categories/types are the only parts of the
# standard OpenProject's REST API can't do, so they run in the Rails console.
#
# Run on forge-ops:
#   docker cp op_provision_rails.rb openproject:/tmp/ && \
#     docker exec openproject bundle exec rails runner /tmp/op_provision_rails.rb
# Then, from the workstation:  for each project -> op_provision.py <identifier>
#
# Idempotent and safe to re-run: categories go through find_or_create_by and
# types through a set union, so a second run reports the same state and writes
# nothing new. To see what a run would change without touching anything:
#
#   docker exec -e DRY_RUN=1 openproject bundle exec rails runner /tmp/op_provision_rails.rb

DRY = ENV["DRY_RUN"].to_s == "1"

# ---------- the three standard taxonomies (define once, reuse by class) ----------
DEV = ["Frontend","Backend","Data & Storage","API & Integrations",
       "Infrastructure & Deploy","Design & Content","Testing & QA","Security","Docs"]
INFRA = ["Compute & Provisioning","Networking & DNS","Storage & Files","Backups & DR",
         "Monitoring & Observability","Config Management","Security & Secrets",
         "Services & Applications","CI/CD & Automation","Documentation"]
BUSINESS = ["Legal & Compliance","Finance","Strategy","Brand & Marketing",
            "Operations","Partnerships"]

CONFIG = {
  # --- development (one shared taxonomy) ---
  "bezacore-marketing"=>DEV, "portfolio"=>DEV, "petoskey-coc"=>DEV, "throughlin"=>DEV,
  "intelligrace"=>DEV, "brizza"=>DEV, "bezacore-cogs"=>DEV,
  "never4ga"=>DEV, "petoskey-designs"=>DEV, "opskit-library"=>DEV,
  "prompt-library"=>DEV, "thejollydev"=>DEV,
  # --- infrastructure (one shared taxonomy) ---
  "bezaforge-infrastructure"=>INFRA, "dev-environment"=>INFRA,
  "ansible-arch"=>INFRA, "ai-workspace"=>INFRA,
  # --- business/ops ---
  "bezacore-ops"=>BUSINESS, "bezacore-labs"=>BUSINESS,
  # --- personal / life (bespoke) ---
  "recovery"    =>["Step Work","Sponsorship","Meetings","Study & Reading","Service"],
  "education"   =>["Coursework","Certifications","Assignments","Resources"],
  "personal"    =>["Home","Health","Finance","Family & Relationships","Admin","Hobbies"],
  "vault-knowledge"=>["Structure","Bases & Templates","Content & MOCs","Sync & Automation","Docs"],
  "bible-study" =>["Original Meaning","Bridging Contexts","Contemporary Application",
                   "Teaching & Ministry Prep","Questions & Research","Resources"],
  "video-projects"=>["Planning & Scripting","Filming","Editing","Publishing","Assets & Gear"],
  "wedding"     =>["Venue & Vendors","Guests & Invitations","Attire","Budget",
                   "Ceremony","Reception","Travel & Lodging"],
}

# Deliberately absent, not forgotten. These three are pure hierarchy nodes that
# hold no work of their own, so a taxonomy and an Epic type would be clutter on
# a page nobody files against. Recorded so a later run doesn't "fix" it.
CONTAINERS = ["infrastructure","personal-life","clients"]

# Retired for good. Not archived-and-might-come-back — done, and deliberately
# never provisioned again. Listed rather than merely absent so the "NOT IN
# CONFIG" report below stays quiet about them instead of nagging every run,
# which is its own kind of resurfacing.
RETIRED = ["master-mind-cutover"]

type_ids = Type.where(name:["Epic","Feature","Bug"]).pluck(:id)
abort "expected Epic/Feature/Bug, found #{type_ids.size} of 3" unless type_ids.size == 3

# ---------- BezaForge realignment: a completed one-time migration ----------
# Ran 2026-07-12 against identifier "bezaforge", since renamed to
# "bezaforge-infrastructure" — the stale lookup returned nil and every later
# reference to it raised. Guarded now, and self-skipping: the legacy categories
# it moved work off no longer exist, so on a current instance this is inert.
# It stays as the record of where those items went.
bf = Project.find_by(identifier:"bezaforge-infrastructure")
abort "bezaforge-infrastructure not found — refusing to run the realignment" if bf.nil?
if DRY
  puts "DRY  realignment skipped entirely (it writes; nothing to preview)"
else
{"Monitoring"=>"Monitoring & Observability","Provisioning"=>"Compute & Provisioning"}.each do |old,new|
  c = Category.find_by(project:bf,name:old); c.update!(name:new) if c
end
INFRA.each { |n| Category.find_or_create_by(project:bf,name:n) }
byname = ->(n){ Category.find_by(project:bf,name:n) }
svc = byname.("Services & Applications")

# AI & Inference -> Services & Applications (all of them)
if (ai = byname.("AI & Inference")) && svc
  WorkPackage.where(project:bf, category_id:ai.id).update_all(category_id:svc.id)
end
# Platform & Tooling -> split by item, then sweep any straggler to Services & Applications
if (pt = byname.("Platform & Tooling")) && svc
  { "CI/CD & Automation"      =>[45,54,65,125],
    "Services & Applications" =>[81,96,451,452,453,454,455],
    "Storage & Files"         =>[85,95],
    "Security & Secrets"      =>[94],
    "Config Management"       =>[100],
    "Compute & Provisioning"  =>[458] }.each do |name,ids|
    target = byname.(name)
    next unless target
    WorkPackage.where(id:ids, category_id:pt.id).update_all(category_id: target.id)
  end
  WorkPackage.where(category_id:pt.id).update_all(category_id:svc.id)  # sweep stragglers
end
# drop now-empty legacy categories
[byname.("AI & Inference"), byname.("Platform & Tooling")].compact.each do |c|
  n = WorkPackage.where(category_id:c.id).count
  n.zero? ? c.destroy : (puts "KEEP #{c.name} (#{n} items still attached)")
end
end

# ---------- all projects: ensure categories + enable standard types ----------
missing = []
CONFIG.each do |ident,cats|
  p = Project.find_by(identifier:ident)
  unless p
    missing << ident
    puts "SKIP #{ident} (not found)"
    next
  end

  if DRY
    add_cats  = cats - p.categories.pluck(:name)
    add_types = type_ids - p.type_ids
    puts "DRY  #{ident}: +#{add_cats.size} categories #{add_cats.inspect} +#{add_types.size} types"
    next
  end

  cats.each { |n| Category.find_or_create_by(project:p,name:n) }
  p.type_ids = (p.type_ids + type_ids).uniq
  p.save!
  puts "#{ident}: categories=#{p.categories.count} types=[#{p.types.pluck(:name).join(', ')}]"
end

# ---------- report anything the standard does not cover ----------
# A new project that is in neither list announces itself here, rather than being
# silently missed the way never4ga was.
puts "---"
unknown = Project.pluck(:identifier) - CONFIG.keys - CONTAINERS - RETIRED
puts "containers (no taxonomy by design): #{CONTAINERS.join(', ')}"
puts "retired (never provisioned again): #{RETIRED.join(', ')}"
puts "NOT IN CONFIG — decide a class for these: #{unknown.join(', ')}" if unknown.any?
puts "IN CONFIG but missing on the instance: #{missing.join(', ')}" if missing.any?
puts "bezaforge-infrastructure now: #{bf.categories.order(:name).pluck(:name).join(', ')}"
