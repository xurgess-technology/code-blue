extends Node
## Multiplayer autoload. The rest of the game only deals with "am I the host", "who is here"
## and a handful of signals; which transport carries the packets is this file's business.
##
## Backends (`backend`):
##   "solo"   no peer at all, everything runs locally (also the state after leave())
##   "enet"   host / join by IP address (LAN, port forwarding, Tailscale, local tests)
##   "steam"  a friends-only Steam lobby plus GodotSteam's SteamMultiplayerPeer
##
## Steam is optional. GodotSteam is a GDExtension (addons/godotsteam); when the extension is
## missing, fails to load, or the Steam client is not running, steam_available() is false,
## the menu hides its Steam buttons and ENet keeps working. Nothing in this file names a
## GodotSteam class directly, so the script still parses without the extension.
##
## Lag and loss simulation (testing only): `--net-lag=MS --net-jitter=MS --net-loss=0..1` on
## the command line of a joining client (or set_lag_simulation() before join()) puts a small
## UDP proxy inside that client process between its ENet peer and the host. Every datagram in
## both directions is delayed by lag +- jitter wall-clock milliseconds and dropped with
## probability `loss`, so ENet's reliable channel really retransmits and unreliable
## snapshots really go missing. ENet only.

signal roster_changed
signal joined_ok
signal join_failed(reason: String)
signal host_left
## Steam hosting is asynchronous: the lobby has to exist before anyone can join.
signal host_ready
signal host_failed(reason: String)
## The local player accepted a Steam invite or chose "Join game" on a friend (overlay or
## friends list), or the game was launched with +connect_lobby. The main scene joins it.
signal invite_accepted(lobby_id: int)

## peer id -> display name
var names: Dictionary = {}
## The name this machine introduces itself with. Survives reset(); set it before join().
var local_name: String = "Surgeon"
var active: bool = false
var solo: bool = false
var backend: String = "solo"

## Steam state
var steam_ready: bool = false
var steam_status: String = "not initialised"
var lobby_id: int = 0
var _steam: Object = null
var _steam_connecting_lobby: int = 0

## Lag simulation settings for the next join()
var sim_lag_ms: float = 0.0
var sim_jitter_ms: float = 0.0
var sim_loss: float = 0.0
var _proxy: LagProxy = null

## Bytes this machine put on / took off the wire through ENet (all channels, headers included).
var bytes_sent: int = 0
var bytes_received: int = 0

const HOST_ID := 1
const STEAM_APP_ID := 480
const LOBBY_TYPE_FRIENDS_ONLY := 1
const RESULT_OK := 1
const CHAT_ROOM_ENTER_SUCCESS := 1
## ENet peer timeouts (ms): a peer that stops answering is dropped after 5 to 12 seconds
## instead of ENet's default 30 (once settled; see PATIENT_* for the first seconds).
const TIMEOUT_MIN_MS := 5000
const TIMEOUT_MAX_MS := 12000
## While a machine builds a level it does not service the connection for seconds, and ENet's
## round-trip estimate stays inflated for a while afterwards (a lost reliable packet is then
## resent many seconds later). Right after connecting and around a new hospital, peers get this
## much more patience; Game hands them back to the normal timeouts once things settle.
const PATIENT_TIMEOUT_LIMIT := 64
const PATIENT_TIMEOUT_MIN_MS := 10000
const PATIENT_TIMEOUT_MAX_MS := 20000


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	var no_steam := DisplayServer.get_name() == "headless"
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"net-lag": sim_lag_ms = float(v)
			"net-jitter": sim_jitter_ms = float(v)
			"net-loss": sim_loss = clampf(float(v), 0.0, 1.0)
			"no-steam": no_steam = true
			"steam": no_steam = false
	if not no_steam:
		_steam_init()


func _process(_delta: float) -> void:
	if _steam != null and steam_ready:
		_steam.run_callbacks()
	if _proxy != null:
		_proxy.poll()
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null and enet.host != null:
		bytes_sent += enet.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
		bytes_received += enet.host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
		_sample_link(enet)


