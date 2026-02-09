# VL53L0X Distance Sensor - Simple Implementation for PicoRuby

class VL53L0X
  # VL53L0X I2C address
  I2C_ADDRESS = 0x29
  
  # Expected WHO_AM_I value
  CHIP_ID = 0xEE

  # Initialize VL53L0X sensor
  # @param i2c_instance [I2C] Existing I2C instance
  # @param address [Integer] I2C address (default: 0x29)
  # @param read_wait_ms [Integer] wait ms at read distance (default: 30)
  def initialize(i2c_instance, address = I2C_ADDRESS, read_wait_ms = 30)
    @i2c = i2c_instance
    @address = address
    @read_wait_ms = read_wait_ms
    @stop_variable = 0
    @initialized = false
    
    @last_distance = 0
    begin
      # Check chip ID
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

  # Read distance measurement
  # @return [Integer] Distance in millimeters, -1 on error
  def read_distance
    return -1 unless @initialized

    # 1. Start
    start_measurement

    # 2. Wait
    sleep_ms(@read_wait_ms)

    # 3. Get (Checks status, reads data, clears interrupt)
    get_distance
  end

  # Non-Blocking Methods (Polling)
  # ----------------------------------------------------------------
  # Start a single measurement (Non-blocking)
  # Simply triggers the sensor. Does not wait for result.
  # @return [Boolean] true if command sent successfully
  def start_measurement
    return false unless @initialized
    begin
      # SYSRANGE_START
      write_reg(0x00, 0x01)
      true
    rescue
      false
    end
  end

  # Get the latest distance (Non-blocking / Polling)
  # Checks if new data is ready.
  # If ready: reads data, updates @last_distance, clears interrupt, returns new value.
  # If not ready: returns @last_distance immediately.
  # @return [Integer] Distance in millimeters
  def get_distance
    return -1 unless @initialized

    begin
      # Check RESULT_INTERRUPT_STATUS (Register 0x13)
      status = read_reg(0x13, 1)[0]

      # Check bit 0-2 (0x07) for New Sample Ready
      if (status & 0x07) != 0
        # --- Data is Ready ---

        # Read distance data (Register 0x1E)
        data = read_reg(0x1E, 2)
        dist = (data[0] << 8) | data[1]

        # Clear interrupt to allow next measurement (Register 0x0B)
        write_reg(0x0B, 0x01)

        # Update last_distance if valid
        # 8190 indicates out of range or error
        if dist < 8190
          @last_distance = dist
        else
          # Keep previous value or set to -1 depending on preference.
          # Here we set -1 to indicate invalid reading.
          @last_distance = -1
        end
      end
      
      # Return the latest known distance (new or old)
      @last_distance
    rescue
      @last_distance
    end
  end

  # Check if sensor is ready
  # @return [Boolean] true if sensor is initialized
  def ready?
    @initialized
  end

  private

  # Write to register
  # @param reg [Integer] Register address
  # @param data [Integer] Data to write
  def write_reg(reg, data)
    result = @i2c.write(@address, reg, data, timeout: 2000)
    unless result > 0
      raise IOError, "VL53L0X write failed (reg: 0x#{reg.to_s(16)}, data: 0x#{data.to_s(16)})"
    end
  end

  # Read from register
  # @param reg [Integer] Register address
  # @param length [Integer] Number of bytes to read
  # @return [Array<Integer>] Array of read data
  def read_reg(reg, length)
    data = @i2c.read(@address, length, reg, timeout: 1000)
    
    if data.nil? || data.empty?
      raise IOError, "VL53L0X read failed (reg: 0x#{reg.to_s(16)}, length: #{length})"
    end
    
    data.bytes
  end
end
