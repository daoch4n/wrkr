# ==================================================================
# Script: build.ps1
# Description: This script builds Cloudflare Workers, obfuscates them,
#              check for forbidden strings and compresses them into zip files.
# Creator: vadash
# ==================================================================

# Constants
$howManyToBuild = 10
$sevenZipPath = "C:\Program Files\7-Zip\7z.exe"
$sensitiveFileAuto = ".\sensitive_words_auto.txt"
$sensitiveFileManual = ".\sensitive_words_manual.txt"
$workerPath = ".\output\_worker.js"

function Replace-NameCalls {
    param(
        [string]$workerPath
    )

    # Read the content of the worker file
    $content = Get-Content -Path $workerPath -Raw

    # Find all __name function calls
    $nameCalls = [regex]::Matches($content, '__name\(([^,]+),\s*"([^"]+)"\)')

    if ($nameCalls) {
        # Create a List to store replacements
        $replacements = New-Object System.Collections.Generic.List[object]

        foreach ($call in $nameCalls) {
            # Generate a random 8-character hex string
            $randomHexString = -join (Get-Random -Count 8 -InputObject ([char[]]'0123456789abcdef'))

            # Construct the new __name call with the random hex string
            $newCall = $call.Value -replace '__name\(([^,]+),\s*"([^"]+)"\)', "__name(`$1, `"$randomHexString`")"

            # Add the original and new calls to the List
            $replacements.Add(@{ Original = $call.Value; New = $newCall })
        }

        # Replace the original calls with the new ones
        $newContent = $content
        foreach ($replacement in $replacements) {
            $newContent = $newContent.Replace($replacement.Original, $replacement.New)
        }

        # Write the modified content back to the file
        Set-Content -Path $workerPath -Value $newContent -Force
        Write-Host "Successfully replaced __name calls in '$workerPath'"
    } else {
        Write-Host "No __name calls found in '$workerPath'"
    }
}

# Validate 7-Zip installation
if (!(Test-Path $sevenZipPath)) {
    Write-Host "Error: 7-Zip not found at $sevenZipPath"
    exit 1
}

# Kill 7z GUI if it's running
taskkill /f /im 7zFM.exe

# Remove the output directory if it exists
Remove-Item -Recurse -Force -Path .\output\ -ErrorAction SilentlyContinue

# Load forbidden strings from file
if (Test-Path $sensitiveFileAuto) {
    $sensitiveStringsAuto = Get-Content $sensitiveFileAuto
} else {
    Write-Host "Error: $sensitiveFileAuto not found."
    exit 1
}
if (Test-Path $sensitiveFileManual) {
    $sensitiveStringsManual = Get-Content $sensitiveFileManual
} else {
    Write-Host "Error: $sensitiveFileManual not found."
    exit 1
}

# Build worker once
try {
    # Ensure the output directory exists
    if (!(Test-Path -Path .\output\)) {
        New-Item -ItemType Directory -Path .\output\
    }

    # Build the worker
    npx wrangler deploy --dry-run --outdir output

    # Rename worker
    Rename-Item -Path ".\output\worker.js" -NewName "_worker.js"

    # Remove debug code (__name functions)
    Replace-NameCalls -workerPath $workerPath

    # Remove comments from worker
    npx uglify-js $workerPath -o $workerPath --compress --mangle -O keep_quoted_props

    # Remove Unicode symbols
    $workerContent = Get-Content -Path $workerPath -Raw
    $cleanedContent = $workerContent -replace '[^\x20-\x7E\s]', ''
    Set-Content -Path $workerPath -Value $cleanedContent

    # Store the original worker content
    $originalWorker = Get-Content -Path $workerPath -Raw
} catch {
    Write-Host "Failed to build worker: $_"
    pause
    exit 1
}

$successfulBuilds = 0
while ($successfulBuilds -lt $howManyToBuild) {
    try {
        # Create fresh copy of worker
        Set-Content -Path $workerPath -Value $originalWorker

        # Replace forbidden variable/function names with random hex names
        $forbiddenReplacements = @{}
        $usedHexValues = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($forbiddenString in $sensitiveStringsManual) {
            # Generate a unique random hex string (4-8 chars)
            do {
                $length = Get-Random -Minimum 4 -Maximum 9
                $randomHex = -join ((48..57) + (97..102) | Get-Random -Count $length | ForEach-Object {[char]$_})
            } while (!$usedHexValues.Add($randomHex)) # Keep trying until we get a unique value

            $forbiddenReplacements[$forbiddenString] = "var_$randomHex"
        }
        $jsContent = Get-Content -Path $workerPath -Raw
        foreach ($forbiddenString in $sensitiveStringsManual) {
            # Use word boundaries with case-insensitive matching
            $pattern = "(?i)\b$forbiddenString\b"
            $jsContent = $jsContent -replace $pattern, $forbiddenReplacements[$forbiddenString]
        }
        Set-Content -Path $workerPath -Value $jsContent

        # Obfuscate the worker with proper tool
        node .\obfuscate.mjs

        # Search for forbidden strings in the worker output script
        $workerScript = Get-Content -Path $workerPath -Raw
        $forbiddenFound = $false
        foreach ($string in $sensitiveStringsAuto) {
            if ($workerScript -imatch $string) {
                Write-Host "Warning: Forbidden string '$string' found in worker script. Retrying..."
                [System.Console]::Beep(800,500)
                $forbiddenFound = $true
                break
            }
        }

        # Skip to the next iteration if a forbidden string was found
        if ($forbiddenFound) {
            continue
        }

        # Replace "let" and "const" with "var"
        (Get-Content -Path $workerPath) -replace '\b(let|const)\b', 'var' | Set-Content -Path $workerPath

        # Prepare for 7-Zip compression
        $randomGuid = [guid]::NewGuid().ToString()
        $zipFileName = "worker-$randomGuid.zip"
        $zipsDirectory = ".\output\zips"

        # Ensure the zips directory exists
        if (!(Test-Path -Path $zipsDirectory)) {
            New-Item -ItemType Directory -Path $zipsDirectory
        }

        # Set no compression to see real size
        & $sevenZipPath a -tzip -mx=0 "$zipsDirectory\$zipFileName" $workerPath

        # Increment successful builds counter only after everything succeeds
        $successfulBuilds++
        Write-Host "Successfully created worker $successfulBuilds of $howManyToBuild"

    } catch {
        Write-Host "An error occurred: $_"
        continue
    }
}

# Clean up temporary files
Get-ChildItem -Path .\output\ -Exclude zips | Remove-Item -Recurse -Force
Write-Host "Build process completed. Created $successfulBuilds workers."
