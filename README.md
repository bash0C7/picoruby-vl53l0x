# picoruby-vl53l0x

A pure Ruby implementation of VL53L0X distance sensor driver for PicoRuby.

> **Compatibility:** the public API of the original v0 release
> (`VL53L0X.new(i2c)` + `vl53l0x.ready?` + `vl53l0x.read_distance`) is
> preserved exactly. Existing code keeps working without changes.

## Installation

Add this line to your PicoRuby build configuration (`picoruby/build_config/xtensa-esp.rb`):

```ruby
conf.gem github: 'bash0C7/picoruby-vl53l0x', branch: 'main'
```

## Dependencies

- `picoruby-i2c`: I2C communication library (included in PicoRuby)

## Quick Start

The original blocking API. `read_distance` triggers a measurement, waits for
completion, and returns the distance.

```ruby
require 'i2c'
require 'vl53l0x'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 25, scl_pin: 21)
vl53l0x = VL53L0X.new(i2c)

if vl53l0x.ready?
  distance = vl53l0x.read_distance   # mm, or -1 on out-of-range / error
  puts "Distance: #{distance}mm" if distance > 0
end
```

## Experimental APIs (v0.1.0)

> The APIs in this section are experimental in v0.1.0 and may change before
> v1.0.0. Only the Quick Start above is the stable contract.
>
> Three non-blocking acquisition strategies are available. Pick one per
> application — they all share the same I2C bus without mutex protection.

### Manual non-blocking primitives

Trigger once, poll for readiness, read the result yourself:

```ruby
vl53l0x.start_measurement

loop do
  if vl53l0x.ready_to_get_distance?
    distance = vl53l0x.get_distance
    puts "Distance: #{distance}mm"
    vl53l0x.start_measurement
  end
  # other work here...
  sleep_ms 5
end
```

| Method | Description |
|---|---|
| `start_measurement` | Trigger a single-shot measurement; returns Boolean |
| `ready_to_get_distance?` | Poll whether result is available; returns Boolean |
| `get_distance` | Read result and clear interrupt; returns Integer (mm) or `-1` |

> **Note:** `ready_to_get_distance?` reads register `0x13`
> (`RESULT_INTERRUPT_STATUS_GPIO`). This minimal driver does not configure
> `REG_SYSTEM_INTERRUPT_CONFIG_GPIO` (`0x0A`), so depending on the chip
> revision the status may not fire reliably — prefer the cooperative `tick`
> or background sampler below for production code.

### Tick-driven sampler

Call `tick` from your main loop. Each call performs one full measurement
cycle (`start_measurement → sleep_ms(33) → get_distance`) — the `sleep_ms`
cooperatively yields, so other Tasks run during the wait.

```ruby
vl53l0x = VL53L0X.new(i2c)
vl53l0x.configure_sampling(interval_ms: 33)  # optional; 33ms default

loop do
  if vl53l0x.tick
    dist = vl53l0x.latest_distance
    puts "Distance: #{dist}mm" if dist
  end
end
```

`tick` returns `true` when a fresh distance has been stored. `fresh?` /
`latest_distance` are also available:

```ruby
loop do
  vl53l0x.tick
  puts vl53l0x.latest_distance if vl53l0x.fresh?
end
```

### Background Task sampler

Spawn a background Task that keeps the cached distance fresh while your main
loop does other work (LED, UART, display).

```ruby
vl53l0x = VL53L0X.new(i2c)
vl53l0x.start_sampling(interval_ms: 33)  # ~30 Hz background sampling

loop do
  dist = vl53l0x.latest_distance   # no I2C from this thread
  puts "Distance: #{dist}mm" if dist
  sleep_ms 200                      # main loop runs slowly; samples keep flowing
end

vl53l0x.stop_sampling
```

Cached accessors (require prior `start_sampling` or `tick`):

```ruby
vl53l0x.fresh?            # true once at least one sample has been cached
vl53l0x.latest_distance   # last distance (mm), or nil
```

Notes:
- Works on both mruby/c (R2P2-ESP32) and microruby — the gem detects via `RUBY_ENGINE`.
- Mixing the background sampler with synchronous `read_distance` calls is
  undefined; pick one strategy per application.

## API Reference

### Stable

```ruby
vl53l0x = VL53L0X.new(i2c)              # default address 0x29
vl53l0x = VL53L0X.new(i2c, 0x30)        # custom I2C address
vl53l0x = VL53L0X.new(i2c, 0x29, 40)   # custom address and blocking wait time
```

| Method | Description | Blocking |
|---|---|---|
| `ready?` | Returns `true` if initialized successfully | No |
| `read_distance` | Trigger, wait, read; returns distance (mm) or `-1` | **Yes (~30ms)** |

### Experimental

| Method | Description |
|---|---|
| `start_measurement` | Trigger a single-shot measurement (Boolean) |
| `ready_to_get_distance?` | Poll status register 0x13 (Boolean; see caveat above) |
| `get_distance` | Read latest result + clear interrupt (Integer mm or `-1`) |
| `configure_sampling(interval_ms:)` | Set interval for `tick` / `start_sampling` (default: 33ms) |
| `tick(now_ms = nil)` | Cooperative tick; one call = one sample (~33ms cooperative wait); returns `true` on fresh sample |
| `fresh?` | `true` once at least one sample has been cached |
| `latest_distance` | Last cached distance (mm), or `nil` if never sampled |
| `start_sampling(interval_ms:)` | Spawn background sampling Task; idempotent |
| `stop_sampling` | Halt background sampling Task |

### Constants

| Constant | Value | Description |
|---|---|---|
| `I2C_ADDRESS` | `0x29` | Default I2C address |
| `TIMING_BUDGET_DEFAULT` | `33` | Single-shot timing budget (ms) |
| `DEFAULT_SAMPLER_INTERVAL_MS` | `33` | Default `tick` / `start_sampling` interval |

## Technical Details

### VL53L0X Specifications

see: https://www.switch-science.com/products/5219

### Error Conditions

`read_distance` and `get_distance` return `-1` when:

- Sensor is not properly initialized (chip ID mismatch)
- I2C communication fails
- Distance is out of measurable range (≥8190mm)
- Target is too close (<30mm)
- Target is highly reflective or transparent

`latest_distance` returns `nil` before the first sample has been taken.

### Async Timing Note

The VL53L0X single-shot measurement takes ~30ms at the default timing budget.
`DEFAULT_SAMPLER_INTERVAL_MS = 33` is the minimum safe interval; a smaller
value will cause `get_distance` to be called before the measurement
completes. Set a larger value if measurements are unreliable or power
consumption is a concern.

### Wiring Example (ATOM Matrix)

```
VL53L0X -> ATOM Matrix
VCC     -> 3.3V
GND     -> GND
SDA     -> GPIO 25
SCL     -> GPIO 21
```

## Testing

Host-side tests run under CRuby with `test-unit` and a `FakeI2C` double:

```sh
bundle install
bundle exec rake test
```

Tests cover initialization, blocking `read_distance`, the non-blocking
primitives (`start_measurement`, `ready_to_get_distance?`, `get_distance`),
and the cooperative `tick` sampler (interval gating, `configure_sampling`,
femtoruby `now_ms == 0` skip). The background-Task sampler is verified
on hardware (no `Task` under CRuby).

## License

MIT
