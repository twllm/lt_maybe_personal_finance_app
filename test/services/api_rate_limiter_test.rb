require "test_helper"

class ApiRateLimiterTest < ActiveSupport::TestCase
  setup do
    @api_key = api_keys(:active_key)
    @redis = mock("redis")
    Redis.stubs(:new).returns(@redis)
    @limiter = ApiRateLimiter.new(@api_key)
    
    # Set up default Redis behavior
    @redis.stubs(:hget).returns("0")
    @redis.stubs(:multi).yields(@redis)
    @redis.stubs(:hincrby).returns(1)
    @redis.stubs(:expire).returns(true)
  end

  teardown do
    Redis.unstub(:new)
    travel_back
  end

  # Helper methods
  def with_frozen_time(&block)
    # Freeze time at the beginning of an hour for predictable tests
    travel_to Time.zone.parse("2025-01-15 10:00:00"), &block
  end

  def current_hourly_window
    current_time = Time.current.to_i
    (current_time / 3600) * 3600
  end

  def redis_key_for(api_key)
    "api_rate_limit:#{api_key.id}"
  end

  # Rate limit enforcement tests
  test "rate_limit_exceeded? returns false when under limit" do
    @redis.expects(:hget).with(redis_key_for(@api_key), current_hourly_window.to_s).returns("50")
    
    assert_not @limiter.rate_limit_exceeded?
  end

  test "rate_limit_exceeded? returns true when at limit" do
    @redis.expects(:hget).with(redis_key_for(@api_key), current_hourly_window.to_s).returns("100")
    
    assert @limiter.rate_limit_exceeded?
  end

  test "rate_limit_exceeded? returns true when over limit" do
    @redis.expects(:hget).with(redis_key_for(@api_key), current_hourly_window.to_s).returns("150")
    
    assert @limiter.rate_limit_exceeded?
  end

  test "rate limit uses standard tier by default" do
    assert_equal 100, @limiter.rate_limit
  end

  # Request counting tests
  test "increment_request_count! increments count in Redis" do
    with_frozen_time do
      window = current_hourly_window
      
      @redis.expects(:multi).yields(@redis)
      @redis.expects(:hincrby).with(redis_key_for(@api_key), window.to_s, 1).returns(1)
      @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
      
      @limiter.increment_request_count!
    end
  end

  test "current_count returns count for current hour window" do
    with_frozen_time do
      window = current_hourly_window
      
      @redis.expects(:hget).with(redis_key_for(@api_key), window.to_s).returns("42")
      
      assert_equal 42, @limiter.current_count
    end
  end

  test "current_count returns 0 when no requests recorded" do
    with_frozen_time do
      window = current_hourly_window
      
      @redis.expects(:hget).with(redis_key_for(@api_key), window.to_s).returns(nil)
      
      assert_equal 0, @limiter.current_count
    end
  end

  test "counts reset after hour window passes" do
    with_frozen_time do
      # Set count for current hour
      first_window = current_hourly_window
      @redis.expects(:hget).with(redis_key_for(@api_key), first_window.to_s).returns("50")
      assert_equal 50, @limiter.current_count
      
      # Travel to next hour
      travel 1.hour
      second_window = current_hourly_window
      
      # Should query new window
      @redis.expects(:hget).with(redis_key_for(@api_key), second_window.to_s).returns("0")
      assert_equal 0, @limiter.current_count
    end
  end

  # Redis operations tests
  test "uses correct Redis key format" do
    key = @limiter.send(:redis_key)
    assert_equal "api_rate_limit:#{@api_key.id}", key
  end

  test "Redis expiration is set to 7200 seconds (2 hours)" do
    with_frozen_time do
      @redis.expects(:multi).yields(@redis)
      @redis.expects(:hincrby).returns(1)
      @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
      
      @limiter.increment_request_count!
    end
  end

  test "uses Redis multi for atomic operations" do
    with_frozen_time do
      transaction = mock("transaction")
      @redis.expects(:multi).yields(transaction)
      transaction.expects(:hincrby).with(redis_key_for(@api_key), current_hourly_window.to_s, 1)
      transaction.expects(:expire).with(redis_key_for(@api_key), 7200)
      
      @limiter.increment_request_count!
    end
  end

  # Time window calculations tests
  test "reset_time returns seconds until next hour" do
    travel_to Time.zone.parse("2025-01-15 10:15:30") do
      # 44 minutes and 30 seconds until 11:00:00
      expected = 44 * 60 + 30
      assert_equal expected, @limiter.reset_time
    end
  end

  test "reset_time at beginning of hour" do
    travel_to Time.zone.parse("2025-01-15 10:00:00") do
      # 60 minutes until 11:00:00
      assert_equal 3600, @limiter.reset_time
    end
  end

  test "reset_time just before hour boundary" do
    travel_to Time.zone.parse("2025-01-15 10:59:59") do
      # 1 second until 11:00:00
      assert_equal 1, @limiter.reset_time
    end
  end

  test "hourly windows are aligned to the hour" do
    # Test various times within the same hour
    base_time = Time.zone.parse("2025-01-15 10:00:00")
    expected_window = base_time.to_i
    
    [0, 15, 30, 45, 59].each do |minutes|
      travel_to base_time + minutes.minutes do
        assert_equal expected_window, current_hourly_window
      end
    end
  end

  # Usage information tests
  test "usage_info returns all expected fields" do
    with_frozen_time do
      @redis.expects(:hget).with(redis_key_for(@api_key), current_hourly_window.to_s).returns("25")
      
      info = @limiter.usage_info
      
      assert_equal 25, info[:current_count]
      assert_equal 100, info[:rate_limit]
      assert_equal 75, info[:remaining]
      assert_equal 3600, info[:reset_time]
      assert_equal :standard, info[:tier]
    end
  end

  test "usage_info remaining count never goes negative" do
    with_frozen_time do
      @redis.expects(:hget).with(redis_key_for(@api_key), current_hourly_window.to_s).returns("150")
      
      info = @limiter.usage_info
      
      assert_equal 0, info[:remaining]
    end
  end

  # Class methods tests
  test "self.usage_for returns usage without incrementing" do
    with_frozen_time do
      @redis.expects(:hget).with(redis_key_for(@api_key), current_hourly_window.to_s).returns("30")
      @redis.expects(:hincrby).never
      
      info = ApiRateLimiter.usage_for(@api_key)
      
      assert_equal 30, info[:current_count]
      assert_equal 100, info[:rate_limit]
    end
  end

  test "self.limit returns ApiRateLimiter in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    
    limiter = ApiRateLimiter.limit(@api_key)
    assert_instance_of ApiRateLimiter, limiter
  end

  test "self.limit returns NoopApiRateLimiter in self-hosted mode" do
    with_self_hosting do
      limiter = ApiRateLimiter.limit(@api_key)
      assert_instance_of NoopApiRateLimiter, limiter
    end
  end

  # Edge cases tests
  test "handles Redis connection errors gracefully" do
    Redis.unstub(:new)
    Redis.stubs(:new).raises(Redis::CannotConnectError)
    
    assert_raises(Redis::CannotConnectError) do
      ApiRateLimiter.new(@api_key)
    end
  end

  test "handles concurrent increment requests" do
    with_frozen_time do
      window = current_hourly_window
      
      # Simulate multiple concurrent increments
      5.times do |i|
        @redis.expects(:multi).yields(@redis)
        @redis.expects(:hincrby).with(redis_key_for(@api_key), window.to_s, 1).returns(i + 1)
        @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
        
        @limiter.increment_request_count!
      end
    end
  end

  test "handles hour boundary transitions correctly" do
    # Start at 10:59:55
    travel_to Time.zone.parse("2025-01-15 10:59:55") do
      first_window = current_hourly_window
      
      @redis.expects(:hget).with(redis_key_for(@api_key), first_window.to_s).returns("99")
      assert_equal 99, @limiter.current_count
      
      # Increment puts us at the limit
      @redis.expects(:multi).yields(@redis)
      @redis.expects(:hincrby).with(redis_key_for(@api_key), first_window.to_s, 1).returns(100)
      @redis.expects(:expire).with(redis_key_for(@api_key), 7200).returns(true)
      @limiter.increment_request_count!
      
      # Travel to next hour (11:00:05)
      travel 10.seconds
      second_window = current_hourly_window
      
      # New hour should have fresh limit
      @redis.expects(:hget).with(redis_key_for(@api_key), second_window.to_s).returns("0")
      assert_equal 0, @limiter.current_count
      assert_not @limiter.rate_limit_exceeded?
    end
  end

  test "different rate limit tiers" do
    # Test that rate limits are correctly defined
    assert_equal 100, ApiRateLimiter::RATE_LIMITS[:standard]
    assert_equal 1000, ApiRateLimiter::RATE_LIMITS[:premium]
    assert_equal 10000, ApiRateLimiter::RATE_LIMITS[:enterprise]
  end

  # NoopApiRateLimiter tests
  test "NoopApiRateLimiter never enforces rate limits" do
    noop_limiter = NoopApiRateLimiter.new(@api_key)
    
    assert_not noop_limiter.rate_limit_exceeded?
    assert_equal 0, noop_limiter.current_count
    assert_equal Float::INFINITY, noop_limiter.rate_limit
    assert_equal 0, noop_limiter.reset_time
  end

  test "NoopApiRateLimiter increment does nothing" do
    noop_limiter = NoopApiRateLimiter.new(@api_key)
    
    # Should not raise any errors
    assert_nothing_raised do
      noop_limiter.increment_request_count!
    end
    
    # Count should still be 0
    assert_equal 0, noop_limiter.current_count
  end

  test "NoopApiRateLimiter usage_info returns expected structure" do
    noop_limiter = NoopApiRateLimiter.new(@api_key)
    info = noop_limiter.usage_info
    
    assert_equal 0, info[:current_count]
    assert_equal Float::INFINITY, info[:rate_limit]
    assert_equal Float::INFINITY, info[:remaining]
    assert_equal 0, info[:reset_time]
    assert_equal :noop, info[:tier]
  end

  test "NoopApiRateLimiter.usage_for returns usage info" do
    info = NoopApiRateLimiter.usage_for(@api_key)
    
    assert_equal 0, info[:current_count]
    assert_equal Float::INFINITY, info[:rate_limit]
    assert_equal :noop, info[:tier]
  end
end