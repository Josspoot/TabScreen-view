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
2. Escanea el QR de la terminal con la tablet y escribe en la Mac el código de verificación que muestra.
3. Aparece una pantalla nueva llamada **TabScreen** con la resolución de tu tablet; toca **Pantalla completa**.

La pantalla virtual se crea cuando se conecta la tablet, directamente con su resolución física (con `--res` se crea al arrancar). En tablets de alta resolución (lado largo ≥ 2400 px) usa HiDPI: por ejemplo, una tablet de 2880x1800 se ve como un monitor Retina de 1440x900.

Toca fuera del panel para cerrarlo; toca dos veces la pantalla para volver a abrirlo.

### Por cable USB (menos retraso)

Wi-Fi y cable funcionan al mismo tiempo. Por cable el video no depende del Wi-Fi y la tablet usa WebCodecs, que decodifica con mucho menos retraso.

1. Instala adb en la Mac: `brew install --cask android-platform-tools`.
2. En la tablet activa las **Opciones de desarrollador**: *Ajustes → Acerca de la tablet → Información de software* y toca 7 veces **Número de compilación**. Luego, en *Ajustes → Opciones de desarrollador*, activa **Depuración por USB**.
3. Con TabScreen corriendo, conecta la tablet por cable y acepta «¿Permitir la depuración por USB?» (marca *Permitir siempre desde este equipo*).
4. TabScreen abre la página sola en la tablet. Por cable no se pide el código de verificación: la tablet está conectada físicamente y ya autorizaste la depuración USB.

`--no-usb` desactiva la conexión por cable.

### Código de verificación

Escanear el QR no basta para ver tu pantalla. Cuando se conecta un dispositivo nuevo:

1. El dispositivo muestra un **código de 6 dígitos**.
2. En la Mac aparece una ventana donde debes **escribir ese código** y elegir *Rechazar*, *Solo esta vez* o *Permitir y recordar*.
3. Los dispositivos recordados entran directo la próxima vez. Para olvidarlos (y generar un QR nuevo): `tabscreen --forget-devices`.

El QR se conserva entre ejecuciones, así que la tablet se reconecta sola cuando reinicias TabScreen (mientras la Mac siga en la misma red).

Tras un rechazo o un código incorrecto, esa IP no puede volver a pedir acceso durante 60 segundos, y solo se atiende una solicitud a la vez.

### Ubicación

En el panel de la tablet elige dónde la pusiste físicamente (**izquierda, derecha, arriba o abajo**) y la pantalla virtual se reacomoda al instante, centrada en ese borde de la pantalla principal. La Mac recuerda la última ubicación; también puedes fijarla con `--position izquierda`.

Las preferencias se guardan en `~/Library/Application Support/TabScreen/settings.json`.

### Opciones

| Opción | Descripción | Por defecto |
|---|---|---|
| `-r, --res <WxH\|preset>` | Resolución fija. Presets: `hd` 1280x800, `fhd` 1920x1080, `wuxga` 1920x1200, `2k` 2560x1600 | automática (la de la tablet) |
| `--hidpi` | Modo Retina: la interfaz se ve a la mitad de tamaño, más nítida | automático |
| `--fps <n>` | Cuadros por segundo | `60` |
| `--full-res` | Envía el video a la resolución completa de la pantalla (sin esto se limita a ~1920x1200 y la tablet lo reescala, para reducir el retraso) | desactivado |
| `--bitrate <Mbps>` | Bitrate del video | automático |
| `-p, --port <n>` | Puerto HTTP | `8420` |
| `--position <lado>` | `izquierda`, `derecha`, `arriba` o `abajo` respecto a la pantalla principal | la última usada (o derecha) |
| `--forget-devices` | Olvida los dispositivos de confianza y sale | — |
| `--no-usb` | No usa la conexión por cable USB | activado si hay adb |

## Cómo funciona

- **Pantalla virtual:** `CGVirtualDisplay`, una API privada de CoreGraphics (la misma que usan [DeskPad](https://github.com/Stengo/DeskPad) y BetterDisplay). macOS la trata como un monitor real.
- **Captura:** ScreenCaptureKit en NV12.
- **Codificación:** VideoToolbox H.264 en modo de baja latencia, a ritmo constante (se repite el último cuadro si la pantalla está quieta).
- **Transporte:** un único puerto HTTP que sirve la página y un WebSocket con el video. El QR incluye un token aleatorio por sesión.
- **Reproducción:** por cable USB la página se abre como `localhost` (contexto seguro) y usa **WebCodecs**: decodifica cada cuadro apenas llega y lo pinta en un canvas. Por Wi-Fi (`http://IP`) Chrome no permite WebCodecs, así que empaqueta cada cuadro como MP4 fragmentado y lo reproduce con Media Source Extensions, con algo más de retraso. `?mode=mse` fuerza MSE.
- **Cable USB:** TabScreen revisa `adb devices` cada 2 s; al conectar una tablet crea el túnel `adb reverse tcp:8420 tcp:8420` y abre la página en su Chrome.

### Protocolo (WebSocket `/ws?t=TOKEN`)

Mensajes binarios servidor → cliente (enteros big-endian):

| Tipo | Contenido |
|---|---|
| `0x01` config | `u16 ancho, u16 alto, u8 fps, u16 lenSPS, SPS, u16 lenPPS, PPS` |
| `0x02` cuadro | `u8 flags (bit0 = keyframe), u64 pts µs, datos AVCC` |

Mensajes de texto (JSON):

- Cliente → servidor: `{"type":"hello","deviceId":"…","name":"…","screen":"2560x1600"}`, `{"type":"keyframe"}`, `{"type":"position","side":"left|right|above|below"}`, `{"type":"stats","received":60,"shown":58,"dropped":2,"lag":80}` (cada 10 s).
- Servidor → cliente: `{"type":"pair","code":"123456"}`, `{"type":"approved"}`, `{"type":"rejected","reason":"…"}`, `{"type":"position","side":"left"}`.

El cliente no recibe video hasta que la Mac lo aprueba (dispositivo de confianza o código confirmado).

## Limitaciones conocidas

- `CGVirtualDisplay` es API privada: podría romperse con una actualización de macOS.
- El video y el ID del dispositivo viajan **sin cifrar** por la red local. El código de verificación impide que alguien entre solo con el QR, pero no protege contra alguien que espíe el tráfico de tu red. No lo uses en redes públicas.
- La tablet puede apagar la pantalla por inactividad; ajusta el tiempo de espera en Android si pasa.

## Hoja de ruta

- [ ] Táctil de la tablet → mouse de la Mac
- [ ] App de barra de menú con QR en ventana
- [x] Conexión por cable USB (`adb reverse`) con WebCodecs
- [ ] App Android nativa (MediaCodec) con táctil
- [ ] HTTPS para usar WebCodecs también por Wi-Fi
- [ ] Varias tablets / varias pantallas virtuales

## Contribuir

¡Los PRs son bienvenidos! Abre un issue para discutir cambios grandes.

## Licencia

[MIT](LICENSE)
