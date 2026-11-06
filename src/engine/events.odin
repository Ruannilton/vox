package engine

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import "vendor:glfw"

// VS-07 — bus central de eventos: produtores (callbacks GLFW, cursor de
// replay) apenas empurram eventos na fila; o loop principal drena uma vez por
// frame, grava em JSONL e despacha aos handlers registrados.

EVENT_QUEUE_CAPACITY :: 4096
EVENTS_DIR :: "events" // relativo ao cwd (bin/)

EventType :: enum {
	KeyPress,
	KeyRelease,
	MouseMove,
	MouseButton,
	CloseRequested,
	TeleportTo,
	LookAt,
	AddBlock,
	RemoveBlock,
	Wait,
	ToggleTelemetry,
	TelemetrySnapshot,
}

KeyPayload :: struct {
	key:      i32,
	scancode: i32,
	duration: f64, // < 0 = ausente
}

MouseMovePayload :: struct {
	dx, dy: f32,
}

MouseButtonPayload :: struct {
	button: i32,
	press:  bool,
}

Vec3fPayload :: struct {
	v: [3]f32, // TeleportTo (position) e LookAt (target)
}

Vec3iPayload :: struct {
	v:        [3]i32, // AddBlock/RemoveBlock (position)
	block_id: u32,
}

WaitPayload :: struct {
	seconds: f64,
}

EventPayload :: union {
	KeyPayload,
	MouseMovePayload,
	MouseButtonPayload,
	Vec3fPayload,
	Vec3iPayload,
	WaitPayload,
	struct {}, // CloseRequested, ToggleTelemetry, TelemetrySnapshot
}

Event :: struct {
	t:       f64, // segundos desde o início da aplicação (glfw.GetTime() - t0)
	type:    EventType,
	payload: EventPayload,
}

events: struct {
	t0: f64,

	// fila anel (produtores: callbacks "c"/contextless e cursor de replay)
	queue:          [EVENT_QUEUE_CAPACITY]Event,
	head, tail:     int,
	overflow_count: u64,
	overflow_warned: bool,

	// estado derivado de KeyPress/KeyRelease (substitui o polling glfw.GetKey)
	pressed:           map[i32]bool,
	scheduled_release: map[i32]f64, // KeyPress{duration}: release sintetizado

	handlers: map[EventType]proc(Event),

	// gravação
	record_enabled: bool,
	record_path:    string,
	record_file:    ^os.File,

	// replay
	replay_path:          string,
	replay_events:        []Event, // ordenado por t
	replay_cursor:        int,
	replay_hold_until:    f64, // nenhum evento com t < hold é despachado
	replay_dispatched:    u64,
	replay_skipped:       u64, // linhas inválidas + tipos desconhecidos
	replay_finished:      bool,
	replay_finish_time:   f64,
	exit_after_replay:    bool,
}

events_init :: proc() {
	events.record_enabled = true
	events.pressed = make(map[i32]bool)
	events.scheduled_release = make(map[i32]f64)
	events.handlers = make(map[EventType]proc(Event))

	args := os.args
	record_explicit := false
	for i := 1; i < len(args); i += 1 {
		switch args[i] {
		case "--record":
			if i + 1 < len(args) {
				events.record_path = args[i + 1]
				record_explicit = true
				i += 1
			} else {
				log.error("Flag --record exige um caminho")
				os.exit(1)
			}
		case "--no-record":
			events.record_enabled = false
		case "--replay":
			if i + 1 < len(args) {
				events.replay_path = args[i + 1]
				i += 1
			} else {
				log.error("Flag --replay exige um caminho")
				os.exit(1)
			}
		case "--exit-after-replay":
			events.exit_after_replay = true
		}
	}
	if record_explicit {
		if !events.record_enabled {
			log.warn("Flags conflitantes --no-record + --record; --record vence")
		}
		events.record_enabled = true
	}

	if events.replay_path != "" {
		events_load_replay(events.replay_path)
	}
}

