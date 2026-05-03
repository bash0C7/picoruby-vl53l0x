# test/vl53l0x_test.rb
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)

# PicoRuby shim: sleep_ms is a Kernel-level method on-device.
# Under CRuby it does not exist; stub it as a no-op for host tests.
module Kernel
  def sleep_ms(_ms); end
end

# PicoRuby shim: Machine.uptime_us is the on-device monotonic microsecond
# clock. _now_ms calls it directly. Stub it for host tests.
unless defined?(Machine)
  module Machine
    def self.uptime_us
      0
    end
  end
end

require "test/unit"

class FakeI2C
  attr_reader :writes, :reads

  def initialize
    @writes = []
    @reads = []
    @read_queue = []
  end

  # Queue a canned response (a String of bytes) for the next read call.
  def queue_read(bytes)
    @read_queue << bytes
  end

  def write(addr, *args, **opts)
    @writes << { addr: addr, args: args, opts: opts }
    args.size
  end

  def read(addr, length, reg = nil, **opts)
    @reads << { addr: addr, length: length, reg: reg, opts: opts }
    @read_queue.shift || ("\x00".b * length)
  end
end

# --- harness sanity ---

class HarnessTest < Test::Unit::TestCase
  def test_fake_i2c_records_writes
    i2c = FakeI2C.new
    i2c.write(0x29, 0x00, 0x01)
    assert_equal 1, i2c.writes.size
    assert_equal 0x29, i2c.writes.first[:addr]
  end

  def test_fake_i2c_serves_queued_reads
    i2c = FakeI2C.new
    i2c.queue_read("\xEE".b)
    bytes = i2c.read(0x29, 1, 0xC0)
    assert_equal "\xEE".b, bytes
    assert_equal 1, i2c.reads.size
  end
end

require "vl53l0x"

# Helper: queue the canned bytes that VL53L0X#initialize consumes
# (WHO_AM_I read at 0xC0 returning CHIP_ID, then stop_variable read at 0x91).
module InitHelper
  def queue_init_reads(i2c)
    i2c.queue_read("\xEE".b)  # WHO_AM_I = CHIP_ID
    i2c.queue_read("\x42".b)  # stop_variable (any byte)
  end
end

# --- initialize / ready? ---

class VL53L0XInitTest < Test::Unit::TestCase
  include InitHelper

  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @vl = VL53L0X.new(@i2c)
  end

  def test_ready_after_successful_init
    assert_equal true, @vl.ready?
  end

  def test_who_am_i_is_first_read_at_register_0xC0
    first = @i2c.reads.first
    assert_equal 0x29, first[:addr]
    assert_equal 0xC0, first[:reg]
    assert_equal 1,    first[:length]
  end

  def test_stop_variable_read_at_register_0x91
    assert(@i2c.reads.any? { |r| r[:reg] == 0x91 },
      "init must read stop_variable at register 0x91")
  end

  def test_latest_is_nil_after_init
    assert_nil @vl.latest_distance
  end

  def test_fresh_is_false_after_init
    assert_equal false, @vl.fresh?
  end

  def test_default_sampler_interval_is_33ms
    assert_equal 33, @vl.instance_variable_get(:@sampler_interval_ms)
  end

  def test_sampler_task_is_nil_after_init
    assert_nil @vl.instance_variable_get(:@sampler_task)
  end

  def test_sampler_running_is_false_after_init
    assert_equal false, @vl.instance_variable_get(:@sampler_running)
  end
end

class VL53L0XInitFailureTest < Test::Unit::TestCase
  def test_ready_false_on_who_am_i_mismatch
    i2c = FakeI2C.new
    i2c.queue_read("\x00".b)  # wrong CHIP_ID
    vl = VL53L0X.new(i2c)
    assert_equal false, vl.ready?
  end
end

class VL53L0XCustomAddressTest < Test::Unit::TestCase
  include InitHelper

  def test_init_uses_custom_address
    i2c = FakeI2C.new
    queue_init_reads(i2c)
    vl = VL53L0X.new(i2c, 0x52)
    assert_equal true, vl.ready?
    assert(i2c.reads.all?  { |r| r[:addr] == 0x52 })
    assert(i2c.writes.all? { |w| w[:addr] == 0x52 })
  end
end

# --- blocking read_distance ---

class VL53L0XReadDistanceTest < Test::Unit::TestCase
  include InitHelper

  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @vl = VL53L0X.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_returns_distance_in_mm
    @i2c.queue_read("\x01\x2C".b)  # 0x012C = 300
    assert_equal 300, @vl.read_distance
  end

  def test_triggers_measurement_with_write_to_register_0x00
    @i2c.queue_read("\x00\x64".b)
    @vl.read_distance
    first = @i2c.writes.first
    assert_equal 0x00, first[:args][0]
    assert_equal 0x01, first[:args][1]
  end

  def test_reads_result_at_register_0x1E_with_2_bytes
    @i2c.queue_read("\x00\x64".b)
    @vl.read_distance
    result_read = @i2c.reads.find { |r| r[:reg] == 0x1E }
    assert_not_nil result_read
    assert_equal 2, result_read[:length]
  end

  def test_clears_interrupt_after_read
    @i2c.queue_read("\x00\x64".b)
    @vl.read_distance
    last_write = @i2c.writes.last
    assert_equal 0x0B, last_write[:args][0]
    assert_equal 0x01, last_write[:args][1]
  end

  def test_returns_minus_1_for_out_of_range
    @i2c.queue_read("\x1F\xFE".b)  # 8190 -> out of range
    assert_equal(-1, @vl.read_distance)
  end

  def test_returns_minus_1_when_not_initialized
    i2c = FakeI2C.new
    i2c.queue_read("\x00".b)  # bad CHIP_ID
    vl = VL53L0X.new(i2c)
    assert_equal(-1, vl.read_distance)
  end
