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

The simplest way to use the sensor. `read_distance` triggers a measurement and waits ~30ms before returning.

```ruby
require 'i2c'
require 'vl53l0x'

i2c = I2C.new(
  unit: :ESP32_I2C0,
  frequency: 100_000,
  sda_pin: 25,
  scl_pin: 21
)

vl53l0x = VL53L0X.new(i2c)

if vl53l0x.ready?
  distance = vl53l0x.read_distance
  if distance > 0
    puts "Distance: #{distance}mm"
  else
    puts "Out of range or error"
  end
else
  puts "Sensor initialization failed"
end
```

## Async Usage

Three acquisition strategies are available. Pick one per application — mixing strategies shares the I2C bus without mutex protection.

### 1. Tick-driven sampler (main loop in control)

Call `tick` from your main loop. Each call performs one full measurement cycle:
`start_measurement → sleep_ms(33) → get_distance`. The `sleep_ms` cooperatively
yields, so other Tasks run during the wait.

```ruby
vl53l0x = VL53L0X.new(i2c)
vl53l0x.configure_sampling(interval_ms: 33)  # optional; 33ms is the default

loop do
  if vl53l0x.tick
    dist = vl53l0x.latest_distance
    puts "Distance: #{dist}mm" if dist
  end
end
```

`tick` returns `true` when a fresh distance is stored. Use `fresh?` to gate first access:

```ruby
loop do
  vl53l0x.tick
  puts vl53l0x.latest_distance if vl53l0x.fresh?
end
```

### 2. Background Task sampler (main loop runs freely)

Spawn a background Task that measures continuously while your main loop does other work.

```ruby
vl53l0x = VL53L0X.new(i2c)
vl53l0x.start_sampling(interval_ms: 33)  # Task runs in background

loop do
  dist = vl53l0x.latest_distance   # no I2C; reads shared cache
  puts "Distance: #{dist}mm" if dist
  sleep_ms 200                      # main loop runs slowly; samples keep flowing
end

vl53l0x.stop_sampling
```

Works on both mruby/c (R2P2-ESP32) and microruby. The gem detects via `RUBY_ENGINE`.

### 3. Manual polling (low-level non-blocking)

For fine-grained control — trigger once, poll for readiness, then read:

```ruby
vl53l0x.start_measurement

loop do
  if vl53l0x.ready_to_get_distance?
    distance = vl53l0x.get_distance
    puts "Distance: #{distance}mm"
    vl53l0x.start_measurement    # trigger next measurement
  end

  # other work here...
  sleep_ms 5
end
```

## API Reference

### Initialization

```ruby
vl53l0x = VL53L0X.new(i2c)              # default address 0x29, wait 30ms
vl53l0x = VL53L0X.new(i2c, 0x30)        # custom I2C address
vl53l0x = VL53L0X.new(i2c, 0x29, 40)   # custom address and blocking wait time
```

### Core Methods

| Method | Description | Blocking |
|---|---|---|
| `ready?` | Returns `true` if initialized successfully | No |
| `read_distance` | Trigger, wait, read; returns distance (mm) or `-1` | **Yes (~30ms)** |
| `start_measurement` | Trigger a single-shot measurement | No |
| `ready_to_get_distance?` | Poll whether result is available | No |
| `get_distance` | Read result and clear interrupt | No |

### Async / Sampler Methods

| Method | Description |
|---|---|
| `configure_sampling(interval_ms:)` | Set interval for `tick` / `start_sampling` (default: 33ms) |
| `tick(now_ms = nil)` | Cooperative tick; one call = one sample (~33ms cooperative wait); returns `true` when fresh distance stored |
| `fresh?` | `true` once at least one sample has been cached |
| `latest_distance` | Last cached distance (mm), or `nil` if never sampled |
| `start_sampling(interval_ms:)` | Spawn background Task; idempotent |
| `stop_sampling` | Halt background Task |

### Constants

| Constant | Value | Description |
|---|---|---|
| `TIMING_BUDGET_DEFAULT` | `33` | Default single-shot timing budget (ms) |
| `DEFAULT_SAMPLER_INTERVAL_MS` | `33` | Default `tick` / `start_sampling` interval |
| `I2C_ADDRESS` | `0x29` | Default I2C address |

## Complete Example (ATOM Matrix)

```ruby
require 'i2c'
require 'vl53l0x'

i2c = I2C.new(
  unit: :ESP32_I2C0,
  frequency: 100_000,
  sda_pin: 25,
  scl_pin: 21,
  timeout: 2000
)

vl53l0x = VL53L0X.new(i2c)

unless vl53l0x.ready?
  puts "Failed to initialize VL53L0X"
  exit
end

# Background sampler: main loop free to do LED / display work
vl53l0x.start_sampling(interval_ms: VL53L0X::TIMING_BUDGET_DEFAULT)

loop do
  dist = vl53l0x.latest_distance
  if dist
    status = case dist
             when 0..50   then "[Very Close]"
             when 51..200  then "[Close]"
             when 201..500 then "[Medium]"
             when 501..1000 then "[Far]"
             else               "[Very Far]"
             end
    puts "Distance: #{dist}mm #{status}"
  end
  sleep_ms 200
end
```

## Technical Details

### VL53L0X Specifications

see: https://www.switch-science.com/products/5219

### Error Conditions

Returns `-1` when:

- Sensor is not properly initialized (chip ID mismatch)
- I2C communication fails
- Distance is out of measurable range (≥8190mm)
- Target is too close (<30mm)
- Target is highly reflective or transparent

`latest_distance` returns `nil` before the first sample has been taken.

### Async Timing Note

The VL53L0X single-shot measurement takes ~30ms at the default timing budget.
`DEFAULT_SAMPLER_INTERVAL_MS = 33` is the minimum safe interval. Set a larger
value if measurements are unreliable or power consumption is a concern.

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
