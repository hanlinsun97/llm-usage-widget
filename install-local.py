"""Install the verified build into ~/Applications and restart it.

The replaced version is kept as one zip (not a second .app, so Spotlight does
not list it); only the newest zip is kept. Restore with
`ditto -x -k <zip> ~/Applications/` after quitting the app.
"""
from pathlib import Path
import datetime, json, os, shutil, signal, subprocess, time

source = Path.home() / 'Library/Caches/LLMUsage.noindex/LLM Usage.app'
target = Path.home() / 'Applications/LLM Usage.app'
backups = Path.home() / 'Library/Application Support/LLMUsage/backups'
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
backups.mkdir(parents=True, exist_ok=True)
archive = backups / f'LLM Usage-{stamp}.zip'
if target.exists():
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(target), str(archive)], check=True)
staged = target.with_name('LLM Usage.installing.noindex')
if staged.exists():
    raise SystemExit('Staging path exists; inspect before proceeding')
shutil.copytree(source, staged)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
paths = {str(p / 'Contents/MacOS/LLMUsage') for p in (target, source)}
for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) == 2 and parts[1] in paths:
        os.kill(int(parts[0]), signal.SIGTERM)
time.sleep(.5)
previous = target.with_name('LLM Usage.previous.noindex')
if target.exists():
    target.rename(previous)
try:
    staged.rename(target)
except BaseException:
    if previous.exists():
        previous.rename(target)
    raise
if previous.exists():
    shutil.rmtree(previous)  # the zip above is the rollback copy
for old in sorted(backups.glob('LLM Usage-*.zip'))[:-1]:
    old.unlink()
subprocess.run(['open', '-g', str(target)], check=True)
receipt = {'installed': str(target), 'backup': str(archive) if archive.exists() else None,
           'verified': 'codesign --verify --deep --strict'}
Path(__file__).with_name('installation.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
