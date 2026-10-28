# ai-snooker - regenerate VBXE assets and assemble THE GAME.
# One game, one binary: build/snooker.xex   (run from project root: .\tools\build.ps1)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    Write-Host '[1/2] generating VBXE assets ...'
    python tools/vbxe_export.py
    if ($LASTEXITCODE -ne 0) { throw 'vbxe_export.py failed -- assets NOT regenerated' }
    python tools/century_sim.py      # the century's "100": build/assets/century.inc
    python tools/chalk_sim.py        # the chalk marks' colours: build/assets/chalk.inc
    python tools/menu_gfx.py         # the menu windows' font, colours: build/assets/menugfx.inc
    python tools/trick_sim.py        # the trick shots: build/assets/tricks.inc, tricks_v.inc
    if ($LASTEXITCODE -ne 0) { throw 'century_sim.py failed' }
    Write-Host '[2/2] assembling src/main.asm ...'
    # .lab is what tools/asm_bench.py needs for the per-proc profile / digests
    # (the whole XEX, VRAM data too, only as a step in build/snooker.xex; make_atr.py reads it
    #  and writes it over with the code alone, beside build/snookerVBXE.atr -- one XEX file)
    & "$root\mads.exe" src/main.asm "-o:build/snooker.xex" "-t:build/snooker.lab"
    if ($LASTEXITCODE -eq 0) {
        # the segments for the RAM under the OS ROM (src/osrom.asm) -> staged pieces + INI copiers
        python tools/xex_osrom.py build/snooker.xex
        if ($LASTEXITCODE -eq 0) {
            # the bootable disk: the boot loader, the title / photos sectors, the XEX (src/atr.inc)
            & "$root\mads.exe" src/atrboot.asm "-o:build/atrboot.bin"
            if ($LASTEXITCODE -eq 0) { python tools/make_atr.py }
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host 'OK -> build/snookerVBXE.atr   (boot it in Altirra with VBXE enabled; the .xex alone has no VRAM data)'
        }
    }
    # Verification: tools/asm_bench.py (the one simulator) -- --phys, --cushion, --ai ...;
    #   asm_bench.py --scenario X --procs --report = cycles/frame + per-proc table
    #   (tools/out/bench/bench_fps*.txt); --compare-pos vs tools/out/bench/q12_X.json =
    #   divergence in mm from the previous Q12 record-based engine (src/old_q12/).
    # src/anim.asm remains as a reference (not built).
} finally {
    # never a whole XEX left behind (code + VRAM, ~489 KB): make_atr.py writes the code alone
    # over it; on any failure before that it goes
    $x = 'build/snooker.xex'
    if ((Test-Path $x) -and (Get-Item $x).Length -gt 65536) {
        Remove-Item $x
        Write-Host 'build/snooker.xex removed: the whole XEX (make_atr.py did not run)'
    }
    Pop-Location
}
