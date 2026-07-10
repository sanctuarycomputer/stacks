# test/lib/stacks/etl/groups/groups_source_test.rb
require 'test_helper'
require 'ostruct'

class Stacks::Etl::Groups::GroupsSourceTest < ActiveSupport::TestCase
  META = Stacks::Etl::Groups::GroupsSource::META_HEADERS

  def raw(mid, from, subject, date, body, references = nil)
    h = +"Message-ID: #{mid}\r\nFrom: #{from}\r\nTo: dev@sanctuary.computer\r\nSubject: #{subject}\r\nDate: #{date}\r\nContent-Type: text/plain\r\n"
    h << "References: #{references}\r\n" if references
    "#{h}\r\n#{body}"
  end

  # A Gmail message list ref carries an id AND a thread_id (thread_id is intentionally NOT
  # used for grouping — we group on the RFC822 root from the metadata pass).
  def ref(id, thread_id = 't') = OpenStruct.new(id: id, thread_id: thread_id)

  # Pass-1 metadata response: payload.headers with the root-relevant headers.
  def meta(message_id, references = nil, in_reply_to = nil)
    headers = [OpenStruct.new(name: 'Message-ID', value: message_id)]
    headers << OpenStruct.new(name: 'References', value: references) if references
    headers << OpenStruct.new(name: 'In-Reply-To', value: in_reply_to) if in_reply_to
    OpenStruct.new(payload: OpenStruct.new(headers: headers))
  end

  # Stub BOTH passes for one message on a gmail mock: metadata (pass 1) + raw (pass 2).
  def stub_msg(gmail, gid, message_id, from, subject, date, body, references = nil)
    gmail.stubs(:get_user_message).with('me', gid, format: 'metadata', metadata_headers: META)
         .returns(meta(message_id, references))
    gmail.stubs(:get_user_message).with('me', gid, format: 'raw')
         .returns(OpenStruct.new(raw: raw(message_id, from, subject, date, body, references)))
  end

  def one_page(*refs) = OpenStruct.new(messages: refs, next_page_token: nil)

  test 'dedups a thread received in two mailboxes into one Document (segments unioned once)' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' },
      { email: 'nested@x.com', role: 'MEMBER', type: 'GROUP' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    # Both members received both messages of the one thread.
    alice_gmail = mock('alice')
    alice_gmail.stubs(:list_user_messages).returns(one_page(ref('a1'), ref('a2')))
    stub_msg(alice_gmail, 'a1', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    stub_msg(alice_gmail, 'a2', '<c@x>', 'Bob <bob@x.co>', 'Re: Deploy failed', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')

    bob_gmail = mock('bob')
    bob_gmail.stubs(:list_user_messages).returns(one_page(ref('b1'), ref('b2')))
    stub_msg(bob_gmail, 'b1', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    stub_msg(bob_gmail, 'b2', '<c@x>', 'Bob <bob@x.co>', 'Re: Deploy failed', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(alice_gmail)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bob_gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }

    assert_equal 1, yielded.size, "the second mailbox's copy of the thread must dedup away by Message-ID"
    d = yielded.first
    assert_equal '<a@x>', d[:external_id]
    assert_equal ['down', 'up'], d[:segments].map { |s| s[:text] }
  end

  test 'groups by RFC822 root even when Gmail split the conversation across thread_ids (no message loss)' do
    # The regression the streaming rewrite must NOT reintroduce: root <a@x> and its reply <c@x>
    # sit in DIFFERENT Gmail thread_ids (tA, tB) — a real Gmail behaviour on subject drift.
    # Grouping on root (via the metadata pass) keeps them in one Document with both segments;
    # grouping on thread_id would have dropped the reply.
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer')
      .returns([{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' }])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(['alice@sanctuary.computer'])

    gmail = mock('g')
    gmail.stubs(:list_user_messages).returns(one_page(ref('g1', 'tA'), ref('g2', 'tB')))
    stub_msg(gmail, 'g1', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    stub_msg(gmail, 'g2', '<c@x>', 'Bob <bob@x.co>', 'Re: Deploy — status', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).returns(gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 1).each_thread { |n| yielded << n }

    assert_equal 1, yielded.size
    assert_equal '<a@x>', yielded.first[:external_id]
    assert_equal ['down', 'up'], yielded.first[:segments].map { |s| s[:text] },
                 'the reply in a different Gmail thread but same RFC822 root must not be lost'
  end

  test 'streams one Document per logical thread (bounded, incremental)' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer')
      .returns([{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' }])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(['alice@sanctuary.computer'])

    gmail = mock('g')
    gmail.stubs(:list_user_messages).returns(one_page(ref('m1'), ref('m2')))
    stub_msg(gmail, 'm1', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    stub_msg(gmail, 'm2', '<b@x>', 'Alice <alice@x.co>', 'Lunch?', 'Mon, 02 Jun 2026 10:00:00 +0000', 'tacos')
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).returns(gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 1).each_thread { |n| yielded << n }

    assert_equal 2, yielded.size, 'two distinct roots -> two Documents'
    assert_equal ['<a@x>', '<b@x>'], yielded.map { |n| n[:external_id] }.sort
    assert(yielded.all? { |d| d[:segments].size == 1 })
  end

  test 'paginates the message list across pages' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer')
      .returns([{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' }])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(['alice@sanctuary.computer'])

    gmail = mock('g')
    gmail.stubs(:list_user_messages).with('me', has_entries(q: instance_of(String), max_results: 100, page_token: nil))
         .returns(OpenStruct.new(messages: [ref('p1')], next_page_token: 'P2'))
    gmail.stubs(:list_user_messages).with('me', has_entries(page_token: 'P2'))
         .returns(OpenStruct.new(messages: [ref('p2')], next_page_token: nil))
    stub_msg(gmail, 'p1', '<a@x>', 'Alice <alice@x.co>', 'One', 'Mon, 01 Jun 2026 10:00:00 +0000', 'first')
    stub_msg(gmail, 'p2', '<b@x>', 'Bob <bob@x.co>', 'Two', 'Mon, 02 Jun 2026 10:00:00 +0000', 'second')
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).returns(gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 1).each_thread { |n| yielded << n }
    assert_equal ['<a@x>', '<b@x>'], yielded.map { |n| n[:external_id] }.sort,
                 'messages from BOTH list pages must be ingested'
  end

  test 'owner-first: a later mailbox extra message on an already-seen root is not merged' do
    # alice (OWNER) has only the root; bob (MEMBER) has root + a reply. alice's copy is emitted
    # first; bob's extra reply for the same root is deduped-by-root and dropped — the deliberate
    # cross-mailbox trade for bounded memory (within a mailbox nothing is lost — see the split test).
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    alice_gmail = mock('alice')
    alice_gmail.stubs(:list_user_messages).returns(one_page(ref('a1')))
    stub_msg(alice_gmail, 'a1', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')

    bob_gmail = mock('bob')
    bob_gmail.stubs(:list_user_messages).returns(one_page(ref('b1'), ref('b2')))
    stub_msg(bob_gmail, 'b1', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    stub_msg(bob_gmail, 'b2', '<c@x>', 'Bob <bob@x.co>', 'Re: Deploy failed', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(alice_gmail)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bob_gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }

    assert_equal 1, yielded.size
    assert_equal ['down'], yielded.first[:segments].map { |s| s[:text] },
                 'only the owner-mailbox copy is kept once the root is already seen'
  end

  test 'a message whose metadata has no Message-ID header is skipped, not crashed or misgrouped' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer')
      .returns([{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' }])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(['alice@sanctuary.computer'])

    gmail = mock('g')
    gmail.stubs(:list_user_messages).returns(one_page(ref('g_ok'), ref('g_bad')))
    stub_msg(gmail, 'g_ok', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    # g_bad: metadata present but NO Message-ID header -> must be skipped in pass 1 (never body-fetched).
    gmail.stubs(:get_user_message).with('me', 'g_bad', format: 'metadata', metadata_headers: META)
         .returns(OpenStruct.new(payload: OpenStruct.new(headers: [OpenStruct.new(name: 'Subject', value: 'no id')])))
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).returns(gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 1).each_thread { |n| yielded << n }
    assert_equal ['<a@x>'], yielded.map { |n| n[:external_id] }, 'the id-less message is dropped; the valid one still ingests'
  end

  test 'pick_crawlers prefers owners, caps at k, excludes non-USER and inactive members' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'member@sanctuary.computer', role: 'MEMBER', type: 'USER' },
      { email: 'owner@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'nested@x.com', role: 'MEMBER', type: 'GROUP' },      # non-USER -> excluded
      { email: 'ext@other.com', role: 'OWNER', type: 'USER' }        # not in active set -> excluded
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['member@sanctuary.computer', 'owner@sanctuary.computer'])

    gmail = mock('g')
    gmail.stubs(:list_user_messages).returns(one_page)
    # k:1 -> ONLY the OWNER mailbox may be crawled (owner beats member; GROUP + inactive excluded).
    Stacks::Etl::Meet::Auth.expects(:gmail_service).with(sub: 'owner@sanctuary.computer').returns(gmail)

    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 1).each_thread { |_| }
  end

  test 'query targets the group via list/to/cc + after: default-30-day window, never deliveredto:' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer')
      .returns([{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' }])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(['alice@sanctuary.computer'])

    captured_q = nil
    empty_page  = OpenStruct.new(messages: [], next_page_token: nil)
    spy_gmail   = Object.new
    spy_gmail.define_singleton_method(:list_user_messages) do |_user, opts|
      captured_q = opts[:q]
      empty_page
    end
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).returns(spy_gmail)

    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer').each_thread { |_| }

    assert_includes captured_q, '(list:dev@sanctuary.computer OR to:dev@sanctuary.computer OR cc:dev@sanctuary.computer)'
    refute_includes captured_q, 'deliveredto:'
    assert_includes captured_q, "after:#{30.days.ago.strftime('%Y/%m/%d')}"
  end

  test 'a group whose member-list lookup fails does not abort the other groups' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([
      { email: 'broken@sanctuary.computer', name: 'Broken' },
      { email: 'dev@sanctuary.computer', name: 'Dev' }
    ])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('broken@sanctuary.computer')
      .raises(Google::Apis::ClientError.new('group vanished'))
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer')
      .returns([{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' }])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(['alice@sanctuary.computer'])

    gmail = mock('g')
    gmail.stubs(:list_user_messages).returns(one_page(ref('g_a')))
    stub_msg(gmail, 'g_a', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).returns(gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer').each_thread { |n| yielded << n }
    assert_equal ['<a@x>'], yielded.map { |n| n[:external_id] },
                 'the healthy group must still ingest despite the broken group failing member lookup'
  end

  test 'a failing member mailbox does not abort the group' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    good = mock('alice')
    good.stubs(:list_user_messages).returns(one_page(ref('g_a')))
    stub_msg(good, 'g_a', '<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    bad = mock('bob')
    bad.stubs(:list_user_messages).raises(Google::Apis::ClientError.new('no gmail license'))

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(good)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bad)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }
    assert_equal 1, yielded.size
    assert_equal '<a@x>', yielded.first[:external_id]
  end
end
