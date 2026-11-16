extends Node

## 隔离UDP协议核跨语言向量与弱网语义，不接入生产Tunnel，不写配置/存档。
const CODEC := preload("res://script/udp_tunnel_codec.gd")
const VECTOR := "4c3344550100000102030405060700000000000102ffb7b4cc6229cad9781e775cffcb80b798"
var _checks: int = 0
var _failures: int = 0

class ClockCodec extends "res://script/udp_tunnel_codec.gd":
	var clock: int = 1000
	func _now_msec() -> int:
		return clock

func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("NETWORK_UDP_CODEC_CHECK FAIL " + label)

func _make(direction: int, pps: float = 2048.0) -> ClockCodec:
	var codec := ClockCodec.new()
	var key := PackedByteArray()
	for i: int in 32:
		key.append(i)
	_check(codec.configure("0001020304050607".hex_decode(), key, direction,
		"127.0.0.1", 27994, 20000, pps) == OK, "会话配置")
	return codec

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var tx := _make(0)
	var rx := _make(1)
	var packet: PackedByteArray = tx.seal("000102ff".hex_decode())
	_check(packet.hex_encode() == VECTOR, "Node/Godot大端HMAC固定向量一致")
	_check(rx.open(packet, "127.0.0.1", 1).is_empty(), "错误源端口拒绝")
	_check(rx.open(packet, "127.0.0.2", 27994).is_empty(), "错误来源地址拒绝")
	_check(rx._highest == -1, "无效来源不占用重放序号")
	_check(rx.open(packet, "127.0.0.1", 27994) == "000102ff".hex_decode(), "合法字节完整恢复")
	_check(rx.open(packet, "127.0.0.1", 27994).is_empty(), "重复数据报拒绝")
	_check(tx.open(packet, "127.0.0.1", 27994).is_empty(), "反射方向拒绝")
	for index: int in [0, 4, 5, 6, 14, 18, packet.size() - 1]:
		var bad: PackedByteArray = packet.duplicate()
		bad[index] ^= 1
		_check(rx.open(bad, "127.0.0.1", 27994).is_empty(), "头部或内容篡改拒绝%d" % index)
	tx = _make(0)
	rx = _make(1)
	var packets: Array[PackedByteArray] = []
	for i: int in 12:
		packets.append(tx.seal(PackedByteArray([i])))
	for i: int in [2, 1, 3, 6, 5, 7, 10, 9, 11]:
		_check(rx.open(packets[i], "127.0.0.1", 27994) == PackedByteArray([i]),
			"丢0/4/8且乱序，后包无需等缺失包%d" % i)
	_check(rx.open(packets[3], "127.0.0.1", 27994).is_empty(), "乱序接受后仍去重")
	var large := PackedByteArray()
	large.resize(CODEC.MAX_PAYLOAD)
	var mtu: PackedByteArray = tx.seal(large)
	_check(mtu.size() == CODEC.MAX_DATAGRAM and rx.open(mtu, "127.0.0.1", 27994) == large, "ENet1392字节完整通过")
	large.resize(CODEC.MAX_PAYLOAD + 1)
	_check(tx.seal(large).is_empty() and tx.seal(PackedByteArray()).is_empty(), "超MTU或空载荷拒绝")
	tx = _make(0)
	rx = _make(1)
	packet = tx.seal(PackedByteArray([99]))
	_check(not rx.open(packet, "127.0.0.1", 27994).is_empty(), "窗口初包")
	var accepted: int = 0
	for i: int in CODEC.REPLAY_WINDOW + 20:
		if not rx.open(tx.seal(PackedByteArray([1])), "127.0.0.1", 27994).is_empty():
			accepted += 1
	_check(accepted == CODEC.REPLAY_WINDOW + 20 and rx._seen.size() == CODEC.REPLAY_WINDOW, "重放集合有界")
	_check(rx.open(packet, "127.0.0.1", 27994).is_empty(), "窗口外旧包拒绝")
	tx = _make(0)
	rx = _make(1, 1.0)
	var a: PackedByteArray = tx.seal(PackedByteArray([1]))
	var b: PackedByteArray = tx.seal(PackedByteArray([2]))
	_check(not rx.open(a, "127.0.0.1", 27994).is_empty() and rx.open(b, "127.0.0.1", 27994).is_empty(), "认证后包速率限流")
	rx.clock += 1000
	_check(rx.open(b, "127.0.0.1", 27994) == PackedByteArray([2]), "限流不消耗序号，补充配额后可收")
	rx.clock = 20000
	_check(rx.open(tx.seal(PackedByteArray([3])), "127.0.0.1", 27994).is_empty(), "过期凭据拒绝")
	tx._next_sequence = CODEC.MAX_SEQUENCE
	_check(not tx.seal(PackedByteArray([1])).is_empty() and tx.seal(PackedByteArray([1])).is_empty(), "序号耗尽必须换会话不回绕")
	rx.close()
	_check(rx._key.is_empty() and rx._seen.is_empty(), "关闭会话清凭据和窗口")
	tx = _make(0)
	rx = _make(1)
	tx._next_sequence = 44
	var outside: PackedByteArray = tx.seal(PackedByteArray([44]))
	var edge: PackedByteArray = tx.seal(PackedByteArray([45]))
	tx._next_sequence = 300
	_check(not rx.open(tx.seal(PackedByteArray([1])), "127.0.0.1", 27994).is_empty(), "窗口先收高序号")
	_check(not rx.open(edge, "127.0.0.1", 27994).is_empty()
		and rx.open(outside, "127.0.0.1", 27994).is_empty(), "未收过窗口边沿45可收而44拒绝")
	for sequence: int in [0x80000000, 0xFFFFFFFF]:
		tx._next_sequence = sequence
		_check(not rx.open(tx.seal(PackedByteArray([2])), "127.0.0.1", 27994).is_empty(), "无符号高位序号接收%d" % sequence)
	tx = _make(0)
	rx = _make(1)
	rx._bps = CODEC.MAX_DATAGRAM
	rx._byte_tokens = rx._bps
	large.resize(CODEC.MAX_PAYLOAD)
	_check(not rx.open(tx.seal(large), "127.0.0.1", 27994).is_empty(), "字节桶可接MTU包")
	packet = tx.seal(PackedByteArray([1]))
	_check(rx.open(packet, "127.0.0.1", 27994).is_empty(), "包数仍有额度时独立按字节限流")
	rx.clock += 1000
	_check(not rx.open(packet, "127.0.0.1", 27994).is_empty(), "字节桶按单调时间补充")
	var invalid := ClockCodec.new()
	_check(invalid.configure("0001020304050607".hex_decode(), tx._key, 0,
		"bad-ip", 1, 20000) == ERR_INVALID_PARAMETER, "非法源地址配置拒绝")
	_check(invalid.configure("0001020304050607".hex_decode(), tx._key, 0,
		"127.0.0.1", 1, 1000) == ERR_INVALID_PARAMETER, "过期deadline配置拒绝")
	print("NETWORK_UDP_CODEC_CHECK checks=%d failures=%d" % [_checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)
