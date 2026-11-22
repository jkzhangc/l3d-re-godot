#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""保守导出固定地面物品；独立 CLI 默认为只读 dry-run，不运行 Godot。"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

from dump_orig_events import dec, event_header, lmu_events, parse_commands, parse_chunk_array
from parse_lcf import ber_of, chunks_of, ldb_sections

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent.parent
ALIAS_PATH = HERE / 'item_pickup_aliases.json'
GENERATOR = 'rm2k3_fixed_pickup_v1'


def fields(raw):
    result = {}
    pos = 0
    from parse_lcf import ber
    while pos < len(raw):
        key, pos = ber(raw, pos)
        if key == 0:
            return result
        size, pos = ber(raw, pos)
        if pos + size > len(raw):
            raise ValueError('LCF字段截断')
        result[key] = raw[pos:pos + size]
        pos += size
    return result


def condition(page):
    values = fields(page.get(2, b''))
    return {str(key): ber_of(value) for key, value in values.items()}


def database(game):
    data, sections = ldb_sections(str(Path(game) / 'RPG_RT.ldb'))
    def table(section):
        if section not in sections:
            return {}
        pos, length = sections[section]
        return dict(parse_chunk_array(data, pos, pos + length))
    return table(13), table(24), table(25)


def resource_index(project):
    index, names = {}, {}
    for path in sorted((Path(project) / 'object').glob('*.tres')):
        text = path.read_text(encoding='utf-8-sig')
        values = {}
        for key in ('item_id', 'item_name'):
            match = re.search(r'^' + key + r' = ("(?:[^"\\]|\\.)*")$', text, re.M)
            if match:
                values[key] = json.loads(match.group(1))
        if not values.get('item_id') or not values.get('item_name'):
            continue
        resource_path = 'res://' + path.relative_to(project).as_posix()
        index[resource_path] = values
        names.setdefault(values['item_name'], []).append(resource_path)
    return index, names


def resolve_item(name, index, names, aliases):
    if name in aliases:
        path = aliases[name]
        if not isinstance(path, str) or path not in index:
            raise ValueError('别名目标不是已有物品资源: %r' % path)
        return path, '显式精确别名: ' + name
    matches = names.get(name, [])
    if len(matches) == 1:
        return matches[0], '现有item_name精确匹配: ' + name
    if matches:
        raise ValueError('同名资源歧义: ' + ', '.join(matches))
    raise ValueError('未知物品，无精确映射: ' + name)


def commands(page):
    # 命令块固定为0x34；旧侦察器的逐块试读会把条件块误识别为命令。
    parsed = parse_commands(page.get(0x34, b'\0\0\0\0'))
    if (parsed is None or not parsed or parsed[-1]['code'] != 0 or
            any(c['code'] == 0 for c in parsed[:-1])):
        raise ValueError('命令块损坏或缺少唯一结束符')
    return parsed


def significant(cmds):
    return [(c['code'], c['indent'], c['params']) for c in cmds
            if c['code'] not in (12410, 22410)]


def visible_page(page):
    # 仅自动接受明确的行走图；图块图形/空图页保留报告，避免误认逻辑事件。
    return bool(page.get(21, b''))


def empty_page(page):
    return (not visible_page(page) and ber_of(page.get(22, b'\0')) == 0 and
            all(c['code'] in (0, 12410, 22410) for c in commands(page)))


def l3d_profile(common):
    # 仅识别已核实的L3D地面拾取公共调用约定，而不是展开任意公共事件。
    result = set()
    for cid, entry in common.items():
        if dec(entry.get(1, b'')) != '通常武器入手処理':
            continue
        cmds = parse_commands(entry.get(22, b'')) or []
        grants = [c['params'] for c in cmds if c['code'] == 10320]
        if grants and all(p == [0, 1, 665, 0, 1] for p in grants):
            result.add(cid)
    return result