## Diagnostics for a dropped connection: the last round-trip estimate per peer and the longest
## frame (a stretch without servicing the connection) of the last 10 to 20 seconds.
var _link_stats: Dictionary = {}   # peer id -> String
var _stall_ms := [0, 0]            # longest frame this window, previous window
var _last_frame_ms := 0
var _link_sample_ms := 0


func _sample_link(enet: ENetMultiplayerPeer) -> void:
	var now := Time.get_ticks_msec()
	if _last_frame_ms > 0:
		_stall_ms[0] = maxi(int(_stall_ms[0]), now - _last_frame_ms)
	_last_frame_ms = now
	if now - _link_sample_ms < 1000:
		return
	if now / 10000 != _link_sample_ms / 10000:
		_stall_ms = [0, _stall_ms[0]]
	_link_sample_ms = now
	for id in names.keys():
		if id == multiplayer.get_unique_id():
			continue
		var pp := enet.get_peer(id)
		if pp != null:
			_link_stats[id] = "rtt %d ms (var %d), loss %.1f%%" % [pp.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME), pp.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE), pp.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / 655.36]


func _log_lost(id: int) -> void:
	if backend != "enet":
		return
	print("[net] peer %d disconnected: last %s; longest frame lately %d ms" % [id, _link_stats.get(id, "no stats"), maxi(int(_stall_ms[0]), int(_stall_ms[1]))])


func is_host() -> bool:
	return solo or (active and multiplayer.is_server())


func my_id() -> int:
	if solo or multiplayer.multiplayer_peer == null:
		return HOST_ID
	return multiplayer.get_unique_id()


func peer_ids() -> Array:
	var ids := names.keys()
	ids.sort()
	return ids


func name_for(id: int) -> String:
	return names.get(id, "Surgeon %d" % id)


## Solo play: no peer at all, everything runs locally.
func start_solo(player_name: String) -> void:
	reset()
	local_name = player_name
	solo = true
	backend = "solo"
	names = {HOST_ID: player_name}
	roster_changed.emit()


func host(player_name: String, port: int = C.DEFAULT_PORT) -> String:
	reset()
	local_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, C.MAX_PLAYERS)
	if err != OK:
		return "Could not listen on port %d (error %d). Is something already hosting?" % [port, err]
	multiplayer.multiplayer_peer = peer
	active = true
	backend = "enet"
	names = {HOST_ID: player_name}
	roster_changed.emit()
	return ""


## Join by address. `player_name` is optional: without it, whatever `local_name` holds is used.
func join(address: String, port: int = C.DEFAULT_PORT, player_name: String = "") -> String:
	reset()
	if not player_name.is_empty():
		local_name = player_name
	var target := address
	var target_port := port
	if sim_lag_ms > 0.0 or sim_jitter_ms > 0.0 or sim_loss > 0.0:
		var ip := address if address.is_valid_ip_address() else IP.resolve_hostname(address, IP.TYPE_IPV4)
		_proxy = LagProxy.new(sim_lag_ms, sim_jitter_ms, sim_loss)
		var local_port := _proxy.start(ip, port)
		if local_port <= 0:
			_proxy = null
			return "Could not start the lag simulator."
		target = "127.0.0.1"
		target_port = local_port
		print("[net] lag simulation: %d ms +- %d ms, %.0f%% loss via 127.0.0.1:%d" % [sim_lag_ms, sim_jitter_ms, sim_loss * 100.0, local_port])
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(target, target_port)
	if err != OK:
		_proxy = null
		return "Could not reach %s:%d (error %d)." % [address, port, err]
	multiplayer.multiplayer_peer = peer
	active = true
	backend = "enet"
	return ""


func set_lag_simulation(lag_ms: float, jitter_ms: float = 0.0, loss: float = 0.0) -> void:
	sim_lag_ms = maxf(0.0, lag_ms)
	sim_jitter_ms = maxf(0.0, jitter_ms)
	sim_loss = clampf(loss, 0.0, 1.0)


func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	reset()


