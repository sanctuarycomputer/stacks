class ProjectTrackerLink < ApplicationRecord
  include BustsTaskCache
  # BustsTaskCache only fires on destroy today: its second after_commit
  # declaration replaces its first (same method name). A link that is added or
  # edited changes tasks too, so that half is declared here under its own name.
  after_commit :bust_task_cache_on_save, on: [:create, :update]

  belongs_to :project_tracker
  validates :name, presence: :true
  # Anchored: the URL must BE an http(s) URL with a host, not merely contain
  # one (URI::regexp matched "javascript:alert(1)//https://x"). These render as
  # clickable pills for admins and are writable over MCP, so no other schemes
  # and no embedded credentials.
  before_validation { self.url = url.strip if url.is_a?(String) }
  validate :url_is_plain_http
  enum link_type: {
    other: 0,
    proposal: 1,
    project_wiki: 2,
    design_file: 3,
    staging_link: 4,
    production_link: 5,
    qa_document: 6,
    operator_manual: 7,
    sow: 8,
    msa: 9,
    # Where the project's conversation lives, so Stacksbot can find the channel
    # and the homepage by id instead of by name-matching. Settable over MCP via
    # update_project_tracker (twist_channel_url / notion_homepage_url).
    twist_channel: 10,
    notion_homepage: 11,
  }

  # The one shape a Twist channel link is stored in. People paste what the
  # browser shows (a thread, a comment, no trailing slash), so the link is cut
  # back to its channel before it is checked.
  TWIST_CHANNEL_PATH = %r{\A/a/(\d+)/ch/(\d+)(?:/.*)?\z}

  def self.twist_workspace_id
    Stacks::Utils.config[:twist][:workspace_id].to_s
  end

  def self.twist_channel_url(channel_id)
    "https://twist.com/a/#{twist_workspace_id}/ch/#{channel_id}/"
  end

  def self.twist_channel_shape
    "must be a Twist channel in our workspace, like #{twist_channel_url(794756)}"
  end

  # Declared below the strip above, so a padded URL is stripped first.
  before_validation :tidy_twist_channel_url, if: :twist_channel?
  validate :url_is_our_twist_channel, if: :twist_channel?
  after_commit :forget_twist_channel_access, if: -> { twist_channel? || saved_change_to_link_type? }

  # The channel id, or nil when this is not a well-formed channel link.
  def twist_channel_id
    return nil unless twist_channel?
    m = url.to_s.match(%r{\Ahttps://twist\.com/a/#{Regexp.escape(self.class.twist_workspace_id)}/ch/([1-9]\d*)/\z})
    m && m[1].to_i
  end

  private

  def bust_task_cache_on_save
    bust_task_cache
  end

  def tidy_twist_channel_url
    parsed = URI.parse(url.to_s) rescue nil
    return unless parsed.is_a?(URI::HTTPS) && parsed.host.to_s.downcase == "twist.com" && parsed.userinfo.nil?
    m = parsed.path.to_s.match(TWIST_CHANNEL_PATH)
    # to_i: "ch/00012/" is channel 12, and channel 0 does not exist.
    return unless m && m[1] == self.class.twist_workspace_id && m[2].to_i.positive?
    self.url = self.class.twist_channel_url(m[2].to_i)
  end

  def url_is_our_twist_channel
    errors.add(:url, self.class.twist_channel_shape) if twist_channel_id.nil?
  end

  # The stored answer was about the old link. (update_all: no callbacks, no
  # validations; the tracker may be mid-destroy.)
  def forget_twist_channel_access
    return unless destroyed? || saved_change_to_url? || saved_change_to_link_type? || saved_change_to_id?
    ProjectTracker.where(id: project_tracker_id).update_all(twist_channel_accessible: nil, twist_channel_checked_at: nil)
  end

  def url_is_plain_http
    parsed = begin
      URI.parse(url.to_s)
    rescue URI::InvalidURIError
      nil
    end
    unless parsed.is_a?(URI::HTTP) && parsed.host.present?
      errors.add(:url, "must be an http or https URL")
      return
    end
    # Ruby's URI drops an empty userinfo ("https://@host") rather than
    # reporting it, so look at the authority text, not the parsed field.
    errors.add(:url, "must not embed credentials") if url.match?(%r{\A[a-z][a-z0-9+.-]*://[^/?#]*@}i)
  end
end