def l3d_grant(cmds, profile):
    body = significant(cmds)
    # 安全屋喷雾前置只是容量检查：失败时返回，不是剧情/商店分支。
    guard = [(12010, 0, [1, 1200, 1, 1407, 1, 0]),
             (11550, 1, [100, 100, 50]), (12310, 1, []),
             (10, 1, []), (22011, 0, [])]
    if body[:5] == guard:
        body = body[5:]
    if len(body) < 7 or body[0][0:2] != (10220, 0):
        return None
    assignment = body[0][2]
    if len(assignment) != 7 or assignment[:5] != [0, 665, 665, 0, 0] or assignment[6] != 0:
        return None
    if body[1][0:2] != (12330, 0) or body[1][2] not in [[0, cid, 0] for cid in profile]:
        return None
    tail = [(12010, 0, [0, 1460, 0, 0, 0, 0]),
            (10210, 1, [0, 1460, 1460, 1]),
            (10, 1, []), (22011, 0, []), (0, 0, [])]
    disappear = (10860, 1, [10005, 0, 0, 0, 0])
    rest = body[2:]
    if rest != tail and rest != tail[:2] + [disappear] + tail[2:]:
        return None
    return assignment[5]


def page_view(pid, page):
    cmds = commands(page)
    return {'page_id': pid, 'condition': condition(page),
            'graphic': dec(page.get(21, b'')), 'trigger': ber_of(page.get(33, b'\0')),
            'commands': [{'code': c['code'], 'indent': c['indent'],
                          'text': dec(c['str']), 'params': c['params']} for c in cmds]}


## RM 事件页按页号从小到大匹配：同条件值的后续页永远不可达，按死页剔除。
def _dedupe_pages(active):
    seen, out = set(), []
    for pid, pg in sorted(active, key=lambda item: item[0]):
        cond = condition(pg)
        key = (cond.get('1', 0), cond.get('4', 0), cond.get('5', 0), cond.get('10', 0))
        if key in seen:
            continue
        seen.add(key)
        out.append((pid, pg))
    return out


## 多页池用：每页必须是已核实的固定拾取模板，或单一顶层常量给物品。
def _page_source_id(cmds, profile):
    sid = l3d_grant(cmds, profile)
    if sid is not None:
        return sid
    grants = [c for c in cmds if c['code'] == 10320]
    if len(grants) == 1 and grants[0]['indent'] == 0:
        params = grants[0]['params']
        if len(params) == 5 and params[:2] == [0, 0] and params[3:] == [0, 1]:
            return params[2]
    raise ValueError('页内给物品命令不是已核实的固定拾取/单一常量模板')


## 同一物品事件的多个可达页 = 一个随机掉落池（原作用状态变量档位切换页）。
## 严格限制：所有页必须是同一状态变量的值比较、按键触发、有行走图；
## 无法映射的页只进报告，不阻断其它可映射项；一项都映射不上才整体跳过。
def _analyze_pool(pages, base, item_db, variables, profile, index, names, aliases):
    rows = []
    for pid, pg in pages:
        cond = condition(pg)
        if cond.get('1', 0) != 4 or cond.get('10', 0) != 0:
            raise ValueError('多页物品事件的条件不是同一变量的值比较: %s' % cond)
        if ber_of(pg.get(33, b'\0')) not in (0, 1):
            raise ValueError('多页中存在非按键触发页')
        if not visible_page(pg):
            raise ValueError('多页中存在空图页')
        rows.append((pid, pg, cond))
    used = {row[2].get('4', 0) for row in rows}
    if len(used) != 1:
        raise ValueError('多页物品事件混用多个状态变量: %s' % sorted(used))
    var_id = next(iter(used))
    items, unmapped, page_ids = [], [], []
    for pid, pg, _cond in rows:
        sid = _page_source_id(commands(pg), profile)
        item_name = dec(item_db.get(sid, {}).get(1, b''))
        if not item_name:
            unmapped.append({'page_id': pid, 'source_item_id': sid,
                             'reason': '原作数据库没有此物品名称'})
            continue
        try:
            resource, why = resolve_item(item_name, index, names, aliases)
        except ValueError as exc:
            unmapped.append({'page_id': pid, 'source_item_id': sid,
                             'source_item_name': item_name, 'reason': str(exc)})
            continue
        items.append({'page_id': pid, 'source_item_id': sid, 'source_item_name': item_name,
                      'item_id': index[resource]['item_id'], 'resource_path': resource,
                      'mapping_reason': why})
        page_ids.append(pid)
    if not items:
        raise ValueError('多页物品事件没有可映射物品')
    var_name = dec(variables.get(var_id, {}).get(1, b''))
    single = len(items) == 1
    return dict(base, page_id=items[0]['page_id'], page_ids=page_ids,
                source_variable_id=var_id, source_variable_name=var_name,
                items=items, unmapped_items=unmapped, pool_mode='multi_page',
                item_id=items[0]['item_id'] if single else '',
                resource_path=items[0]['resource_path'] if single else '',
                position=[base['x'] * 32 + 16, base['y'] * 32 + 16],
                generator=GENERATOR,
                mapping_reason='同一物品事件的 %d 个可达页合并为随机池（变量 %d%s 分档；%s）'
                               % (len(items), var_id, ('/' + var_name) if var_name else '',
                                  '未映射页 ' + str([u['page_id'] for u in unmapped])
                                  if unmapped else '全部页已映射'))


