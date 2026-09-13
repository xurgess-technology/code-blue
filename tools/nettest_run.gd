extends SceneTree
## Runs every multiplayer scenario in tools/nettest.gd, each as real separate processes (one
## host plus one to three clients) on localhost, and prints a summary. Exits 0 only if every
## scenario passed.
##
##   godot --headless --path . --script tools/nettest_run.gd
##   godot --headless --path . --script tools/nettest_run.gd -- --only=deliver,late_join
##   godot --headless --path . --script tools/nettest_run.gd -- --only=bandwidth
##
## Options (after --):
##   --only=a,b         run just these scenarios (names from SCENARIOS below)
##   --lag=MS --jitter=MS --loss=0..1
##                      simulated network for the clients of *every* scenario (the full_shift_lag
##                      scenario has its own: 120 ms +- 40 ms, 3% loss, unless overridden here)
##   --realtime         run the game processes in real time instead of --fixed-fps 60
##   --speed=N          with --fixed-fps, cap each process at N times real time (default 4)
##   --verbose          echo every line the processes print, not just the test's own
##   --port=N           first port to use (default 7790; one more per scenario)
##
## Full logs of each process go to tools/nettest_logs/<scenario>_<role>.log.
##
## How the lag layer works: Net (scripts/net.gd) reads --net-lag / --net-jitter / --net-loss and
## routes that client's ENet traffic through a UDP relay inside the client process that delays
## and drops datagrams in both directions (wall-clock milliseconds). With --fixed-fps the game
## runs faster than real time, so the same wall-clock lag is proportionally more game time: the
## test is harsher than real play, not gentler.

const LAG_DEFAULT := {"lag": 120.0, "jitter": 40.0, "loss": 0.03}

## name: {scenario, clients, timeout (wall s), start_after {client index: marker line},
##        may_die [process indices whose exit code is ignored], lag (bool), extra [args]}
const SCENARIOS := [
	{"name": "names", "scenario": "names", "clients": 3, "timeout": 120},
	{"name": "deliver", "scenario": "deliver", "clients": 2, "timeout": 180},
	{"name": "surgery", "scenario": "surgery", "clients": 2, "timeout": 240},
	{"name": "leave_items", "scenario": "leave_items", "clients": 2, "timeout": 180},
	{"name": "leave_operating", "scenario": "leave_operating", "clients": 2, "timeout": 300, "may_die": [1]},
	{"name": "late_join", "scenario": "late_join", "clients": 2, "timeout": 300, "start_after": {2: "[marker] shift_started"}},
	{"name": "host_quit", "scenario": "host_quit", "clients": 2, "timeout": 180},
	{"name": "host_kill", "scenario": "host_kill", "clients": 2, "timeout": 180, "may_die": [0]},
	# Seed 4247 is the seal with an amputation: four steps, the longest case.
	{"name": "economy", "scenario": "economy", "clients": 3, "timeout": 300, "start_after": {3: "[marker] economy_bought"}},
	{"name": "downed", "scenario": "downed", "clients": 2, "timeout": 300},
	{"name": "full_shift_lag", "scenario": "full_shift", "clients": 2, "timeout": 900, "lag": true, "extra": ["--seed=4247"]},
	# loop (sweep 2): two patients on two tables, two clients operating at once.
	{"name": "two_patients", "scenario": "two_patients", "clients": 2, "timeout": 300},
]
## Not part of the default run: bandwidth measurements (4 players, no lag, --stats). `bandwidth`
## is Bob's gunshot (seed 4242, the case the pre-delta numbers were taken on); `bandwidth_amp`
## is Bob's amputation (seed 4243), four steps including the saw.
const EXTRA := [
	{"name": "bandwidth", "scenario": "full_shift", "clients": 3, "timeout": 900, "extra": ["--stats", "--seed=4242"]},
	{"name": "bandwidth_amp", "scenario": "full_shift", "clients": 3, "timeout": 900, "extra": ["--stats", "--seed=4243"]},
]

var _only: Array = []
var _lag := {}
var _realtime := false
var _speed := 4
var _verbose := false
var _log_dir := ""
var _port_base := 7790


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"only": _only = Array(v.split(",", false))
			"lag": _lag["lag"] = float(v)
			"jitter": _lag["jitter"] = float(v)
			"loss": _lag["loss"] = float(v)
			"realtime": _realtime = true
			"speed": _speed = maxi(1, int(v))
			"verbose": _verbose = true
			"port": _port_base = int(v)   # first port (parallel worktrees must not share one)
	_log_dir = ProjectSettings.globalize_path("res://tools/nettest_logs")
	DirAccess.make_dir_recursive_absolute(_log_dir)
	_main.call_deferred()


func _main() -> void:
	var todo: Array = []
	for s in SCENARIOS + EXTRA:
		if (_only.is_empty() and SCENARIOS.has(s)) or _only.has(s.name):
			todo.append(s)
	if todo.is_empty():
		print("[run] nothing to run; scenarios: ", ", ".join((SCENARIOS + EXTRA).map(func(s): return s.name)))
		quit(1)
		return
	var results := []
	var port := _port_base
	for s in todo:
		var started := Time.get_ticks_msec()
		var r: Dictionary = await _run_scenario(s, port)
		port += 1
		r["secs"] = (Time.get_ticks_msec() - started) / 1000.0
		results.append(r)
		print("[run] %s %s (%.0f s)%s" % [s.name, "PASS" if r.ok else "FAIL", r.secs, "" if r.ok else ": " + r.why])
	print("[run] ==================================================")
	var all_ok := true
	for r in results:
		all_ok = all_ok and r.ok
		print("[run] %-16s %s  %5.0f s  %s" % [r.name, "PASS" if r.ok else "FAIL", r.secs, r.why])
		for line in r.stats:
			print("[run]    ", line)
	print("[run] %s" % ("ALL PASSED" if all_ok else "SOME FAILED"))
	quit(0 if all_ok else 1)


