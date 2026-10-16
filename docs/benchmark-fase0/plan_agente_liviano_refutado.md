# Plan: agente de código TUI ultraliviano (diseño en papel) y su refutación

> **Estado:** diseño teórico. Ninguna cifra de RAM de la columna "estimado" fue medida.
> **Fecha:** 2026-10-09 · **Entorno medido:** Windows (PowerShell 7.6.6), opencode 1.18.35, Gentle Shell sobre Pi (Node.js).

---

## 1. Resumen y veredicto

| Pregunta | Respuesta |
|---|---|
| ¿Un agente nativo (Rust) puede usar mucho menos RAM que Gentle Shell? | Probablemente sí, pero **no está demostrado**. Mi estimación de 15-40 MB en reposo es una hipótesis, no un dato. |
| ¿Vale la pena reescribir? | **No como primer paso.** Gentle Shell ya está en ~260 MB (medido, una muestra). Antes de reescribir, hay palancas baratas sin probar. |
| ¿Qué partes de mi diseño original resisten la refutación? | Truncar salidas de herramientas, no vigilar el repo (sin snapshot/polling), renderizar solo el viewport, arranque perezoso de MCP (con matices). |
| ¿Cuáles no? | "Subagentes como tareas en el mismo proceso", "SQLite elimina el problema de memoria" y "el costo está en V8" quedan **refutados o muy debilitados** (sección 4). |
| ¿Qué falla en cómo se midió hasta ahora? | Una sola muestra, momentos distintos de la sesión, métrica de memoria ambigua, procesos hijos mezclados (sección 5). |

**Decisión recomendada:** ejecutar el protocolo de la sección 7 en ambas herramientas; probar el tope de heap de Node (sección 8); solo si Gentle Shell sigue por encima de lo aceptable, pasar a un prototipo mínimo (sección 9, fase 1).

---

## 2. Evidencia disponible (con nivel de confianza)

### 2.1 Mediciones propias del usuario

| Dato | Valor | Cómo se obtuvo | Confianza |
|---|---|---|---|
| opencode, proceso principal | 977 MB (CPU acumulada ~1000 s) | `Get-Process ... WS` | Media: sesión larga, una muestra |
| opencode, 5 muestras de 1 s | 801 MB constantes, CPU 0.2-2.3 % | script con `$p.CPU` | Media: ventana de 5 s, no sabemos si estaba en reposo real |
| Procesos `node` auxiliares (junto a opencode) | 86 + 52 + 42 MB | `Get-Process` | Media: se asumió que eran MCPs, **no se verificó** |
| Gentle Shell, total `node` | 424 MB (5 procesos) → 260 MB (2 procesos) | `Get-Process node` | Baja-media: el primer valor mezcló procesos ajenos |
| Proceso principal de Gentle Shell | 211 MB, `pi-coding-agent/cli.js` + extensión `gentle-pi` | `Win32_Process.CommandLine` | Alta para la identidad del proceso; media para la cifra |

### 2.2 Evidencia del repositorio oficial de opencode (`anomalyco/opencode`)

