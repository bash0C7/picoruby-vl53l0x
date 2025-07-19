# VL53L0X Distance Sensor - Simple Implementation for PicoRuby

class VL53L0X
  # VL53L0X I2C address
  I2C_ADDRESS = 0x29
  
  # Expected WHO_AM_I value
  CHIP_ID = 0xEE

  # Initialize VL53L0X sensor
  # @param i2c_instance [I2C] Existing I2C instance
  # @param address [Integer] I2C address (default: 0x29)
  def initialize(i2c_instance, address = I2C_ADDRESS)
    @i2c = i2c_instance
    @address = address
    @stop_variable = 0
    @initialized = false
    
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
    
    begin
      # Start measurement
      write_reg(0x00, 0x01)
      
      # Fixed time wait
      sleep_ms(30)
      
      # Read distance
      data = read_reg(0x1E, 2)
      distance_mm = (data[0] << 8) | data[1]
      
      # Clear interrupt
      write_reg(0x0B, 0x01)
      
      # 8190 indicates out of range error
      return -1 if distance_mm >= 8190
      
      distance_mm
    rescue
      -1
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