// Chamado no fim da inicialização, antes do primeiro PollEvents (REQ-EVT-07).
events_set_t0 :: proc() {
	events.t0 = glfw.GetTime()
	if events.record_enabled {
		events_recorder_open()
	}
}

events_destroy :: proc() {
	if events.record_file != nil {
		os.flush(events.record_file)
		os.close(events.record_file)
	}
	delete(events.pressed)
	delete(events.scheduled_release)
	delete(events.handlers)
	delete(events.replay_events)
}

// --- Produtores ---

@(private)
events_now :: proc "contextless" () -> f64 {
	return glfw.GetTime() - events.t0
}

// Empurra um evento na fila. Contextless: pode ser chamado de callbacks "c".
events_push :: proc "contextless" (e: Event) {
	next := (events.tail + 1) % EVENT_QUEUE_CAPACITY
	if next == events.head {
		events.overflow_count += 1
		return
	}
	events.queue[events.tail] = e
	events.tail = next
}

// Versão com timestamp para callbacks "c"/contextless: apenas produz.
events_push_now :: proc "contextless" (type: EventType, payload: EventPayload) {
	events_push(Event{t = events_now(), type = type, payload = payload})
}

events_time_now :: proc() -> f64 {
	return events_now()
}

// Emissão fora de callback (cursor de replay, handlers): timestama e empurra.
events_emit :: proc(type: EventType, payload: EventPayload) {
	events_push(Event{t = events_now(), type = type, payload = payload})
}

// --- Registro de handlers ---

events_register :: proc(types: []EventType, handler: proc(Event)) {
	for t in types do events.handlers[t] = handler
}

events_is_pressed :: proc(key: i32) -> bool {
	return events.pressed[key]
}

// --- Gravação ---

@(private)
events_timestamp_string :: proc() -> string {
	now := time.now()
	year, month, day := time.date(now)
	hour, min, sec := time.clock(now)
	return fmt.tprintf("%04d%02d%02d_%02d%02d%02d", year, int(month), day, hour, min, sec)
}

@(private)
events_recorder_open :: proc() {
	path := events.record_path
	if path == "" {
		if !os.is_dir(EVENTS_DIR) {
			os.make_directory(EVENTS_DIR)
		}
		path = fmt.tprintf("%s/events_%s.jsonl", EVENTS_DIR, events_timestamp_string())
	}
	f := events_try_open(path)
	if f == nil {
		log.errorf("Falha ao abrir arquivo de eventos {}", path)
		events.record_enabled = false
		return
	}
	events.record_file = f
	events.record_path = path
	log.infof("Gravação de eventos em {}", path)
}

// Abre o arquivo de gravação, criando os diretórios do caminho se preciso.
@(private)
events_try_open :: proc(path: string) -> ^os.File {
	for i := 0; i < len(path); i += 1 {
		if path[i] == '/' do os.make_directory(path[:i]) // já existe: erro ignorado
	}
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err == nil do return f
	return nil
}

