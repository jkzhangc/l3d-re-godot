#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""固定掉落转换纯Python回归；不运行Godot、不写原地图或用户配置。"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import export_item_pickups as pickup


def ber(value):
    parts = [value & 127]
    value >>= 7
    while value:
        parts.insert(0, (value & 127) | 128)
        value >>= 7
    return bytes(parts)


def chunk(key, value):
    return ber(key) + ber(len(value)) + value


def cond(flags=0, switch=1, variable=1, value=1):
    return (chunk(1, ber(flags)) + chunk(2, ber(switch)) +
            chunk(4, ber(variable)) + chunk(5, ber(value)) + b'\0')


def cmd(code, params=(), indent=0, text=''):
    raw = text.encode('cp932')
    return ber(code) + ber(indent) + ber(len(raw)) + raw + ber(len(params)) + b''.join(ber(p) for p in params)


def page(body=None, graphic=True, condition=None, trigger=0):
    return {2: cond() if condition is None else condition, 21: b'A' if graphic else b'',
            33: ber(trigger), 52: cmd(0) if body is None else body + cmd(0)}


def event(pages, name='EV0001', x=2, y=3):
    return {1: name.encode('cp932'), 2: ber(x), 3: ber(y),
            5: ber(len(pages)) + b''.join(ber(i) + b''.join(chunk(k, v) for k, v in pg.items()) + b'\0' for i, pg in pages)}


def l3d_body(item=198, extra=b''):
    return (cmd(10220, [0, 665, 665, 0, 0, item, 0]) + cmd(12330, [0, 547, 0]) +
            cmd(12010, [0, 1460, 0, 0, 0, 0]) + cmd(10210, [0, 1460, 1460, 1], 1) +
            extra + cmd(10, indent=1) + cmd(22011))