## Drop the connection state. Keeps `local_name`: the menu sets it before join() calls this.
func reset() -> void:
	if lobby_id != 0 and _steam != null and steam_ready:
		_steam.leaveLobby(lobby_id)
	lobby_id = 0
	_steam_connecting_lobby = 0
	multiplayer.multiplayer_peer = null
	names.clear()
	active = false
	solo = false
	backend = "solo"
	if _proxy != null:
		_proxy.close()
		_proxy = null


## Split "host:port" / "host" / "ws://host:port" into an address and a port.
static func parse_address(text: String, default_port: int = C.DEFAULT_PORT) -> Dictionary:
	var s := text.strip_edges()
	s = s.trim_prefix("ws://").trim_prefix("wss://").trim_prefix("http://").trim_prefix("https://")
	s = s.trim_suffix("/")
	if s.is_empty():
		s = "127.0.0.1"
	var port := default_port
	# IPv6 in brackets, e.g. [::1]:7777
	if s.begins_with("["):
		var close := s.find("]")
		if close > 0:
			var host_part := s.substr(1, close - 1)
			var rest := s.substr(close + 1)
			if rest.begins_with(":") and rest.substr(1).is_valid_int():
				port = int(rest.substr(1))
			return {"address": host_part, "port": port}
	var bits := s.split(":")
	if bits.size() == 2 and bits[1].is_valid_int():
		return {"address": bits[0], "port": int(bits[1])}
	return {"address": s, "port": port}


## Every non-loopback IPv4 this machine has, for showing friends what to type.
static func local_addresses() -> Array[String]:
	var out: Array[String] = []
	for a in IP.get_local_addresses():
		if a.contains(":"):
			continue  # skip IPv6
		if a.begins_with("127.") or a.begins_with("169.254."):
			continue
		out.append(a)
	return out


# =========================================================================
# Steam
# =========================================================================

## True when GodotSteam loaded, the Steam client is running and SteamAPI initialised.
func steam_available() -> bool:
	return steam_ready and ClassDB.class_exists("SteamMultiplayerPeer")


func _steam_init() -> void:
	if not Engine.has_singleton("Steam"):
		steam_status = "GodotSteam extension not loaded"
		return
	_steam = Engine.get_singleton("Steam")
	var res = _steam.steamInitEx(STEAM_APP_ID, false)
	var status := int(res.get("status", -1)) if res is Dictionary else (0 if res == true else -1)
	if status != 0:
		steam_status = "Steam init failed (%s)" % (str(res.get("verbal", status)) if res is Dictionary else str(res))
		print("[net] %s; Steam features hidden." % steam_status)
		_steam = null
		return
	steam_ready = true
	steam_status = "ok"
	var pname := String(_steam.getPersonaName())
	if not pname.is_empty():
		local_name = pname.substr(0, 16)
	_steam.connect("lobby_created", _on_lobby_created)
	_steam.connect("lobby_joined", _on_lobby_joined)
	_steam.connect("join_requested", _on_steam_join_requested)
	_steam.connect("lobby_chat_update", func(_l, _c, _m, _s): _refresh_steam_names())
	_steam.connect("persona_state_change", func(_id, _f): _refresh_steam_names())
	print("[net] Steam ready as %s (%d)" % [pname, int(_steam.getSteamID())])
	# Launched from an invite while the game was closed: "+connect_lobby <id>".
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "+connect_lobby" and i + 1 < args.size() and args[i + 1].is_valid_int():
			var lid := int(args[i + 1])
			# Let the menu build first.
			get_tree().process_frame.connect(func(): invite_accepted.emit(lid), CONNECT_ONE_SHOT)


func my_steam_name() -> String:
	return String(_steam.getPersonaName()) if steam_ready else ""


## Create a friends-only lobby and host a SteamMultiplayerPeer on it. Answers through
## host_ready / host_failed. Returns "" when the request went out.
func host_steam(player_name: String = "") -> String:
	if not steam_available():
		return "Steam is not available (%s)." % steam_status
	reset()
	local_name = player_name if not player_name.is_empty() else my_steam_name()
	_steam.createLobby(LOBBY_TYPE_FRIENDS_ONLY, C.MAX_PLAYERS)
	return ""


