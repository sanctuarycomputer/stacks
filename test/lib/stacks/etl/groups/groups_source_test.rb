# test/lib/stacks/etl/groups/groups_source_test.rb
require 'test_helper'
require 'ostruct'

class Stacks::Etl::Groups::GroupsSourceTest < ActiveSupport::TestCase
  def raw(mid, from, subject, date, body, references = nil)
    h = +"Message-ID: #{mid}\r\nFrom: #{from}\r\nTo: dev@sanctuary.computer\r\nSubject: #{subject}\r\nDate: #{date}\r\nContent-Type: text/plain\r\n"
    h << "References: #{references}\r\n" if references
    "#{h}\r\n#{body}"
  end

  # A Gmail message list ref carries an id AND a thread_id (the crawl buckets by thread_id).
  def ref(id, thread_id) = OpenStruct.new(id: id, thread_id: thread_id)

  test 'dedups a thread received in two mailboxes into one Document (segments unioned once)' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' },
      { email: 'nested@x.com', role: 'MEMBER', type: 'GROUP' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    root  = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    reply = raw('<c@x>', 'Bob <bob@x.co>', 'Re: Deploy failed', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')

    # Realistic list traffic: BOTH members received BOTH messages of the one thread.
    alice_gmail = mock('alice')
    alice_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [ref('a1', 't1'), ref('a2', 't1')], next_page_token: nil))
    alice_gmail.stubs(:get_user_message).with('me', 'a1', format: 'raw').returns(OpenStruct.new(raw: root))
    alice_gmail.stubs(:get_user_message).with('me', 'a2', format: 'raw').returns(OpenStruct.new(raw: reply))

    bob_gmail = mock('bob')
    bob_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [ref('b1', 't9'), ref('b2', 't9')], next_page_token: nil))
    bob_gmail.stubs(:get_user_message).with('me', 'b1', format: 'raw').returns(OpenStruct.new(raw: root))
    bob_gmail.stubs(:get_user_message).with('me', 'b2', format: 'raw').returns(OpenStruct.new(raw: reply))

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(alice_gmail)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bob_gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }

    assert_equal 1, yielded.size, "the second mailbox's copy of the thread must dedup away by Message-ID"
    d = yielded.first
    assert_equal '<a@x>', d[:external_id]
    assert_equal ['down', 'up'], d[:segments].map { |s| s[:text] }
  end

  test 'streams one Document per Gmail thread (bounded, incremental)' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer')
      .returns([{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' }])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(['alice@sanctuary.computer'])

    t1 = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    t2 = raw('<b@x>', 'Alice <alice@x.co>', 'Lunch?', 'Mon, 02 Jun 2026 10:00:00 +0000', 'tacos')

    gmail = mock('g')
    # Two DISTINCT Gmail threads in one list page — must yield as two separate Documents.
    gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [ref('m1', 't1'), ref('m2', 't2')], next_page_token: nil))
    gmail.stubs(:get_user_message).with('me', 'm1', format: 'raw').returns(OpenStruct.new(raw: t1))
    gmail.stubs(:get_user_message).with('me', 'm2', format: 'raw').returns(OpenStruct.new(raw: t2))
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).returns(gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 1).each_thread { |n| yielded << n }

    assert_equal 2, yielded.size, 'two distinct Gmail threads -> two Documents, streamed separately'
    assert_equal ['<a@x>', '<b@x>'], yielded.map { |n| n[:external_id] }.sort
    assert(yielded.all? { |d| d[:segments].size == 1 })
  end

  test 'owner-first streaming: a later mailbox extra message on an already-seen thread is not merged' do
    # alice (OWNER) has only the root; bob (MEMBER) has root + a reply. Under streaming union,
    # alice's copy of the thread is emitted first, and bob's extra reply for that same root is
    # deduped-by-root and dropped. This is the deliberate trade for bounded memory — locked
    # here so it reads as intentional, not a regression.
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    root  = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    reply = raw('<c@x>', 'Bob <bob@x.co>', 'Re: Deploy failed', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')

    alice_gmail = mock('alice')
    alice_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [ref('a1', 't1')], next_page_token: nil))
    alice_gmail.stubs(:get_user_message).with('me', 'a1', format: 'raw').returns(OpenStruct.new(raw: root))

    bob_gmail = mock('bob')
    bob_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [ref('b1', 't9'), ref('b2', 't9')], next_page_token: nil))
    bob_gmail.stubs(:get_user_message).with('me', 'b1', format: 'raw').returns(OpenStruct.new(raw: root))
    bob_gmail.stubs(:get_user_message).with('me', 'b2', format: 'raw').returns(OpenStruct.new(raw: reply))

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(alice_gmail)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bob_gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }

    assert_equal 1, yielded.size
    assert_equal ['down'], yielded.first[:segments].map { |s| s[:text] },
                 'only the owner-mailbox copy is kept once the root is already seen'
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
    gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [], next_page_token: nil))
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

    root = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    gmail = mock('g')
    gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [ref('g_a', 't1')], next_page_token: nil))
    gmail.stubs(:get_user_message).returns(OpenStruct.new(raw: root))
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

    root = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    good = mock('alice')
    good.stubs(:list_user_messages).returns(OpenStruct.new(messages: [ref('g_a', 't1')], next_page_token: nil))
    good.stubs(:get_user_message).returns(OpenStruct.new(raw: root))
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
