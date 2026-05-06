# NOVAthesis Direct Compilation Script (No latexmk/Perl required)
# Usage: .\compile-direct.ps1 [engine] [-Clean] [-Fresh] [-NoSynctex]
# Engines: lua (default), pdf, xe
# -Clean: remove all auxiliary files after compilation (keeps only .pdf)
# -Fresh: delete aux/bbl/toc etc. before build (fixes truncated .aux / \@writefile runaway)
# -NoSynctex: pass -synctex=0 (use if OneDrive or a PDF viewer locks .synctex.gz)

param(
    [string]$Engine = "lua",
    [switch]$Clean,
    # Delete LaTeX auxiliary files before building (fixes corrupt/truncated .aux bookmark entries, stale refs).
    [switch]$Fresh,
    [switch]$NoSynctex
)

function Clear-TemplateSynctexArtifacts {
    # Stale or locked SyncTeX files cause: "Can't rename template.synctex(busy) to template.synctex.gz"
    # and LuaLaTeX returns exit code 1 even when the PDF is fine.
    Get-ChildItem -Path . -Filter "template.synctex*" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Get-LogTailText {
    param([string]$LogPath, [int]$Lines = 120)
    if (-not (Test-Path $LogPath)) { return "" }
    $chunk = Get-Content -LiteralPath $LogPath -Tail $Lines -ErrorAction SilentlyContinue
    if (-not $chunk) { return "" }
    return ($chunk -join "`n")
}

function Test-LogHasCorruptAux {
    param([string]$LogPath)
    $tail = Get-LogTailText $LogPath 200
    if (-not $tail) { return $false }
    return ($tail -match 'File ended while scanning use of \\@writefile' -or
            $tail -match 'File ended while scanning use of \\BKM@entry')
}

function Test-LogSyncTeXRenameFailed {
    param([string]$LogPath)
    $tail = Get-LogTailText $LogPath 60
    if (-not $tail) { return $false }
    return ($tail -match "SyncTeX: Can't rename" -or $tail -match 'synctex\(busy\)')
}

Write-Host "NOVAthesis Direct Compilation Script" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Check if template.tex exists
if (-not (Test-Path "template.tex")) {
    Write-Host "ERROR: template.tex not found in current directory!" -ForegroundColor Red
    exit 1
}

# Determine which LaTeX compiler to use
$latexCmdName = $null
switch ($Engine.ToLower()) {
    "lua" {
        $latexCmdName = "lualatex"
        Write-Host "Using: LuaLaTeX" -ForegroundColor Green
    }
    "pdf" {
        $latexCmdName = "pdflatex"
        Write-Host "Using: pdfLaTeX" -ForegroundColor Green
    }
    "xe" {
        $latexCmdName = "xelatex"
        Write-Host "Using: XeLaTeX" -ForegroundColor Green
    }
    default {
        Write-Host "ERROR: Unknown engine '$Engine'. Use: lua, pdf, or xe" -ForegroundColor Red
        exit 1
    }
}

# Check if the LaTeX compiler is available
$compiler = Get-Command $latexCmdName -ErrorAction SilentlyContinue
$miktexPath = "$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64"

# If not in PATH, try MiKTeX installation directory
if (-not $compiler) {
    if (Test-Path "$miktexPath\$latexCmdName.exe") {
        $latexCmd = "$miktexPath\$latexCmdName.exe"
        Write-Host "Found $latexCmdName in MiKTeX directory" -ForegroundColor Green
    } else {
        Write-Host "ERROR: $latexCmdName not found. Please check your MiKTeX installation." -ForegroundColor Red
        Write-Host "Tried: $miktexPath\$latexCmdName.exe" -ForegroundColor Yellow
        exit 1
    }
} else {
    $latexCmd = $compiler.Source
}

# Check if biber is available
$biber = Get-Command biber -ErrorAction SilentlyContinue
if (-not $biber) {
    # Try MiKTeX directory
    if (Test-Path "$miktexPath\biber.exe") {
        $biber = "$miktexPath\biber.exe"
    } else {
        Write-Host "WARNING: biber not found. Bibliography may not be processed correctly." -ForegroundColor Yellow
    }
}

Write-Host "Main file: template.tex" -ForegroundColor Green
Write-Host ""

if ($Fresh) {
    Write-Host "Fresh build: removing auxiliary files..." -ForegroundColor Cyan
    $freshPatterns = @(
        "template.aux", "template.bbl", "template.bcf", "template.blg", "template.out",
        "template.toc", "template.lof", "template.lot", "template.lol", "template.run.xml"
    )
    foreach ($f in $freshPatterns) {
        if (Test-Path $f) { Remove-Item -Force $f }
    }
    Clear-TemplateSynctexArtifacts
    Write-Host ""
}

# Compilation flags
$synctexFlag = if ($NoSynctex) { "-synctex=0" } else { "-synctex=1" }
$flags = "-shell-escape", $synctexFlag, "-interaction=nonstopmode"
if ($NoSynctex) {
    Write-Host "SyncTeX disabled (-NoSynctex)." -ForegroundColor Yellow
    Write-Host ""
}

# Step 1: First LaTeX pass (with recovery for corrupt .aux and SyncTeX file locks)
Write-Host "Step 1/4: First LaTeX pass..." -ForegroundColor Yellow
Clear-TemplateSynctexArtifacts
try {
    & $latexCmd $flags template.tex
    $exit1 = $LASTEXITCODE
} catch {
    Write-Host "ERROR: Failed to run $latexCmd" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

if ($exit1 -ne 0 -and (Test-LogHasCorruptAux "template.log")) {
    Write-Host "WARNING: Corrupt or truncated template.aux detected; deleting aux/toc/out and retrying once..." -ForegroundColor Yellow
    foreach ($f in @("template.aux", "template.toc", "template.out", "template.lof", "template.lot", "template.lol")) {
        if (Test-Path $f) { Remove-Item -Force $f }
    }
    Clear-TemplateSynctexArtifacts
    & $latexCmd $flags template.tex
    $exit1 = $LASTEXITCODE
}

if ($exit1 -ne 0 -and (Test-Path "template.pdf") -and (Test-LogSyncTeXRenameFailed "template.log")) {
    Write-Host "WARNING: SyncTeX output was locked (PDF was still written). Continuing. Tip: close the PDF preview or use -NoSynctex." -ForegroundColor Yellow
    $exit1 = 0
}

if ($exit1 -ne 0) {
    Write-Host "ERROR: First LaTeX pass failed!" -ForegroundColor Red
    exit $exit1
}

# Step 2: Biber (bibliography processing)
if ($biber) {
    Write-Host "Step 2/4: Processing bibliography with biber..." -ForegroundColor Yellow
    try {
        & biber template
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: Biber had issues, but continuing..." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "WARNING: Biber failed, but continuing..." -ForegroundColor Yellow
    }
} else {
    Write-Host "Step 2/4: Skipping bibliography (biber not found)..." -ForegroundColor Yellow
}

# Step 3: Second LaTeX pass (resolve references)
Write-Host "Step 3/4: Second LaTeX pass (resolving references)..." -ForegroundColor Yellow
try {
    Clear-TemplateSynctexArtifacts
    & $latexCmd $flags template.tex | Out-Null
    if ($LASTEXITCODE -ne 0 -and (Test-Path "template.pdf") -and (Test-LogSyncTeXRenameFailed "template.log")) {
        Write-Host "WARNING: SyncTeX rename failed on pass 2; PDF should still be usable." -ForegroundColor Yellow
    } elseif ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: Second pass had issues, but continuing..." -ForegroundColor Yellow
    }
} catch {
    Write-Host "WARNING: Second pass failed, but continuing..." -ForegroundColor Yellow
}

# Step 4: Third LaTeX pass (finalize)
Write-Host "Step 4/4: Final LaTeX pass..." -ForegroundColor Yellow
try {
    Clear-TemplateSynctexArtifacts
    & $latexCmd $flags template.tex | Out-Null
    if ($LASTEXITCODE -ne 0 -and (Test-Path "template.pdf") -and (Test-LogSyncTeXRenameFailed "template.log")) {
        Write-Host "WARNING: SyncTeX rename failed on pass 3; PDF should still be usable." -ForegroundColor Yellow
    } elseif ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: Final pass had issues." -ForegroundColor Yellow
    }
} catch {
    Write-Host "WARNING: Final pass failed." -ForegroundColor Yellow
}

