# picoruby-vl53l0x — Repo-Local Rules for Claude Code

This is a **PicoRuby Runtime Gem** following upstream `picoruby/picoruby`
conventions. All logic is pure Ruby. There is no C extension and none should
be added.

## Public API contract — DO NOT BREAK

The following surface is frozen:

- `VL53L0X.new(i2c)`, `VL53L0X.new(i2c, address)`, `VL53L0X.new(i2c, address, read_wait_ms)`
- `vl53l0x.ready?` → Boolean
- `vl53l0x.read_distance` → Integer (mm or -1)
- `vl53l0x.start_measurement` → Boolean
- `vl53l0x.ready_to_get_distance?` → Boolean
- `vl53l0x.get_distance` → Integer (mm or -1)

## PicoRuby compatibility

Per `~/CLAUDE.md`, **avoid** these in `mrblib/*.rb`:

- `defined?` (use `Object.const_defined?(:Sym)` instead)
- `Hash#fetch`
- `String#reverse`, `String#rjust`
- inline `rescue`
- `proc`, `lambda`

`sleep_ms` is the cooperative-yield delay (`mrubyc/src/rrt0.c:1507`). Use it
freely — it allows other Tasks to run during the wait.

## Task-spawn pattern (dual-engine)

For any async feature, use the same pattern as picoruby-mpu6886:

```ruby
if RUBY_ENGINE == "mruby/c"
  $__vl53l0x_sampler_target = self
  mrb = PicoRubyVM::InstructionSequence.compile(
    '$__vl53l0x_sampler_target._run_sampler_loop'
  ).to_binary
  task = Task.create(mrb)
  task&.run
else
  vl = self
  task = Task.new { vl._run_sampler_loop }
end
```

## Tick design — single-call cooperative cycle

`tick` performs ONE full measurement cycle per call, mirroring the proven
`_run_sampler_loop` pattern:

```ruby
start_measurement → sleep_ms(TIMING_BUDGET_DEFAULT) → @latest = get_distance → return true
```

**Do NOT split this across multiple method calls with a state machine.** A
2-call `:idle` / `:measuring` design was tried and failed in main-Task context
on mruby/c — instance-variable state did not survive the `sleep_ms` boundary
when the method returned and was re-entered. The single-call form keeps the
trigger → wait → read sequence in one contiguous execution, identical to the
working `_run_sampler_loop`.

**Do NOT use `ready_to_get_distance?` in `tick`.** Register 0x13
(RESULT_INTERRUPT_STATUS_GPIO) requires `REG_SYSTEM_INTERRUPT_CONFIG_GPIO
(0x0A) = 0x04` during init. This minimal driver omits that, so register 0x13
never fires.

**Do NOT use `Machine.uptime_us` for measurement timing in `tick`.**
On femtoruby (mruby/c), `Machine.uptime_us` always returns 0. `sleep_ms` is
the only reliable wait. The `now_ms > 0` guard in the interval check
correctly skips time-based gating on femtoruby.

## Sampler timing

`DEFAULT_SAMPLER_INTERVAL_MS = TIMING_BUDGET_DEFAULT = 33`. In `_run_sampler_loop`,
the sequence is `start_measurement → sleep_ms(interval_ms) → get_distance`. The
`interval_ms` must be ≥ 33ms so the measurement completes before `get_distance`
is called. Do not reduce this below 33.

## Machine.uptime_us constraint

`_now_ms` calls `Machine.uptime_us / 1000`. Only call it from the main Task
context (inside `tick`). Calling `Machine.uptime_us` from within a background
Task causes silent Task death on mruby/c. `_run_sampler_loop` must NOT call `_now_ms`.

## Tests

No automated test suite currently exists. Validate changes via:
- On-device smoke test with ATOM Matrix (blocking `read_distance`)
- On-device async smoke test (tick or start_sampling + latest_distance)

Combat-proof location: `~/dev/src/github.com/bash0C7/picoruby-recipes/components/R2P2-ESP32/storage/home/`

## Git

- Conventional Commits: `feat` / `fix` / `docs` / `test` / `refactor` / `chore`
- Imperative mood, English only
- Per `~/CLAUDE.md` TDD discipline, RED / GREEN / REFACTOR are independent commits