class PickupTests(unittest.TestCase):
    def setUp(self):
        self.path = 'res://object/item_first_aid_spray.tres'
        self.herb = 'res://object/item_greenherbs.tres'
        self.water = 'res://object/item_mineralwater.tres'
        self.index = {self.path: {'item_id': 'first_aid_spray', 'item_name': '急救喷雾'},
                      self.herb: {'item_id': 'greenherbs_01', 'item_name': '緑ハーブ代理'},
                      self.water: {'item_id': 'mineralwater_01', 'item_name': 'ミネラルウォータ代理'}}
        self.names = {'急救喷雾': [self.path], '緑ハーブ代理': [self.herb],
                      'ミネラルウォータ代理': [self.water]}
        self.aliases = {'スプレー代理': self.path, '救急スプレー': self.path,
                        '緑ハーブ代理': self.herb, 'ミネラルウォータ代理': self.water}
        self.db = {198: {1: 'スプレー代理'.encode('cp932')}, 7: {1: '救急スプレー'.encode('cp932')},
                   199: {1: '緑ハーブ代理'.encode('cp932')},
                   196: {1: 'ミネラルウォータ代理'.encode('cp932')}}
        self.variables = {1408: {1: 'ｾｰﾌﾊｳｽ固定item表示ok'.encode('cp932')}}

    def analyze(self, ev):
        return pickup.analyze_event(25, 62, ev, self.db, self.variables, {547},
                                    self.index, self.names, self.aliases, 40, 40)

    def test_fixed_profile_and_32px_center(self):
        ev = event([(1, page(graphic=False)), (2, page(l3d_body(), condition=cond(4, variable=1408)))])
        item, report = self.analyze(ev)
        self.assertEqual(report['status'], 'converted')
        self.assertEqual(item['position'], [80, 112])
        self.assertEqual(item['source_key'], 'rm2k3:map:0025:event:0062')
        self.assertEqual(item['page_id'], 2)

    def test_stable_key_does_not_use_event_name(self):
        pages = [(1, page(l3d_body()))]
        a, _ = self.analyze(event(pages, name='元名'))
        b, _ = self.analyze(event(pages, name='変更名'))
        self.assertEqual(a['source_key'], b['source_key'])

    def test_omitted_coordinates_are_zero(self):
        ev = event([(1, page(l3d_body()))])
        del ev[2]
        del ev[3]
        item, _ = self.analyze(ev)
        self.assertEqual(item['position'], [16, 16])

    def test_direct_grant_requires_consumed_page(self):
        body = cmd(10320, [0, 0, 7, 0, 1]) + cmd(10210, [0, 50, 50, 0])
        ev = event([(1, page(body)), (2, page(graphic=False, condition=cond(1, switch=50)))], name='救急スプレー')
        item, report = self.analyze(ev)
        self.assertEqual(item['item_id'], 'first_aid_spray')
        self.assertEqual(report['status'], 'converted')

    def test_npc_reward_with_switch_is_not_ground_pickup(self):
        body = cmd(10320, [0, 0, 7, 0, 1]) + cmd(10210, [0, 50, 50, 0])
        ev = event([(1, page(body)), (2, page(graphic=False, condition=cond(1, switch=50)))], name='村人')
        item, report = self.analyze(ev)
        self.assertIsNone(item)
        self.assertIn('疑似剧情奖励', report['reason'])

    def test_extra_switch_side_effect_is_not_discarded(self):
        body = cmd(10320, [0, 0, 7, 0, 1]) + cmd(10210, [0, 50, 50, 0]) + cmd(10210, [0, 51, 51, 0])
        ev = event([(1, page(body)), (2, page(graphic=False, condition=cond(1, switch=50)))], name='救急スプレー')
        item, report = self.analyze(ev)
        self.assertIsNone(item)
        self.assertIn('剧情副作用', report['reason'])

    def test_shop_or_story_context_is_not_pickup(self):
        for extra in (cmd(10720), cmd(10140), cmd(10220, [0, 1, 1, 0, 0, 3, 0])):
            body = extra + cmd(10320, [0, 0, 7, 0, 1])
            item, report = self.analyze(event([(1, page(body))], name='救急スプレー'))
            self.assertIsNone(item)
            self.assertEqual(report['status'], 'skipped')

    def test_conditional_and_empty_graphic_pages_are_not_flattened(self):
        cases = [event([(1, page(l3d_body(), graphic=False))]),
                 event([(1, page(l3d_body(), condition=cond(1)))]),
                 event([(1, page(l3d_body())), (2, page(graphic=False))]),
                 event([(1, page(l3d_body())), (2, page(l3d_body()))]),
                 event([(1, page(l3d_body(), trigger=4))])]
        for ev in cases:
            with self.subTest(ev=ev):
                item, report = self.analyze(ev)
                self.assertIsNone(item)
                self.assertEqual(report['status'], 'skipped')

    def test_unknown_item_report_and_exact_alias_only(self):
        item, report = self.analyze(event([(1, page(l3d_body(item=999))) ]))
        self.assertIsNone(item)
        self.assertIn('没有此物品名称', report['reason'])
        with self.assertRaisesRegex(ValueError, '无精确映射'):
            pickup.resolve_item('贩卖スプレー代理', self.index, self.names, self.aliases)
        with self.assertRaisesRegex(ValueError, '歧义'):
            pickup.resolve_item('重名', self.index, {'重名': ['a', 'b']}, {})

    def test_quantity_and_variable_grant_are_skipped(self):
        for params in ([0, 0, 7, 0, 2], [0, 1, 7, 0, 1], [1, 0, 7, 0, 1]):
            item, report = self.analyze(event([(1, page(cmd(10320, params))) ]))
            self.assertIsNone(item)
            self.assertEqual(report['status'], 'skipped')

    def test_multipage_pool_merges_reachable_pages(self):
        pages = [(1, page(graphic=False)),
                 (2, page(l3d_body(item=198), condition=cond(4, variable=1369, value=1))),
                 (3, page(l3d_body(item=199), condition=cond(4, variable=1369, value=2)))]
        item, report = self.analyze(event(pages, name='回復列'))
        self.assertEqual(report['status'], 'converted')
        self.assertEqual(item['pool_mode'], 'multi_page')
        self.assertEqual([x['source_item_id'] for x in item['items']], [198, 199])
        self.assertEqual(item['page_ids'], [2, 3])
        self.assertEqual(item['source_variable_id'], 1369)

    def test_duplicate_condition_page_is_dead(self):
        pages = [(1, page(graphic=False)),
                 (2, page(l3d_body(item=198), condition=cond(4, variable=1377, value=4))),
                 (3, page(l3d_body(item=199), condition=cond(4, variable=1377, value=4))),
                 (4, page(l3d_body(item=196), condition=cond(4, variable=1377, value=5)))]
        item, _ = self.analyze(event(pages, name='近接列１'))
        self.assertEqual([x['source_item_id'] for x in item['items']], [198, 196])

    def test_fixed_spray_condition_value_is_not_one(self):
        # Map0024 固定スプレー：V1385..1390 == 6，旧实现写死 ==1 会全部拒收
        ev = event([(1, page(graphic=False)),
                    (2, page(l3d_body(item=198), condition=cond(4, variable=1385, value=6)))],
                   name='固定スプレー１')
        item, report = self.analyze(ev)
        self.assertEqual(report['status'], 'converted')
        self.assertEqual(item['item_id'], 'first_aid_spray')

    def test_multipage_unknown_item_does_not_block_others(self):
        pages = [(1, page(graphic=False)),
                 (2, page(l3d_body(item=198), condition=cond(4, variable=1369, value=1))),
                 (3, page(l3d_body(item=999), condition=cond(4, variable=1369, value=2)))]
        item, report = self.analyze(event(pages, name='混合列'))
        self.assertEqual(len(item['items']), 1)
        self.assertEqual(item['items'][0]['source_item_id'], 198)
        self.assertEqual([u['page_id'] for u in item['unmapped_items']], [3])

    def test_infinite_weapon_rack_is_not_converted(self):
        pages = [(1, page(graphic=False)),
                 (2, page(l3d_body(item=198), condition=cond(4, variable=1401, value=1))),
                 (3, page(l3d_body(item=199), condition=cond(4, variable=1401, value=2)))]
        item, report = self.analyze(event(pages, name='無限固定武器１'))
        self.assertIsNone(item)
        self.assertEqual(report['status'], 'skipped')

    def test_wrong_command_block_is_never_guessed(self):
        pg = page(l3d_body())
        pg[2] = cmd(10320, [0, 0, 7, 0, 1])
        self.assertEqual(pickup.commands(pg)[0]['code'], 10220)

    def test_higher_priority_blank_page_is_not_ignored(self):
        ev = event([(1, page(l3d_body())), (2, page(graphic=False, condition=cond(1, switch=50)))])
        item, report = self.analyze(ev)
        self.assertIsNone(item)
        self.assertIn('高优先级', report['reason'])

    def test_out_of_bounds_coordinate_is_reported(self):
        item, report = self.analyze(event([(1, page(l3d_body()))], x=40))
        self.assertIsNone(item)
        self.assertIn('坐标超出', report['reason'])

    def test_unrecognized_common_call_is_not_inlined(self):
        body = l3d_body().replace(cmd(12330, [0, 547, 0]), cmd(12330, [0, 548, 0]))
        item, report = self.analyze(event([(1, page(body))]))
        self.assertIsNone(item)
        self.assertEqual(report['status'], 'skipped')

    def test_fake_common_name_without_variable_item_grant_is_rejected(self):
        common = {547: {1: '通常武器入手処理'.encode('cp932'), 22: cmd(10320, [0, 0, 7, 0, 1]) + cmd(0)}}
        self.assertEqual(pickup.l3d_profile(common), set())

    def test_real_resource_aliases_exist(self):
        index, names = pickup.resource_index(pickup.PROJECT)
        aliases = json.loads(pickup.ALIAS_PATH.read_text(encoding='utf-8'))['aliases']
        for name, path in aliases.items():
            with self.subTest(name=name):
                self.assertEqual(pickup.resolve_item(name, index, names, aliases)[0], path)

    def test_bad_event_does_not_block_other_events(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            obj = root / 'object'
            obj.mkdir()
            (obj / 'item_first_aid_spray.tres').write_text('item_id = "first_aid_spray"\nitem_name = "急救喷雾"\n', encoding='utf-8')
            alias = root / 'aliases.json'
            alias.write_text(json.dumps({'aliases': self.aliases}), encoding='utf-8')
            common = {1: '通常武器入手処理'.encode('cp932'), 22: cmd(10320, [0, 1, 665, 0, 1]) + cmd(0)}
            def table(entries):
                return ber(len(entries)) + b''.join(ber(i) + b''.join(chunk(k, v) for k, v in ch.items()) + b'\0' for i, ch in entries)
            (root / 'RPG_RT.ldb').write_bytes(b'\x0bLcfDataBase' + chunk(13, table(self.db.items())) + chunk(25, table([(547, common)])) + b'\0')
            good = event([(1, page(l3d_body()))])
            bad = event([(1, page(l3d_body()))])
            bad[5] = b'\xff'
            (root / 'Map0025.lmu').write_bytes(b'\x0aLcfMapUnit' + chunk(81, table([(1, bad), (2, good)])) + b'\0')
            items, report = pickup.export_pickups(root, 25, 40, 40, root, alias)
            self.assertEqual(len(items), 1)
            self.assertEqual(report['summary'], {'error': 1, 'converted': 1})
            self.assertFalse(report['safehouse'])
            self.assertEqual(items[0]['empty_weight'], 1.0)

    def test_safehouse_detection_suppresses_empty_result(self):
        self.assertTrue(pickup.is_safehouse_name('セーフハウス'))
        self.assertFalse(pickup.is_safehouse_name('CP1-1'))
        self.assertFalse(pickup.is_safehouse_name('スタート地点'))


if __name__ == '__main__':
    unittest.main()
