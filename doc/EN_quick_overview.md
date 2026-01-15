# RWPLAY Quick Overview

RWPLAY is a fantasy console powered by a 32-bit RISC-V processor.

## Generations

### RWPLAY 1

#### Specifications

| Parameter | Value |
|-----------|-------|
| RAM | 524.3 KB |
| CPU | 8 MHz |
| Video Modes | 960×540, 640×360, 480×270 |
| Pixel Format | ARGB1555 (16-bit) |
| Audio | Mono, 22.05 kHz |
| Audio Channels | 8 |
| Audio Formats | PCM S16LE, IMA ADPCM |

#### RISC-V Extensions

- **I** - Base Integer Instruction Set
- **M** - Multiplication and Division
- **F** - Single-Precision Floating-Point
- **D** - Double-Precision Floating-Point
- **Zicsr** - CSR Instructions
- **Zifencei** - Instruction-Fetch Fence
- **Zba** - Address Generation
- **Zbb** - Basic Bit Manipulation
- **Zicntr** - Performance Counters

#### Privilege Modes

The processor supports **M** (Machine) and **U** (User) modes with PMP (Physical Memory Protection).

> ⚠️ **Note:** PMP does not work in M-mode.

## Memory Map

| Address | Device | Description |
|---------|--------|-------------|
| `0x0000_1000` | BOOT_INFO | Boot information structure |
| `0x0200_0000` | CLINT | Timer and inter-processor interrupts |
| `0x0C00_0000` | PLIC | External interrupt controller |
| `0x0C00_1000` | GPU | Video output control |
| `0x0C00_2000` | PRNG | Random number generator |
| `0x1000_0000` | UART | Serial port (debug output) |
| `0x3000_0000` | BLITTER | 2D graphics accelerator |
| `0x3000_1000` | GAMEPAD1 | First gamepad |
| `0x3000_1100` | GAMEPAD2 | Second gamepad |
| `0x3000_2000` | AUDIO | Audio subsystem |
| `0x3000_3000` | DMA | Direct Memory Access |
| `0x4000_0000` | FRAMEBUFFER1 | 960×540 framebuffer |
| `0x400F_D200` | FRAMEBUFFER2 | 640×360 framebuffer |
| `0x4016_DA00` | FRAMEBUFFER3 | 480×270 framebuffer |
| `0x8000_0000` | RAM | RAM start |

### BOOT_INFO Structure

```zig
pub const BootInfo = extern struct {
    cpu_frequency: u64,        // CPU frequency in Hz
    ram_size: u32,             // RAM size in bytes
    fps: u32,                  // Frame rate
    free_ram_start: u32,       // Free memory start
    external_storage_size: u32, // External storage size
    nvram_storage_size: u32,   // Non-volatile memory size
};
```

## Boot Images

The console only works with its custom image format - **RWPI** (RWPLAY Image).

### RWPI Format

The format consists of concatenated files. The entry point is `/boot.elf` in ELF format.

### Creating an Image

Use the `imagemaker` utility from the SDK:

```sh
$ imagemaker examples/snake/manifest.json snake.rwpi
```

## Graphics

### Framebuffers

The console has three framebuffers with different resolutions:

| ID | Resolution | Memory Size |
|----|------------|-------------|
| `fb1` | 960×540 | 1,036,800 bytes |
| `fb2` | 640×360 | 460,800 bytes |
| `fb3` | 480×270 | 259,200 bytes |

### ARGB1555 Pixel Format

```
Bit:    15    14-10   9-5    4-0
        A     R       G      B
        1bit  5bit    5bit   5bit
```

- **A** - Alpha (1 = opaque, 0 = transparent)
- **R, G, B** - Color components (0–31)

### GPU Control

```zig
const sdk = @import("sdk");

// Enable framebuffer
sdk.gpu.switchFramebuffer(.fb1);

// Enable VBlank interrupts
sdk.gpu.setVblankInterrupts(true);
```

## Blitter (2D Accelerator)

The Blitter is a hardware 2D accelerator for fast graphics operations.

### Commands

#### Clear Screen

```zig
sdk.blitter.clear(.fb1, .{
    .color = sdk.ARGB1555.fromRGB(0, 0, 0),
});
```

#### Rectangle

```zig
sdk.blitter.rect(.fb1, .{
    .color = sdk.ARGB1555.fromRGB(255, 0, 0),
    .pos = .{ .x = 100, .y = 100 },
    .w = 50,
    .h = 30,
    .origin = .center,
    .mode = .crop,
});
```

#### Circle

```zig
sdk.blitter.circle(.fb1, .{
    .color = sdk.ARGB1555.fromRGB(0, 255, 0),
    .pos = .{ .x = 200, .y = 150 },
    .r = 25,
});
```

#### Copy (Sprites)

```zig
sdk.blitter.copy(.fb1, .{
    .src = @intFromPtr(sprite_data.ptr) - sdk.Memory.RAM_START,
    .w = 32,
    .h = 32,
    .src_pos = .{ .x = 0, .y = 0 },
    .dst_pos = .{ .x = 100, .y = 100 },
    .alpha = .mask,
});
```

> ⚠️ **Note:** Blitter expects an address relative to the beginning of RAM, not an absolute address!. Other devices will interpret the addresses similarly.

### Origin Points

```
top_left     top      top_right
    ┌─────────┬─────────┐
    │         │         │
left├─────────┼─────────┤right
    │       center      │
    └─────────┴─────────┘
bottom_left  bottom  bottom_right
```

### Boundary Modes

- **crop** - Clip parts that exceed boundaries
- **wrap** - Wrap to the opposite side

## Audio

### Specifications

