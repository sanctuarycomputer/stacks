# test/lib/stacks/etl/groups/message_parser_test.rb
require 'test_helper'

class Stacks::Etl::Groups::MessageParserTest < ActiveSupport::TestCase
  P = Stacks::Etl::Groups::MessageParser

  def raw(message_id:, from:, subject:, date:, body:, references: nil, in_reply_to: nil, content_type: 'text/plain; charset=UTF-8')
    headers = +"Message-ID: #{message_id}\r\nFrom: #{from}\r\nTo: dev@sanctuary.computer\r\nSubject: #{subject}\r\nDate: #{date}\r\nContent-Type: #{content_type}\r\n"
    headers << "References: #{references}\r\n" if references
    headers << "In-Reply-To: #{in_reply_to}\r\n" if in_reply_to
    "#{headers}\r\n#{body}"
  end

  test 'parse extracts headers, address parts, and text body; root is own id when no references' do
    m = P.parse(raw(message_id: '<a@x>', from: 'Alice <alice@x.co>', subject: 'Deploy failed',
                    date: 'Mon, 01 Jun 2026 10:00:00 +0000', body: 'the api is down'))
    assert_equal '<a@x>', m[:message_id]
    assert_equal '<a@x>', m[:root_id]
    assert_equal 'Alice', m[:from_name]
    assert_equal 'alice@x.co', m[:from_email]
    assert_equal 'Deploy failed', m[:subject]
    assert_equal 'the api is down', m[:body].strip
  end

  test 'parse derives root_id from the first References entry even without the root body' do
    m = P.parse(raw(message_id: '<c@x>', from: 'Bob <bob@x.co>', subject: 'Re: Deploy failed',
                    date: 'Mon, 01 Jun 2026 11:00:00 +0000', body: 'looking now',
                    references: '<a@x> <b@x>', in_reply_to: '<b@x>'))
    assert_equal '<a@x>', m[:root_id]
  end

  test 'parse falls back to HTML->text when there is no text/plain part' do
    m = P.parse(raw(message_id: '<h@x>', from: 'Sentry <sentry@x.co>', subject: 'New issue',
                    date: 'Mon, 01 Jun 2026 12:00:00 +0000',
                    body: '<html><body><b>API-4WZ</b> DBConnection error</body></html>',
                    content_type: 'text/html; charset=UTF-8'))
    assert_includes m[:body], 'API-4WZ'
    assert_includes m[:body], 'DBConnection error'
    refute_includes m[:body], '<b>'
  end

  test 'assemble groups messages by root into one thread doc with sorted segments' do
    msgs = [
      P.parse(raw(message_id: '<a@x>', from: 'Alice <alice@x.co>', subject: 'Deploy failed',
                  date: 'Mon, 01 Jun 2026 10:00:00 +0000', body: 'the api is down')),
      P.parse(raw(message_id: '<c@x>', from: 'Bob <bob@x.co>', subject: 'Re: Deploy failed',
                  date: 'Mon, 01 Jun 2026 11:00:00 +0000', body: 'fixed it', references: '<a@x>'))
    ]
    docs = P.assemble(group_email: 'dev@sanctuary.computer', group_name: 'Dev', messages: msgs)
    assert_equal 1, docs.size
    d = docs.first
    assert_equal :google_groups, d[:source]
    assert_equal '<a@x>', d[:external_id]
    assert_equal 'Deploy failed', d[:title]
    assert_equal Time.utc(2026, 6, 1, 10), d[:occurred_at]         # first_message_at
    assert_equal ['the api is down', 'fixed it'], d[:segments].map { |s| s[:text] }
    assert_equal 'https://groups.google.com/a/sanctuary.computer/g/dev', d[:url]
    assert_equal 2, d[:participant_count]
    assert_includes d[:contacts], { email: 'dev@sanctuary.computer', name: 'Dev', role: 'group' }
    assert_includes d[:contacts], { email: 'alice@x.co', name: 'Alice', role: 'sender' }
  end

  test 'assemble content_hash changes when a reply is added (drives re-index)' do
    a = P.parse(raw(message_id: '<a@x>', from: 'Alice <alice@x.co>', subject: 'Deploy failed',
                    date: 'Mon, 01 Jun 2026 10:00:00 +0000', body: 'down'))
    c = P.parse(raw(message_id: '<c@x>', from: 'Bob <bob@x.co>', subject: 'Re: Deploy failed',
                    date: 'Mon, 01 Jun 2026 11:00:00 +0000', body: 'up', references: '<a@x>'))
    one = P.assemble(group_email: 'dev@sanctuary.computer', group_name: 'Dev', messages: [a]).first
    two = P.assemble(group_email: 'dev@sanctuary.computer', group_name: 'Dev', messages: [a, c]).first
    refute_equal one[:content_hash], two[:content_hash]
  end

  test 'strip_quoted keeps new content (including > lines) but removes the On...wrote: tail' do
    body = "> 90% of requests are failing\nlooking into it now\n\nOn Mon, 01 Jun 2026 Alice <alice@x.co> wrote:\n> old quoted line\n> more quoted"
    m = P.parse(raw(message_id: '<z@x>', from: 'Bob <bob@x.co>', subject: 'Re: Deploy failed',
                    date: 'Mon, 01 Jun 2026 11:00:00 +0000', body: body))
    assert_includes m[:body], '90% of requests are failing', 'a legit > line in new content must survive'
    assert_includes m[:body], 'looking into it now'
    refute_includes m[:body], 'old quoted line', 'the quoted tail after "On ... wrote:" must be removed'
  end

  # root_id_from is the shared key used by BOTH the raw parse (mail-gem values: References is an
  # Array of bare ids, or a String for one) AND the crawl's pass-1 metadata pass (raw header
  # value: a single space-joined String WITH angle brackets). Both must derive the identical
  # root or cross-mailbox dedup and the split-thread fix break.
  test 'root_id_from derives the identical root from the raw-metadata string and the mail-gem array shapes' do
    assert_equal '<a@x>', P.root_id_from(message_id: '<c@x>', references: '<a@x> <b@x>'), 'metadata string, multi-ref'
    assert_equal '<a@x>', P.root_id_from(message_id: '<c@x>', references: ['a@x', 'b@x']), 'mail-gem array, multi-ref'
    assert_equal '<a@x>', P.root_id_from(message_id: '<c@x>', references: 'a@x'), 'mail-gem single-ref String'
  end

  test 'root_id_from falls back In-Reply-To -> self, and is nil with nothing' do
    assert_equal '<a@x>', P.root_id_from(message_id: '<c@x>', references: nil, in_reply_to: '<a@x>')
    assert_equal '<a@x>', P.root_id_from(message_id: '<c@x>', references: '   ', in_reply_to: '<a@x> <b@x>'), 'blank refs -> first In-Reply-To'
    assert_equal '<r@x>', P.root_id_from(message_id: '<r@x>'), 'no refs / no in-reply-to -> the message is its own root'
    assert_nil P.root_id_from(message_id: '')
  end
end
