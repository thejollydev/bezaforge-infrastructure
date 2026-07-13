# op_provision_rails.rb — standard taxonomies (by project CLASS) + type enablement,
# plus the BezaForge realignment. Categories/types are the only parts of the
# standard OpenProject's REST API can't do, so they run in the Rails console.
#
# Run ONCE on forge-ops:
#   docker exec openproject bundle exec rails runner "$(cat op_provision_rails.rb)"
# Then, from the workstation:  for each project -> op_provision.py <identifier>

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
  "bezacore-marketing"=>DEV, "portfolio"=>DEV, "pcoc"=>DEV, "throughlin"=>DEV,
  "intelligrace"=>DEV, "brizza"=>DEV, "bezacore-cogs"=>DEV,
  # --- infrastructure (one shared taxonomy) ---
  "bezaforge"=>INFRA, "dev-environment"=>INFRA,
  # --- business/ops ---
  "bezacore-ops"=>BUSINESS,
  # --- personal / life (bespoke) ---
  "recovery"    =>["Step Work","Sponsorship","Meetings","Study & Reading","Service"],
  "education"   =>["Coursework","Certifications","Assignments","Resources"],
  "personal"    =>["Home","Health","Finance","Family & Relationships","Admin","Hobbies"],
  "vault-knowledge"=>["Structure","Bases & Templates","Content & MOCs","Sync & Automation","Docs"],
  "bible-study" =>["Original Meaning","Bridging Contexts","Contemporary Application",
                   "Teaching & Ministry Prep","Questions & Research","Resources"],
}

type_ids = Type.where(name:["Epic","Feature","Bug"]).pluck(:id)

# ---------- BezaForge realignment: rename (preserves item links), retag, cleanup ----------
bf = Project.find_by(identifier:"bezaforge")
{"Monitoring"=>"Monitoring & Observability","Provisioning"=>"Compute & Provisioning"}.each do |old,new|
  c = Category.find_by(project:bf,name:old); c.update!(name:new) if c
end
INFRA.each { |n| Category.find_or_create_by(project:bf,name:n) }
byname = ->(n){ Category.find_by(project:bf,name:n) }
svc = byname.("Services & Applications")

# AI & Inference -> Services & Applications (all of them)
if (ai = byname.("AI & Inference"))
  WorkPackage.where(project:bf, category_id:ai.id).update_all(category_id:svc.id)
end
# Platform & Tooling -> split by item, then sweep any straggler to Services & Applications
if (pt = byname.("Platform & Tooling"))
  { "CI/CD & Automation"      =>[45,54,65,125],
    "Services & Applications" =>[81,96,451,452,453,454,455],
    "Storage & Files"         =>[85,95],
    "Security & Secrets"      =>[94],
    "Config Management"       =>[100],
    "Compute & Provisioning"  =>[458] }.each do |name,ids|
    WorkPackage.where(id:ids, category_id:pt.id).update_all(category_id: byname.(name).id)
  end
  WorkPackage.where(category_id:pt.id).update_all(category_id:svc.id)  # sweep stragglers
end
# drop now-empty legacy categories
[byname.("AI & Inference"), byname.("Platform & Tooling")].compact.each do |c|
  n = WorkPackage.where(category_id:c.id).count
  n.zero? ? c.destroy : (puts "KEEP #{c.name} (#{n} items still attached)")
end

# ---------- all projects: ensure categories + enable standard types ----------
CONFIG.each do |ident,cats|
  p = Project.find_by(identifier:ident)
  unless p then puts "SKIP #{ident} (not found)"; next end
  cats.each { |n| Category.find_or_create_by(project:p,name:n) }
  p.type_ids = (p.type_ids + type_ids).uniq
  p.save!
  puts "#{ident}: categories=#{p.categories.count} types=[#{p.types.pluck(:name).join(', ')}]"
end
puts "---"
puts "bezaforge now: #{bf.categories.order(:name).pluck(:name).join(', ')}"