- Sample Rate: **22,050 Hz**
- Channels: **8**
- Formats: **PCM S16LE**, **IMA ADPCM**

### Basic Usage

```zig
const sdk = @import("sdk");

// Enable audio subsystem
sdk.audio.setEnabled(true);
sdk.audio.setMasterVolume(0.8);

// Configure a voice
const voice = sdk.audio.voice(0);
voice.sample_addr = sample_offset;  // Relative to RAM_START
voice.sample_len = sample_length;
voice.volume_l = 1.0;
voice.volume_r = 1.0;
voice.pitch = 1.0;
voice.loop_enabled = false;
voice.compressed = false;  // true for IMA ADPCM

// Play
voice.play();
```

### Voice Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `sample_addr` | u32 | Sample address (relative to RAM) |
| `sample_len` | u32 | Length in samples |
| `block_align` | u16 | Block size (for ADPCM) |
| `samples_per_block` | u16 | Samples per block (for ADPCM) |
| `loop_start` | u32 | Loop start position |
| `loop_end` | u32 | Loop end position |
| `volume_l` | f32 | Left channel volume (0.0–1.0) |
| `volume_r` | f32 | Right channel volume (0.0–1.0) |
| `pitch` | f32 | Pitch (1.0 = original) |
| `position` | f32 | Current playback position |
| `playing` | bool | Playing flag |
| `loop_enabled` | bool | Enable looping |
| `compressed` | bool | true = IMA ADPCM, false = PCM |

### Audio Conversion

**With compression (IMA ADPCM):**

```sh
ffmpeg -i input.mp3 -acodec adpcm_ima_wav -ar 22050 -ac 1 output.wav
```

**Without compression (PCM):**

```sh
ffmpeg -i input.mp3 -acodec pcm_s16le -ar 22050 -ac 1 output.wav
```

## Input

### Gamepads

The console supports **2 gamepads**. Each gamepad has:

- 2 analog sticks
- 2 triggers
- D-pad (up, down, left, right)
- 4 action buttons (north, south, east, west)
- 2 bumpers
- Start and Select
- Stick clicks

### Reading State

```zig
const sdk = @import("sdk");

const gamepad = sdk.gamepad1;

if (gamepad.isConnected()) {
    const controls = gamepad.status().controls();
    
    // Buttons
    if (controls.south.down) {
        // South button is pressed
    }
    
    // Check for single press (sticky)
    if (controls.start.sticky) {
        // Start was pressed since last clear
    }
    
    // Analog stick
    const stick = controls.left_stick;
    const dir = stick.direction(4000);  // deadzone = 4000
    
    // Triggers (0–65535)
    const lt = controls.left_trigger;
}

// Clear sticky flags
gamepad.clearSticky();
```

### Stick Directions

```zig
pub const Direction = enum {
    none,
    north, north_east,
    east, south_east,
    south, south_west,
    west, north_west,
};

pub const Cardinal = enum {
    none, north, east, south, west,
};
```

### Rumble

```zig
// rumble(weak, strong, duration_ms)
gamepad.rumble(0x8000, 0xFFFF, 200);

// Disable
gamepad.rumbleOff();
```

## DMA and Storage

### Storage Devices

| Device | Description |
|--------|-------------|
| `external_storage` | External storage (read-only) |
| `nvram_storage` | Non-volatile memory (read/write) |

### Reading Data

```zig
const sdk = @import("sdk");

var buffer: [1024]u8 = undefined;

// Read from external storage
sdk.dma.read(.external_storage, 0, &buffer);
```

### Writing Data (NVRAM)

```zig
const save_data = "player_score:1000";
sdk.dma.write(.nvram_storage, 0, save_data);
```

### Pattern Fill

```zig
const pattern = [_]u8{ 0xAA, 0x55 };
sdk.dma.fill(.nvram_storage, 0, &pattern, 1024);

// Single byte fill
sdk.dma.memset(.nvram_storage, 0, 0x00, 1024);
```

## Timers and Interrupts

### CLINT (Core Local Interruptor)

```zig
const sdk = @import("sdk");

// Read current time (in ticks)
const ticks = sdk.clint.readMtime();

// Read time in nanoseconds
const ns = sdk.clint.readMtimeNs();

// Set interrupt after N ticks
sdk.clint.interruptAfter(8_000_000);  // 1 second at 8 MHz

// Set interrupt after N nanoseconds
sdk.clint.interruptAfterNs(16_666_667);  // ~60 FPS
```

### PLIC (Platform-Level Interrupt Controller)

```zig
const sdk = @import("sdk");

// In interrupt handler
const device = sdk.plic.claim;

switch (device) {
    .gpu => {
        // Handle VBlank
    },
    else => {},
}
```

## UART (Debug Output)

```zig
const sdk = @import("sdk");

sdk.uart.print("Hello, RWPLAY!\n", .{});
sdk.uart.print("Value: {d}\n", .{42});
```

## Random Number Generator

```zig
const sdk = @import("sdk");

// Get a single byte
const byte = sdk.prng.status().value;

// Use as std.Random
const random = sdk.Prng.interface();
const value = random.int(u32);
```

## Debugging

The dev version of the emulator supports **GDB Remote Protocol**. When the game starts, it immediately stops and waits for the debugger to be connected.

### Connecting with GDB

```sh
$ riscv32-unknown-elf-gdb game.elf
(gdb) target remote localhost:1234
```

### VS Code Configuration (CodeLLDB)

```json
{
    "name": "Debug Game",
    "type": "lldb",
    "request": "attach",
    "targetCreateCommands": [
        "target create ${workspaceFolder}/zig-out/bin/game.elf"
    ],
    "processCreateCommands": [
        "gdb-remote localhost:1234"
    ]
}
```
