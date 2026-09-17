import json
from pathlib import Path

from tools.rm2k3_map_restore.tileconverter_bridge import build_bridge_outputs


def test_bridge_generates_godot_ready_autotile_outputs(tmp_path):
    input_path = Path(__file__).resolve().parents[1] / '機械系ダンジョン1 - ○.png'
    if not input_path.exists():
        raise FileNotFoundError(f'Missing chipset fixture: {input_path}')

    out_dir = tmp_path / 'converted'
    report = build_bridge_outputs(
        source_path=input_path,
        output_dir=out_dir,
        groups=['A1', 'A2', 'A3', 'A4', 'A5', 'B', 'C', 'D', 'E'],
        scale=2,
    )

    assert 'A1' in report['generated_groups']
    assert 'A2' in report['generated_groups']
    assert (out_dir / f'{input_path.stem}_A1_godot.png').exists()
    assert (out_dir / f'{input_path.stem}_A2_godot.png').exists()
    assert (out_dir / f'{input_path.stem}_mapping.json').exists()
    assert (out_dir / f'{input_path.stem}_report.json').exists()
    data = json.loads((out_dir / f'{input_path.stem}_mapping.json').read_text(encoding='utf-8'))
    assert 'A1' in data['groups'] and 'A2' in data['groups']
