require 'mail'
require 'digest'

module Stacks
  module Etl
    module Groups
      # Parses raw RFC822 messages and assembles them into thread-level normalized
      # documents (the shape Stacks::Etl::Connector#ingest consumes). Keyed on the
      # RFC822 Message-ID so the same message from two crawled mailboxes dedups to one.
      class MessageParser
        REPLY_MARKER = /^On .+ wrote:\s*$/i.freeze

        def self.parse(raw)
          m = Mail.read_from_string(raw)
          mid = bracket(m.message_id)
          from_name, from_email = address_parts(m[:from])
          {
            message_id: mid,
            root_id: root_id_from(message_id: m.message_id, references: m.references, in_reply_to: m.in_reply_to),
            from_name: from_name,
            from_email: from_email,
            to: addresses(m[:to]),
            cc: addresses(m[:cc]),
            subject: m.subject.to_s,
            date: m.date&.to_time,
            body: strip_quoted(body_text(m))
          }
        end

        # Thread root = first References entry, else In-Reply-To, else the message's own
        # Message-ID (all angle-bracket-normalized). Shared by parse (mail-gem values, arrays)
        # and the crawl's cheap metadata pass (raw header strings), so both derive the SAME
        # thread key regardless of how Gmail bucketed the message into a thread_id.
        def self.root_id_from(message_id:, references: nil, in_reply_to: nil)
          refs = Array(references).flat_map { |r| r.to_s.split }.reject(&:empty?).map { |r| bracket(r) }
          irt  = Array(in_reply_to).flat_map { |r| r.to_s.split }.reject(&:empty?).map { |r| bracket(r) }.first
          mid  = message_id.to_s.strip.empty? ? nil : bracket(message_id)
          refs.first || irt || mid
        end

        # messages: parse-hashes already deduped by :message_id. Returns one doc per root.
        def self.assemble(group_email:, group_name:, messages:)
          messages.group_by { |m| m[:root_id] }.map do |root_id, msgs|
            sorted = msgs.sort_by { |m| m[:date] || Time.at(0) }
            first = sorted.first
            bodies = sorted.map { |m| m[:body] }
            {
              source: :google_groups,
              external_id: root_id,
              title: normalize_subject(first[:subject]),
              url: group_url(group_email),
              occurred_at: first[:date],
              content_hash: Digest::SHA256.hexdigest(bodies.join("\n")),
              participant_count: sorted.map { |m| m[:from_email] }.compact.uniq.size,
              contacts: contacts_for(sorted, group_email, group_name),
              segments: sorted.map { |m|
                { speaker_name: m[:from_name], speaker_email: m[:from_email],
                  text: m[:body], started_at: m[:date], ended_at: nil }
              },
              raw_metadata: {
                'group_email' => group_email,
                'list_id' => group_email.sub('@', '.'),
                'gmail_message_ids' => sorted.map { |m| m[:message_id] }
              },
              build_source_record: lambda { |doc|
                gt = GoogleGroupThread.find_or_initialize_by(root_message_id: doc.external_id)
                gt.update!(group_email: group_email, list_id: group_email.sub('@', '.'),
                           subject: normalize_subject(first[:subject]), message_count: sorted.size,
                           first_message_at: first[:date], last_message_at: sorted.last[:date])
                gt
              }
            }
          end
        end

        def self.contacts_for(sorted, group_email, group_name)
          out = [{ email: group_email, name: group_name, role: 'group' }]
          sender_emails = sorted.map { |m| m[:from_email] }.compact.to_set
          sorted.each do |m|
            out << { email: m[:from_email], name: m[:from_name], role: 'sender' } if m[:from_email]
            (m[:to] + m[:cc]).each do |addr|
              next if addr == group_email || sender_emails.include?(addr)
              out << { email: addr, name: nil, role: 'recipient' }
            end
          end
          out.uniq
        end

        def self.group_url(group_email)
          local, domain = group_email.split('@', 2)
          "https://groups.google.com/a/#{domain}/g/#{local}"
        end

        def self.normalize_subject(subject)
          subject.to_s.sub(/\A((re|fwd|fw)\s*:\s*)+/i, '').strip
        end

        # Prefer text/plain; fall back to HTML->text (Sentry/Mailchimp are HTML-only and
        # ARE the signal we keep, so this branch is load-bearing).
        def self.body_text(m)
          if m.multipart?
            if m.text_part
              m.text_part.decoded
            elsif m.html_part
              strip_html(m.html_part.decoded)
            else
              ''
            end
          elsif m.mime_type == 'text/html'
            strip_html(m.decoded)
          else
            m.decoded.to_s
          end
        end

        def self.strip_html(html)
          ActionController::Base.helpers.strip_tags(html.to_s).gsub(/[ \t]+\n/, "\n").strip
        end

        # Best-effort: drop the quoted-reply tail — the "On ... wrote:" attribution line
        # and everything after it. Lines are NOT filtered for a leading '>' anymore, because
        # legitimate new content (shell output, "> 90% error rate", markdown quotes) can start
        # with '>' and must survive; Gmail/Groups quoting is preceded by the marker we cut on.
        def self.strip_quoted(text)
          lines = text.to_s.lines
          cut = lines.index { |l| l.match?(REPLY_MARKER) }
          lines = lines[0...cut] if cut
          lines.join.strip
        end

        def self.address_parts(field)
          return [nil, nil] unless field
          addr = field.addrs.first
          addr ? [addr.display_name, addr.address&.downcase] : [nil, nil]
        rescue StandardError
          [nil, field.to_s]
        end

        def self.addresses(field)
          return [] unless field
          field.addrs.map { |a| a.address&.downcase }.compact
        rescue StandardError
          []
        end

        def self.bracket(id)
          id = id.to_s.strip
          id.start_with?('<') ? id : "<#{id}>"
        end
      end
    end
  end
end
