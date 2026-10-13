module Mcp
  # Which trackers and which Notion projects a page of documents belongs to,
  # for list_documents and get_document. Ids only: a matcher's reason and
  # confidence stay in Stacks.
  #
  # A document reaches a tracker two ways: its Meeting was matched to it (a
  # transcript and its notes share the match), or it is a ships@ email linked
  # to it as a weekly ship. notion_project_ids is every Notion project those
  # trackers name, so a reader can copy them onto what it writes about the
  # document without a lookup of its own.
  #
  # Behind the wall: callers pass documents they read through
  # Document.corpus_eligible, and the ship links are read through
  # WeeklyShip.corpus_eligible as well, so a walled-off email gives nothing
  # even if it is handed in. Nothing of a document's content is read here.
  #
  # At most three queries however many documents are passed.
  module DocumentProjects

    # { document id => { project_tracker_ids: [...], notion_project_ids: [...] } }
    # project_tracker_ids keeps its meaning (the meeting's trackers, sorted;
    # empty when the document is not a meeting). notion_project_ids is the
    # sorted, de-duplicated union over the meeting's trackers and the weekly
    # ship's, empty when there is none.
    def self.for(documents)
      docs = Array(documents)
      meeting_docs = docs.select { |d| d.source_record_type == 'Meeting' && d.source_record_id }
      by_meeting = Meeting.project_tracker_ids_by_meeting(meeting_docs.map(&:source_record_id))
      mail_ids = docs.select(&:google_groups?).map(&:id)
      by_ship = mail_ids.empty? ? {} : WeeklyShip.corpus_eligible.where(document_id: mail_ids).pluck(:document_id, :project_tracker_id)
                                                 .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      tracker_ids = (by_meeting.values.flatten + by_ship.values.flatten).uniq
      projects = tracker_ids.empty? ? {} : ProjectTracker.where(id: tracker_ids).pluck(:id, :notion_project_ids).to_h

      docs.to_h do |d|
        matched = d.source_record_type == 'Meeting' ? by_meeting.fetch(d.source_record_id, []) : []
        linked = matched + by_ship.fetch(d.id, [])
        notion = linked.flat_map { |id| Array(projects[id]) }.select(&:present?).uniq.sort
        [d.id, { project_tracker_ids: matched, notion_project_ids: notion }]
      end
    end
  end
end