# Check if PDF was created
Write-Host ""
if (Test-Path "template.pdf") {
    $pdfSize = (Get-Item "template.pdf").Length / 1MB
    Write-Host "SUCCESS: PDF generated successfully!" -ForegroundColor Green
    Write-Host "Output: template.pdf ($([math]::Round($pdfSize, 2)) MB)" -ForegroundColor Green

    # Clean up auxiliary files if -Clean flag is set
    if ($Clean) {
        Write-Host ""
        Write-Host "Cleaning auxiliary files..." -ForegroundColor Cyan
        $auxExtensions = @(
            "*.aux", "*.bbl", "*.bcf", "*.blg", "*.fdb_latexmk", "*.fls",
            "*.glg", "*.glo", "*.gls", "*.acn", "*.acr", "*.alg",
            "*.ist", "*.lof", "*.log", "*.lot", "*.out", "*.run.xml",
            "*.slg", "*.slo", "*.sls", "*.toc", "*.xdy",
            "*.synctex", "*.synctex.gz", "*.synctex(busy)"
        )
        foreach ($pattern in $auxExtensions) {
            Get-ChildItem -Path . -Filter $pattern -File | Remove-Item -Force
        }
        Write-Host "Done - only template.pdf remains." -ForegroundColor Green
    }

    exit 0
} else {
    Write-Host "ERROR: template.pdf was not created!" -ForegroundColor Red
    Write-Host "Check template.log for error details." -ForegroundColor Yellow
    exit 1
}