def analyze_event(map_id, eid, chunks, item_db, variables, profile, index, names, aliases, width, height):
    name, x, y, pages = event_header(chunks)
    name, x, y = dec(name), 0 if x is None else x, 0 if y is None else y
    base = {'map_id': map_id, 'event_id': eid, 'event_name': name, 'x': x, 'y': y,
            'source_key': 'rm2k3:map:%04d:event:%04d' % (map_id, eid)}
    views = [page_view(pid, pg) for pid, pg in pages]
    potential = any(c['code'] == 10320 or
                    (c['code'] == 10220 and len(c['params']) > 2 and c['params'][1:3] == [665, 665])
                    for view in views for c in view['commands'])
    potential = potential or name in aliases or name in names or '固定' in name or '救急箱' in name
    if not potential:
        return None, None
    report = dict(base, pages=views)
    try:
        if not pages:
            raise ValueError('没有事件页')
        if not (0 <= x < width and 0 <= y < height):
            raise ValueError('坐标超出地图范围')
        active = [(pid, pg) for pid, pg in pages if not empty_page(pg)]
        # 無限固定武器架「拿了不消失」，改成一次性 random_pickup 会改变玩法，保留人工处理。
        if '無限固定武器' in name:
            raise ValueError('无限固定武器架不自动转换为一次性拾取，保留人工处理')
        reachable = _dedupe_pages(active)
        if len(reachable) >= 2:
            pickup = _analyze_pool(reachable, base, item_db, variables, profile,
                                   index, names, aliases)
            report.update(status='converted', reason=pickup['mapping_reason'],
                          item_id=pickup['item_id'], resource_path=pickup['resource_path'],
                          item_count=len(pickup['items']),
                          item_ids=[item['item_id'] for item in pickup['items']],
                          source_variable_id=pickup.get('source_variable_id', 0),
                          source_variable_name=pickup.get('source_variable_name', ''),
                          unmapped_items=pickup['unmapped_items'])
            return pickup, report
        if len(reachable) != 1:
            raise ValueError('没有可用的物品事件页（全部为空页）')
        pid, pg = reachable[0]
        report['page_id'] = pid
        if not visible_page(pg):
            raise ValueError('空图页/不可见事件，不自动放置地面物品')
        if ber_of(pg.get(33, b'\0')) not in (0, 1):
            raise ValueError('自动/并行/事件接触页，可能是剧情奖励')
        cmds = commands(pg)
        source_id = l3d_grant(cmds, profile)
        is_l3d_ground_template = source_id is not None
        cond = condition(pg)
        flags = cond.get('1', 0)
        reason = '完整L3D固定地面拾取命令模板（赋常量物品ID→通常武器入手处理）'
        if source_id is not None:
            if flags:
                # 只接受「同一变量比较、非零即显示」的固定补给条件。
                # 早期实现把变量名硬编码成 ｾｰﾌﾊｳｽ固定item表示ok 且要求值=1，
                # 结果 Map0024 的固定スプレー（V1385..1390 == 6）全部被判为未实现。
                if not (flags == 4 and cond.get('10', 0) == 0 and cond.get('5', 0) != 0):
                    raise ValueError('未实现出现条件，保留人工处理: %s' % cond)
                label = dec(variables.get(cond.get('4', 0), {}).get(1, b''))
                reason += '；固定补给显示条件（变量 %d%s 非零）' % (
                    cond.get('4', 0), ('/' + label) if label else '')
            if any(not empty_page(other) for other_pid, other in pages if other_pid != pid):
                raise ValueError('存在其他逻辑页')
            if any(condition(other).get('1', 0) != 0 or other_pid > pid for other_pid, other in pages if other_pid != pid):
                raise ValueError('存在更高优先级/条件空白页，不能静态生成')
        else:
            grants = [c for c in cmds if c['code'] == 10320]
            if len(grants) != 1 or grants[0]['indent'] != 0:
                raise ValueError('非单一顶层给物品命令，或未知公共调用/补给箱机制')
            params = grants[0]['params']
            if len(params) != 5 or params[:2] != [0, 0] or params[3:] != [0, 1]:
                raise ValueError('变量物品/减物品/数量不是1，不支持无损转换')
            if flags:
                raise ValueError('给物品页带出现条件，需人工处理')
            allowed = {0, 10320, 10210, 10110, 20110, 11550, 12410, 22410}
            if any(c['code'] not in allowed or c['indent'] != 0 for c in cmds):
                raise ValueError('给物品命令带剧情/商店/选择/分支上下文')
            switch_cmds = [c for c in cmds if c['code'] == 10210]
            if len(switch_cmds) != 1:
                raise ValueError('必须只有一个拾取消费开关，不能吞掉剧情副作用')
            switch_params = switch_cmds[0]['params']
            if (len(switch_params) != 4 or switch_params[0] != 0 or
                    switch_params[1] != switch_params[2] or switch_params[3] != 0):
                raise ValueError('不是单个拾取后开启的开关')
            switch_id = switch_params[1]
            later = [(other_pid, other) for other_pid, other in pages if other_pid > pid]
            if len(later) != 1 or not empty_page(later[0][1]):
                raise ValueError('缺少唯一的拾取后空白页；不能把可重复奖励变成一次拾取')
            blank = condition(later[0][1])
            if blank.get('1', 0) != 1 or blank.get('2', 1) != switch_id:
                raise ValueError('拾取后空白页条件与消费开关不匹配')
            if any(condition(other).get('1', 0) for other_pid, other in pages if other_pid < pid):
                raise ValueError('低优先级条件页可能提供其他逻辑')
            source_id, reason = params[2], '单一顶层常量给物品+匹配开关空白页'
        item_name = dec(item_db.get(source_id, {}).get(1, b''))
        report.update(source_item_id=source_id, source_item_name=item_name)
        if not item_name:
            raise ValueError('原作数据库没有此物品名称: %d' % source_id)
        resource, mapping_reason = resolve_item(item_name, index, names, aliases)
        if not is_l3d_ground_template:
            # 命令不是已核实的地面模板时，必须另有精确的物品事件名/拾取提示，
            # 不能因为NPC/商店发了道具并切页就自动当成地面物品。
            identity = {item_name, index[resource]['item_name']}
            identity.update(alias for alias, target in aliases.items() if target == resource)
            pickup_prompts = {'%sを手に入れた！' % n for n in identity}
            pickup_prompts.update('%sを手に入れた。' % n for n in identity)
            if name not in identity and not any(dec(c['str']) in pickup_prompts for c in cmds
                                                if c['code'] in (10110, 20110)):
                raise ValueError('给物品但缺少精确地面物品身份/拾取提示，疑似剧情奖励')
        pickup = dict(base, page_id=pid, source_item_id=source_id, source_item_name=item_name,
                      item_id=index[resource]['item_id'], resource_path=resource,
                      position=[x * 32 + 16, y * 32 + 16], generator=GENERATOR,
                      mapping_reason=reason + '；' + mapping_reason)
        report.update(status='converted', reason=pickup['mapping_reason'],
                      item_id=pickup['item_id'], resource_path=resource)
        return pickup, report
    except (ValueError, IndexError, TypeError) as exc:
        report.update(status='skipped', reason=str(exc))
        return None, report