@(private)
events_record_line :: proc(e: Event) {
	if events.record_file == nil do return
	line: string
	switch p in e.payload {
	case KeyPayload:
		key_name := events_key_name(p.key, p.scancode)
		if p.duration >= 0 {
			line = fmt.tprintf(
				`{{"t": {}, "type": "KeyPress", "key": {}, "key_name": "{}", "duration": {}}}` + "\n",
				fmt.tprintf("%.6f", e.t), p.key, key_name, fmt.tprintf("%.3f", p.duration),
			)
		} else {
			line = fmt.tprintf(
				`{{"t": {}, "type": "{}", "key": {}, "key_name": "{}"}}` + "\n",
				fmt.tprintf("%.6f", e.t), event_type_name(e.type), p.key, key_name,
			)
		}
	case MouseMovePayload:
		line = fmt.tprintf(
			`{{"t": {}, "type": "MouseMove", "dx": {}, "dy": {}}}` + "\n",
			fmt.tprintf("%.6f", e.t), fmt.tprintf("%.4f", p.dx), fmt.tprintf("%.4f", p.dy),
		)
	case MouseButtonPayload:
		action := p.press ? "press" : "release"
		line = fmt.tprintf(
			`{{"t": {}, "type": "MouseButton", "button": {}, "action": "{}"}}` + "\n",
			fmt.tprintf("%.6f", e.t), p.button, action,
		)
	case Vec3fPayload:
		field := e.type == .TeleportTo ? "position" : "target"
		line = fmt.tprintf(
			`{{"t": {}, "type": "{}", "{}": [{}, {}, {}]}}` + "\n",
			fmt.tprintf("%.6f", e.t), event_type_name(e.type), field,
			fmt.tprintf("%.4f", p.v.x), fmt.tprintf("%.4f", p.v.y), fmt.tprintf("%.4f", p.v.z),
		)
	case Vec3iPayload:
		if e.type == .AddBlock {
			line = fmt.tprintf(
				`{{"t": {}, "type": "AddBlock", "position": [{}, {}, {}], "block_id": {}}}` + "\n",
				fmt.tprintf("%.6f", e.t), p.v.x, p.v.y, p.v.z, p.block_id,
			)
		} else {
			line = fmt.tprintf(
				`{{"t": {}, "type": "RemoveBlock", "position": [{}, {}, {}]}}` + "\n",
				fmt.tprintf("%.6f", e.t), p.v.x, p.v.y, p.v.z,
			)
		}
	case WaitPayload:
		line = fmt.tprintf(
			`{{"t": {}, "type": "Wait", "seconds": {}}}` + "\n",
			fmt.tprintf("%.6f", e.t), fmt.tprintf("%.3f", p.seconds),
		)
	case struct {}:
		line = fmt.tprintf(
			`{{"t": {}, "type": "{}"}}` + "\n",
			fmt.tprintf("%.6f", e.t), event_type_name(e.type),
		)
	}
	os.write_string(events.record_file, line)
	os.flush(events.record_file)
}

@(private)
events_key_name :: proc(key, scancode: i32) -> string {
	name := glfw.GetKeyName(key, scancode)
	if name == "" do return "?"
	return string(name)
}

// --- Dreno (uma vez por frame, thread principal) ---

events_drain :: proc() {
	t_drain := events_now()

	// releases sintetizados de KeyPress{duration} que já venceram
	for key, until in events.scheduled_release {
		if until <= t_drain {
			events_push(Event{t = t_drain, type = .KeyRelease, payload = KeyPayload{key = key, duration = -1}})
			delete_key(&events.scheduled_release, key)
		}
	}

	// aviso único de overflow por sessão
	if events.overflow_count > 0 && !events.overflow_warned {
		log.warnf("Fila de eventos em overflow; {} eventos descartados", events.overflow_count)
		events.overflow_warned = true
	}

	for events.head != events.tail {
		e := events.queue[events.head]
		events.head = (events.head + 1) % EVENT_QUEUE_CAPACITY

		events_record_line(e)
		events_apply_key_state(e, t_drain)

		if handler, ok := events.handlers[e.type]; ok {
			handler(e)
		}
	}
}

@(private)
events_apply_key_state :: proc(e: Event, t_drain: f64) {
	p, is_key := e.payload.(KeyPayload)
	if !is_key do return
	#partial switch e.type {
	case .KeyPress:
		events.pressed[p.key] = true
		if p.duration >= 0 {
			// última escrita vence (re-marca release de tecla já pressionada)
			events.scheduled_release[p.key] = t_drain + p.duration
		}
	case .KeyRelease:
		events.pressed[p.key] = false
		delete_key(&events.scheduled_release, p.key)
	case:
	}
}

// --- Replay ---

