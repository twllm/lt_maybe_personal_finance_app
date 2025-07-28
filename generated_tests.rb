require "test_helper"

class ApiRateLimiterTest < ActiveSupport::TestCase
  setup do
    @api_key = api_keys(:active_key)
    @redis = mock("redis")
    Redis.stubs(:new).returns(@redis)
    @limiter = ApiRateLimiter.new(@api_key)
    
    # Set up default Redis behavior for cleaner tests
    setup_default_redis_stubs
  end

  teardown do
    Redis.unstub(:new)
    travel_back
  end

  # ===== Test Helper Methods =====
  
  def setup_default_redis_stubs
    # Default to no requests recorded
    @redis.stubs(:hget).returns(nil)
    @redis.stubs(:multi).yields(@redis)
    @redis.stubs(:hincrby).returns(1)
    @redis.stubs(:expire).returns(true)
  end

  def with_frozen_time(time_string = "2025-01-15 10:00:00", &block)
    # Freeze time at a specific moment for predictable tests
    travel_to Time.zone.parse(time_string), &block
  end

  def current_hourly_window
    current_time = Time.current.to_i
    (current_time / 3600) * 3600
  end

  def redis_key_for(api_key)
    "api_rate_limit:#{api_key.id}"
  end

  def stub_redis_request_count(count)
    @redis.stubs(:hget).with(redis_key_for(@api_key), current_hourly_window.to_s).returns(count.to_s)
  end

  def expect_redis_increment
    window = current_hourly_window
    @redis.expects(:multi).yields(@redis)
    @redis.expects(:hincrby).with(redis_key_for(@api_key), window.to_s, 1).returns(1)
    @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
  end

  # ===== Rate Limit Constants Tests =====

  test "RATE_LIMITS constant contains all expected tiers with correct values" do
    assert_equal({ standard: 100, premium: 1000, enterprise: 10000 }, ApiRateLimiter::RATE_LIMITS)
    assert ApiRateLimiter::RATE_LIMITS.frozen?, "RATE_LIMITS should be frozen"
  end

  test "DEFAULT_TIER is set to standard" do
    assert_equal :standard, ApiRateLimiter::DEFAULT_TIER
  end

  # ===== Initialization Tests =====

  test "initializes with API key and creates Redis connection" do
    Redis.unstub(:new)
    Redis.expects(:new).returns(@redis)
    
    limiter = ApiRateLimiter.new(@api_key)
    assert_not_nil limiter
  end

  test "raises error when Redis connection fails during initialization" do
    Redis.unstub(:new)
    Redis.stubs(:new).raises(Redis::CannotConnectError, "Connection refused")
    
    assert_raises(Redis::CannotConnectError) do
      ApiRateLimiter.new(@api_key)
    end
  end

  # ===== Rate Limit Enforcement Tests =====

  test "rate_limit_exceeded? returns false when no requests have been made" do
    with_frozen_time do
      stub_redis_request_count(0)
      assert_not @limiter.rate_limit_exceeded?
    end
  end

  test "rate_limit_exceeded? returns false when request count is below limit" do
    with_frozen_time do
      stub_redis_request_count(99)
      assert_not @limiter.rate_limit_exceeded?
    end
  end

  test "rate_limit_exceeded? returns true when request count equals limit" do
    with_frozen_time do
      stub_redis_request_count(100)
      assert @limiter.rate_limit_exceeded?
    end
  end

  test "rate_limit_exceeded? returns true when request count exceeds limit" do
    with_frozen_time do
      stub_redis_request_count(150)
      assert @limiter.rate_limit_exceeded?
    end
  end

  test "rate_limit_exceeded? handles nil Redis response as zero requests" do
    with_frozen_time do
      @redis.stubs(:hget).returns(nil)
      assert_not @limiter.rate_limit_exceeded?
    end
  end

  test "rate_limit_exceeded? handles non-numeric Redis response gracefully" do
    with_frozen_time do
      @redis.stubs(:hget).returns("invalid")
      assert_not @limiter.rate_limit_exceeded?
    end
  end

  # ===== Rate Limit Tier Tests =====

  test "rate_limit returns standard tier limit by default" do
    assert_equal 100, @limiter.rate_limit
  end

  test "determine_tier is a private method that returns DEFAULT_TIER" do
    # Test the private method behavior
    assert_equal :standard, @limiter.send(:determine_tier)
  end

  # ===== Request Counting Tests =====

  test "increment_request_count! increments count in Redis with correct key and window" do
    with_frozen_time do
      expect_redis_increment
      @limiter.increment_request_count!
    end
  end

  test "increment_request_count! uses atomic Redis transaction" do
    with_frozen_time do
      transaction = mock("transaction")
      window = current_hourly_window
      
      @redis.expects(:multi).yields(transaction)
      transaction.expects(:hincrby).with(redis_key_for(@api_key), window.to_s, 1).returns(1)
      transaction.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
      
      @limiter.increment_request_count!
    end
  end

  test "increment_request_count! sets TTL to 7200 seconds (2 hours)" do
    with_frozen_time do
      @redis.expects(:multi).yields(@redis)
      @redis.expects(:hincrby).returns(1)
      @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
      
      @limiter.increment_request_count!
    end
  end

  test "increment_request_count! handles Redis errors by letting them bubble up" do
    with_frozen_time do
      @redis.expects(:multi).raises(Redis::ConnectionError, "Connection lost")
      
      assert_raises(Redis::ConnectionError) do
        @limiter.increment_request_count!
      end
    end
  end

  test "current_count returns count for current hour window" do
    with_frozen_time do
      stub_redis_request_count(42)
      assert_equal 42, @limiter.current_count
    end
  end

  test "current_count returns 0 when Redis returns nil" do
    with_frozen_time do
      @redis.stubs(:hget).returns(nil)
      assert_equal 0, @limiter.current_count
    end
  end

  test "current_count returns 0 when Redis returns empty string" do
    with_frozen_time do
      @redis.stubs(:hget).returns("")
      assert_equal 0, @limiter.current_count
    end
  end

  test "current_count handles non-numeric values from Redis gracefully" do
    with_frozen_time do
      @redis.stubs(:hget).returns("not-a-number")
      assert_equal 0, @limiter.current_count
    end
  end

  test "current_count uses correct Redis key format" do
    with_frozen_time do
      window = current_hourly_window
      @redis.expects(:hget).with(redis_key_for(@api_key), window.to_s).returns("10")
      
      assert_equal 10, @limiter.current_count
    end
  end

  # ===== Time Window Tests =====

  test "hourly windows are aligned to the start of each hour" do
    # Test that any time within an hour maps to the same window
    base_time = Time.zone.parse("2025-01-15 10:00:00")
    expected_window = base_time.to_i
    
    [0, 1, 15, 30, 45, 59].each do |minutes|
      [0, 30, 59].each do |seconds|
        travel_to base_time + minutes.minutes + seconds.seconds do
          assert_equal expected_window, current_hourly_window,
            "Failed at #{minutes} minutes #{seconds} seconds"
        end
      end
    end
  end

  test "counts reset when moving to next hour window" do
    with_frozen_time("2025-01-15 10:59:59") do
      first_window = current_hourly_window
      @redis.expects(:hget).with(redis_key_for(@api_key), first_window.to_s).returns("99")
      assert_equal 99, @limiter.current_count
      
      # Move to next hour
      travel 1.second # Now at 11:00:00
      second_window = current_hourly_window
      
      assert_not_equal first_window, second_window, "Windows should be different"
      
      @redis.expects(:hget).with(redis_key_for(@api_key), second_window.to_s).returns(nil)
      assert_equal 0, @limiter.current_count
    end
  end

  test "reset_time returns seconds until next hour boundary" do
    # Test at various times within an hour
    test_cases = [
      ["2025-01-15 10:00:00", 3600],  # Beginning of hour
      ["2025-01-15 10:00:01", 3599],  # 1 second into hour
      ["2025-01-15 10:30:00", 1800],  # Half hour
      ["2025-01-15 10:45:00", 900],   # Quarter to
      ["2025-01-15 10:59:00", 60],    # 1 minute left
      ["2025-01-15 10:59:59", 1],     # 1 second left
    ]
    
    test_cases.each do |time_string, expected_seconds|
      travel_to Time.zone.parse(time_string) do
        assert_equal expected_seconds, @limiter.reset_time,
          "Failed for time #{time_string}"
      end
    end
  end

  test "reset_time works correctly across time zone changes" do
    # Test with different time zones
    original_zone = Time.zone
    
    begin
      Time.zone = "America/New_York"
      travel_to Time.zone.parse("2025-01-15 10:30:00") do
        assert_equal 1800, @limiter.reset_time
      end
      
      Time.zone = "Europe/London"
      travel_to Time.zone.parse("2025-01-15 15:45:00") do
        assert_equal 900, @limiter.reset_time
      end
    ensure
      Time.zone = original_zone
    end
  end

  # ===== Usage Information Tests =====

  test "usage_info returns complete hash with all expected keys" do
    with_frozen_time do
      stub_redis_request_count(25)
      
      info = @limiter.usage_info
      
      assert_kind_of Hash, info
      assert_equal [:current_count, :rate_limit, :remaining, :reset_time, :tier], info.keys.sort
      assert_equal 25, info[:current_count]
      assert_equal 100, info[:rate_limit]
      assert_equal 75, info[:remaining]
      assert_equal 3600, info[:reset_time]
      assert_equal :standard, info[:tier]
    end
  end

  test "usage_info remaining count never goes negative" do
    with_frozen_time do
      stub_redis_request_count(200)  # Way over limit
      
      info = @limiter.usage_info
      
      assert_equal 0, info[:remaining], "Remaining should be 0, not negative"
    end
  end

  test "usage_info works correctly at rate limit boundary" do
    with_frozen_time do
      stub_redis_request_count(100)  # Exactly at limit
      
      info = @limiter.usage_info
      
      assert_equal 100, info[:current_count]
      assert_equal 0, info[:remaining]
    end
  end

  # ===== Class Method Tests =====

  test "self.usage_for creates limiter instance and returns usage without incrementing" do
    with_frozen_time do
      stub_redis_request_count(30)
      @redis.expects(:hincrby).never  # Should not increment
      
      info = ApiRateLimiter.usage_for(@api_key)
      
      assert_equal 30, info[:current_count]
      assert_equal 100, info[:rate_limit]
      assert_equal 70, info[:remaining]
    end
  end

  test "self.limit returns ApiRateLimiter instance in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    
    limiter = ApiRateLimiter.limit(@api_key)
    
    assert_instance_of ApiRateLimiter, limiter
  end

  test "self.limit returns NoopApiRateLimiter instance in self-hosted mode" do
    with_self_hosting do
      limiter = ApiRateLimiter.limit(@api_key)
      
      assert_instance_of NoopApiRateLimiter, limiter
    end
  end

  # ===== Redis Key Tests =====

  test "redis_key uses correct format with API key ID" do
    key = @limiter.send(:redis_key)
    assert_equal "api_rate_limit:#{@api_key.id}", key
  end

  test "redis_key is consistent for same API key" do
    key1 = @limiter.send(:redis_key)
    key2 = ApiRateLimiter.new(@api_key).send(:redis_key)
    
    assert_equal key1, key2
  end

  # ===== Concurrent Request Tests =====

  test "handles multiple rapid increments correctly" do
    with_frozen_time do
      window = current_hourly_window
      
      # Simulate 5 rapid requests
      5.times do |i|
        @redis.expects(:multi).yields(@redis)
        @redis.expects(:hincrby).with(redis_key_for(@api_key), window.to_s, 1).returns(i + 1)
        @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
        
        @limiter.increment_request_count!
      end
    end
  end

  test "rate limiting works correctly at hour boundaries" do
    # Start 5 seconds before hour boundary
    travel_to Time.zone.parse("2025-01-15 10:59:55") do
      first_window = current_hourly_window
      
      # Make requests up to the limit
      @redis.expects(:hget).with(redis_key_for(@api_key), first_window.to_s).returns("99")
      assert_not @limiter.rate_limit_exceeded?
      
      # One more request puts us at limit
      expect_redis_increment
      @limiter.increment_request_count!
      
      # Now we're at the limit
      @redis.expects(:hget).with(redis_key_for(@api_key), first_window.to_s).returns("100")
      assert @limiter.rate_limit_exceeded?
      
      # Wait for new hour
      travel 10.seconds  # Now at 11:00:05
      second_window = current_hourly_window
      
      # New hour, fresh limit
      @redis.expects(:hget).with(redis_key_for(@api_key), second_window.to_s).returns(nil)
      assert_not @limiter.rate_limit_exceeded?
    end
  end

  # ===== Error Handling Tests =====

  test "handles Redis connection errors during read operations" do
    with_frozen_time do
      @redis.expects(:hget).raises(Redis::ConnectionError, "Connection lost")
      
      assert_raises(Redis::ConnectionError) do
        @limiter.current_count
      end
    end
  end

  test "handles Redis timeout errors" do
    with_frozen_time do
      @redis.expects(:multi).raises(Redis::TimeoutError, "Timeout waiting for Redis")
      
      assert_raises(Redis::TimeoutError) do
        @limiter.increment_request_count!
      end
    end
  end

  # ===== Large Number Tests =====

  test "handles very large request counts correctly" do
    with_frozen_time do
      large_count = "999999999"
      @redis.stubs(:hget).returns(large_count)
      
      assert_equal 999999999, @limiter.current_count
      assert @limiter.rate_limit_exceeded?
    end
  end

  # ===== NoopApiRateLimiter Tests =====

  class NoopApiRateLimiterTest < ActiveSupport::TestCase
    setup do
      @api_key = api_keys(:active_key)
      @limiter = NoopApiRateLimiter.new(@api_key)
    end

    test "rate_limit_exceeded? always returns false" do
      assert_not @limiter.rate_limit_exceeded?
      
      # Even after "incrementing" many times
      1000.times { @limiter.increment_request_count! }
      assert_not @limiter.rate_limit_exceeded?
    end

    test "increment_request_count! does not raise errors" do
      assert_nothing_raised do
        @limiter.increment_request_count!
      end
    end

    test "current_count always returns 0" do
      assert_equal 0, @limiter.current_count
      
      @limiter.increment_request_count!
      assert_equal 0, @limiter.current_count
    end

    test "rate_limit returns infinity" do
      assert_equal Float::INFINITY, @limiter.rate_limit
    end

    test "reset_time always returns 0" do
      assert_equal 0, @limiter.reset_time
    end

    test "usage_info returns expected structure with infinite limits" do
      info = @limiter.usage_info
      
      assert_equal({
        current_count: 0,
        rate_limit: Float::INFINITY,
        remaining: Float::INFINITY,
        reset_time: 0,
        tier: :noop
      }, info)
    end

    test "self.usage_for class method works correctly" do
      info = NoopApiRateLimiter.usage_for(@api_key)
      
      assert_equal 0, info[:current_count]
      assert_equal Float::INFINITY, info[:rate_limit]
      assert_equal Float::INFINITY, info[:remaining]
      assert_equal 0, info[:reset_time]
      assert_equal :noop, info[:tier]
    end

    test "NoopApiRateLimiter is used in self-hosted mode via ApiRateLimiter.limit" do
      with_self_hosting do
        limiter = ApiRateLimiter.limit(@api_key)
        
        assert_instance_of NoopApiRateLimiter, limiter
        assert_not limiter.rate_limit_exceeded?
        assert_equal Float::INFINITY, limiter.rate_limit
      end
    end
  end

  # ===== Integration-style Tests =====

  test "complete rate limiting flow from zero to exceeded" do
    with_frozen_time do
      window = current_hourly_window
      
      # Start with no requests
      @redis.expects(:hget).with(redis_key_for(@api_key), window.to_s).returns(nil)
      assert_equal 0, @limiter.current_count
      assert_not @limiter.rate_limit_exceeded?
      
      # Make some requests
      50.times do |i|
        @redis.expects(:multi).yields(@redis)
        @redis.expects(:hincrby).with(redis_key_for(@api_key), window.to_s, 1).returns(i + 1)
        @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
        @limiter.increment_request_count!
      end
      
      # Check midway
      @redis.expects(:hget).with(redis_key_for(@api_key), window.to_s).returns("50")
      info = @limiter.usage_info
      assert_equal 50, info[:current_count]
      assert_equal 50, info[:remaining]
      assert_not @limiter.rate_limit_exceeded?
      
      # Continue to limit
      50.times do |i|
        @redis.expects(:multi).yields(@redis)
        @redis.expects(:hincrby).with(redis_key_for(@api_key), window.to_s, 1).returns(50 + i + 1)
        @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
        @limiter.increment_request_count!
      end
      
      # Now at limit
      @redis.expects(:hget).with(redis_key_for(@api_key), window.to_s).returns("100")
      assert @limiter.rate_limit_exceeded?
      
      info = @limiter.usage_info
      assert_equal 100, info[:current_count]
      assert_equal 0, info[:remaining]
    end
  end

  test "rate limiter respects different API keys independently" do
    with_frozen_time do
      api_key1 = api_keys(:active_key)
      api_key2 = api_keys(:one)
      
      limiter1 = ApiRateLimiter.new(api_key1)
      limiter2 = ApiRateLimiter.new(api_key2)
      
      # Different keys should have different Redis keys
      assert_not_equal limiter1.send(:redis_key), limiter2.send(:redis_key)
      
      # Set different counts for each
      window = current_hourly_window
      @redis.expects(:hget).with(redis_key_for(api_key1), window.to_s).returns("50")
      @redis.expects(:hget).with(redis_key_for(api_key2), window.to_s).returns("75")
      
      assert_equal 50, limiter1.current_count
      assert_equal 75, limiter2.current_count
    end
  end
end