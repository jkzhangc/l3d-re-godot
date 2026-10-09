// 字段校验与 address 白名单。
// 契约见 `互联网联机模式策划方案.md` §3.1（房间对象）与 §3.6（校验/限流）。
//
// 设计原则：**永不信任客户端自报值**。所有进入存储的字段都先经过这里的规范化与
// 边界收窄；调用方拿到的一定是「已 clamp / 已过滤」的值，或一个明确的拒绝原因。

/** 人数上限固定为 4，与 Godot 侧 `Net.MAX_CLIENTS` 同源。 */
export const MAX_CLIENTS = 4;

/** 房间名字符数上限（按**字符**计，不按字节 —— 中文各占 1 个字符）。 */
export const MAX_ROOM_NAME_CHARS = 32;
/** 房主名上限。 */
export const MAX_HOST_NAME_CHARS = 20;
/** protocol / gameVersion 的长度上限。 */
export const MAX_VERSION_CHARS = 64;

const DEFAULT_ROOM_NAME = '房主的房间';
const DEFAULT_HOST_NAME = '玩家';
const DEFAULT_DIFFICULTY = 0;

/** protocol / gameVersion 允许的字符集（避免把控制字符或怪符号塞进列表）。 */
const VERSION_ALLOWED = /^[A-Za-z0-9._-]+$/;

/** 域名白名单正则（与方案 §3.6 一致）。 */
const DOMAIN_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

/** 内网 / 保留网段 —— 一律拒绝，防止把「指向内网」的地址注册成房间。 */
const PRIVATE_V4_PREFIXES = ['10.', '127.', '169.254.', '192.168.', '0.'];

/**
 * 清洗文本：去首尾空白 → 剔除控制字符 → 截断到 maxChars（按字符）。
 * 清洗后为空则返回 fallback。
 */
export function sanitizeText(value, maxChars, fallback) {
  if (typeof value !== 'string') return fallback;
  // eslint-disable-next-line no-control-regex
  const stripped = value.replace(/[\u0000-\u001F\u007F-\u009F]/g, '');
  const trimmed = stripped.trim();
  if (trimmed.length === 0) return fallback;
  return Array.from(trimmed).slice(0, maxChars).join('');
}

/** 是否为合法 IPv4（4 段，每段 0–255，无前导零歧义）。 */
function parseIPv4(value) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(value);
  if (!m) return null;
  const octets = m.slice(1).map((s) => Number(s));
  if (octets.some((n) => n > 255)) return null;
  return octets;
}

function isPrivateIPv4(octets) {
  const [a, b] = octets;
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 0) return true;
  if (a === 169 && b === 254) return true;
  if (a === 192 && b === 168) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  return false;
}

/**
 * address 校验：域名 或 公网 IPv4。
 * 拒绝：IPv6（M1 不测）、localhost、以及全部内网/保留网段。
 * @returns {{ok: true} | {ok: false, reason: string}}
 */
export function validateAddress(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return { ok: false, reason: 'address 缺失' };
  }
  if (value.length > 253) return { ok: false, reason: 'address 过长' };
  if (value.includes(':')) return { ok: false, reason: 'M1 不支持 IPv6 地址' };
  if (value.toLowerCase() === 'localhost') {
    return { ok: false, reason: 'address 不得为 localhost' };
  }
  const lower = value.toLowerCase();
  const octets = parseIPv4(lower);
  if (octets) {
    if (isPrivateIPv4(octets)) {
      return { ok: false, reason: 'address 不得为内网/保留网段' };
    }
    return { ok: true };
  }
  // 兜底拦一次内网前缀（例如 "10.0.0.1x" 这类非法 IPv4 但意图明显）。
  if (PRIVATE_V4_PREFIXES.some((p) => lower.startsWith(p))) {
    return { ok: false, reason: 'address 不得为内网/保留网段' };
  }
  if (!DOMAIN_RE.test(lower)) {
    return { ok: false, reason: 'address 既非合法域名也非合法公网 IPv4' };
  }
  return { ok: true };
}

/**
 * 校验并规范化一条注册房间的请求体。
 * @returns {{ok: true, value: object} | {ok: false, reason: string}}
 */
export function validateRoomPayload(body) {
  if (body === null || typeof body !== 'object') {
    return { ok: false, reason: '请求体必须是 JSON 对象' };
  }

  const addrResult = validateAddress(body.address);
  if (!addrResult.ok) return addrResult;

  const port = Number(body.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return { ok: false, reason: 'port 必须是 1–65535 的整数' };
  }

  // M1 只实现 UDP（ENet）。tcp 需要 WebSocketMultiplayerPeer（方案 A4），尚未落地；
  // 显式拒绝而非静默接受，避免列表里出现「点进去必然失败」的房间。
  const transport = typeof body.transport === 'string' ? body.transport : 'udp';
  if (transport !== 'udp') {
    return { ok: false, reason: 'M1 仅支持 transport=udp' };
  }

  const protocol = sanitizeText(body.protocol, MAX_VERSION_CHARS, '');
  if (protocol.length === 0 || !VERSION_ALLOWED.test(protocol)) {
    return { ok: false, reason: 'protocol 缺失或含非法字符' };
  }

  const gameVersion = sanitizeText(body.gameVersion, MAX_VERSION_CHARS, '');
  if (gameVersion.length > 0 && !VERSION_ALLOWED.test(gameVersion)) {
    return { ok: false, reason: 'gameVersion 含非法字符' };
  }

  // maxPlayers：本项目固定 4，>4 直接拒绝（不 clamp —— 拒绝比静默改值更诚实）。
  const maxPlayers = body.maxPlayers === undefined ? MAX_CLIENTS : Number(body.maxPlayers);
  if (!Number.isInteger(maxPlayers) || maxPlayers < 1 || maxPlayers > MAX_CLIENTS) {
    return { ok: false, reason: `maxPlayers 必须是不超过 ${MAX_CLIENTS} 的正整数` };
  }

  // currentPlayers：**clamp** 到 [1, maxPlayers]，永不信任自报值。
  let currentPlayers = body.currentPlayers === undefined ? 1 : Number(body.currentPlayers);
  if (!Number.isFinite(currentPlayers)) currentPlayers = 1;
  currentPlayers = Math.min(Math.max(Math.trunc(currentPlayers), 1), maxPlayers);

  let difficulty = Number(body.difficulty);
  if (!Number.isInteger(difficulty) || difficulty < 0 || difficulty > 3) {
    difficulty = DEFAULT_DIFFICULTY;
  }

  return {
    ok: true,
    value: {
      name: sanitizeText(body.name, MAX_ROOM_NAME_CHARS, DEFAULT_ROOM_NAME),
      hostName: sanitizeText(body.hostName, MAX_HOST_NAME_CHARS, DEFAULT_HOST_NAME),
      address: typeof body.address === 'string' ? body.address.trim() : '',
      port,
      transport,
      currentPlayers,
      maxPlayers,
      difficulty,
      chapterLabel: sanitizeText(body.chapterLabel, MAX_ROOM_NAME_CHARS, ''),
      gameVersion,
      protocol,
      hasPassword: body.hasPassword === true,
    },
  };
}
