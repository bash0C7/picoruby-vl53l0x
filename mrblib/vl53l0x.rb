# VL53L0X Distance Sensor - Pure Ruby Implementation for PicoRuby

class VL53L0X
  I2C_ADDRESS = 0x29
  CHIP_ID = 0xEE

  # Default timing budget for single-shot measurement (ms)
  TIMING_BUDGET_DEFAULT = 33

  # Default tick / start_sampling interval. Single source of truth.
  DEFAULT_SAMPLER_INTERVAL_MS = 33

  # Initialize VL53L0X sensor
  # @param i2c_instance [I2C] Existing I2C instance
  # @param address [Integer] I2C address (default: 0x29)
  # @param read_wait_ms [Integer] wait ms at read_distance (default: 30)
  def initialize(i2c_instance, address = I2C_ADDRESS, read_wait_ms = 30)
    @i2c = i2c_instance
    @address = address
    @read_wait_ms = read_wait_ms
    @stop_variable = 0
    @initialized = false
    init_sampler_state

    begin
      who_am_i = read_reg(0xC0, 1)[0]
      return unless who_am_i == CHIP_ID

      write_reg(0x80, 0x01)
      write_reg(0xFF, 0x01)
      write_reg(0x00, 0x00)
      @stop_variable = read_reg(0x91, 1)[0]
      write_reg(0x00, 0x01)
      write_reg(0xFF, 0x00)
      write_reg(0x80, 0x00)

      sleep_ms(100)

      @initialized = true
    rescue
      @initialized = false
    end
  end

  # @return [Boolean] true if sensor is initialized
  def ready?
    @initialized
  end

  # Trigger measurement, wait, and return distance in mm. Blocks ~@read_wait_ms.
  # @return [Integer] Distance in mm, -1 on error or out of range
  def read_distance
    return -1 unless @initialized

    begin
      write_reg(0x00, 0x01)
      sleep_ms(@read_wait_ms)
      data = read_reg(0x1E, 2)
      distance_mm = (data[0] << 8) | data[1]
      write_reg(0x0B, 0x01)
      return -1 if distance_mm >= 8190
      distance_mm
    rescue
      -1
    end
  end

  # Trigger a single-shot measurement without waiting. Non-blocking.
  # @return [Boolean] true if command sent successfully
  def start_measurement
    return false unless @initialized

    begin
      write_reg(0x00, 0x01)
      true
    rescue
      false
    end
  end

  # Poll whether a measurement result is available.
  # @return [Boolean] true if data is ready to read
  def ready_to_get_distance?
    return false unless @initialized

    status = read_reg(0x13, 1)[0]
    (status & 0x07) != 0
  end

  # Read the latest distance result and clear the interrupt. Non-blocking.
  # Call only after ready_to_get_distance? returns true.
  # @return [Integer] Distance in mm, -1 on error or out of range
  def get_distance
    return -1 unless @initialized

    begin
      data = read_reg(0x1E, 2)
      dist = (data[0] << 8) | data[1]
      write_reg(0x0B, 0x01)
      dist < 8190 ? dist : -1
    rescue
      -1
    end
  end

  # --- Async / sampler API ---

  # Configure the sampling interval for both tick() and start_sampling().
  # @param interval_ms [Integer] minimum milliseconds between successive samples
  def configure_sampling(interval_ms: DEFAULT_SAMPLER_INTERVAL_MS)
    @sampler_interval_ms = interval_ms
  end

  # Cooperative tick. Call repeatedly from your main loop.
  #
  # Each call performs one full measurement cycle:
  #   start_measurement -> sleep_ms(TIMING_BUDGET_DEFAULT) -> get_distance
  # The sleep_ms cooperatively yields, allowing other Tasks to run.
  #
  # Mirrors the proven _run_sampler_loop pattern (one continuous flow per
  # sample) instead of splitting across method calls. State-machine designs
  # were tried and proved unreliable in main-Task context on mruby/c.
  #
  # Interval check (sampler_interval_ms) uses now_ms only when it is > 0.
  # On targets where Machine.uptime_us returns 0 the check is skipped and
  # samples flow continuously at ~TIMING_BUDGET_DEFAULT ms per call.
  #
  # @param now_ms [Integer, nil] monotonic millisecond timestamp (nil = auto)
  # @return [Boolean] true when a fresh distance is stored in latest_distance
  def tick(now_ms = nil)
    return false unless @initialized

    now_ms = _now_ms if now_ms.nil?
    if !@latest.nil? && now_ms > 0 && @latest_at_ms > 0
      return false if (now_ms - @latest_at_ms) < @sampler_interval_ms
    end

    return false unless start_measurement
    sleep_ms(TIMING_BUDGET_DEFAULT)
    @latest = get_distance
    @latest_at_ms = now_ms
    true
  end

  # @return [Boolean] true once at least one sample has been cached
  def fresh?
    !@latest.nil?
  end

  # @return [Integer, nil] the most recent distance in mm, or nil if never sampled
  def latest_distance
    @latest
  end

  # Spawn a background Task that measures at @sampler_interval_ms and updates
  # the cached latest_distance. Idempotent: a second call returns the existing Task.
  #
  # Task body: start_measurement → sleep_ms(interval_ms) → get_distance → Task.pass
  # interval_ms must be >= TIMING_BUDGET_DEFAULT (33ms) to allow measurement completion.
  #
  # Dual-engine: mruby/c uses compiled script + Task.create; microruby uses Task.new.
  # Pattern from picoruby-mpu6886 / picoruby-psg.
  #
  # @param interval_ms [Integer] sampling interval in ms (default 33ms)
  # @return [Task] handle to the running sampler
  def start_sampling(interval_ms: DEFAULT_SAMPLER_INTERVAL_MS)
    return @sampler_task if @sampler_task

    @sampler_interval_ms = interval_ms
    @sampler_running = true
    @latest = nil
    @latest_at_ms = 0

    if RUBY_ENGINE == "mruby/c"
      $__vl53l0x_sampler_target = self
      mrb = PicoRubyVM::InstructionSequence.compile(
        '$__vl53l0x_sampler_target._run_sampler_loop'
      ).to_binary
      @sampler_task = Task.create(mrb)
      raise "VL53L0X: failed to create sampler task" if @sampler_task.nil?
      @sampler_task.run
    else
      vl = self
      @sampler_task = Task.new { vl._run_sampler_loop }
    end
    @sampler_task
  end

  # Halt the background sampler and clear the Task handle.
  # Safe to call when no sampler is running.
  def stop_sampling
    return unless @sampler_task

    @sampler_running = false
    @sampler_task.join
    @sampler_task = nil
  end

  # Body of the background sampler Task. Public-by-necessity.
  # DO NOT call directly. Use start_sampling / stop_sampling.
  #
  # Task.pass is load-bearing: without it the mruby/c scheduler cannot give
  # the main Task time between iterations, causing memory pressure / VM OOM.
  def _run_sampler_loop
    interval_ms = @sampler_interval_ms
    while @sampler_running
      if start_measurement
        sleep_ms(interval_ms)
        @latest = get_distance
      end
      Task.pass
    end
  end

  # Monotonic millisecond clock. Only safe to call from main Task context
  # (tick fallback) — calling from a background Task silently kills it on mruby/c.
  def _now_ms
    Machine.uptime_us / 1000
  end

  private

  def init_sampler_state
    @latest = nil
    @latest_at_ms = 0
    @sampler_interval_ms = DEFAULT_SAMPLER_INTERVAL_MS
    @sampler_task = nil
    @sampler_running = false
  end

  def write_reg(reg, data)
    result = @i2c.write(@address, reg, data, timeout: 2000)
    unless result > 0
      raise IOError, "VL53L0X write failed (reg: 0x#{reg.to_s(16)}, data: 0x#{data.to_s(16)})"
    end
  end

  def read_reg(reg, length)
    data = @i2c.read(@address, length, reg, timeout: 1000)
    if data.nil? || data.empty?
      raise IOError, "VL53L0X read failed (reg: 0x#{reg.to_s(16)}, length: #{length})"
    end
    data.bytes
  end
end