@(private)
json_event :: struct {
	t:        f64             `json:"t"`,
	type:     string          `json:"type"`,
	key:      Maybe(i32)      `json:"key"`,
	key_name: string          `json:"key_name"`,
	duration: Maybe(f64)      `json:"duration"`,
	dx:       Maybe(f64)      `json:"dx"`,
	dy:       Maybe(f64)      `json:"dy"`,
	button:   Maybe(i32)      `json:"button"`,
	action:   Maybe(string)   `json:"action"`,
	position: Maybe([]f64)    `json:"position"`,
	target:   Maybe([]f64)    `json:"target"`,
	block_id: Maybe(u32)      `json:"block_id"`,
	seconds:  Maybe(f64)      `json:"seconds"`,
}

@(private)
event_type_from_name :: proc(name: string) -> (EventType, bool) {
	switch name {
	case "KeyPress":      return .KeyPress, true
	case "KeyRelease":    return .KeyRelease, true
	case "MouseMove":     return .MouseMove, true
	case "MouseButton":   return .MouseButton, true
	case "CloseRequested": return .CloseRequested, true
	case "TeleportTo":    return .TeleportTo, true
	case "LookAt":        return .LookAt, true
	case "AddBlock":      return .AddBlock, true
	case "RemoveBlock":   return .RemoveBlock, true
	case "Wait":          return .Wait, true
	case "ToggleTelemetry":    return .ToggleTelemetry, true
	case "TelemetrySnapshot":  return .TelemetrySnapshot, true
	}
	return {}, false
}

event_type_name :: proc(type: EventType) -> string {
	switch type {
	case .KeyPress:            return "KeyPress"
	case .KeyRelease:          return "KeyRelease"
	case .MouseMove:           return "MouseMove"
	case .MouseButton:         return "MouseButton"
	case .CloseRequested:      return "CloseRequested"
	case .TeleportTo:          return "TeleportTo"
	case .LookAt:              return "LookAt"
	case .AddBlock:            return "AddBlock"
	case .RemoveBlock:         return "RemoveBlock"
	case .Wait:                return "Wait"
	case .ToggleTelemetry:     return "ToggleTelemetry"
	case .TelemetrySnapshot:   return "TelemetrySnapshot"
	}
	return "?"
}

// Converte uma linha JSON em evento; ok = false marca skip (linha inválida
// ou tipo desconhecido), distinguindo apenas a falha de parse de JSON.
@(private)
events_parse_line :: proc(line: string) -> (Event, bool) {
	ev := json_event{}
	err := json.unmarshal(transmute([]byte)line, &ev)
	if err != nil do return {}, false

	type, known := event_type_from_name(ev.type)
	if !known do return {}, false

	e := Event{t = ev.t, type = type}
	switch type {
	case .KeyPress, .KeyRelease:
		key, ok := ev.key.(i32)
		if !ok do return {}, false
		duration := f64(-1)
		if d, has := ev.duration.(f64); has do duration = d
		e.payload = KeyPayload{key = key, duration = duration}
	case .MouseMove:
		dx, ok_x := ev.dx.(f64)
		dy, ok_y := ev.dy.(f64)
		if !ok_x || !ok_y do return {}, false
		e.payload = MouseMovePayload{dx = f32(dx), dy = f32(dy)}
	case .MouseButton:
		button, ok_b := ev.button.(i32)
		action, ok_a := ev.action.(string)
		if !ok_b || !ok_a do return {}, false
		if action != "press" && action != "release" do return {}, false
		e.payload = MouseButtonPayload{button = button, press = action == "press"}
	case .TeleportTo, .LookAt:
		field := ev.position
		if type == .LookAt do field = ev.target
		vec, ok := field.([]f64)
		if !ok || len(vec) != 3 do return {}, false
		e.payload = Vec3fPayload{v = {f32(vec[0]), f32(vec[1]), f32(vec[2])}}
	case .AddBlock, .RemoveBlock:
		vec, ok := ev.position.([]f64)
		if !ok || len(vec) != 3 do return {}, false
		block_id := u32(0)
		if type == .AddBlock {
			id, has_id := ev.block_id.(u32)
			if !has_id || id == 0 || id > 65535 do return {}, false
			block_id = u32(id)
		}
		e.payload = Vec3iPayload{v = {i32(vec[0]), i32(vec[1]), i32(vec[2])}, block_id = block_id}
	case .Wait:
		seconds, ok := ev.seconds.(f64)
		if !ok || seconds < 0 do return {}, false
		e.payload = WaitPayload{seconds = seconds}
	case .CloseRequested, .ToggleTelemetry, .TelemetrySnapshot:
		e.payload = struct {}{}
	}
	return e, true
}