func _run_scenario(s: Dictionary, port: int) -> Dictionary:
	print("[run] ---- %s: host + %d client(s) on port %d" % [s.name, s.clients, port])
	var exe := OS.get_executable_path()
	var base := ["--headless"]
	if not _realtime:
		base += ["--fixed-fps", "60", "--max-fps", str(60 * _speed)]
	base += ["--path", ProjectSettings.globalize_path("res://"), "res://tools/nettest.tscn", "--"]
	var common := ["--scenario=%s" % s.scenario, "--clients=%d" % s.clients, "--port=%d" % port, "--timeout=%d" % (int(s.timeout) - 10)]
	common += s.get("extra", [])
	var lag := _lag.duplicate()
	if s.get("lag", false):
		for k in LAG_DEFAULT.keys():
			if not lag.has(k):
				lag[k] = LAG_DEFAULT[k]
	var procs := []   # {tag, args, pid, out, err, buf, log, started, exit}
	for i in s.clients + 1:
		var args: Array = base + common
		if i == 0:
			args += ["--role=host"]
		else:
			args += ["--role=client", "--index=%d" % i]
			if not lag.is_empty():
				args += ["--net-lag=%d" % int(lag.get("lag", 0.0)), "--net-jitter=%d" % int(lag.get("jitter", 0.0)), "--net-loss=%.3f" % float(lag.get("loss", 0.0))]
		var tag := "host" if i == 0 else "c%d" % i
		procs.append({"tag": tag, "args": args, "pid": -1, "started": false, "exit": -999,
			"log": FileAccess.open("%s/%s_%s.log" % [_log_dir, s.name, tag], FileAccess.WRITE), "buf": ""})
	var start_after: Dictionary = s.get("start_after", {})
	var may_die: Array = s.get("may_die", [])
	var markers := {}
	var stats := []
	var t0 := Time.get_ticks_msec()
	var timed_out := false
	while true:
		# Start processes: the host first, clients a moment later, gated ones on their marker.
		for i in procs.size():
			var p: Dictionary = procs[i]
			if p.started:
				continue
			var gate: String = start_after.get(i, "")
			var ready := (i == 0) or (Time.get_ticks_msec() - t0 > 1500 + 300 * i)
			if gate != "":
				ready = markers.has(gate)
			if ready:
				var h := OS.execute_with_pipe(exe, PackedStringArray(p.args), false)
				if h.is_empty():
					return {"name": s.name, "ok": false, "why": "could not start %s" % p.tag, "stats": []}
				p.pid = h.pid
				p.out = h.stdio
				p.err = h.stderr
				p.started = true
		# Pump output.
		var running := 0
		for p in procs:
			if not p.started:
				running += 1
				continue
			for line in _read_lines(p):
				p.log.store_line(line)
				if line.begins_with("[marker]"):
					markers[line.strip_edges()] = true
				if line.begins_with("[stats]"):
					stats.append(line)
				if _verbose or line.begins_with("[net") or line.begins_with("[stats]") or line.contains("SCRIPT ERROR") or line.begins_with("ERROR"):
					print("  [%s] %s" % [p.tag, line])
			if p.exit == -999:
				if OS.is_process_running(p.pid):
					running += 1
				else:
					for line in _read_lines(p, true):
						p.log.store_line(line)
						if _verbose or line.begins_with("[net") or line.begins_with("[stats]") or line.contains("SCRIPT ERROR"):
							print("  [%s] %s" % [p.tag, line])
						if line.begins_with("[stats]"):
							stats.append(line)
					p.exit = OS.get_process_exit_code(p.pid)
		if running == 0:
			break
		if Time.get_ticks_msec() - t0 > int(s.timeout) * 1000:
			timed_out = true
			for p in procs:
				if p.started and OS.is_process_running(p.pid):
					OS.kill(p.pid)
			break
		await create_timer(0.05).timeout
	for p in procs:
		if p.log != null:
			p.log.close()
	if timed_out:
		return {"name": s.name, "ok": false, "why": "runner timeout after %d s" % int(s.timeout), "stats": stats}
	var bad := []
	for i in procs.size():
		if may_die.has(i):
			continue
		if int(procs[i].exit) != 0:
			bad.append("%s exited %d" % [procs[i].tag, procs[i].exit])
	return {"name": s.name, "ok": bad.is_empty(), "why": ", ".join(bad) if not bad.is_empty() else "every process passed", "stats": stats}


func _read_lines(p: Dictionary, final := false) -> Array:
	var lines := []
	for key in ["out", "err"]:
		var f: FileAccess = p.get(key)
		if f == null:
			continue
		var buf_key: String = "buf_" + key
		var buf: String = p.get(buf_key, "")
		while true:
			var b: PackedByteArray = f.get_buffer(8192)
			if b.is_empty():
				break
			buf += b.get_string_from_utf8()
			if b.size() < 8192:
				break
		var parts: PackedStringArray = buf.split("\n")
		for i in parts.size() - 1:
			lines.append(parts[i].strip_edges(false, true))
		buf = parts[parts.size() - 1]
		if final and not buf.is_empty():
			lines.append(buf)
			buf = ""
		p[buf_key] = buf
	return lines
