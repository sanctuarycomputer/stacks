ic = Tree.create!(name: "Individual Contributor")
Trait.create!(name: "Knowledge & Impact", tree: ic)
Trait.create!(name: "Problem Solving", tree: ic)
Trait.create!(name: "Communications", tree: ic)
Trait.create!(name: "Work Management", tree: ic)
Trait.create!(name: "Teamwork", tree: ic)

strategist = Tree.create!(name: "Strategist")
Trait.create!(name: "Strategy & Insight", tree: strategist)
Trait.create!(name: "Client Success", tree: strategist)
Trait.create!(name: "Facilitation", tree: strategist)
Trait.create!(name: "Design & Technical Sense", tree: strategist)
Trait.create!(name: "Delivery", tree: strategist)

designer = Tree.create!(name: "Designer")
Trait.create!(name: "Concept", tree: designer)
Trait.create!(name: "Creativity", tree: designer)
Trait.create!(name: "Craft", tree: designer)
Trait.create!(name: "Skills", tree: designer)
Trait.create!(name: "Collaboration", tree: designer)

dev = Tree.create!(name: "Engineer")
Trait.create!(name: "Quality & Testing", tree: dev)
Trait.create!(name: "Debugging & Observability", tree: dev)
Trait.create!(name: "Software Architecture & Security", tree: dev)
Trait.create!(name: "Deployment & Ops", tree: dev)
Trait.create!(name: "Documentation, Git Fluency & Code Reviews", tree: dev)

leadership = Tree.create!(name: "Studio Impact")
Trait.create!(name: "Collaboration", tree: leadership)
Trait.create!(name: "Ambiguity & Accountability", tree: leadership)
Trait.create!(name: "People Skills", tree: leadership)
Trait.create!(name: "Work Delivery", tree: leadership)
Trait.create!(name: "Strategic Thinking", tree: leadership)

Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
Enterprise.find_or_create_by!(name: "Garden3D LLC")
Enterprise.find_or_create_by!(name: "USB Club LLC")
# "Index" already exists in prod from earlier P&L work — no seed needed.

# The chunks.content_tsv generated column + its GIN index are added by the
# CreateChunks migration but can't be represented in db/schema.rb (Rails 6.1
# can't dump generated columns). On a migrate-based deploy they exist; this
# idempotent recreation makes a `db:setup`/`db:schema:load`-built database
# (dev bootstrap, review apps) work for keyword/hybrid search too.
if ActiveRecord::Base.connection.table_exists?(:chunks)
  ActiveRecord::Base.connection.execute(<<~SQL)
    ALTER TABLE chunks ADD COLUMN IF NOT EXISTS content_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;
    CREATE INDEX IF NOT EXISTS index_chunks_on_content_tsv ON chunks USING gin (content_tsv);
  SQL
end