def export_pickups(game, map_id, width, height, project=PROJECT, alias_path=ALIAS_PATH):
    result, reports = [], []
    try:
        item_db, variables, common = database(game)
        profile = l3d_profile(common)
        index, names = resource_index(Path(project))
        aliases = json.loads(Path(alias_path).read_text(encoding='utf-8'))['aliases']
        events = lmu_events(str(Path(game) / ('Map%04d.lmu' % map_id)))
    except (OSError, ValueError, IndexError, KeyError) as exc:
        return [], {'map_id': map_id, 'status': 'error', 'reason': str(exc), 'events': []}
    for eid, chunks in events:
        try:
            pickup, report = analyze_event(map_id, eid, chunks, item_db, variables, profile,
                                           index, names, aliases, width, height)
        except (ValueError, IndexError, TypeError) as exc:
            pickup = None
            report = {'map_id': map_id, 'event_id': eid,
                      'event_name': dec(chunks.get(1, b'')),
                      'x': ber_of(chunks.get(2, b'\0')), 'y': ber_of(chunks.get(3, b'\0')),
                      'source_key': 'rm2k3:map:%04d:event:%04d' % (map_id, eid),
                      'status': 'error', 'reason': str(exc)}
        if pickup is not None:
            result.append(pickup)
        if report is not None:
            reports.append(report)
    flat_items = []
    for pickup in result:
        if pickup.get('items'):
            flat_items.extend(item['item_id'] for item in pickup['items'])
        elif pickup.get('item_id'):
            flat_items.append(pickup['item_id'])
    return result, {'map_id': map_id, 'generator': GENERATOR, 'events_total': len(events),
                    'summary': dict(Counter(r['status'] for r in reports)),
                    'items': dict(Counter(flat_items)), 'events': reports}


