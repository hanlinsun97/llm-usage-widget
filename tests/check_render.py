"""Validate native --preview-menu output, including real status-button actions."""
import json
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]) if len(sys.argv)>1 else root
source_time = max((root / name).stat().st_mtime for name in ('App.swift', 'MenuBar.swift', 'widget.html'))
for name in ('render-check.json', 'menu-check.json'):
    assert (output / name).stat().st_mtime >= source_time, f'Stale native check: {name}'
desktop = json.loads((output / 'render-check.json').read_text())
menu = json.loads((output / 'menu-check.json').read_text())
run_id = sys.argv[2] if len(sys.argv) > 2 else None
for result in (desktop, menu):
    # Evidence must come from the binary that exists now, and from this run when a run id is given.
    binary = Path(result['binary'])
    assert binary.exists() and abs(binary.stat().st_mtime - result['binaryModified']) < 1e-3, 'Evidence from another binary'
    assert binary.stat().st_mtime >= source_time, 'Binary older than its sources'
    if run_id: assert result['runId'] == run_id, 'Evidence from another run'

def rgb(token):
    token = token.strip().lstrip('#')
    return 'rgb(' + ', '.join(str(int(token[i:i+2], 16)) for i in (0, 2, 4)) + ')'

for result in (desktop, menu):
    assert result['rows'] == 4
    assert not result['clipped'] and not result['overflow']
    assert len({card['y'] for card in result['cards']}) == result['layoutRows']
    assert len({card['x'] for card in result['cards']}) == 4 // result['layoutRows']
    assert result['arcs'] >= 2 and result['paces'] >= 1 and result['badges'] >= 1, result
    assert result['ringColor'] == rgb(result['ringToken']), (result['ringColor'], result['ringToken'])
    assert result['fiveColor'] == rgb(result['fiveToken']), (result['fiveColor'], result['fiveToken'])
    # The moving 5-hour badge clears the weekly ring at every tenth-percent.
    badge = result['badgeGeometry']
    assert badge['samples'] == 1001 and badge['clearance'] >= 1.5, badge
    print('Badge clearance:', round(badge['clearance'], 2), 'px at', badge['worst'])
    # Every centre label, including "Updating"/"No data" and worst-case tokens, sits inside the ring.
    geometry = result['geometry']
    assert geometry['clearance'] >= 1.5, geometry
    print('Centre text clearance:', round(geometry['clearance'], 2), 'px; worst case:', geometry['worst'])
assert menu['compact'] and not desktop['compact']
for result in (desktop, menu):
    assert 'tok' not in result['text'].lower()
    assert result['text'].count('week') == 4 and result['text'].count('hour') == 4
    assert result['text'].count('↻') == 1  # global refresh only
assert menu['menuImageWidth'] == 96
for key in ('openedByButton', 'closedByButton', 'reopenedByButton', 'settings', 'transient'):
    assert menu[key], key
# Opening the popover must not draw a focus ring on whatever WebKit focused.
assert menu['focusOutline'] == 'none', (menu.get('focused'), menu['focusOutline'])
settings_path = output / 'settings-check.json'
if settings_path.exists():
    assert settings_path.stat().st_mtime >= source_time, 'Stale native settings check'
    settings = json.loads(settings_path.read_text())
    assert settings['opened'] and settings['closed'] and settings['hasGlassSlider']
    assert settings['visibleSeconds'] >= .8
    assert all(title in settings['items'] for title in ('Quit LLM Usage','Desktop layout','Popover layout'))
print('PASS: layouts, no clipping, centre text inside ring, badge clearance, pace track, ring colour, native open/close/reopen without focus ring, settings')
