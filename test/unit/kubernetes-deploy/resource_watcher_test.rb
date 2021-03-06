# frozen_string_literal: true
require 'test_helper'

class ResourceWatcherTest < KubernetesDeploy::TestCase
  def test_requires_enumerable
    expected_msg = "ResourceWatcher expects Enumerable collection, got `Object` instead"
    assert_raises_message(ArgumentError, expected_msg) do
      build_watcher(Object.new)
    end

    build_watcher([])
  end

  def test_success_with_mock_resource_and_summary_recording_enabled
    resource = build_mock_resource

    watcher = build_watcher([resource])
    watcher.run(delay_sync: 0.1)
    logger.print_summary(true)

    assert_logs_match_all([
      /Successfully deployed in \d.\ds: web-pod/,
      "Successfully deployed 1 resource",
      /web-pod\s+success \(1 hits\)/,
    ], in_order: true)
  end

  def test_success_with_mock_resource_and_summary_recording_disabled
    resource = build_mock_resource

    watcher = build_watcher([resource])
    watcher.run(delay_sync: 0.1, record_summary: false)
    logger.print_summary(true)

    assert_logs_match(/Successfully deployed in \d.\ds: web-pod/)
    refute_logs_match("Successfully deployed 1 resource")
    refute_logs_match(/web-pod.*success/)
  end

  def test_failure_with_mock_resource
    resource = build_mock_resource(final_status: "failed")

    watcher = build_watcher([resource])
    watcher.run(delay_sync: 0.1)
    logger.print_summary(:failure)

    assert_logs_match_all([
      /web-pod failed to deploy after \d\.\ds/,
      "Result: FAILURE",
      "Failed to deploy 1 resource",
      "Something went wrong",
    ], in_order: true)
  end

  def test_timeout_from_resource
    resource = build_mock_resource(final_status: "timeout")

    watcher = build_watcher([resource])
    watcher.run(delay_sync: 0.1)

    assert_logs_match(/web-pod rollout timed out/)
  end

  def test_wait_logging_when_resources_do_not_finish_together
    first = build_mock_resource(final_status: "success", hits_to_complete: 1, name: "first")
    second = build_mock_resource(final_status: "timeout", hits_to_complete: 2, name: "second")
    third = build_mock_resource(final_status: "failed", hits_to_complete: 3, name: "third")
    fourth = build_mock_resource(final_status: "success", hits_to_complete: 4, name: "fourth")

    watcher = build_watcher([first, second, third, fourth])
    watcher.run(delay_sync: 0.01)

    assert_logs_match_all([
      /Successfully deployed in \d.\ds: first/,
      /Continuing to wait for: second, third, fourth/,
      /second rollout timed out/,
      /Continuing to wait for: third, fourth/,
      /third failed to deploy after \d.\ds/,
      /Continuing to wait for: fourth/,
      /Successfully deployed in \d.\ds: fourth/,
    ], in_order: true)
  end

  def test_reminder_logged_at_interval_even_when_nothing_happened
    resource1 = build_mock_resource(final_status: "success", hits_to_complete: 1, name: 'first')
    resource2 = build_mock_resource(final_status: "success", hits_to_complete: 9, name: 'second')
    resource3 = build_mock_resource(final_status: "success", hits_to_complete: 9, name: 'third')
    watcher = build_watcher([resource1, resource2, resource3])
    watcher.run(delay_sync: 0.01, reminder_interval: 0.05)

    assert_logs_match_all([
      /Successfully deployed in \d.\ds: first/,
      /Continuing to wait for: second, third/,
      /Still waiting for: second, third/,
      /Successfully deployed in \d.\ds: second, third/,
    ], in_order: true)
    assert_logs_match(/Continuing to wait for: second, third/, 1) # only once
  end

  def test_timeout_allows_success
    resource = build_mock_resource(hits_to_complete: 1)
    watcher = KubernetesDeploy::ResourceWatcher.new(resources: [resource],
      timeout: 2, task_config: task_config(namespace: 'test'))

    watcher.run(delay_sync: 0.1)
    assert_logs_match(/Successfully deployed in \d.\ds: web-pod/)
  end

  def test_timeout_raises_after_timeout_seconds
    resource = build_mock_resource(hits_to_complete: 10**100)
    watcher = KubernetesDeploy::ResourceWatcher.new(resources: [resource],
      timeout: 0.02, task_config: task_config(namespace: 'test'))

    assert_raises(KubernetesDeploy::DeploymentTimeoutError) { watcher.run(delay_sync: 0.01) }
  end

  private

  def build_watcher(resources)
    KubernetesDeploy::ResourceWatcher.new(
      resources: resources,
      task_config: task_config(namespace: 'test')
    )
  end

  MockResource = Struct.new(:id, :hits_to_complete, :status) do
    def debug_message(*)
      @debug_message
    end

    def sync(_cache)
      @hits ||= 0
      @hits += 1
    end

    def after_sync
    end

    def type
      "MockResource"
    end
    alias_method :kubectl_resource_type, :type

    def deploy_succeeded?
      status == "success" && hits_complete?
    end

    def deploy_failed?
      status == "failed" && hits_complete?
    end

    def deploy_timed_out?
      status == "timeout" && hits_complete?
    end

    def timeout
      hits_to_complete
    end

    def sync_debug_info(_)
      @debug_message = "Something went wrong"
    end

    def pretty_status
      "#{id}  #{status} (#{@hits} hits)"
    end

    def report_status_to_statsd(watch_time)
    end

    private

    def hits_complete?
      @hits >= hits_to_complete
    end
  end

  def build_mock_resource(final_status: "success", hits_to_complete: 1, name: "web-pod")
    MockResource.new(name, hits_to_complete, final_status)
  end
end