- Hay reportes de crecimiento de memoria con el tiempo, con la etiqueta `perf` (issue #11399).
- Hay un caso documentado de conexiones SSE atascadas (`CLOSE_WAIT`) que hacen crecer una cola sin límite; el PR de arreglo (#24058) aparece cerrado, así que no se puede asumir que esté resuelto.
- La herramienta `read` carga el archivo completo en memoria antes de dividirlo por líneas (issue #10157).
- Un reporte con una base de datos de ~9 GB muestra que `export` falla al serializar partes de sesión de más de ~1 GB (issue #22072).
- Un reporte en Windows menciona uso normal tras reiniciar de ~800 MB a 1.9 GB (issue #11868).

### 2.3 Evidencia del README de Gentle Shell

- Cada subagente corre **como proceso propio**, con tarjeta en vivo, controles de parada e historial restaurable al reanudar.
- Los cambios se capturan desde las llamadas de escritura y edición exitosas, sin escaneo del repo ni polling.
- Es un arnés sobre Pi: skills, ODD, revisión nativa, YOLO, perfiles, estadísticas, notificaciones de audio. Más de 5.900 commits y ~500 issues abiertos indican un alcance funcional grande.
- No publica cifras de memoria.

---

## 3. Diseño original en papel (lo que propuse)

### 3.1 Stack

| Capa | Tecnología | Argumento |
|---|---|---|
| Lenguaje | Rust (alternativa Go) | Sin runtime JS ni GC pesado |
| TUI | `ratatui` + `crossterm` | Redibujo por diferencias de celdas |
| Async | `tokio` | Tareas ligeras en lugar de procesos |
| HTTP/streaming | `reqwest` + SSE por chunks | No acumula respuestas completas |
| Sesiones | SQLite o JSONL append-only | El historial vive en disco |
| Diffs | `similar` | Bajo demanda, sin vigilar el repo |
| Subagentes | Tareas `tokio` en el mismo proceso | Evita un proceso por subagente |
| MCP | Procesos hijo stdio, arranque perezoso | No lanzar servidores sin uso |
| Búsqueda | `grep-searcher` (núcleo de ripgrep) | Sin índice residente |
| Extensiones | WebAssembly (`wasmtime`) o procesos stdio | Núcleo pequeño |

### 3.2 Reglas de diseño

1. Salidas de herramientas truncadas al capturarse, texto completo en disco.
2. Sin snapshot ni polling; el undo lo hace git.
3. Todo dirigido por eventos; CPU ~0 % en reposo.
4. Renderizar solo el viewport visible.
5. Compactación como operación sobre disco.
6. Sin LSP ni indexado por defecto.

### 3.3 Presupuesto de memoria estimado (NO medido)

| Componente | Reposo | Sesión larga con subagentes |
|---|---|---|
| Binario + TUI | 5-10 MB | 10-20 MB |
| Cliente HTTP + TLS | 3-8 MB | 5-15 MB |
| Estado de sesión (ventana de contexto) | 1-5 MB | 5-20 MB |
| Subagentes (tareas) | ~0 | 10-30 MB |
| Procesos MCP (fuera del total) | variable | variable |
| **Total del núcleo** | **~15-40 MB** | **~60-100 MB** |

---

## 4. Refutación punto por punto

Veredictos: ✅ se sostiene · ⚠️ se sostiene con matices · ❌ refutado o sin sustento.

### 4.1 "El costo principal es el runtime V8" — ❌

- **Error factual:** opencode no corre sobre V8 según lo que mostró la salida de `Get-Process` (el proceso se llama `opencode`, no `node`); mi suposición de V8 vino de tratar a ambas herramientas como Node. No verifiqué el runtime de opencode. Gentle Shell sí corre sobre Node (la línea de comandos lo confirma: `node.exe ... pi-coding-agent/cli.js`).
- **Consecuencia:** la comparación 800 MB vs 260 MB ocurre entre **dos runtimes y dos programas distintos**. No se puede atribuir la diferencia al lenguaje: puede deberse a funciones que opencode carga y Pi no (más herramientas, más caché, sesiones acumuladas, MCPs).
- **Prueba falsable:** medir el heap real (`process.memoryUsage()` o `--heapsnapshot`) separado del resto del proceso. Si la mayor parte es heap de aplicación y no el motor, reescribir en Rust solo ahorra si se rediseñan las estructuras de datos, no por cambiar de lenguaje.

### 4.2 "La ventana de contexto en RAM es el problema" — ❌

- 103.000 tokens son del orden de **0,4 MB de texto**. El historial textual no explica cientos de MB.
- Lo que sí crece: objetos intermedios, partes de mensajes con metadatos, salidas de herramientas sin truncar, buffers de streaming, cachés de render, estados de subagentes, conexiones.
- **Consecuencia:** "guardar el historial en disco" ahorra menos de lo que sugerí. El diseño debe atacar retención de objetos y buffers, no el texto.

### 4.3 "SQLite resuelve la memoria de sesiones" — ❌

- El reporte #22072 muestra lo contrario: una base de 9,36 GB y un `export` que falla al cargar y serializar partes en un solo JSON. Tener los datos en disco **no impide** que una operación los traiga todos a memoria.
- **Corrección de diseño:** paginación obligatoria, streaming de resultados, límites de tamaño por parte y una política de retención. Sin eso, SQLite solo mueve el problema.

### 4.4 "Subagentes como tareas del mismo proceso" — ❌ (como regla general)

Gentle Shell eligió un proceso por subagente y su README lo presenta como característica: tarjeta en vivo, controles de parada, historial restaurable, comunicación padre-hijo.

| Propiedad | Proceso aparte | Tarea en el mismo proceso |
|---|---|---|
| Aislamiento de fallos | Un crash no mata al padre | Un `panic` o fuga afecta a todos |
| Detener un subagente | Terminar el proceso es seguro | Cancelación cooperativa; puede no responder |
| Límites de memoria | Se pueden imponer por proceso (Job Objects en Windows) | Un solo espacio compartido, sin tope individual |
| Permisos | Se pueden acotar por proceso | Misma superficie de ataque |
| Costo de RAM | Mayor (cada Node ~40-200 MB, **no medido por mí**) | Menor |

- **Veredicto:** el ahorro de RAM es real pero se paga con aislamiento. En Rust, una alternativa intermedia es un **subproceso nativo pequeño** (el mismo binario con un modo `--worker`), cuyo costo base sería de pocos MB, no de decenas.

### 4.5 "MCP con arranque perezoso" — ⚠️

- El modelo necesita conocer las **definiciones de herramientas** (nombre, descripción, esquema) para decidir cuándo usarlas. Esas definiciones salen de consultar al servidor MCP al conectarse.
- Un arranque verdaderamente perezoso exige **cachear los esquemas en disco** y lanzar el servidor solo en la primera invocación. Si el esquema cambia, hay que invalidar la caché.
- Además, las definiciones se inyectan en cada prompt: el ahorro principal es de **tokens**, no de RAM.
- **Se sostiene** como optimización, con la caché de esquemas como requisito.

### 4.6 "Truncar salidas de herramientas" — ⚠️

- Reduce memoria y tokens, y ataca un problema real (lecturas completas, #10157).
- Riesgo: el modelo pierde información y puede razonar sobre una salida incompleta sin saberlo.
- **Condición para que sea válido:** truncado visible para el modelo ("se omitieron N líneas, usa `read` con offset"), texto completo recuperable en disco, y límites distintos por herramienta (un `grep` no es igual que un `build`).

### 4.7 "Sin snapshot ni polling" — ✅

- Coincide con la config que el usuario ya aplicó (`"snapshot": false`) y con el diseño declarado de Gentle Shell.
- Límite que Gentle Shell reconoce: los cambios hechos por shell o ediciones externas no quedan registrados; la ausencia de una entrada no demuestra un árbol limpio. Mi diseño heredaría esa limitación y debería documentarla.

### 4.8 "Renderizar solo el viewport con `ratatui`" — ⚠️

- Correcto como principio, pero el costo se desplaza a otras partes: resaltado de sintaxis, Markdown, ancho de caracteres Unicode, emojis, y las particularidades de la consola en Windows (ConPTY).
- La CPU medida en opencode ya es baja (~1 % promedio, una muestra). **El render no parece ser el cuello de botella**, así que optimizarlo no justifica por sí solo la reescritura.

### 4.9 "WebAssembly para extensiones" — ❌ para este caso

- El valor de Gentle Shell está en su ecosistema: skills (prompts en Markdown), extensiones de Pi en TypeScript, paquetes npm de Gentle AI, memoria (Engram), temas.
- Un núcleo en Rust **rompe la compatibilidad** con ese ecosistema. Las skills en Markdown sí se pueden reutilizar; las extensiones TypeScript no.
- Reimplementar el alcance funcional de Gentle Shell (ODD, revisión nativa, perfiles, YOLO con guardas, estadísticas, audio) es un esfuerzo de meses, no de semanas. Esto es una estimación mía, no un dato.

### 4.10 "15-40 MB en reposo" — ❌ (sin sustento)

- No hay prototipo ni medición. Es una extrapolación.
- Un cliente TLS, un parser de eventos, un renderizador y el estado de varias sesiones suelen sumar más de lo que se espera; además, Windows cuenta como "working set" páginas de DLL compartidas.
- **Tratar la cifra como objetivo a verificar, no como resultado.**

---

## 5. Refutación de la metodología de medición

| # | Problema | Efecto | Corrección |
|---|---|---|---|
| 1 | **Una sola muestra por herramienta** | No se distingue arranque de estado estable | Series temporales de 30 min con muestreo cada 60 s |
| 2 | **Momentos distintos de la sesión.** opencode llevaba horas (CPU acumulada ~1000 s); Gentle Shell se midió recién abierto | Sesgo a favor de Gentle Shell | Mismo tiempo de uso y mismo tipo de tarea en ambas |
| 3 | **Métrica ambigua.** `WorkingSet64` incluye páginas compartibles | Sobreestima o subestima según el caso | Registrar `WorkingSet64` **y** `PrivateMemorySize64` |
| 4 | **Árbol de procesos no definido.** Se sumaron todos los `node` | Se mezclaron procesos ajenos (el de `@colby…` quedó sin identificar) | Medir el árbol de procesos desde un PID raíz |
| 5 | **Suposición no verificada:** que los `node` de ~42-86 MB eran MCPs de opencode | Atribución sin prueba | Revisar `CommandLine` y `ParentProcessId` de cada uno |
| 6 | **Carga desigual.** Distintos proveedores, modelos y prompts | La latencia de red y el volumen de salida varían | Mismo repo, mismo prompt guion, mismo modelo si es posible |
| 7 | **CPU en 5 s de ventana** | No captura picos de streaming ni de subagentes | Muestrear CPU durante tarea activa y en reposo, por separado |
| 8 | **Hipótesis lingüística dada como hecho.** Dije que `Get-Counter` falló por el idioma de Windows; el error `c0000bb8` encaja con ese caso pero no lo verifiqué | Posible diagnóstico equivocado | Probar `Get-Counter -ListSet Process` o usar contadores por ruta localizada |
| 9 | **Subagentes no medidos en Gentle Shell** | El pico real puede ser mucho mayor que 260 MB | Medir con un subagente activo y con varios |
| 10 | **Sin controlar el antivirus ni procesos de fondo** | Ruido en CPU y RAM | Registrar procesos concurrentes; repetir 3 veces |

**Correcciones a afirmaciones previas mías:**
- Dije que los MCPs serían el mayor consumidor; la medición mostró que no (opencode principal ~977 MB, `node` auxiliares ~180 MB en total).
- Atribuí la baja de 424 a 260 MB al cierre de opencode; es plausible pero no está demostrado.

---

## 6. Diseño revisado (v2) tras la refutación

| Decisión | v1 | v2 |
|---|---|---|
| Subagentes | Tareas en el mismo proceso | **Subprocesos nativos del mismo binario** (`--worker`) con límites por Job Object; opción de tareas solo para trabajo de solo lectura |
| Sesiones | SQLite "resuelve" memoria | SQLite con **paginación obligatoria**, límite de tamaño por parte, retención configurable |
| MCP | Arranque perezoso | Perezoso **con caché de esquemas** e invalidación por versión |
| Salidas de herramientas | Truncar | Truncar **con aviso al modelo** y texto completo recuperable |
| Extensiones | WASM | **Reutilizar skills en Markdown**; extensiones por procesos stdio; sin prometer compatibilidad con paquetes de Pi |
| Objetivo de memoria | 15-40 MB | **Hipótesis a verificar** con prototipo (fase 1) |
| Alcance | Reemplazo completo | **Prototipo mínimo**: chat + 3 herramientas + sesiones |

---

## 7. Protocolo de benchmark reproducible

### 7.1 Condiciones

1. Cerrar opencode y Gentle Shell antes de empezar; verificar `Get-Process node, opencode` vacío.
2. Mismo repositorio (`D:\socialemperors`), mismo guion de prompts (mínimo 5 tareas: leer archivos, buscar, editar, ejecutar tests, resumir).
3. Misma duración: 30 minutos por herramienta, **3 repeticiones**.
4. Escenarios: (A) arranque en reposo, (B) tarea activa, (C) con un subagente, (D) tras 30 min.
5. Registrar el modelo y proveedor usados.

### 7.2 Script de muestreo del árbol de procesos

```powershell
function Get-ProcTree([int]$RootId) {
  $all  = Get-CimInstance Win32_Process
  $seen = [System.Collections.Generic.HashSet[int]]::new()
  $q    = [System.Collections.Generic.Queue[int]]::new()
  $q.Enqueue($RootId)
  while ($q.Count) {
    $id = $q.Dequeue()
    if (-not $seen.Add($id)) { continue }
    $all | Where-Object ParentProcessId -eq $id |
      ForEach-Object { $q.Enqueue([int]$_.ProcessId) }
  }
  $seen
}

function Sample-Tree([int]$RootId) {
  $ps = Get-Process -Id @(Get-ProcTree $RootId) -ErrorAction SilentlyContinue
  [pscustomobject]@{
    Time       = Get-Date -Format s
    Procs      = @($ps).Count
    WS_MB      = [int](($ps | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    Private_MB = [int](($ps | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB)
    CPU_s      = [math]::Round(($ps | Measure-Object CPU -Sum).Sum, 1)
  }
}

# Uso: reemplaza <PID> por el proceso raíz de la herramienta (no el de la shell)
$root = <PID>
1..30 | ForEach-Object {
  Sample-Tree $root | Export-Csv "bench_$root.csv" -Append -NoTypeInformation
  Start-Sleep 60
}
```

### 7.3 Cómo elegir el PID raíz

- opencode: el proceso `opencode` principal; sus hijos (MCPs) quedan dentro del árbol.
- Gentle Shell: el proceso `node` del launcher (`gentle-shell`); si el principal es `pi-coding-agent/cli.js`, subir por `ParentProcessId` hasta el primer ancestro que no sea la shell.

### 7.4 Métricas de decisión

| Métrica | Cómo se calcula | Umbral sugerido (a validar) |
|---|---|---|
| RAM privada en reposo | mediana de Private_MB en escenario A | referencia: Gentle Shell |
| RAM privada tras 30 min | Private_MB final | crecimiento < 20 % |
| Pendiente de crecimiento | regresión lineal MB/min | cercana a 0 |
| CPU en reposo | CPU_s por minuto / núcleos | < 1 % |
| Costo por subagente | ΔPrivate_MB al lanzar uno | informativo |

---

## 8. Alternativas de bajo costo antes de reescribir

1. **Config de opencode** (ya aplicada): `snapshot: false`, `compaction.auto/prune`.
2. **Sesiones:** `/new` al cambiar de tarea; cerrar *spaces* sin uso; revisar el tamaño de `opencode.db`.
3. **Tope de heap en Node para Pi** (hipótesis **no probada**): lanzar con `NODE_OPTIONS=--max-old-space-size=256` y medir. V8 puede retener memoria sin necesitarla; un tope fuerza recolecciones más frecuentes. Riesgo: errores *out of memory* en sesiones grandes.
4. **Limitar lecturas** (`offset/limit`) para esquivar el comportamiento de `read`.
5. **Revisar qué carga cada herramienta:** `opencode debug config`; `/gentle:customize` para ocultar paneles.
6. **Actualizar versiones** y revisar changelogs por correcciones de memoria.

---

## 9. Roadmap del prototipo (solo si 7 y 8 no alcanzan)

| Fase | Contenido | Criterio de salida |
|---|---|---|
| 0 | Ejecutar protocolo (7) y tope de heap (8) | Datos de ambas herramientas y decisión documentada |
| 1 | Prototipo: chat con streaming SSE, 3 herramientas (`read` con límite, `grep`, `edit`), sesiones JSONL | **Medir RAM privada real.** Si > 60 MB en reposo, revisar hipótesis |
| 2 | TUI con `ratatui`, viewport, Markdown básico, Windows ConPTY | CPU en reposo < 1 %; sin parpadeo |
| 3 | Subprocesos `--worker`, Job Objects, parada segura | Un subagente cuesta < 15 MB (a verificar) |
| 4 | MCP con caché de esquemas y arranque perezoso | Arranque sin lanzar servidores; esquemas coherentes |
| 5 | Compatibilidad: importar skills Markdown y AGENTS.md | Una skill de Gentle Shell funciona sin cambios |
| 6 | Pruebas de larga duración (4 h) | Pendiente de crecimiento ≈ 0 |

---

## 10. Riesgos

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| El ahorro real es menor que el estimado | Alta | Alto | Medir en la fase 1 antes de continuar |
| Costo de desarrollo desproporcionado | Alta | Alto | Prototipo mínimo; decidir con datos |
| Pérdida de compatibilidad con el ecosistema | Alta | Medio | Reutilizar skills Markdown; no prometer paridad |
| Problemas de consola en Windows | Media | Medio | Probar ConPTY desde la fase 2 |
| Truncado que degrada la calidad del modelo | Media | Medio | Aviso explícito y recuperación del texto completo |
| Fugas en el nuevo código (conexiones, colas) | Media | Alto | Colas con límite y tiempo de espera, como se discutió en el issue de opencode |

---

## 11. Fuentes y límites

**Repositorio oficial de opencode (`anomalyco/opencode`):** issues #11399, #10157, #22072, #11868 y PR #24058.
**Gentle Shell:** `github.com/Gentleman-Programming/gentle-shell` (README).
**Guía de terceros (no oficial):** `tencent-source/opencode-debloat`, sobre `snapshot` y `compaction`; sus cifras de RAM no fueron verificadas.

**Límites de este documento:**
- Todas las cifras de la sección 3.3 son estimaciones del autor, sin prototipo.
- Las mediciones del usuario son de una sola muestra por herramienta y no son estrictamente comparables.
- No se verificó el runtime interno de opencode ni la causa exacta de su consumo.
- No se midió Gentle Shell con subagentes activos.