def map_dimensions(path):
    raw = Path(path).read_bytes()
    chunks = {cid: raw[pos:pos + size] for cid, pos, size in
              chunks_of(raw, raw.index(b'LcfMapUnit') + 10, len(raw))}
    w = ber_of(chunks[2]) if 2 in chunks else None
    h = ber_of(chunks[3]) if 3 in chunks else None
    count = len(chunks.get(71, b'')) // 2
    if w is None and h and count % h == 0:
        w = count // h
    if h is None and w and count % w == 0:
        h = count // w
    if w is None and h is None:
        choices = [(x, count // x) for x in range(20, count + 1)
                   if count % x == 0 and count // x >= 15]
        if len(choices) == 1:
            w, h = choices[0]
    if not w or not h or w * h != count:
        raise ValueError('地图尺寸缺失/歧义，不能猜测事件边界: ' + str(path))
    return w, h


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('game_dir')
    ap.add_argument('map_ids', nargs='+', type=int)
    ap.add_argument('--project', type=Path, default=PROJECT)
    ap.add_argument('--aliases', type=Path, default=ALIAS_PATH)
    ap.add_argument('--report', type=Path, help='可选审计JSON；不传时不写文件')
    args = ap.parse_args()
    reports = []
    # 事件dry-run独立于Pillow/atlas，也不创建场景、TileSet、配置或缓存。
    for mid in args.map_ids:
        path = Path(args.game_dir) / ('Map%04d.lmu' % mid)
        try:
            w, h = map_dimensions(path)
            pickups, report = export_pickups(args.game_dir, mid, w, h, args.project, args.aliases)
        except (OSError, ValueError, IndexError) as exc:
            report = {'map_id': mid, 'status': 'error', 'reason': str(exc), 'events': []}
        reports.append(report)
        print('Map%04d: %s items=%s' % (mid, report.get('summary', report.get('reason')),
                                       json.dumps(report.get('items', {}), ensure_ascii=False)))
        for event in report['events']:
            if event['status'] != 'converted':
                print('  跳过事件%s %s: %s' % (event['event_id'], event.get('event_name', ''), event['reason']))
    if args.report:
        args.report.write_text(json.dumps(reports, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
