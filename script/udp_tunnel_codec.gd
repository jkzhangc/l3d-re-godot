extends RefCounted

## ── 架构定位 ──
## 系统：UDP弱网隔离原型 ｜ 层：纯字节认证/防重放协议核
## 未接入Tunnel/Net，无socket/场景树；凭据及已验证来源由未来受保护控制面提供。
## 不重传/排序ENet数据报；每次可靠重发会由隧道封装新序号，避免额外TCP队头阻塞。
const HEADER_BYTES := 18
const TAG_BYTES := 16
const MAX_PAYLOAD := 1392
const MAX_DATAGRAM := HEADER_BYTES + MAX_PAYLOAD + TAG_BYTES
const REPLAY_WINDOW := 256
const MAX_SEQUENCE := 0xFFFFFFFF

var _id := PackedByteArray()
var _key := PackedByteArray()
var _tx_direction: int = 0
var _source_address: String = ""
var _source_port: int = 0
var _expires_at_msec: int = 0
var _next_sequence: int = 0
var _highest: int = -1
var _seen: Dictionary = {}
var _closed: bool = true
var _crypto := Crypto.new()
var _pps: float = 2048.0
var _bps: float = 2097152.0
var _packet_tokens: float = 0.0
var _byte_tokens: float = 0.0
var _last_refill_msec: int = 0


func configure(session_id: PackedByteArray, key: PackedByteArray, tx_direction: int,
		source_address: String, source_port: int, expires_at_msec: int,
		packets_per_second: float = 2048.0, bytes_per_second: float = 2097152.0) -> Error:
	close()
	if session_id.size() != 8 or key.size() != 32 or tx_direction not in [0, 1] \
			or not source_address.is_valid_ip_address() or source_port < 1 or source_port > 65535 \
			or expires_at_msec <= _now_msec() or not is_finite(packets_per_second) \
			or packets_per_second < 1.0 or not is_finite(bytes_per_second) or bytes_per_second < MAX_DATAGRAM:
		return ERR_INVALID_PARAMETER
	_id = session_id.duplicate()
	_key = key.duplicate()
	_tx_direction = tx_direction
	_source_address = source_address
	_source_port = source_port
	_expires_at_msec = expires_at_msec
	_next_sequence = 0
	_highest = -1
	_seen.clear()
	_pps = packets_per_second
	_bps = bytes_per_second
	_packet_tokens = _pps
	_byte_tokens = _bps
	_last_refill_msec = _now_msec()
	_closed = false
	return OK


func _now_msec() -> int:
	return Time.get_ticks_msec()


func seal(payload: PackedByteArray) -> PackedByteArray:
	if _closed or _now_msec() >= _expires_at_msec or _next_sequence > MAX_SEQUENCE \
			or payload.is_empty() or payload.size() > MAX_PAYLOAD:
		return PackedByteArray()
	var body := PackedByteArray([76, 51, 68, 85, 1, _tx_direction])
	body.append_array(_id)
	body.append_array(PackedByteArray([(_next_sequence >> 24) & 255, (_next_sequence >> 16) & 255,
		(_next_sequence >> 8) & 255, _next_sequence & 255]))
	_next_sequence += 1
	body.append_array(payload)
	var tag: PackedByteArray = _crypto.hmac_digest(HashingContext.HASH_SHA256, _key, body)
	if tag.size() < TAG_BYTES:
		return PackedByteArray()
	body.append_array(tag.slice(0, TAG_BYTES))
	return body


func open(packet: PackedByteArray, source_address: String, source_port: int) -> PackedByteArray:
	var now: int = _now_msec()
	if _closed or now >= _expires_at_msec or packet.size() <= HEADER_BYTES + TAG_BYTES \
			or packet.size() > MAX_DATAGRAM or source_address != _source_address or source_port != _source_port:
		return PackedByteArray()
	if packet.slice(0, 4) != PackedByteArray([76, 51, 68, 85]) or packet[4] != 1 \
			or packet[5] != 1 - _tx_direction or packet.slice(6, 14) != _id:
		return PackedByteArray()
	var body: PackedByteArray = packet.slice(0, packet.size() - TAG_BYTES)
	var tag: PackedByteArray = _crypto.hmac_digest(HashingContext.HASH_SHA256, _key, body).slice(0, TAG_BYTES)
	if not _crypto.constant_time_compare(tag, packet.slice(packet.size() - TAG_BYTES)):
		return PackedByteArray()
	var sequence: int = (packet[14] << 24) | (packet[15] << 16) | (packet[16] << 8) | packet[17]
	if sequence <= _highest - REPLAY_WINDOW or _seen.has(sequence):
		return PackedByteArray()
	var elapsed: float = maxf(0.0, float(now - _last_refill_msec)) / 1000.0
	_packet_tokens = minf(_pps, _packet_tokens + elapsed * _pps)
	_byte_tokens = minf(_bps, _byte_tokens + elapsed * _bps)
	_last_refill_msec = maxi(_last_refill_msec, now)
	if _packet_tokens < 1.0 or _byte_tokens < packet.size():
		return PackedByteArray()
	_packet_tokens -= 1.0
	_byte_tokens -= packet.size()
	_highest = maxi(_highest, sequence)
	_seen[sequence] = true
	for old: int in _seen.keys():
		if old <= _highest - REPLAY_WINDOW:
			_seen.erase(old)
	return body.slice(HEADER_BYTES)


func close() -> void:
	_closed = true
	_key.fill(0)
	_key.clear()
	_seen.clear()
