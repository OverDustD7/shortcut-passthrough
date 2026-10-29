# build.ps1 -- build the APK with an existing Android SDK + JDK. No Gradle, no network.
#
# Point it at your toolchain with environment variables:
#   ANDROID_HOME (or ANDROID_SDK_ROOT) -> SDK root containing build-tools/ and platforms/
#   JAVA_HOME                          -> JDK 8+ (17 tested)
#
#   .\build.ps1
#   .\build.ps1 -Sdk D:\Android\Sdk -Jdk 'C:\Program Files\Java\jdk-17'
param(
    [string]$Sdk = $env:ANDROID_HOME,
    [string]$Jdk = $env:JAVA_HOME
)

$ErrorActionPreference = 'Continue'
$proj = $PSScriptRoot

if (-not $Sdk) { $Sdk = $env:ANDROID_SDK_ROOT }
foreach ($cand in @($Sdk, 'C:\Android\Sdk', (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
    if (-not $Sdk -and $cand -and (Test-Path (Join-Path $cand 'build-tools'))) { $Sdk = $cand }
}
if (-not $Sdk -or -not (Test-Path (Join-Path $Sdk 'build-tools'))) {
    throw "Android SDK not found. Set ANDROID_HOME or pass -Sdk."
}

$bt = Get-ChildItem (Join-Path $Sdk 'build-tools') -Directory |
      Sort-Object { [version]($_.Name -replace '[^0-9.]', '') } -Descending |
      Select-Object -First 1
if (-not $bt) { throw "no build-tools under $Sdk" }

$plat = Get-ChildItem (Join-Path $Sdk 'platforms') -Directory |
        Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
        Select-Object -First 1
if (-not $plat) { throw "no platform under $Sdk\platforms" }
$ajar = Join-Path $plat.FullName 'android.jar'

foreach ($cand in @($Jdk, 'C:\Program Files\Java\jdk-17', 'C:\Program Files\Android\Android Studio\jbr')) {
    if (-not $Jdk -and $cand -and (Test-Path (Join-Path $cand 'bin\javac.exe'))) { $Jdk = $cand }
}
if (-not $Jdk -or -not (Test-Path (Join-Path $Jdk 'bin\javac.exe'))) {
    throw "JDK not found. Set JAVA_HOME or pass -Jdk."
}

Write-Host "SDK        : $Sdk"
Write-Host "build-tools: $($bt.Name)"
Write-Host "platform   : $($plat.Name)"
Write-Host "JDK        : $Jdk"

$out  = Join-Path $proj 'build'
$flat = Join-Path $out 'flat'
$cls  = Join-Path $out 'classes'
$dex  = Join-Path $out 'dex'
$ks   = Join-Path $proj 'debug.keystore'

$env:JAVA_HOME = $Jdk
$env:PATH = (Join-Path $Jdk 'bin') + ';' + $env:PATH

foreach ($p in @($out, $flat, $cls, $dex)) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
}

function Step($n) { Write-Host ""; Write-Host "== $n ==" }

Step '1. aapt2 compile'
& (Join-Path $bt.FullName 'aapt2.exe') compile --dir (Join-Path $proj 'res') -o $flat
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed ($LASTEXITCODE)" }

Step '2. aapt2 link'
$flats = Get-ChildItem $flat -Recurse -Filter *.flat | ForEach-Object { $_.FullName }
$unsigned = Join-Path $out 'app-unsigned.apk'
& (Join-Path $bt.FullName 'aapt2.exe') link -o $unsigned -I $ajar `
    --manifest (Join-Path $proj 'AndroidManifest.xml') `
    --min-sdk-version 26 --target-sdk-version 34 $flats
if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed ($LASTEXITCODE)" }

Step '3. javac'
$srcs = Get-ChildItem (Join-Path $proj 'src') -Recurse -Filter *.java | ForEach-Object { $_.FullName }
& (Join-Path $Jdk 'bin\javac.exe') -encoding UTF-8 -source 8 -target 8 -bootclasspath $ajar -d $cls $srcs
if ($LASTEXITCODE -ne 0) { throw "javac failed ($LASTEXITCODE)" }

Step '4. d8'
$classes = Get-ChildItem $cls -Recurse -Filter *.class | ForEach-Object { $_.FullName }
& (Join-Path $bt.FullName 'd8.bat') --release --lib $ajar --min-api 26 --output $dex $classes
if ($LASTEXITCODE -ne 0) { throw "d8 failed ($LASTEXITCODE)" }

Step '5. add classes.dex'
$dexFile = Join-Path $dex 'classes.dex'
if (-not (Test-Path $dexFile)) { throw "no classes.dex produced" }
Push-Location $dex
& (Join-Path $Jdk 'bin\jar.exe') uf $unsigned 'classes.dex'
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { throw "jar uf failed ($rc)" }

Step '6. zipalign'
$aligned = Join-Path $out 'app-aligned.apk'
& (Join-Path $bt.FullName 'zipalign.exe') -f 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { throw "zipalign failed ($LASTEXITCODE)" }

Step '7. keystore'
if (-not (Test-Path $ks)) {
    & (Join-Path $Jdk 'bin\keytool.exe') -genkeypair -keystore $ks -storepass android -keypass android `
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10950 `
        -dname "CN=Android Debug,O=Android,C=US"
    if ($LASTEXITCODE -ne 0) { throw "keytool failed ($LASTEXITCODE)" }
} else { Write-Host "reuse $ks" }

Step '8. sign'
$signed = Join-Path $out 'shortcut-passthrough.apk'
& (Join-Path $bt.FullName 'apksigner.bat') sign --ks $ks --ks-pass pass:android --key-pass pass:android `
    --min-sdk-version 26 --out $signed $aligned
if ($LASTEXITCODE -ne 0) { throw "apksigner failed ($LASTEXITCODE)" }

Step '9. verify'
& (Join-Path $bt.FullName 'apksigner.bat') verify --print-certs $signed | Select-Object -First 4
& (Join-Path $bt.FullName 'aapt2.exe') dump badging $signed | Select-Object -First 6

Write-Host ""
Write-Host "APK: $signed  ($([math]::Round((Get-Item $signed).Length/1KB,1)) KB)"
