# Быстрый обзор RWPLAY

Консоль RWPLAY - это фэнтези-консоль, работающая на базе 32-битного процессора архитектуры RISC-V.

## Поколения

### RWPLAY 1

#### Характеристики

| Параметр | Значение |
|----------|----------|
| ОЗУ | 524.3 KB |
| Процессор | 8 МГц |
| Видеорежимы | 960×540, 640×360, 480×270 |
| Формат пикселей | ARGB1555 (16 бит) |
| Аудио | Моно, 22.05 кГц |
| Аудиоканалы | 8 |
| Аудиоформаты | PCM S16LE, IMA ADPCM |

#### Расширения RISC-V

- **I** - базовый целочисленный набор
- **M** - умножение и деление
- **F** - одинарная точность с плавающей запятой
- **D** - двойная точность с плавающей запятой
- **Zicsr** - инструкции CSR
- **Zifencei** - синхронизация инструкций
- **Zba** - адресные манипуляции
- **Zbb** - базовые битовые операции
- **Zicntr** - счётчики производительности

#### Привилегированные режимы

Процессор поддерживает режимы **M** (Machine) и **U** (User) с PMP (Physical Memory Protection).

> ⚠️ **Важно:** PMP не применяется на уровне M.

## Карта памяти

| Адрес | Устройство | Описание |
|-------|------------|----------|
| `0x0000_1000` | BOOT_INFO | Информация о загрузке |
| `0x0200_0000` | CLINT | Таймер и межпроцессорные прерывания |
| `0x0C00_0000` | PLIC | Контроллер внешних прерываний |
| `0x0C00_1000` | GPU | Управление видеовыходом |
| `0x0C00_2000` | PRNG | Генератор случайных чисел |
| `0x1000_0000` | UART | Последовательный порт (отладочный вывод) |
| `0x3000_0000` | BLITTER | 2D-графический ускоритель |
| `0x3000_1000` | GAMEPAD1 | Первый геймпад |
| `0x3000_1100` | GAMEPAD2 | Второй геймпад |
| `0x3000_2000` | AUDIO | Аудиоподсистема |
| `0x3000_3000` | DMA | Прямой доступ к памяти |
| `0x4000_0000` | FRAMEBUFFER1 | Фреймбуфер 960×540 |
| `0x400F_D200` | FRAMEBUFFER2 | Фреймбуфер 640×360 |
| `0x4016_DA00` | FRAMEBUFFER3 | Фреймбуфер 480×270 |
| `0x8000_0000` | RAM | Начало оперативной памяти |

### Структура BOOT_INFO

```zig
pub const BootInfo = extern struct {
    cpu_frequency: u64,        // Частота процессора в Гц
    ram_size: u32,             // Размер ОЗУ в байтах
    fps: u32,                  // Частота кадров
    free_ram_start: u32,       // Начало свободной памяти
    external_storage_size: u32, // Размер внешнего хранилища
    nvram_storage_size: u32,   // Размер энергонезависимой памяти
};
```

## Загрузочные образы

Консоль работает только с собственным форматом образов - **RWPI** (RWPLAY Image).

### Формат RWPI

Формат представляет собой последовательно склеенные файлы. Точка входа - файл `/boot.elf` в формате ELF.

### Создание образа

Используйте утилиту `imagemaker` из SDK:

```sh
$ imagemaker examples/snake/manifest.json snake.rwpi
```

## Графика

### Фреймбуферы

Консоль имеет три фреймбуфера разного разрешения:

| ID | Разрешение | Размер памяти |
|----|------------|---------------|
| `fb1` | 960×540 | 1,036,800 байт |
| `fb2` | 640×360 | 460,800 байт |
| `fb3` | 480×270 | 259,200 байт |

### Формат пикселей ARGB1555

```
Бит:    15    14-10   9-5    4-0
        A     R       G      B
        1бит  5бит    5бит   5бит
```

- **A** - альфа (1 = непрозрачный, 0 = прозрачный)
- **R, G, B** - компоненты цвета (0–31)

