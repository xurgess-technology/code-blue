extends Node
## Multiplayer autoload. Wraps ENet so the rest of the game only deals with
## "am I the host", "who is here", and a handful of signals. Swapping in Steam
## peer-to-peer later means replacing the peer created in host()/join() with
## GodotSteam's MultiplayerPeer; nothing else here changes.

signal roster_changed
signal joined_ok
signal join_failed(reason: String)
signal host_left

## peer id -> display name
var names: Dictionary = {}
var local_name: String = "Surgeon"
var active: bool = false
var solo: bool = false

const HOST_ID := 1


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_host() -> bool:
	return solo or (active and multiplayer.is_server())


func my_id() -> int:
	return HOST_ID if solo else multiplayer.get_unique_id()


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
	active = false
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
	solo = false
	names = {HOST_ID: player_name}
	roster_changed.emit()
	return ""


func join(address: String, port: int = C.DEFAULT_PORT) -> String:
	reset()
	local_name = ""  # set by the caller through local_name before join
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return "Could not reach %s:%d (error %d)." % [address, port, err]
	multiplayer.multiplayer_peer = peer
	active = true
	solo = false
	return ""


func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	reset()


func reset() -> void:
	multiplayer.multiplayer_peer = null
	names.clear()
	active = false
	solo = false


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


# ---------- peer plumbing ----------

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		# Tell the newcomer everyone who is already here, then let them introduce themselves.
		_send_roster.rpc_id(id, names)


func _on_peer_disconnected(id: int) -> void:
	names.erase(id)
	roster_changed.emit()
	if multiplayer.is_server():
		_send_roster.rpc(names)


func _on_connected() -> void:
	_introduce.rpc_id(HOST_ID, local_name)
	joined_ok.emit()


func _on_connect_failed() -> void:
	reset()
	join_failed.emit("The host did not answer.")


func _on_server_disconnected() -> void:
	reset()
	host_left.emit()


@rpc("any_peer", "reliable")
func _introduce(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	var clean := player_name.strip_edges().substr(0, 16)
	names[id] = clean if not clean.is_empty() else "Surgeon %d" % id
	roster_changed.emit()
	_send_roster.rpc(names)


@rpc("authority", "reliable", "call_remote")
func _send_roster(roster: Dictionary) -> void:
	names = roster.duplicate()
	roster_changed.emit()
