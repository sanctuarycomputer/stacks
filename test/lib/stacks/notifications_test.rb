require "test_helper"

class StacksNotificationsOptixDeactivationTest < ActiveSupport::TestCase
  def result(deactivated: [], skipped: [], errors: [])
    Stacks::Optix::DeactivateInactiveMembers::Result.new(
      deactivated: deactivated, skipped: skipped, errors: errors,
    )
  end

  test "posts a Twist comment to the exceptions thread with counts, skips, and errors" do
    r = result(
      deactivated: [{ user_id: "50", member_id: 1050, email: "a@b.c", name: "A B", invoice_total: 0.0 }],
      skipped: [{ user_id: "51", email: "s@b.c", reason: "no member_id mapping (no invoices on record)" }],
      errors: [{ user_id: "52", email: "e@b.c", error: "Stacks::Optix::ApiError: boom" }],
    )

    captured = nil
    twist = mock
    twist.expects(:add_comment_to_thread).with do |thread_id, content, recipients|
      captured = { thread_id: thread_id, content: content, recipients: recipients }
      true
    end
    Stacks::Notifications.stubs(:twist).returns(twist)

    Stacks::Notifications.report_optix_deactivation_run(r)

    assert_equal Stacks::Notifications::TWIST_EXCEPTIONS_THREAD_ID, captured[:thread_id]
    assert_equal [Stacks::Notifications::TWIST_EXCEPTION_NOTIFY_USER_ID], captured[:recipients]
    assert_includes captured[:content], "1 deactivated"
    assert_includes captured[:content], "1 skipped"
    assert_includes captured[:content], "1 errored"
    assert_includes captured[:content], "a@b.c"
    assert_includes captured[:content], "s@b.c — no member_id mapping (no invoices on record)"
    assert_includes captured[:content], "e@b.c — Stacks::Optix::ApiError: boom"
  end

  test "a non-2xx Twist response raises so the caller's rescue can log + Sentry it" do
    r = result(skipped: [{ user_id: "51", email: "s@b.c", reason: "no member_id mapping" }])
    twist = mock
    twist.expects(:add_comment_to_thread).returns(stub(code: 500))
    Stacks::Notifications.stubs(:twist).returns(twist)

    err = assert_raises(RuntimeError) { Stacks::Notifications.report_optix_deactivation_run(r) }
    assert_match(/HTTP 500/, err.message)
  end

  test "a run with nothing to report posts nothing" do
    Stacks::Notifications.expects(:twist).never
    Stacks::Notifications.report_optix_deactivation_run(result)
  end

  test "caps the deactivated email list at 50" do
    deactivated = Array.new(51) { |i| { user_id: i.to_s, email: "m#{i}@x.c", invoice_total: 0.0 } }

    content = nil
    twist = mock
    twist.expects(:add_comment_to_thread).with { |_thread_id, c, _recipients| content = c; true }
    Stacks::Notifications.stubs(:twist).returns(twist)

    Stacks::Notifications.report_optix_deactivation_run(result(deactivated: deactivated))

    assert_includes content, "m49@x.c"
    refute_includes content, "m50@x.c"
    assert_includes content, "+1 more"
  end
end

# Stacksbot's Observe sensor skips any Twist post that opens with `# <Producer> via [Stacksbot](<url>)`.
# Without it, every exception backtrace and Optix run in the exceptions thread was re-read as new signal.
class StacksNotificationsProvenanceHeaderTest < ActiveSupport::TestCase
  HEADER_RE = /\A# .+ via \[Stacksbot\]\(https:\/\/app\.notion\.com\/p\/[0-9a-f]{32}\)\n/

  test "the Optix run post opens with the provenance header" do
    r = Stacks::Optix::DeactivateInactiveMembers::Result.new(
      deactivated: [{ user_id: "50", member_id: 1050, email: "a@b.c", name: "A B", invoice_total: 0.0 }], skipped: [], errors: [],
    )
    content = nil
    twist = mock
    twist.expects(:add_comment_to_thread).with { |_t, c, _r| content = c; true }.returns(stub(code: 200))
    Stacks::Notifications.stubs(:twist).returns(twist)
    Stacks::Notifications.report_optix_deactivation_run(r)
    assert_match HEADER_RE, content
    assert_match(/\A# Optix Deactivation Run via \[Stacksbot\]/, content)
  end

  test "the exception post opens with the provenance header; the stored notification body is unchanged" do
    content = nil
    twist = mock
    twist.expects(:add_comment_to_thread).with { |_t, c, _r| content = c; true }
    Stacks::Notifications.stubs(:twist).returns(twist)
    Sentry.stubs(:capture_exception)
    SystemExceptionNotification.any_instance.stubs(:deliver)
    notification = Stacks::Notifications.report_exception(RuntimeError.new("boom"))
    assert_match HEADER_RE, content
    assert_match(/\A# Stacks Exception via \[Stacksbot\]/, content)
    assert_includes content, "RuntimeError: boom"
    refute_match(/via \[Stacksbot\]/, notification.body, "the admin UI copy keeps its own format")
  end
end
