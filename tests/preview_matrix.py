"""Exercise the actual AppKit surfaces for layout/accent combinations."""
import json, os, subprocess, sys, time, uuid
from pathlib import Path
root=Path(__file__).resolve().parents[1]
exe=os.path.expanduser('~/Library/Caches/LLMUsage.noindex/LLM Usage.app/Contents/MacOS/LLMUsage')
for color, desktop, popover in [('green',2,1),('green-one-row',1,2)]:  # output folder names kept for history
    output=root if color=='green' else root/'previews'/color
    output.mkdir(parents=True,exist_ok=True)
    started=time.time()
    run_id=str(uuid.uuid4())
    env=dict(os.environ,LLM_PREVIEW_DIR=str(output),LLM_PREVIEW_RUN=run_id,LLM_PREVIEW_ACCOUNTS=str(root/'tests/accounts-fixture.json'),
             LLM_PREVIEW_desktopRows=str(desktop),LLM_PREVIEW_popoverRows=str(popover))
    process=subprocess.Popen([exe,'--preview-menu','--preview-settings'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        path=output/'settings-check.json'
        for _ in range(120):
            if process.poll() is not None: raise RuntimeError('Preview exited early')
            if path.exists() and path.stat().st_mtime>=started:
                try: complete=json.loads(path.read_text()).get('closed')
                except json.JSONDecodeError: complete=False
                if complete: break
            time.sleep(.1)
        else: raise RuntimeError(f'{color}: preview timed out')
        subprocess.run([sys.executable,str(root/'tests/check_render.py'),str(output),run_id],check=True)
        print(f'PASS: {color}, desktop {desktop} row(s), popover {popover} row(s)',flush=True)
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill();process.wait()