// Carrega e valida o arquivo de replay. Fatal (exit != 0) se ausente,
// ilegível ou com JSON inválido na primeira linha (REQ-EVT-08). Chamado por
// events_init, antes da criação da janela.
@(private)
events_load_replay :: proc(path: string) {
	data, ferr := os.read_entire_file_from_path(path, context.allocator)
	if ferr != nil {
		log.errorf("Arquivo de replay não encontrado ou ilegível: {}", path)
		os.exit(1)
	}

	lines := strings.split(string(data), "\n")
	parsed := make([dynamic]Event, 0, 512, context.temp_allocator)
	first_content_line := true
	for line_raw in lines {
		line := strings.trim_right(strings.trim_space(line_raw), "\r")
		if line == "" do continue

		e, valid := events_parse_line(line)
		if !valid {
			if first_content_line {
				log.errorf("Replay {}: JSON inválido na primeira linha; abortando", path)
				os.exit(1)
			}
			events.replay_skipped += 1
			log.warnf("Replay: linha inválida ou tipo desconhecido, pulando: {}", line)
			continue
		}
		first_content_line = false
		append(&parsed, e)
	}
	delete(lines)

	// ordenação por t (insertion sort: arquivos já vêm quase ordenados)
	events.replay_events = make([]Event, len(parsed), context.allocator)
	copy(events.replay_events, parsed[:])
	for i := 1; i < len(events.replay_events); i += 1 {
		for j := i; j > 0 && events.replay_events[j].t < events.replay_events[j - 1].t; j -= 1 {
			events.replay_events[j], events.replay_events[j - 1] = events.replay_events[j - 1], events.replay_events[j]
		}
	}

	log.infof(
		"Replay carregado: {} eventos, {} linhas puladas ({})",
		len(events.replay_events), events.replay_skipped, path,
	)
}

// Alimenta a fila com os eventos do replay devidos até `now` (REQ-EVT-05:
// Wait segura o cursor; nada com t < hold_until é despachado).
events_replay_feed :: proc(now: f64) {
	if events.replay_path == "" || events.replay_finished do return

	for events.replay_cursor < len(events.replay_events) {
		e := events.replay_events[events.replay_cursor]
		if e.t > now do break
		// Wait: eventos com t anterior ao fim da espera só saem quando o
		// relógio da sessão também passou desse instante (REQ-EVT-05)
		if e.t < events.replay_hold_until && now < events.replay_hold_until do break

		events.replay_cursor += 1
		events.replay_dispatched += 1
		events_push(Event{t = events_now(), type = e.type, payload = e.payload})
		if w, is_wait := e.payload.(WaitPayload); is_wait {
			events.replay_hold_until = e.t + w.seconds
		}
	}

	if events.replay_cursor >= len(events.replay_events) {
		events.replay_finished = true
		events.replay_finish_time = now
		ignored := len(events.replay_events) - events.replay_cursor
		log.infof(
			"REPLAY SUMMARY: despachados={}, pulados(linhas)={}, ignorados(aguardando)={}, duração={}s",
			events.replay_dispatched, events.replay_skipped, ignored, fmt.tprintf("%.3f", now),
		)
	}
}

events_replay_is_finished :: proc() -> bool {
	return events.replay_finished
}

events_should_exit_after_replay :: proc() -> bool {
	return events.exit_after_replay && events.replay_finished
}