### Управление GPU

```zig
const sdk = @import("sdk");

// Переключить активный фреймбуфер
sdk.gpu.switchFramebuffer(.fb1);

// Включить прерывания вертикальной синхронизации
sdk.gpu.setVblankInterrupts(true);
```


## Blitter (2D-ускоритель)

Blitter - это аппаратный 2D-ускоритель для быстрых графических операций.

### Команды

#### Очистка экрана

```zig
sdk.blitter.clear(.fb1, .{
    .color = sdk.ARGB1555.fromRGB(0, 0, 0),
});
```

#### Прямоугольник

```zig
sdk.blitter.rect(.fb1, .{
    .color = sdk.ARGB1555.fromRGB(255, 0, 0),
    .pos = .{ .x = 100, .y = 100 },
    .w = 50,
    .h = 30,
    .origin = .center,  // Точка привязки
    .mode = .crop,      // Режим обрезки
});
```

#### Круг

```zig
sdk.blitter.circle(.fb1, .{
    .color = sdk.ARGB1555.fromRGB(0, 255, 0),
    .pos = .{ .x = 200, .y = 150 },
    .r = 25,
});
```

#### Копирование (спрайты)

```zig
sdk.blitter.copy(.fb1, .{
    .src = @intFromPtr(sprite_data.ptr) - sdk.Memory.RAM_START,
    .w = 32,
    .h = 32,
    .src_pos = .{ .x = 0, .y = 0 },
    .dst_pos = .{ .x = 100, .y = 100 },
    .alpha = .mask,  // Учитывать альфа-канал
});
```

> ⚠️ **Важно:** Blitter ожидает адрес относительно начала ОЗУ, а не абсолютный адрес!. Другие устройства будут интерпретировать адреса аналогично.

### Точки привязки (Origin)

```
top_left     top      top_right
    ┌─────────┬─────────┐
    │         │         │
left├─────────┼─────────┤right
    │       center      │
    └─────────┴─────────┘
bottom_left  bottom  bottom_right
```

### Режимы обработки границ

- **crop** - обрезать части, выходящие за границы
- **wrap** - переносить на противоположную сторону

## Аудио

### Характеристики

- Частота дискретизации: **22,050 Гц**
- Количество каналов: **8**
- Форматы: **PCM S16LE**, **IMA ADPCM**

### Базовое использование

```zig
const sdk = @import("sdk");

// Включить аудиоподсистему
sdk.audio.setEnabled(true);
sdk.audio.setMasterVolume(0.8);

// Настроить голос
const voice = sdk.audio.voice(0);
voice.sample_addr = sample_offset;  // Относительно RAM_START
voice.sample_len = sample_length;
voice.volume_l = 1.0;
voice.volume_r = 1.0;
voice.pitch = 1.0;
voice.loop_enabled = false;
voice.compressed = false;  // true для IMA ADPCM

// Воспроизвести
voice.play();
```

### Параметры голоса

| Параметр | Тип | Описание |
|----------|-----|----------|
| `sample_addr` | u32 | Адрес сэмпла (относительно RAM) |
| `sample_len` | u32 | Длина в сэмплах |
| `block_align` | u16 | Размер блока (для ADPCM) |
| `samples_per_block` | u16 | Сэмплов в блоке (для ADPCM) |
| `loop_start` | u32 | Начало цикла |
| `loop_end` | u32 | Конец цикла |
| `volume_l` | f32 | Громкость левого канала (0.0–1.0) |
| `volume_r` | f32 | Громкость правого канала (0.0–1.0) |
| `pitch` | f32 | Высота тона (1.0 = оригинальная) |
| `position` | f32 | Текущая позиция воспроизведения |
| `playing` | bool | Флаг воспроизведения |
| `loop_enabled` | bool | Включить зацикливание |
| `compressed` | bool | true = IMA ADPCM, false = PCM |

### Конвертация аудио

**С сжатием (IMA ADPCM):**