end

# --- non-blocking primitives ---

class VL53L0XStartMeasurementTest < Test::Unit::TestCase
  include InitHelper

  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @vl = VL53L0X.new(@i2c)
    @i2c.writes.clear
  end

  def test_writes_0x01_to_register_0x00_and_returns_true
    assert_equal true, @vl.start_measurement
    last = @i2c.writes.last
    assert_equal 0x00, last[:args][0]
    assert_equal 0x01, last[:args][1]
  end

  def test_returns_false_when_not_initialized
    i2c = FakeI2C.new
    i2c.queue_read("\x00".b)
    vl = VL53L0X.new(i2c)
    assert_equal false, vl.start_measurement
  end
end

class VL53L0XReadyToGetDistanceTest < Test::Unit::TestCase
  include InitHelper

  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @vl = VL53L0X.new(@i2c)
    @i2c.reads.clear
  end

  def test_reads_status_register_0x13
    @i2c.queue_read("\x00".b)
    @vl.ready_to_get_distance?
    assert_equal 0x13, @i2c.reads.first[:reg]
  end

  def test_true_when_status_low_three_bits_nonzero
    @i2c.queue_read("\x01".b)
    assert_equal true, @vl.ready_to_get_distance?
  end

  def test_false_when_status_low_three_bits_zero
    @i2c.queue_read("\xF8".b)  # high bits set, low three zero
    assert_equal false, @vl.ready_to_get_distance?
  end
end

class VL53L0XGetDistanceTest < Test::Unit::TestCase
  include InitHelper

  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @vl = VL53L0X.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_reads_register_0x1E_and_returns_distance
    @i2c.queue_read("\x01\x90".b)  # 0x0190 = 400
    assert_equal 400, @vl.get_distance
    assert_equal 0x1E, @i2c.reads.first[:reg]
  end

  def test_clears_interrupt_after_read
    @i2c.queue_read("\x00\x64".b)
    @vl.get_distance
    last = @i2c.writes.last
    assert_equal 0x0B, last[:args][0]
    assert_equal 0x01, last[:args][1]
  end

  def test_returns_minus_1_for_out_of_range
    @i2c.queue_read("\x1F\xFE".b)
    assert_equal(-1, @vl.get_distance)
  end
end

# --- tick (cooperative single-call sampler) ---

class VL53L0XTickTest < Test::Unit::TestCase
  include InitHelper

  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @vl = VL53L0X.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_first_tick_acquires_a_sample
    @i2c.queue_read("\x00\x64".b)  # 100mm
    sampled = @vl.tick(1000)
    assert_equal true, sampled
    assert_equal true, @vl.fresh?
    assert_equal 100, @vl.latest_distance
  end

  def test_tick_within_default_interval_is_noop
    @i2c.queue_read("\x00\x64".b)
    @vl.tick(1000)
    @i2c.queue_read("\x00\xC8".b)
    assert_equal false, @vl.tick(1010), "10ms < 33ms default"
    # No second measurement triggered
    triggers = @i2c.writes.count { |w| w[:args][0] == 0x00 && w[:args][1] == 0x01 }
    assert_equal 1, triggers
  end

  def test_tick_after_interval_acquires_new_sample
    @i2c.queue_read("\x00\x64".b)
    @vl.tick(1000)
    @i2c.queue_read("\x00\xC8".b)  # 200mm
    assert_equal true, @vl.tick(1100)
    assert_equal 200, @vl.latest_distance
  end

  def test_configure_sampling_changes_interval
    @vl.configure_sampling(interval_ms: 100)
    @i2c.queue_read("\x00\x64".b)
    @vl.tick(1)
    @i2c.queue_read("\x00\xC8".b)
    assert_equal false, @vl.tick(50),  "still within 100ms"
    @i2c.queue_read("\x01\x2C".b)
    assert_equal true,  @vl.tick(150), "now beyond 100ms"
  end

  def test_tick_skips_interval_check_when_now_ms_is_zero
    # On femtoruby Machine.uptime_us == 0; the now_ms > 0 guard must skip
    # interval gating so samples flow continuously.
    @i2c.queue_read("\x00\x64".b)
    @vl.tick(0)
    @i2c.queue_read("\x00\xC8".b)
    assert_equal true, @vl.tick(0), "interval check must be skipped when now_ms == 0"
    assert_equal 200, @vl.latest_distance
  end

  def test_tick_clears_interrupt_after_read
    @i2c.queue_read("\x00\x64".b)
    @vl.tick(1000)
    last = @i2c.writes.last
    assert_equal 0x0B, last[:args][0]
    assert_equal 0x01, last[:args][1]
  end
end
