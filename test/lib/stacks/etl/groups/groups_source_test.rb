# test/lib/stacks/etl/groups/groups_source_test.rb
require 'test_helper'
require 'ostruct'

class Stacks::Etl::Groups::GroupsSourceTest < ActiveSupport::TestCase
  def raw(mid, from, subject, date, body, references = nil)
    h = +"Message-ID: #{mid}\r\nFrom: #{from}\r\nTo: dev@sanctuary.computer\r\nSubject: #{subject}\r\nDate: #{date}\r\nContent-Type: text/plain\r\n"
    h << "References: #{references}\r\n" if references
    "#{h}\r\n#{body}"
  end

  test 'crawls K members, dedups the same message across mailboxes, yields one thread' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' },
      { email: 'nested@x.com', role: 'MEMBER', type: 'GROUP' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    # Both Alice and Bob received the SAME root message <a@x>; Bob also has reply <c@x>.
    root = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    reply = raw('<c@x>', 'Bob <bob@x.co>', 'Re: Deploy failed', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')

    alice_gmail = mock('alice')
    alice_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [OpenStruct.new(id: 'g_a')], next_page_token: nil))
    alice_gmail.stubs(:get_user_message).with('me', 'g_a', format: 'raw').returns(OpenStruct.new(raw: root))

    bob_gmail = mock('bob')
    bob_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [OpenStruct.new(id: 'g_a2'), OpenStruct.new(id: 'g_c')], next_page_token: nil))
    bob_gmail.stubs(:get_user_message).with('me', 'g_a2', format: 'raw').returns(OpenStruct.new(raw: root))
    bob_gmail.stubs(:get_user_message).with('me', 'g_c', format: 'raw').returns(OpenStruct.new(raw: reply))

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(alice_gmail)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bob_gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }

    assert_equal 1, yielded.size, 'the duplicate root across two mailboxes must collapse to one thread'
    d = yielded.first
    assert_equal '<a@x>', d[:external_id]
    assert_equal ['down', 'up'], d[:segments].map { |s| s[:text] }
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
    good.stubs(:list_user_messages).returns(OpenStruct.new(messages: [OpenStruct.new(id: 'g_a')], next_page_token: nil))
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