```sh
ffmpeg -i input.mp3 -acodec adpcm_ima_wav -ar 22050 -ac 1 output.wav
```

**Без сжатия (PCM):**

```sh
ffmpeg -i input.mp3 -acodec pcm_s16le -ar 22050 -ac 1 output.wav
```

## Ввод

### Геймпады

Консоль поддерживает **2 геймпада**. Каждый геймпад имеет:

- 2 аналоговых стика
- 2 триггера
- D-pad (вверх, вниз, влево, вправо)
- 4 кнопки действий (север, юг, восток, запад)
- 2 бампера
- Start и Select
- Нажатия стиков

### Чтение состояния

```zig
const sdk = @import("sdk");

const gamepad = sdk.gamepad1;

if (gamepad.isConnected()) {
    const controls = gamepad.status().controls();
    
    // Кнопки
    if (controls.south.down) {
        // Кнопка "юг" нажата
    }
    
    // Проверка на однократное нажатие (sticky)
    if (controls.start.sticky) {
        // Start была нажата с последней очистки
    }
    
    // Аналоговый стик
    const stick = controls.left_stick;
    const dir = stick.direction(4000);  // deadzone = 4000
    
    // Триггеры (0–65535)
    const lt = controls.left_trigger;
}

// Очистить sticky-флаги
gamepad.clearSticky();
```

### Направления стика

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

### Вибрация

```zig
// rumble(weak, strong, duration_ms)
gamepad.rumble(0x8000, 0xFFFF, 200);

// Отключить
gamepad.rumbleOff();
```

## DMA и хранилище

### Устройства хранения

| Устройство | Описание |
|------------|----------|
| `external_storage` | Внешний накопитель (только чтение) |
| `nvram_storage` | Энергонезависимая память (чтение/запись) |

### Чтение данных

```zig
const sdk = @import("sdk");

var buffer: [1024]u8 = undefined;

// Чтение из внешнего хранилища
sdk.dma.read(.external_storage, 0, &buffer);
```

### Запись данных (NVRAM)

```zig
const save_data = "player_score:1000";
sdk.dma.write(.nvram_storage, 0, save_data);
```

### Заполнение паттерном

```zig
const pattern = [_]u8{ 0xAA, 0x55 };
sdk.dma.fill(.nvram_storage, 0, &pattern, 1024);

// Заполнение одним байтом
sdk.dma.memset(.nvram_storage, 0, 0x00, 1024);
```

## Таймеры и прерывания

### CLINT (Core Local Interruptor)

```zig
const sdk = @import("sdk");

// Прочитать текущее время (в тактах)
const ticks = sdk.clint.readMtime();

// Прочитать время в наносекундах
const ns = sdk.clint.readMtimeNs();

// Установить прерывание через N тактов
sdk.clint.interruptAfter(8_000_000);  // через 1 секунду при 8 МГц

// Установить прерывание через N наносекунд
sdk.clint.interruptAfterNs(16_666_667);  // ~60 FPS
```

### PLIC (Platform-Level Interrupt Controller)

```zig
const sdk = @import("sdk");

// В обработчике прерывания
const device = sdk.plic.claim;

switch (device) {
    .gpu => {
        // Обработка VBlank
    },
    else => {},
}
```

## UART (отладочный вывод)

```zig
const sdk = @import("sdk");

sdk.uart.print("Hello, RWPLAY!\n", .{});
sdk.uart.print("Value: {d}\n", .{42});
```

## Генератор случайных чисел

```zig
const sdk = @import("sdk");

// Получить один байт
const byte = sdk.prng.status().value;

// Использовать как std.Random
const random = sdk.Prng.interface();
const value = random.int(u32);
```

## Дебаггинг

Dev-версия эмулятора поддерживает **GDB Remote Protocol**. При запуске игры он сразу же останавливается и ждет подключения дебаггера.

### Подключение GDB

```sh
$ riscv32-unknown-elf-gdb game.elf
(gdb) target remote localhost:1234
```

### Конфигурация VS Code (CodeLLDB)

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