func _on_lobby_created(result: int, new_lobby_id: int) -> void:
	if result != RESULT_OK:
		host_failed.emit("Steam could not create a lobby (result %d)." % result)
		return
	lobby_id = new_lobby_id
	_steam.setLobbyJoinable(lobby_id, true)
	_steam.setLobbyData(lobby_id, "game", "code_blue")
	_steam.setLobbyData(lobby_id, "host", local_name)
	var peer: MultiplayerPeer = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.call("host_with_lobby", lobby_id)
	if err != OK:
		err = peer.call("create_host", 0)
	if err != OK:
		_steam.leaveLobby(lobby_id)
		lobby_id = 0
		host_failed.emit("Steam could not host (error %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	active = true
	solo = false
	backend = "steam"
	names = {HOST_ID: local_name}
	_steam.setRichPresence("connect", "+connect_lobby %d" % lobby_id)
	_steam.setRichPresence("status", "Hosting a shift")
	print("[net] Steam lobby %d created" % lobby_id)
	roster_changed.emit()
	host_ready.emit()


## Join a friend's lobby. Answers through joined_ok / join_failed.
func join_steam(target_lobby: int, player_name: String = "") -> String:
	if not steam_available():
		return "Steam is not available (%s)." % steam_status
	reset()
	local_name = player_name if not player_name.is_empty() else my_steam_name()
	_steam_connecting_lobby = target_lobby
	_steam.joinLobby(target_lobby)
	return ""


func _on_lobby_joined(joined: int, _permissions: int, _locked: bool, response: int) -> void:
	if joined != _steam_connecting_lobby:
		return  # our own lobby as host, or a stale request
	_steam_connecting_lobby = 0
	if response != CHAT_ROOM_ENTER_SUCCESS:
		join_failed.emit("Could not enter the Steam lobby (response %d)." % response)
		return
	lobby_id = joined
	var owner := int(_steam.getLobbyOwner(lobby_id))
	if owner == int(_steam.getSteamID()):
		join_failed.emit("That is your own lobby.")
		return
	var peer: MultiplayerPeer = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.call("connect_to_lobby", lobby_id)
	if err != OK:
		err = peer.call("create_client", owner, 0)
	if err != OK:
		_steam.leaveLobby(lobby_id)
		lobby_id = 0
		join_failed.emit("Could not connect to the host over Steam (error %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	active = true
	solo = false
	backend = "steam"
	_steam.setRichPresence("connect", "+connect_lobby %d" % lobby_id)


func _on_steam_join_requested(requested_lobby: int, _friend: int) -> void:
	invite_accepted.emit(requested_lobby)


## Opens the Steam overlay's invite dialog for the current lobby.
func invite_friends() -> bool:
	if backend != "steam" or lobby_id == 0 or _steam == null:
		return false
	_steam.activateGameOverlayInviteDialog(lobby_id)
	return true


## Steam personas are the names that count; the host rewrites the roster from them.
func _refresh_steam_names() -> void:
	if backend != "steam" or not multiplayer.is_server():
		return
	var changed := false
	for id in names.keys():
		var nm := _steam_name_for_peer(id)
		if nm != "" and names[id] != nm:
			names[id] = nm
			changed = true
	if changed:
		roster_changed.emit()
		_send_roster.rpc(names)


func _steam_name_for_peer(id: int) -> String:
	if backend != "steam" or _steam == null or multiplayer.multiplayer_peer == null:
		return ""
	var sid := int(_steam.getSteamID()) if id == HOST_ID else int(multiplayer.multiplayer_peer.call("get_steam_id_for_peer_id", id))
	if sid == 0:
		return ""
	var nm := String(_steam.getPersonaName()) if id == HOST_ID else String(_steam.getFriendPersonaName(sid))
	return nm.strip_edges().substr(0, 16)


# =========================================================================
# peer plumbing
# =========================================================================

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_set_timeouts(id)
		# Tell the newcomer everyone who is already here, then let them introduce themselves.
		_send_roster.rpc_id(id, names)


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		_log_lost(id)
	names.erase(id)
	roster_changed.emit()
	if multiplayer.is_server():
		_send_roster.rpc(names)


func _on_connected() -> void:
	_set_timeouts(HOST_ID)
	_introduce.rpc_id(HOST_ID, local_name)
	joined_ok.emit()


func _set_timeouts(id: int) -> void:
	set_patient(id, true)


## ENet only: `patient` timeouts (see PATIENT_*) or the normal ones for one peer.
func set_patient(id: int, patient: bool) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var pp := enet.get_peer(id)
	if pp == null:
		return
	if patient:
		pp.set_timeout(PATIENT_TIMEOUT_LIMIT, PATIENT_TIMEOUT_MIN_MS, PATIENT_TIMEOUT_MAX_MS)
	else:
		pp.set_timeout(0, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)


func _on_connect_failed() -> void:
	reset()
	join_failed.emit("The host did not answer.")


func _on_server_disconnected() -> void:
	_log_lost(HOST_ID)
	reset()
	host_left.emit()


@rpc("any_peer", "reliable")
func _introduce(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	var clean := player_name.strip_edges().substr(0, 16)
	var steam_name := _steam_name_for_peer(id)
	if steam_name != "":
		clean = steam_name
	names[id] = clean if not clean.is_empty() else "Surgeon %d" % id
	roster_changed.emit()
	_send_roster.rpc(names)


@rpc("authority", "reliable", "call_remote")
func _send_roster(roster: Dictionary) -> void:
	names = roster.duplicate()
	roster_changed.emit()


# =========================================================================
# lag simulation
# =========================================================================

## A UDP relay living inside a client process: ENet client <-> 127.0.0.1:local_port <-> host.
class LagProxy extends RefCounted:
	var lag_ms: float
	var jitter_ms: float
	var loss: float
	var dropped: int = 0
	var forwarded: int = 0
	var _listen := PacketPeerUDP.new()
	var _up := PacketPeerUDP.new()
	var _client_ip := ""
	var _client_port := 0
	var _queue: Array = []   # [release_msec: int, to_host: bool, bytes: PackedByteArray], sorted
	var _rng := RandomNumberGenerator.new()
	const RECV_BUFFER := 1 << 22

	func _init(lag: float, jitter: float, loss_rate: float) -> void:
		lag_ms = lag
		jitter_ms = jitter
		loss = loss_rate
		_rng.randomize()

	func start(host_ip: String, host_port: int) -> int:
		# A roomy receive buffer: the relay only drains once per frame, and a slow frame must not
		# drop datagrams on its own on top of the simulated loss.
		if _listen.bind(0, "127.0.0.1", RECV_BUFFER) != OK:
			return 0
		if _up.bind(0, "*", RECV_BUFFER) != OK:
			return 0
		_up.set_dest_address(host_ip, host_port)
		return _listen.get_local_port()

	func poll() -> void:
		var now := Time.get_ticks_msec()
		while _listen.get_available_packet_count() > 0:
			var pkt := _listen.get_packet()
			_client_ip = _listen.get_packet_ip()
			_client_port = _listen.get_packet_port()
			_enqueue(now, true, pkt)
		while _up.get_available_packet_count() > 0:
			_enqueue(now, false, _up.get_packet())
		while not _queue.is_empty() and int(_queue[0][0]) <= now:
			var e: Array = _queue.pop_front()
			if bool(e[1]):
				_up.put_packet(e[2])
			elif _client_port != 0:
				_listen.set_dest_address(_client_ip, _client_port)
				_listen.put_packet(e[2])
			forwarded += 1

	func _enqueue(now: int, to_host: bool, pkt: PackedByteArray) -> void:
		if loss > 0.0 and _rng.randf() < loss:
			dropped += 1
			return
		var at := now + int(maxf(0.0, lag_ms + _rng.randf_range(-jitter_ms, jitter_ms)))
		var i := _queue.size()
		while i > 0 and int(_queue[i - 1][0]) > at:
			i -= 1
		_queue.insert(i, [at, to_host, pkt])

	func close() -> void:
		_listen.close()
		_up.close()
		_queue.clear()
