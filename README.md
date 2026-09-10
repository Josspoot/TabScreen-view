# TabScreen

Usa una tablet Android (o cualquier dispositivo con Chrome) como **segunda pantalla extendida** de tu Mac. Escaneas un QR y listo: sin cables, sin instalar nada en la tablet.

```
Mac                                                   Tablet
┌─────────────────────────────────────────┐          ┌───────────────────┐
│ Pantalla virtual (CGVirtualDisplay)     │          │ Chrome            │
│   → captura (ScreenCaptureKit)          │  Wi-Fi   │   WebSocket       │
│   → H.264 por hardware (VideoToolbox)   │ ───────► │   → fMP4 → MSE    │
│   → servidor HTTP/WebSocket + QR        │          │   → <video>       │
└─────────────────────────────────────────┘          └───────────────────┘
```

> Estado: **MVP experimental**. Funciona por Wi-Fi con latencia media (~100–200 ms). Todavía no hay táctil ni app nativa.

## Requisitos

- macOS 13 o superior (probado en Apple Silicon).
- Swift 5.10+ (basta con las Command Line Tools: `xcode-select --install`).
- Tablet con Chrome en la **misma red Wi-Fi** que la Mac.

## Uso

```bash
git clone https://github.com/Josspoot/TabScreen-view.git && cd TabScreen-view
swift run -c release tabscreen
```

1. La primera vez macOS pedirá permiso de **Grabación de pantalla** para tu terminal. Actívalo en *Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema* y vuelve a abrir la terminal.
2. Aparece una pantalla nueva llamada **TabScreen**; acomódala en *Ajustes → Pantallas*.
3. Escanea el QR de la terminal con la tablet y toca **Pantalla completa**.

Al conectarse, la pantalla virtual adopta la resolución física de la tablet. En tablets de alta resolución (lado largo ≥ 2400 px) usa HiDPI: por ejemplo, una tablet de 2880x1800 se ve como un monitor Retina de 1440x900.

Toca fuera del panel para cerrarlo; toca dos veces la pantalla para volver a abrirlo.

### Opciones

| Opción | Descripción | Por defecto |
|---|---|---|
| `-r, --res <WxH\|preset>` | Resolución fija. Presets: `hd` 1280x800, `fhd` 1920x1080, `wuxga` 1920x1200, `2k` 2560x1600 | automática (la de la tablet) |
| `--hidpi` | Modo Retina: la interfaz se ve a la mitad de tamaño, más nítida | automático |
| `--fps <n>` | Cuadros por segundo | `60` |
| `--bitrate <Mbps>` | Bitrate del video | automático |
| `-p, --port <n>` | Puerto HTTP | `8420` |

## Cómo funciona

- **Pantalla virtual:** `CGVirtualDisplay`, una API privada de CoreGraphics (la misma que usan [DeskPad](https://github.com/Stengo/DeskPad) y BetterDisplay). macOS la trata como un monitor real.
- **Captura:** ScreenCaptureKit en NV12.
- **Codificación:** VideoToolbox H.264 en modo de baja latencia, a ritmo constante (se repite el último cuadro si la pantalla está quieta).
- **Transporte:** un único puerto HTTP que sirve la página y un WebSocket con el video. El QR incluye un token aleatorio por sesión.
- **Reproducción:** el navegador empaqueta cada cuadro como MP4 fragmentado y lo reproduce con Media Source Extensions. Se usa MSE en lugar de WebCodecs porque Chrome solo permite WebCodecs en contextos seguros (HTTPS/localhost).

### Protocolo (WebSocket `/ws?t=TOKEN`)

Mensajes binarios servidor → cliente (enteros big-endian):

| Tipo | Contenido |
|---|---|
| `0x01` config | `u16 ancho, u16 alto, u8 fps, u16 lenSPS, SPS, u16 lenPPS, PPS` |
| `0x02` cuadro | `u8 flags (bit0 = keyframe), u64 pts µs, datos AVCC` |

Mensajes de texto cliente → servidor (JSON): `{"type":"hello","screen":"2560x1600"}`, `{"type":"keyframe"}`.

## Limitaciones conocidas

- `CGVirtualDisplay` es API privada: podría romperse con una actualización de macOS.
- El video viaja **sin cifrar** por la red local (protegido solo por el token). No lo uses en redes públicas.
- La tablet puede apagar la pantalla por inactividad; ajusta el tiempo de espera en Android si pasa.

## Hoja de ruta

- [ ] Táctil de la tablet → mouse de la Mac
- [ ] App de barra de menú con QR en ventana
- [ ] App Android nativa (MediaCodec) con conexión por USB (`adb reverse`)
- [ ] HTTPS + WebCodecs para menor latencia
- [ ] Varias tablets / varias pantallas virtuales

## Contribuir

¡Los PRs son bienvenidos! Abre un issue para discutir cambios grandes.

## Licencia

[MIT](LICENSE)
