# picoruby-vl53l0x

A pure Ruby implementation of VL53L0X distance sensor driver for PicoRuby.

## Installation

Add this line to your PicoRuby build configuration (`picoruby/build_config/xtensa-esp.rb`):

```ruby
conf.gem github: 'bash0C7/picoruby-vl53l0x', branch: 'main'
```

## Dependencies

- `picoruby-i2c`: I2C communication library (included in PicoRuby)

## Quick Start (Blocking Mode)

This is the simplest way to use the sensor. The `read_distance` method waits until the measurement is complete before returning.

```ruby
require 'i2c'
require 'vl53l0x'

# Initialize I2C (for ATOM Matrix)
i2c = I2C.new(
  unit: :ESP32_I2C0,
  frequency: 100_000,
  sda_pin: 25,
  scl_pin: 21
)

# Initialize VL53L0X sensor
vl53l0x = VL53L0X.new(i2c)

# Check if sensor is ready
if vl53l0x.ready?
  # Read distance measurement (Blocks for ~30ms)
  distance = vl53l0x.read_distance
  if distance > 0
    puts "Distance: #{distance}mm"
  else
    puts "Out of range or error"
  end
else
  puts "Sensor initialization failed"
end

## Advanced Usage (Non-Blocking Mode)

If you need to perform other tasks (like UI updates or handling other sensors) while the VL53L0X is measuring, use the non-blocking methods.

1. **`start_measurement`**: Triggers a new measurement and returns immediately.
2. **`get_distance`**: Checks if data is ready. If yes, it updates and returns the new value. If no, it returns the previous value.

```ruby
# Start the first measurement
vl53l0x.start_measurement

loop do
  # 1. Retrieve the latest distance (Does not block)
  distance = vl53l0x.get_distance
  puts "Distance: #{distance}mm"

  # 2. Trigger the next measurement
  vl53l0x.start_measurement

  # 3. Perform other tasks here...
  # (e.g., Update LED matrix, check buttons, network request)

  # 4. Wait according to the timing budget (approx 33ms for default)
  sleep_ms(VL53L0X::TIMING_BUDGET_DEFAULT)
end
```

## API Reference

### Initialization

```ruby
# Default I2C address (0x29) and default wait time (30ms)
vl53l0x = VL53L0X.new(i2c)

# Custom I2C address
vl53l0x = VL53L0X.new(i2c, 0x30)

# Custom address and wait time for blocking read
vl53l0x = VL53L0X.new(i2c, 0x29, 40)
```

### Methods

| Method | Description | Blocking |
| --- | --- | --- |
| `ready?` | Returns `true` if the sensor is initialized successfully. | No |
| `read_distance` | Triggers measurement, waits, and returns distance (mm). Returns `-1` on error. | **Yes** |
| `start_measurement` | Triggers a Single Shot measurement. Returns `true` on success. | No |
| `get_distance` | Polling method. Returns the latest known distance. If a new measurement is ready, it updates the value; otherwise, it returns the previous value. | No |

## Complete Example

This example demonstrates distance monitoring with the VL53L0X sensor. The sample code was tested and runs on ATOM Matrix:

```ruby
# VL53L0X distance sensor test - ATOM Matrix configuration
require 'i2c'
require 'vl53l0x'

puts "VL53L0X distance sensor test started"

# Initialize I2C with ATOM Matrix configuration
i2c = I2C.new(
  unit: :ESP32_I2C0,
  frequency: 100_000,
  sda_pin: 25,
  scl_pin: 21,
  timeout: 2000
)

puts "I2C config: ESP32_I2C0, SDA:25, SCL:21"

# Initialize VL53L0X sensor
vl53l0x = VL53L0X.new(i2c)

if vl53l0x.ready?
  puts "VL53L0X sensor initialized successfully"
  puts "Range: 30mm - 2000mm"
else
  puts "Failed to initialize VL53L0X sensor"
  puts "Check connections and power supply"
  exit
end

puts "Starting distance measurements..."
puts "---"

# Continuous distance reading loop
loop do
  # Blocking call (simple)
  distance = vl53l0x.read_distance
  
  if distance > 0
    # Categorize distance ranges
    status = case distance
             when 0..50
               "[Very Close]"
             when 51..200
               "[Close]"
             when 201..500
               "[Medium]"
             when 501..1000
               "[Far]"
             else
               "[Very Far]"
             end
    
    puts "Distance: #{distance}mm #{status}"
  else
    puts "Out of range or measurement error"
  end
  
  sleep_ms(200)  # 200ms between readings
end
```

## Technical Details

### VL53L0X Specifications

see: https://www.switch-science.com/products/5219

### Error Conditions

The sensor returns `-1` when:

* Sensor is not properly initialized (chip ID mismatch)
* I2C communication fails
* Distance is out of measurable range (≥8190mm)
* Target is too close (<30mm)
* Target is highly reflective or transparent

## Error Handling

The library handles common error conditions gracefully:

```ruby
begin
  vl53l0x = VL53L0X.new(i2c)
  
  unless vl53l0x.ready?
    puts "Sensor initialization failed"
    puts "Possible causes:"
    puts "- Incorrect wiring (SDA/SCL)"
    puts "- Power supply issues"
    puts "- I2C address conflict"
    exit
  end
  
  distance = vl53l0x.read_distance
  case distance
  when -1
    puts "Measurement failed or out of range"
  when 0..29
    puts "Target too close (minimum: 30mm)"
  else
    puts "Distance: #{distance}mm"
  end
  
rescue IOError => e
  puts "I2C communication error: #{e.message}"
  puts "Check connections and try again"
rescue => e
  puts "Unexpected error: #{e.message}"
end
```

## Troubleshooting

### Common Issues

1. **Sensor not detected**
* Check VCC (3.3V), GND, SDA, SCL connections
* Verify I2C address (0x29)
* Check pull-up resistors on SDA/SCL

2. **Inconsistent readings**
* Ensure stable power supply
* Check for electromagnetic interference
* Verify target surface is not highly reflective

3. **Out of range errors**
* Target may be closer than 30mm
* Target may be farther than 2000mm
* Try different target surface (matte, non-reflective)

### Wiring Example (ATOM Matrix)

```
VL53L0X -> ATOM Matrix
VCC     -> 3.3V
GND     -> GND
SDA     -> GPIO 25
SCL     -> GPIO 21
```

## License

MIT
