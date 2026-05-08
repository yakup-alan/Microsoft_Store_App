@echo off & goto :_cmd_
# CMD blogu PS tarafindan bu satir comment olarak gorulur
:_cmd_
@set "MSAM_ARGS=%*" & @set "CM=0"
@echo "%*"|findstr /i /c:"-List" /c:"-Update" /c:"-NoGUI" /c:"-Download" /c:"-Install" >nul 2>&1 && @set "CM=1"
@net session >nul 2>&1 || @goto :needadmin
@if "%CM%"=="1" (powershell -NoProfile -ExecutionPolicy Bypass -Command "$PSScriptRoot='%~dp0';$PSScriptRoot=$PSScriptRoot.TrimEnd('/\');$f='%~f0';$lines=Get-Content $f -Encoding UTF8;$skip=$true;$ps=@();foreach($l in $lines){if($skip -and $l -match '^#>'){$skip=$false;continue};if(-not $skip){$ps+=$l}};Invoke-Expression ($ps -join [char]10)") else (@start "" /b powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$PSScriptRoot='%~dp0';$PSScriptRoot=$PSScriptRoot.TrimEnd('/\');$f='%~f0';$lines=Get-Content $f -Encoding UTF8;$skip=$true;$ps=@();foreach($l in $lines){if($skip -and $l -match '^#>'){$skip=$false;continue};if(-not $skip){$ps+=$l}};Invoke-Expression ($ps -join [char]10)")
@goto :eof
:needadmin
@if "%CM%"=="1" (powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/k \"%~f0\" %*' -Verb RunAs") else (powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs")
@goto :eof
:_ps_
<#
# PowerShell buradan baslar — CMD blogu yukarida bitti
#>
# ── PowerShell'den doğrudan çalıştırıldığında CMD bloğu atlanır ──────────────
if ($MyInvocation.MyCommand.Path) {
    $PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
}
#Requires -Version 5.1
# ── Komut satırı parametreleri — param() scriptblock'ta çalışmaz, manuel parse
# Hem .\script.cmd -List hem de cmd /c script.cmd -List desteklenir
# Ring/Arch boş başlar — sadece KULLANICI -Ring/-Arch verirse dolar.
# Bu sayede GUI açılışta JSON'dan yüklenen değer ezilmez.
$Fetch    = ''; $Ring = ''; $Arch = ''
$Download = $false; $Install = $false; $Update = $false; $List = $false; $NoGUI = $false

# Parametreleri $env:MSAM_ARGS'tan veya $args'tan al
$_rawArgs = if ($env:MSAM_ARGS) {
    # CMD'den env var ile geldi — split et
    $env:MSAM_ARGS -split '\s+(?=-)' | ForEach-Object { $_ -split '\s+' } | Where-Object { $_ }
} else {
    # Doğrudan PS'ten çalıştırıldı — $args kullan
    $args
}

$_i = 0
$_rawArgs = @($_rawArgs)
while ($_i -lt $_rawArgs.Count) {
    switch ($_rawArgs[$_i].ToString().ToLowerInvariant().Trim()) {
        '-fetch'    { $_i++; if ($_i -lt $_rawArgs.Count) { $Fetch    = $_rawArgs[$_i] } }
        '-ring'     { $_i++; if ($_i -lt $_rawArgs.Count) { $Ring     = $_rawArgs[$_i] } }
        '-arch'     { $_i++; if ($_i -lt $_rawArgs.Count) { $Arch     = $_rawArgs[$_i] } }
        '-download' { $Download = $true }
        '-install'  { $Install  = $true }
        '-update'   { $Update   = $true }
        '-list'     { $List     = $true }
        '-nogui'    { $NoGUI    = $true }
    }
    $_i++
}
$env:MSAM_ARGS = $null  # temizle

# ═══════════════════════════════════════════════════════════════════════════════
# KONSOL MODU — GUI açılmadan çalışır
# -List, -Update, -NoGUI veya -Fetch + (-Download|-Install) kombinasyonlarında
# ═══════════════════════════════════════════════════════════════════════════════
$script:ConsoleMode = $NoGUI -or $List -or $Update -or ($Fetch -and ($Download -or $Install))

# Konsol modu için varsayılanları doldur (boşsa) — GUI modunda Ring/Arch boş kalır
# ki JSON'dan yüklenen değer ezilmesin.
# Fill console-mode defaults only; in GUI mode keep Ring/Arch empty so JSON wins.
if ($script:ConsoleMode) {
    if (-not $Ring) { $Ring = 'Retail' }
    if (-not $Arch) { $Arch = 'x64' }
}

if ($script:ConsoleMode) {

    # Ring → API değeri
    $ringApi = switch ($Ring) {
        'Retail'  { 'Retail' }
        'RP'      { 'RP' }
        'Preview' { 'RP' }
        'WIS'     { 'WIS' }
        'WIF'     { 'WIF' }
        'Slow'    { 'Slow' }
        'Fast'    { 'Fast' }
        default   { 'Retail' }
    }

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    # ── Yardımcı: rg-adguard'dan paket listesi çek ───────────────────────────
    function Get-StorePackages {
        param([string]$Identifier, [string]$RingVal, [string]$ArchVal)

        $isUrl = $Identifier -match '^https?://'
        $isPfn = $Identifier -match '^[\w.]+_\w+$'

        if ($isPfn) {
            $reqType = 'PackageFamilyName'; $reqUrl = $Identifier
        } elseif ($isUrl) {
            $m = [regex]::Match($Identifier, '/detail/([A-Z0-9]{9,})', 'IgnoreCase')
            if ($m.Success) { $reqType = 'ProductId'; $reqUrl = $m.Groups[1].Value }
            else             { $reqType = 'url';       $reqUrl = $Identifier }
        } else {
            $reqType = 'ProductId'; $reqUrl = $Identifier
        }

        $body = "type=$reqType&url=$([Uri]::EscapeDataString($reqUrl))&ring=$RingVal&lang=en-US"
        $bb   = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req  = [System.Net.HttpWebRequest]::Create('https://store.rg-adguard.net/api/GetFiles')
        $req.Method = 'POST'; $req.ContentType = 'application/x-www-form-urlencoded'
        $req.ContentLength = $bb.Length; $req.Timeout = 30000
        $req.UserAgent = 'Mozilla/5.0'; $req.Referer = 'https://store.rg-adguard.net/'
        $rs = $req.GetRequestStream(); $rs.Write($bb, 0, $bb.Length); $rs.Close()
        $resp = $req.GetResponse()
        $html = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $resp.Close()

        $archPat    = "_$([regex]::Escape($ArchVal))(?=[_.])"
        $neutralPat = '_neutral(?=[_.])'
        $expectedBase = if ($isPfn) { ($Identifier -split '_')[0] } else { $null }

        $results = @()
        foreach ($m in [regex]::Matches($html, '<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>')) {
            $fn  = $m.Groups[2].Value.Trim()
            $url = $m.Groups[1].Value.Trim()
            if (-not $fn) { continue }
            if ($fn -match 'BlockMap|\.eappx|\.emsix') { continue }
            if ($fn -notmatch '\.(appx|appxbundle|msix|msixbundle)$') { continue }
            $parts = $fn -split '_'; if ($parts.Count -lt 3) { continue }
            if ($expectedBase -and $parts[0] -ne $expectedBase) { continue }
            try {
                $v = [Version]$parts[1]
                $isBundle = $fn -match '\.(appxbundle|msixbundle)$'
                $results += [PSCustomObject]@{
                    FileName = $fn; Url = $url; Version = $v
                    VerStr = $parts[1]; Arch = $parts[2].ToLowerInvariant()
                    IsBundle = $isBundle; IsDep = ($expectedBase -and $parts[0] -ne $expectedBase)
                }
            } catch {}
        }

        # v5 anchor: iç paket versiyonuyla eşleşen en yüksek bundle
        $bundles = @($results | Where-Object { $_.IsBundle })
        $inners  = @($results | Where-Object { -not $_.IsBundle })
        $archFiltered = @($inners | Where-Object { $_.FileName -match $archPat })
        if (-not $archFiltered) { $archFiltered = @($inners | Where-Object { $_.FileName -match $neutralPat }) }
        if (-not $archFiltered) { $archFiltered = $inners }

        # ─────────────────────────────────────────────────────────────────────
        # Legacy yıl-bazlı schema filtresi (BingWeather, BingNews vs. için)
        # ─────────────────────────────────────────────────────────────────────
        # AKTİF-ŞEMA SEÇİMİ
        # rg-adguard bazen aynı paketin hem yıl-bazlı (2016.x, 2025.x) hem
        # semver-bazlı (4.54.x, 1.26x) sürümlerini döndürür. [Version] sıralaması
        # 2016 > 4 olduğundan eski schema yanlışlıkla "en yeni" seçilir.
        #
        # DOĞRU yaklaşım uygulamaya göre değişir:
        #   - BingWeather/YourPhone: yıl-bazlıdan semver'e geçti → modern aktif
        #   - 3DViewer/OfficeHub/RemoteDesktop: semver'den yıl-bazlıya geçti → legacy aktif
        # Heuristic: "Hangi şemada daha çok sürüm varsa o aktif" — Microsoft'un
        # her uygulamada düzenli yayın yaptığı şema en çok sürüme sahiptir.
        # Eşitlik halinde legacy major ≥ 2024 ise legacy (modern semver Major
        # asla 2024'e ulaşmaz, yıl-bazlı bunu yapar).
        # / Active-schema picker: pool with more versions wins. On tie, prefer
        #   legacy if its top major >= 2024 (recent year-based release).
        # ─────────────────────────────────────────────────────────────────────
        function Select-ActiveSchema {
            param([object[]]$Pool)
            if (-not $Pool -or $Pool.Count -eq 0) { return $Pool }
            $modern = @($Pool | Where-Object { $_.Version.Major -lt 2000 })
            $legacy = @($Pool | Where-Object { $_.Version.Major -ge 2000 })
            if ($modern.Count -eq 0) { return $legacy }
            if ($legacy.Count -eq 0) { return $modern }
            if ($modern.Count -gt $legacy.Count) { return $modern }
            if ($legacy.Count -gt $modern.Count) { return $legacy }
            # Eşit sayıda — legacy'nin en yüksek major'una bak
            $legacyTopMajor = ($legacy | Sort-Object Version -Descending | Select-Object -First 1).Version.Major
            if ($legacyTopMajor -ge 2024) { return $legacy }
            return $modern
        }

        $anchorVer = $null
        if ($bundles) {
            # [Version] karşılaştırması için string set kullan
            $innerVerStrs = @($inners | ForEach-Object { $_.VerStr }) | Select-Object -Unique
            $matched   = @($bundles | Where-Object { $innerVerStrs -contains $_.VerStr })
            $pool      = if ($matched) { $matched } else { $bundles }
            $pool      = @(Select-ActiveSchema -Pool $pool)
            $anchorVer = ($pool | Sort-Object Version -Descending | Select-Object -First 1).Version
        } elseif ($archFiltered) {
            $pool      = @(Select-ActiveSchema -Pool $archFiltered)
            $anchorVer = ($pool | Sort-Object Version -Descending | Select-Object -First 1).Version
        }

        return [PSCustomObject]@{
            All        = $results
            Bundles    = $bundles
            Inners     = $archFiltered
            AnchorVer  = $anchorVer
            Latest     = @($results | Where-Object { $_.Version -eq $anchorVer })
        }
    }

    # ── -List: Yüklü uygulamaları listele ────────────────────────────────────
    if ($List) {
        Write-Host "`nYüklü Store Uygulamaları" -ForegroundColor Cyan
        Write-Host ("─" * 80) -ForegroundColor DarkGray
        Write-Host ("{0,-50} {1,-20} {2}" -f "Uygulama", "Versiyon", "Mimari") -ForegroundColor Yellow
        Write-Host ("─" * 80) -ForegroundColor DarkGray
        Get-AppxPackage -AllUsers | Where-Object { $_.SignatureKind -eq 'Store' } |
            Sort-Object Name |
            ForEach-Object {
                Write-Host ("{0,-50} {1,-20} {2}" -f $_.Name, $_.Version, $_.Architecture)
            }
        Write-Host ("─" * 80) -ForegroundColor DarkGray
        return
    }

    # ── -Update: Tüm yüklü uygulamaları güncelle ─────────────────────────────
    if ($Update) {
        # Ayarlardan indirme dizinini oku
        $settingsFile = Join-Path $env:APPDATA 'StoreAppManager\settings.json'
        $dlFolder = Join-Path $env:USERPROFILE 'Downloads\StorePackages'
        if (Test-Path $settingsFile) {
            try {
                $cfg = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($cfg.DownloadFolder -and (Test-Path $cfg.DownloadFolder -IsValid)) { $dlFolder = $cfg.DownloadFolder }
                if ($cfg.DeleteAfterInstall) { $script:DeleteAfterInstall = [bool]$cfg.DeleteAfterInstall }
            } catch {}
        }
        if (-not (Test-Path $dlFolder)) { New-Item -ItemType Directory -Path $dlFolder -Force | Out-Null }

        Write-Host "`nMagaza Guncelleme Taramasi — Ring: $ringApi" -ForegroundColor Cyan
        Write-Host ("─" * 100) -ForegroundColor DarkGray
        Write-Host ("{0,-48} {1,-20} {2,-20} {3}" -f "Uygulama", "Yüklenen Sürüm", "Mağaza Sürümü", "Durum") -ForegroundColor Yellow
        Write-Host ("─" * 100) -ForegroundColor DarkGray

        $apps = @(Get-AppxPackage -AllUsers | Where-Object {
            $_.SignatureKind -eq 'Store' -and
            $_.Publisher -notmatch 'CN=Microsoft Windows' -and
            $_.IsFramework -eq $false
        } | Sort-Object Name)

        $toUpdate = @()   # { App, PFN, StoreVer, Pkgs }

        # Alias haritası — console modunda da geçerli / Alias map for console mode too
        $consoleAliasMap = @{
            'microsoft.windowsclient.webexperience' = 'MicrosoftWindows.Client.WebExperience'
            'microsoft.quickassist'                 = 'MicrosoftCorporationII.QuickAssist'
            'msteams'                               = 'Microsoft.Teams'
            'microsoft.mspaint'                     = 'Microsoft.Paint'
            'microsoft.photoslegacy'                = 'Microsoft.WindowsPhotos'
        }
        $consoleLegacyNames = @{
            'microsoftwindows.client.webexperience' = @('Microsoft.WindowsClient.WebExperience')
            'microsoftcorporationii.quickassist'    = @('Microsoft.QuickAssist')
            'microsoft.teams'                       = @('MSTeams')
            'microsoft.paint'                       = @('Microsoft.MSPaint')
            'microsoft.windowsphotos'               = @('Microsoft.PhotosLegacy')
        }

        foreach ($app in $apps) {
            Write-Host ("{0,-48} {1,-18}" -f $app.Name, $app.Version) -NoNewline
            try {
                # Alias çözümleme: eski adlı paketler canonical adıyla sorgulanır
                # / Alias resolution: legacy packages are queried under canonical name
                $appBase = ($app.PackageFamilyName -split '_')[0]
                $lookupIdentifier = $app.PackageFamilyName
                if ($consoleAliasMap.ContainsKey($appBase.ToLowerInvariant())) {
                    $canonBase = $consoleAliasMap[$appBase.ToLowerInvariant()]
                    $canonPkg  = Get-AppxPackage -AllUsers -Name "$canonBase*" -ErrorAction SilentlyContinue | Select-Object -First 1
                    $lookupIdentifier = if ($canonPkg) { $canonPkg.PackageFamilyName } else { $canonBase }
                }
                $pkgs = Get-StorePackages -Identifier $lookupIdentifier -RingVal $ringApi -ArchVal $app.Architecture.ToString().ToLowerInvariant()
                if ($pkgs.AnchorVer) {
                    $storeVer   = $pkgs.AnchorVer
                    $iv         = [Version]$app.Version
                    $ivIsYear   = $iv.Major       -ge 2000
                    $svIsYear   = $storeVer.Major -ge 2000
                    $majorDiff  = [Math]::Abs($iv.Major - $storeVer.Major)
                    if ($majorDiff -gt 100 -and ($ivIsYear -xor $svIsYear)) {
                        # Sema gecisi: yil-bazli olan taraf daha yeni
                        if ($svIsYear) {
                            Write-Host ("{0,-18} " -f $storeVer) -NoNewline
                            Write-Host "GÜNCELLEME MEVCUT" -ForegroundColor Yellow
                            $toUpdate += [PSCustomObject]@{ App=$app; StoreVer=$storeVer; Pkgs=$pkgs }
                        } else {
                            Write-Host ("{0,-18} " -f $storeVer) -NoNewline
                            Write-Host "GÜNCEL" -ForegroundColor Green
                        }
                    } elseif ($iv -lt $storeVer) {
                        Write-Host ("{0,-18} " -f $storeVer) -NoNewline
                        Write-Host "GÜNCELLEME MEVCUT" -ForegroundColor Yellow
                        $toUpdate += [PSCustomObject]@{ App=$app; StoreVer=$storeVer; Pkgs=$pkgs }
                    } elseif ($iv -eq $storeVer) {
                        Write-Host ("{0,-18} " -f $storeVer) -NoNewline
                        Write-Host "GÜNCEL" -ForegroundColor Green
                    } else {
                        Write-Host ("{0,-18} " -f $storeVer) -NoNewline
                        Write-Host "GÜNCELLEYEN AŞAMADA" -ForegroundColor Blue
                    }
                } else {
                    Write-Host ("{0,-18} " -f "N/A") -NoNewline
                    Write-Host "N/A" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host ("{0,-18} " -f "HATA") -NoNewline
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
            Start-Sleep -Milliseconds 600
        }

        Write-Host ("─" * 100) -ForegroundColor DarkGray
        Write-Host "$($toUpdate.Count) guncelleme mevcut." -ForegroundColor Cyan

        if ($toUpdate.Count -eq 0) { exit 0 }

        # Onay iste
        Write-Host "`nGuncellenecek uygulamalar:" -ForegroundColor Cyan
        foreach ($u in $toUpdate) {
            Write-Host "  $($u.App.Name)  $($u.App.Version) -> $($u.StoreVer)" -ForegroundColor Yellow
        }
        Write-Host "`nDevam etmek istiyor musunuz? [E/H]: " -NoNewline -ForegroundColor White
        $confirm = Read-Host
        if ($confirm.ToLowerInvariant() -notin @('e','y','evet','yes')) {
            Write-Host "Iptal edildi." -ForegroundColor DarkGray
            return
        }

        # Her uygulamayı indir ve kur
        $success = 0; $failed = 0
        foreach ($u in $toUpdate) {
            Write-Host "`n[$($toUpdate.IndexOf($u)+1)/$($toUpdate.Count)] $($u.App.Name)" -ForegroundColor Cyan
            $downloaded = @()

            foreach ($p in $u.Pkgs.Latest) {
                $dest = Join-Path $dlFolder $p.FileName
                Write-Host "  $($p.FileName)" -ForegroundColor White
                try {
                    $req = [System.Net.HttpWebRequest]::Create($p.Url)
                    $req.UserAgent        = 'Mozilla/5.0'
                    $req.Timeout          = 300000   # 5 dakika
                    $req.ReadWriteTimeout = 300000   # 5 dakika
                    $resp     = $req.GetResponse()
                    $totalLen = $resp.ContentLength
                    $stream   = $resp.GetResponseStream()
                    $fs       = [System.IO.File]::Create($dest)
                    $buf      = New-Object byte[] 65536
                    $recv     = 0
                    $sw       = [System.Diagnostics.Stopwatch]::StartNew()

                    while ($true) {
                        $read = $stream.Read($buf, 0, $buf.Length)
                        if ($read -le 0) { break }
                        $fs.Write($buf, 0, $read); $recv += $read
                        $pct      = if ($totalLen -gt 0) { [int]($recv * 100 / $totalLen) } else { 0 }
                        $recvStr  = "$([math]::Round($recv/1MB,2))".Replace(',','.')
                        $totalStr = if ($totalLen -gt 0) { "$([math]::Round($totalLen/1MB,2))".Replace(',','.') } else { '?' }
                        $elapsed  = $sw.Elapsed.TotalSeconds
                        $speed    = if ($elapsed -gt 0.5) { $bps=$recv/$elapsed; if($bps -ge 1MB){"  $(("$([math]::Round($bps/1MB,1))").Replace(',','.')) MB/s"}elseif($bps -ge 1KB){"  $([int]($bps/1KB)) KB/s"}else{''} } else {''}
                        $eta      = if ($totalLen -gt 0 -and $elapsed -gt 1 -and $recv -gt 0) { $r=($totalLen-$recv)/($recv/$elapsed); if($r -lt 60){"  ETA $([int]$r)s"}else{"  ETA $([int]($r/60))m"} } else {''}
                        $filled   = if ($totalLen -gt 0) { [math]::Floor($pct/5) } else { 0 }
                        $bar      = ('#'*$filled)+('-'*(20-$filled))
                        Write-Host "`r  [$bar] $("$pct".PadLeft(3))%  $($recvStr.PadLeft(7)) / $($totalStr.PadLeft(7)) MB$speed$eta   " -NoNewline
                    }
                    $fs.Close(); $stream.Close(); $resp.Close(); $sw.Stop()
                    $sizeMB = "$([math]::Round((Get-Item $dest).Length/1MB,2))".Replace(',','.')
                    Write-Host "`r  [####################] 100%  $($sizeMB.PadLeft(7)) MB  Tamamlandi ($([math]::Round($sw.Elapsed.TotalSeconds,1))s)          " -ForegroundColor Green
                    $downloaded += $dest
                } catch {
                    Write-Host "`r  HATA: $($_.Exception.Message)                    " -ForegroundColor Red
                }
            }

            if ($downloaded) {
                # Alias kontrolü: kurulmadan önce eski adlı sürüm varsa kaldır
                # / Alias check: remove legacy-named version before installing new one
                $installBase = ($u.App.PackageFamilyName -split '_')[0]
                if ($consoleAliasMap.ContainsKey($installBase.ToLowerInvariant())) {
                    Write-Host "  Eski surum kaldiriliyor ($installBase)... " -NoNewline -ForegroundColor Yellow
                    try {
                        Get-AppxPackage -AllUsers -Name "$installBase*" -ErrorAction SilentlyContinue |
                            Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                        Write-Host "OK" -ForegroundColor Green
                    } catch { Write-Host "Atla" -ForegroundColor DarkGray }
                }
                # Canonical yüklüyse onu da önceden kaldır (çakışmaları önle)
                # / If canonical is already installed, remove it first (prevent conflict)
                $canonLookupBase = ($lookupIdentifier -split '_')[0]
                if ($consoleLegacyNames.ContainsKey($canonLookupBase.ToLowerInvariant())) {
                    foreach ($legBase in $consoleLegacyNames[$canonLookupBase.ToLowerInvariant()]) {
                        $legPkg = Get-AppxPackage -AllUsers -Name "$legBase*" -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($legPkg) {
                            Write-Host "  Eski surum kaldiriliyor ($legBase)... " -NoNewline -ForegroundColor Yellow
                            try { $legPkg | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue; Write-Host "OK" -ForegroundColor Green } catch { Write-Host "Atla" -ForegroundColor DarkGray }
                        }
                    }
                }
                Write-Host "  Kuruluyor... " -NoNewline
                try {
                    Add-AppxPackage -Path $downloaded[0] -ForceApplicationShutdown -ErrorAction Stop
                    Write-Host "OK" -ForegroundColor Green
                    $success++
                    if ($script:DeleteAfterInstall) {
                        try { foreach ($f in $downloaded) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch {}
                    }
                } catch {
                    Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
                    $failed++
                }
            } else {
                $failed++
            }
        }

        Write-Host "`n" + ("─" * 60) -ForegroundColor DarkGray
        Write-Host "Tamamlandi: $success basarili, $failed basarisiz." -ForegroundColor Cyan
        return
    }

    # ── -Fetch + (-Download|-Install): Konsol modunda indir/kur ──────────────
    if ($Fetch) {
        Write-Host "`nFetch: $Fetch  [Ring=$ringApi, Arch=$Arch]" -ForegroundColor Cyan
        Write-Host ("─" * 80) -ForegroundColor DarkGray

        try {
            $pkgs = Get-StorePackages -Identifier $Fetch -RingVal $ringApi -ArchVal $Arch
        } catch {
            Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 1
        }

        if (-not $pkgs.Latest) {
            Write-Host "Paket bulunamadı." -ForegroundColor Red; exit 1
        }

        Write-Host "Bulunan paketler:" -ForegroundColor Yellow
        foreach ($p in ($pkgs.All | Sort-Object Version -Descending)) {
            $tag = if ($p.Version -eq $pkgs.AnchorVer) { "[LATEST]" } else { "[OLDER] " }
            $col = if ($p.Version -eq $pkgs.AnchorVer) { 'Green' } else { 'DarkGray' }
            Write-Host ("  $tag {0,-70} {1}" -f $p.FileName, $p.VerStr) -ForegroundColor $col
        }

        if ($Download -or $Install) {
            # Ayarlardan indirme dizinini oku, yoksa varsayılanı kullan
            $settingsFile = Join-Path $env:APPDATA 'StoreAppManager\settings.json'
            $dlFolder = Join-Path $env:USERPROFILE 'Downloads\StorePackages'
            if (Test-Path $settingsFile) {
                try {
                    $cfg = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($cfg.DownloadFolder -and (Test-Path $cfg.DownloadFolder -IsValid)) {
                        $dlFolder = $cfg.DownloadFolder
                    }
                    if ($cfg.DeleteAfterInstall) { $script:DeleteAfterInstall = [bool]$cfg.DeleteAfterInstall }
                } catch {}
            }
            if (-not (Test-Path $dlFolder)) { New-Item -ItemType Directory -Path $dlFolder -Force | Out-Null }

            Write-Host "`nIndirme dizini: $dlFolder" -ForegroundColor Cyan
            $downloaded = @()

            foreach ($p in $pkgs.Latest) {
                $dest = Join-Path $dlFolder $p.FileName
                Write-Host "  $($p.FileName)" -ForegroundColor White

                try {
                    # HttpWebRequest ile manuel progress
                    $req = [System.Net.HttpWebRequest]::Create($p.Url)
                    $req.UserAgent        = 'Mozilla/5.0'
                    $req.Timeout          = 300000   # 5 dakika baglanti timeout
                    $req.ReadWriteTimeout = 300000   # 5 dakika okuma timeout
                    $resp     = $req.GetResponse()
                    $totalLen = $resp.ContentLength
                    $stream   = $resp.GetResponseStream()
                    $fs       = [System.IO.File]::Create($dest)
                    $buf      = New-Object byte[] 65536
                    $recv     = 0
                    $sw       = [System.Diagnostics.Stopwatch]::StartNew()

                    while ($true) {
                        $read = $stream.Read($buf, 0, $buf.Length)
                        if ($read -le 0) { break }
                        $fs.Write($buf, 0, $read)
                        $recv += $read

                        # Her 64KB'da progress guncelle
                        $pct     = if ($totalLen -gt 0) { [int]($recv * 100 / $totalLen) } else { 0 }
                        $recvMB  = [math]::Round($recv   / 1MB, 2)
                        $totalMB = if ($totalLen -gt 0) { [math]::Round($totalLen / 1MB, 2) } else { 0 }
                        $recvStr  = "$recvMB".Replace(',','.')
                        $totalStr = if ($totalLen -gt 0) { "$totalMB".Replace(',','.') } else { '?' }
                        $elapsed = $sw.Elapsed.TotalSeconds

                        $speed = ''
                        if ($elapsed -gt 0.5) {
                            $bps = $recv / $elapsed
                            if ($bps -ge 1MB)     { $speed = "  $(([math]::Round($bps/1MB,1)).ToString().Replace(',','.')) MB/s" }
                            elseif ($bps -ge 1KB) { $speed = "  $([int]($bps/1KB)) KB/s" }
                        }

                        $eta = ''
                        if ($totalLen -gt 0 -and $elapsed -gt 1 -and $recv -gt 0) {
                            $rem = ($totalLen - $recv) / ($recv / $elapsed)
                            $eta = if ($rem -lt 60) { "  ETA $([int]$rem)s" } else { "  ETA $([int]($rem/60))m" }
                        }

                        $filled = if ($totalLen -gt 0) { [math]::Floor($pct / 5) } else { 0 }
                        $bar    = ('#' * $filled) + ('-' * (20 - $filled))
                        Write-Host "`r  [$bar] $("$pct".PadLeft(3))%  $($recvStr.PadLeft(7)) / $($totalStr.PadLeft(7)) MB$speed$eta   " -NoNewline
                    }

                    $fs.Close(); $stream.Close(); $resp.Close(); $sw.Stop()
                    $sizeMB  = "$([math]::Round((Get-Item $dest).Length / 1MB, 2))".Replace(',','.')
                    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    Write-Host "`r  [####################] 100%  $($sizeMB.PadLeft(7)) MB  Tamamlandi ($($elapsed)s)          " -ForegroundColor Green
                    $downloaded += $dest
                } catch {
                    Write-Host "`r  HATA: $($_.Exception.Message)                    " -ForegroundColor Red
                }
            }

            if ($Install -and $downloaded) {
                Write-Host "`nKuruluyor..." -ForegroundColor Cyan
                foreach ($f in $downloaded) {
                    Write-Host "  > $([System.IO.Path]::GetFileName($f)) ... " -NoNewline
                    try {
                        Add-AppxPackage -Path $f -ForceApplicationShutdown -ErrorAction Stop
                        Write-Host "OK" -ForegroundColor Green
                        if ($script:DeleteAfterInstall) {
                            try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch {}
                        }
                    } catch {
                        Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }
        return
    }

    # -NoGUI tek başına: yardım göster
    if ($NoGUI) {
        Write-Host @"
Microsoft Store App Manager 2.0.3 - Konsol Modu
================================================

KULLANIM:
  .\Microsoft_Store_App_Manager.cmd [parametreler]

PARAMETRELER:
  -Fetch <deger>    PFN, Store URL veya Product ID
                    Ornek: Microsoft.WindowsNotepad_8wekyb3d8bbwe
                           https://apps.microsoft.com/detail/9MSMLRH6LZF3
                           9MSMLRH6LZF3

  -Ring <kanal>     Retail (varsayilan) | RP | WIS | WIF | Slow | Fast
                    Retail = Kararli, RP = Release Preview
                    WIS = Insider Slow, WIF = Insider Fast

  -Arch <mimari>    x64 (varsayilan) | x86 | arm64 | arm | neutral

  -Download         -Fetch ile: indir (GUI acilmaz)
  -Install          -Fetch ile: indir ve kur (GUI acilmaz)
  -Update           Tum yuklu uygulamalari guncelle (GUI acilmaz)
  -List             Yuklu Store uygulamalarini listele (GUI acilmaz)
  -NoGUI            Bu yardim mesajini goster

ORNEKLER:
  # Yuklu uygulamalari listele
  .\Microsoft_Store_App_Manager.cmd -List

  # Guncelleme kontrolu (Retail)
  .\Microsoft_Store_App_Manager.cmd -Update

  # RP kanalinda guncelleme kontrolu
  .\Microsoft_Store_App_Manager.cmd -Update -Ring RP

  # Notepad'i getir (GUI Fetch sekmesi)
  .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.WindowsNotepad_8wekyb3d8bbwe

  # ScreenSketch'i indir (konsol, progress bar)
  .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.ScreenSketch_8wekyb3d8bbwe -Download

  # ScreenSketch'i WIF kanalinden indir ve kur
  .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.ScreenSketch_8wekyb3d8bbwe -Install -Ring WIF

  # Windows Terminal'i arm64 olarak indir
  .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.WindowsTerminal_8wekyb3d8bbwe -Arch arm64 -Download

  # Store URL ile indir
  .\Microsoft_Store_App_Manager.cmd -Fetch https://apps.microsoft.com/detail/9N0DX20HK701 -Download

  # GUI'yi ac (parametresiz)
  .\Microsoft_Store_App_Manager.cmd
"@ -ForegroundColor Cyan
        return
    }
}
# ═══════════════════════════════════════════════════════════════════════════════
# GUI MODU — WPF arayüzü başlatılıyor
# ═══════════════════════════════════════════════════════════════════════════════
<#
.SYNOPSIS
    Microsoft Store App Manager 2.0.3 - WPF + CLI Edition

.DESCRIPTION
    [TR]
    PowerShell tabanlı, WPF/XAML grafik arayüzüne sahip Microsoft Store uygulama yöneticisi.
    Mağaza uygulamalarını ve bağımlılıklarını (Appx, Msix, Bundle) doğrudan Microsoft Store
    sunucularından indirir, yönetir ve kurar. RunspacePool ile asenkron çalışır.
    Karanlık/Aydınlık tema, Türkçe/İngilizce dil desteği ve tam CLI otomasyon desteği içerir.

    [EN]
    A PowerShell-based Microsoft Store package manager with WPF/XAML GUI and full CLI support.
    Fetches, downloads, manages and installs Store apps and dependencies (Appx, Msix, Bundle)
    directly from Microsoft Store servers. Supports all release rings, architectures,
    Dark/Light themes, TR/EN localization, and headless automation via command-line parameters.

.PARAMETER Fetch
    [TR] Otomatik olarak getirilecek paketin PFN, URL veya Product ID degeri.
         GUI modunda Fetch sekmesini doldurur ve otomatik getirir.
         Konsol modunda (-Download veya -Install ile) dogrudan indirir/kurar.
    [EN] Package Family Name, Store URL or Product ID to fetch on launch.
         In GUI mode: fills Fetch tab and triggers fetch automatically.
         In console mode (with -Download or -Install): downloads/installs directly.

    Gecerli formatlar / Valid formats:
      Microsoft.WindowsNotepad_8wekyb3d8bbwe   (PFN)
      https://apps.microsoft.com/detail/9MSMLRH6LZF3  (Store URL)
      9MSMLRH6LZF3                              (Product ID)

.PARAMETER Ring
    [TR] Kullanilacak Store yayin kanali.
    [EN] Store release ring to use.

    Degerler / Values:
      Retail   - Kararlı sürümler (varsayılan / default)
      RP       - Release Preview
      WIS      - Windows Insider Slow
      WIF      - Windows Insider Fast
      Slow     - Alternatif yavaş kanal
      Fast     - Alternatif hızlı kanal

.PARAMETER Arch
    [TR] Hedef mimari. Belirtilmezse x64 kullanilir.
    [EN] Target architecture. Defaults to x64 if not specified.

    Degerler / Values: x64, x86, arm64, arm, neutral

.PARAMETER Download
    [TR] -Fetch ile birlikte kullanilir. Paket getirildikten sonra otomatik indirir.
         Konsol modunu etkinlestirir (GUI acilmaz).
    [EN] Used with -Fetch. Automatically downloads after fetch completes.
         Enables console mode (no GUI).

.PARAMETER Install
    [TR] -Fetch ile birlikte kullanilir. Paket getirildikten sonra indirir ve kurar.
         Konsol modunu etkinlestirir (GUI acilmaz).
    [EN] Used with -Fetch. Downloads and installs after fetch completes.
         Enables console mode (no GUI).

.PARAMETER Update
    [TR] Tum yuklu Store uygulamalarini tarar, guncelleme olanlari listeler,
         onay alinarak indirir ve kurar. Konsol modunu etkinlestirir.
    [EN] Scans all installed Store apps, lists available updates,
         prompts for confirmation, then downloads and installs. Console mode.

.PARAMETER List
    [TR] Yuklu tum Store uygulamalarini (ad, surum, mimari) konsola listeler.
    [EN] Lists all installed Store applications (name, version, architecture) to console.

.PARAMETER NoGUI
    [TR] GUI acmadan bu yardim mesajini gosterir.
    [EN] Shows this help message without opening the GUI.

.EXAMPLE
    # GUI'yi normal ac / Open GUI normally
    .\Microsoft_Store_App_Manager.cmd

.EXAMPLE
    # Yuklu uygulamalari listele / List installed apps
    .\Microsoft_Store_App_Manager.cmd -List

.EXAMPLE
    # Guncelleme kontrolu yap (Retail) / Check for updates (Retail)
    .\Microsoft_Store_App_Manager.cmd -Update

.EXAMPLE
    # RP kanalinda guncelleme kontrolu / Check updates on Release Preview
    .\Microsoft_Store_App_Manager.cmd -Update -Ring RP

.EXAMPLE
    # WIF kanalinda guncelleme kontrolu / Check updates on Windows Insider Fast
    .\Microsoft_Store_App_Manager.cmd -Update -Ring WIF

.EXAMPLE
    # Notepad'i getir (GUI Fetch sekmesi) / Fetch Notepad in GUI
    .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.WindowsNotepad_8wekyb3d8bbwe

.EXAMPLE
    # Notepad'i RP kanalinden getir (GUI) / Fetch Notepad from RP in GUI
    .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.WindowsNotepad_8wekyb3d8bbwe -Ring RP

.EXAMPLE
    # ScreenSketch'i indir (konsol) / Download ScreenSketch (console)
    .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.ScreenSketch_8wekyb3d8bbwe -Download

.EXAMPLE
    # ScreenSketch'i WIF kanalinden indir ve kur / Download+install from WIF
    .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.ScreenSketch_8wekyb3d8bbwe -Install -Ring WIF

.EXAMPLE
    # Windows Terminal'i WIF kanalinden arm64 olarak indir
    .\Microsoft_Store_App_Manager.cmd -Fetch Microsoft.WindowsTerminal_8wekyb3d8bbwe -Ring WIF -Arch arm64 -Download

.EXAMPLE
    # Store URL ile getir ve indir / Fetch by Store URL and download
    .\Microsoft_Store_App_Manager.cmd -Fetch https://apps.microsoft.com/detail/9N0DX20HK701 -Download

.EXAMPLE
    # Yardim mesajini goster / Show help
    .\Microsoft_Store_App_Manager.cmd -NoGUI

.NOTES
    Version      : 2.0.3
    Runtime      : PowerShell 5.1+
    UI Framework : WPF (Windows Presentation Foundation) / XAML
    Launch       : CMD/PowerShell hybrid — cift tikla veya Yonetici olarak calistir
    Source       : rg-adguard.net API (store.rg-adguard.net)

    Ozellikler / Features:
      - GUI: WPF karanlik/aydinlik tema, TR/EN dil destegi
      - CLI: -List, -Update, -Fetch, -Download, -Install, -NoGUI parametreleri
      - Tum kanallar: Retail, RP, WIS, WIF, Slow, Fast
      - Tum mimariler: x64, x86, arm64, arm, neutral
      - Paralel indirme (RunspacePool), gercek zamanli progress bar
      - Otomatik bagimlilik cozumleme
      - Ayarlardan indirme dizini okuma
#>

# ── DPI Ayarı / DPI Awareness ───────────────────────────────────────
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
}
'@ -ErrorAction SilentlyContinue
try { [void][DpiHelper]::SetProcessDpiAwareness(2) } catch { try { [void][DpiHelper]::SetProcessDPIAware() } catch {} }

# ── WPF Bileşenleri / WPF Assemblies ────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

# ── Tek Örnek Kontrolü / Single Instance Check ────────────────────
$script:SingleInstanceMutexName = 'StoreAppManager_SingleInstance_v1'
$script:SingleInstanceMutex = New-Object System.Threading.Mutex($false, $script:SingleInstanceMutexName)
$mutexAcquired = $false
try {
    $mutexAcquired = $script:SingleInstanceMutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $mutexAcquired = $true
}

if (-not $mutexAcquired) {
    # Mevcut pencereyi öne getir / Bring existing window to front
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public class WinActivator {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;

    public static IntPtr FindWindowByTitle(string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, sb.Capacity);
            if (sb.ToString().Contains(titlePart)) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void ActivateWindow(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return;
        if (IsIconic(hWnd)) {
            ShowWindow(hWnd, SW_RESTORE);
        } else {
            ShowWindow(hWnd, SW_SHOW);
        }
        SetForegroundWindow(hWnd);
    }
}
'@ -ErrorAction SilentlyContinue

    try {
        $existing = [WinActivator]::FindWindowByTitle('Microsoft Store App Manager')
        if ($existing -ne [IntPtr]::Zero) {
            [WinActivator]::ActivateWindow($existing)
        }
    } catch {}


    try { $script:SingleInstanceMutex.Close() } catch {}
    return
}

# Çıkışta mutex'i serbest bırak / Release mutex on exit
$script:OnExitScript = {
    try {
        if ($script:SingleInstanceMutex) {
            $script:SingleInstanceMutex.ReleaseMutex()
            $script:SingleInstanceMutex.Dispose()
        }
    } catch {}
}
Register-EngineEvent PowerShell.Exiting -Action $script:OnExitScript | Out-Null

# ── Ayarlar / Settings ──────────────────────────────────────────────
$script:Lang = 'EN'
$script:SettingsFile = Join-Path $env:APPDATA 'StoreAppManager\settings.json'
$script:SettingsLogFile = Join-Path $env:LOCALAPPDATA 'StoreAppManager\settings.log'

# Tanılama log fonksiyonu / Diagnostic log helper
function Write-SettingsLog {
    param([string]$Message)
    try {
        $logDir = Split-Path $script:SettingsLogFile
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $line = "[{0:yyyy-MM-dd HH:mm:ss.fff}] {1}" -f (Get-Date), $Message
        Add-Content -Path $script:SettingsLogFile -Value $line -Encoding UTF8
    } catch {}
}

# Yardımcı: ComboBoxItem.Content'ten güvenli string çıkar
# Helper: Safely extract string from ComboBoxItem.Content (handles edge cases)
function Get-ComboContentString {
    param($Item)
    if ($null -eq $Item) { return $null }
    try {
        $content = $Item.Content
        if ($null -eq $content) { return $null }
        if ($content -is [string]) { return $content.Trim() }
        # WPF ComboBoxItem'in Content'i string olmayabilir — ToString'i dene
        $s = "$content".Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        return $s
    } catch { return $null }
}

function Import-AppSettings {
    $defaults = @{
        DownloadFolder = Join-Path $env:USERPROFILE 'Downloads\StorePackages'
        Lang           = 'EN'
        Theme          = 'Dark'
        DefaultArch    = 'x64'
        DefaultRing    = 'Retail'
        ForceReinstall = $false
        DeleteAfterInstall = $false
        BackgroundOverlay = 'None'
        WingetIgnoredUpdates = @()   # Guncelleme gizlenen paket ID listesi
        InstalledIgnoredApps = @()   # Installed Apps sekmesinde gizlenen PFN listesi
    }

    Write-SettingsLog "Import-AppSettings BAŞLADI. SettingsFile: $script:SettingsFile"

    if (-not (Test-Path $script:SettingsFile)) {
        Write-SettingsLog "Ayar dosyası YOK — varsayılanlar kullanılıyor."
        return $defaults
    }

    try {
        $raw = Get-Content $script:SettingsFile -Raw -Encoding UTF8
        Write-SettingsLog "Dosya okundu, boyut=$($raw.Length) bayt. İçerik: $raw"

        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-SettingsLog "Dosya BOŞ — varsayılanlar kullanılıyor."
            return $defaults
        }

        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        Write-SettingsLog "JSON parse OK. Tip: $($json.GetType().FullName)"

        # Migration check: WaveOverlay (bool) -> BackgroundOverlay (string)
        if ($json.PSObject.Properties['WaveOverlay'] -and -not $json.PSObject.Properties['BackgroundOverlay']) {
            $wo = $json.WaveOverlay
            if ($wo -is [bool] -and $wo) { $defaults.BackgroundOverlay = 'Wave' }
            elseif ($wo -is [string] -and ($wo -eq 'True' -or $wo -eq '1')) { $defaults.BackgroundOverlay = 'Wave' }
        }

        # PSCustomObject olarak gelen JSON'u hashtable'a dök
        $jsonProps = @{}
        foreach ($p in $json.PSObject.Properties) {
            $jsonProps[$p.Name] = $p.Value
        }
        Write-SettingsLog "JSON anahtarları: $($jsonProps.Keys -join ', ')"

        # Her anahtarı sağlam şekilde uygula / Apply each key robustly
        foreach ($key in @($defaults.Keys)) {
            if (-not $jsonProps.ContainsKey($key)) {
                Write-SettingsLog "  $key -> JSON'da yok, varsayılan kalır: '$($defaults[$key])'"
                continue
            }

            $val = $jsonProps[$key]

            if ($defaults[$key] -is [bool]) {
                # Boolean alanlar / Boolean fields
                if ($val -is [bool]) {
                    $defaults[$key] = $val
                } elseif ($val -is [string]) {
                    $defaults[$key] = ($val -eq 'True' -or $val -eq 'true' -or $val -eq '1')
                } elseif ($val -is [int]) {
                    $defaults[$key] = ($val -ne 0)
                }
                Write-SettingsLog "  $key (bool) -> '$($defaults[$key])'"
            } else {
                # String alanlar — güvenli cast / String fields - safe cast
                if ($null -eq $val) {
                    Write-SettingsLog "  $key -> null, varsayılan kalır"
                    continue
                }
                $strVal = "$val".Trim()
                if ([string]::IsNullOrWhiteSpace($strVal)) {
                    Write-SettingsLog "  $key -> boş, varsayılan kalır"
                    continue
                }
                $defaults[$key] = $strVal
                Write-SettingsLog "  $key -> '$strVal'"
            }
        }

        Write-SettingsLog "Import-AppSettings BAŞARILI. Sonuç: Lang=$($defaults.Lang), Theme=$($defaults.Theme), DefaultArch=$($defaults.DefaultArch), DefaultRing=$($defaults.DefaultRing), ForceReinstall=$($defaults.ForceReinstall)"

        # WingetIgnoredUpdates: array alan — normal key loop'u array'i desteklemiyor
        if ($jsonProps.ContainsKey('WingetIgnoredUpdates')) {
            $raw = $jsonProps['WingetIgnoredUpdates']
            if ($raw -is [System.Array]) { $defaults['WingetIgnoredUpdates'] = @($raw | ForEach-Object { "$_" }) }
            elseif ($raw -is [string] -and $raw) { $defaults['WingetIgnoredUpdates'] = @($raw) }
        }
        # InstalledIgnoredApps: array alan
        if ($jsonProps.ContainsKey('InstalledIgnoredApps')) {
            $raw = $jsonProps['InstalledIgnoredApps']
            if ($raw -is [System.Array]) { $defaults['InstalledIgnoredApps'] = @($raw | ForEach-Object { "$_" }) }
            elseif ($raw -is [string] -and $raw) { $defaults['InstalledIgnoredApps'] = @($raw) }
        }
    } catch {
        Write-SettingsLog "HATA: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    }

    return $defaults
}

function Save-AppSettings {
    # Açılış sırasında çağrıları yoksay — combo/event başlatma kazara üzerine yazmasın
    # Ignore calls during init to prevent combo/event setup from overwriting saved values
    if ($script:InitInProgress) {
        Write-SettingsLog "Save-AppSettings ATLANDI (InitInProgress=true)"
        return
    }
    try {
        $dir = Split-Path $script:SettingsFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # Tüm değerleri SAĞLAM string'e çevir / Coerce ALL values to clean strings

        # DownloadFolder
        $dlFolder = if ($script:DownloadFolder) { "$($script:DownloadFolder)" } else { Join-Path $env:USERPROFILE 'Downloads\StorePackages' }

        # Lang
        $langVal = if ($script:Lang -in @('EN','TR')) { "$($script:Lang)" } else { 'EN' }

        # Theme
        $allThemes = @('Dark','Light','iTunes','Intel','Dracula','Nord','Solarized Dark','Solarized Light','Monokai','Synthwave','Cyberpunk','Gruvbox','Tokyo Night','Catppuccin','GitHub Dark')
        $themeVal = if ($script:CurrentTheme -in $allThemes) { "$($script:CurrentTheme)" } else { 'Dark' }

        # DefaultArch — önce $script:AppSettings'ten, yoksa GUI'den / From settings then GUI
        $archVal = $null
        if ($script:AppSettings -and $script:AppSettings.DefaultArch) {
            $archVal = "$($script:AppSettings.DefaultArch)".Trim()
        }
        if ([string]::IsNullOrWhiteSpace($archVal) -and $cmbArch -and $cmbArch.SelectedItem) {
            $archVal = Get-ComboContentString $cmbArch.SelectedItem
        }
        if ([string]::IsNullOrWhiteSpace($archVal)) { $archVal = 'x64' }

        # DefaultRing — önce $script:AppSettings'ten, yoksa GUI'den / From settings then GUI
        $ringVal = $null
        if ($script:AppSettings -and $script:AppSettings.DefaultRing) {
            $ringVal = "$($script:AppSettings.DefaultRing)".Trim()
        }
        if ([string]::IsNullOrWhiteSpace($ringVal) -and $cmbRing -and $cmbRing.SelectedItem) {
            $ringVal = Get-ComboContentString $cmbRing.SelectedItem
        }
        if ([string]::IsNullOrWhiteSpace($ringVal)) { $ringVal = 'Retail' }

        # ForceReinstall
        $forceVal = $false
        if ($script:AppSettings -and $null -ne $script:AppSettings.ForceReinstall) {
            $forceVal = [bool]$script:AppSettings.ForceReinstall
        }

        # DeleteAfterInstall
        $deleteVal = $false
        if ($script:AppSettings -and $null -ne $script:AppSettings.DeleteAfterInstall) {
            $deleteVal = [bool]$script:AppSettings.DeleteAfterInstall
        }

        # BackgroundOverlay
        $overlayVal = 'None'
        if ($cmbSettingsOverlay -and $cmbSettingsOverlay.SelectedItem) {
            $overlayVal = Get-ComboContentString $cmbSettingsOverlay.SelectedItem
        }
        elseif ($script:AppSettings -and $script:AppSettings.BackgroundOverlay) {
            $overlayVal = $script:AppSettings.BackgroundOverlay
        }

        # Düzgün sıralı bir nesne kur — Order korunsun / Build ordered object
        $obj = [pscustomobject][ordered]@{
            DownloadFolder = $dlFolder
            Lang           = $langVal
            Theme          = $themeVal
            DefaultArch    = $archVal
            DefaultRing    = $ringVal
            ForceReinstall = $forceVal
            DeleteAfterInstall = $deleteVal
            BackgroundOverlay = $overlayVal
            WingetIgnoredUpdates = @(if ($script:AppSettings -and $script:AppSettings.WingetIgnoredUpdates) { $script:AppSettings.WingetIgnoredUpdates } else { @() })
            InstalledIgnoredApps = @(if ($script:AppSettings -and $script:AppSettings.InstalledIgnoredApps) { $script:AppSettings.InstalledIgnoredApps } else { @() })
        }

        $jsonText = $obj | ConvertTo-Json -Depth 5
        Set-Content -Path $script:SettingsFile -Value $jsonText -Encoding UTF8 -Force

        Write-SettingsLog "Save-AppSettings YAZDI -> Lang=$langVal, Theme=$themeVal, DefaultArch=$archVal, DefaultRing=$ringVal, ForceReinstall=$forceVal, BackgroundOverlay=$overlayVal"

        # Yazımdan sonra geri okuyup doğrula / Verify by reading back
        try {
            $verify = Get-Content $script:SettingsFile -Raw -Encoding UTF8
            Write-SettingsLog "Doğrulama (geri okundu): $verify"
        } catch {
            Write-SettingsLog "Doğrulama HATA: $($_.Exception.Message)"
        }
    } catch {
        Write-SettingsLog "Save-AppSettings HATA: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    }
}

# ── Yardımcı: Tüm Ring ComboBox'larını senkronize et ────────────────
# Helper: Sync all Ring ComboBoxes across pages (Fetch / Installed / Settings)
$script:SyncingRing = $false
function Sync-RingSelection {
    param([string]$RingLabel)
    if ($script:SyncingRing) { return }
    if ([string]::IsNullOrWhiteSpace($RingLabel)) { return }
    $script:SyncingRing = $true
    try {
        $ringIdx = @('Retail','Preview','WIS','WIF','Slow','Fast').IndexOf($RingLabel)
        if ($ringIdx -lt 0) {
            Write-SettingsLog "Sync-RingSelection: Geçersiz değer '$RingLabel' — yoksayıldı"
            return
        }

        if ($cmbRing -and $cmbRing.SelectedIndex -ne $ringIdx) {
            $cmbRing.SelectedIndex = $ringIdx
        }
        if ($cmbInstalledRing -and $cmbInstalledRing.SelectedIndex -ne $ringIdx) {
            $cmbInstalledRing.SelectedIndex = $ringIdx
        }
        if ($cmbSettingsRing -and $cmbSettingsRing.SelectedIndex -ne $ringIdx) {
            $cmbSettingsRing.SelectedIndex = $ringIdx
        }
        # Ayara yaz ve kalıcı kaydet / Persist to settings
        $script:AppSettings.DefaultRing = $RingLabel
        Write-SettingsLog "Sync-RingSelection: '$RingLabel' uygulandı, kayıt çağrılıyor..."
        Save-AppSettings
    } finally {
        $script:SyncingRing = $false
    }
}

# ── Yardımcı: Tüm Arch ComboBox'larını senkronize et ────────────────
# Helper: Sync all Arch ComboBoxes (Fetch / Settings)
$script:SyncingArch = $false
function Sync-ArchSelection {
    param([string]$ArchLabel)
    if ($script:SyncingArch) { return }
    if ([string]::IsNullOrWhiteSpace($ArchLabel)) { return }
    $script:SyncingArch = $true
    try {
        $archIdx = @('x64','x86','ARM64','ARM').IndexOf($ArchLabel)
        if ($archIdx -lt 0) {
            Write-SettingsLog "Sync-ArchSelection: Geçersiz değer '$ArchLabel' — yoksayıldı"
            return
        }

        if ($cmbArch -and $cmbArch.SelectedIndex -ne $archIdx) {
            $cmbArch.SelectedIndex = $archIdx
        }
        if ($cmbSettingsArch -and $cmbSettingsArch.SelectedIndex -ne $archIdx) {
            $cmbSettingsArch.SelectedIndex = $archIdx
        }
        # Ayara yaz ve kalıcı kaydet / Persist to settings
        $script:AppSettings.DefaultArch = $ArchLabel
        Write-SettingsLog "Sync-ArchSelection: '$ArchLabel' uygulandı, kayıt çağrılıyor..."
        Save-AppSettings
    } finally {
        $script:SyncingArch = $false
    }
}

# Ayarları yükle / Load settings
$script:AppSettings = Import-AppSettings
$script:Lang           = $script:AppSettings.Lang
$script:DownloadFolder = $script:AppSettings.DownloadFolder
if (-not (Test-Path $script:DownloadFolder)) {
    New-Item -ItemType Directory -Path $script:DownloadFolder -Force | Out-Null
}

# AÇILIŞ KORUYUCU FLAG: Açılış tamamlanana kadar Save-AppSettings'i blokla
# STARTUP GUARD: Block Save-AppSettings until init is complete
$script:InitInProgress = $true
Write-SettingsLog "InitInProgress=true ayarlandı — açılış boyunca Save-AppSettings çağrıları yoksayılacak"

# Harici iş mantığı (varsayılan kapalı) / External business logic (disabled by default)
$UseOriginalBusinessLogic = $false
if ($UseOriginalBusinessLogic) {
    # PSScriptRoot boşsa (Invoke-Expression ile çalıştırıldığında) PWD'den türet
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    $OriginalScriptPath = Join-Path $root 'Microsoft_Store_App_Manager.PS1'
    if (Test-Path $OriginalScriptPath) { . $OriginalScriptPath }
}

# ── Dil Sözlüğü / Localization Strings ──────────────────────────────
$script:Strings = @{
    EN = @{
        AppTitle       = 'Microsoft Store App Manager 2.0.3'
        NavFetch       = 'Fetch Packages'
        NavInstalled   = 'Installed Apps'
        NavDownloads   = 'Downloads'
        NavSettings    = 'Settings'
        NavHistory     = 'History'
        NavWinget      = 'Winget'
        PageFetch      = 'Query Store Packages'
        PageFetchSub   = 'Paste a Microsoft Store URL, Product ID or Package Family Name'
        PageInstalled  = 'Installed Apps'
        PageInstSub    = 'Locally installed MSIX / APPX packages'
        PageDownloads  = 'Downloads'
        PageDlSub      = 'Previously downloaded package files'
        PageSettings   = 'Settings'
        PageSetSub     = 'Application preferences and defaults'
        PageHistory    = 'History'
        PageHistSub    = 'Recent fetch and install history'
        LblUrl         = 'Microsoft Store URL or Product ID (optional)'
        LblFieldPackage = 'Package Name / Product ID'
        LblFieldArch    = 'Architecture'
        LblFieldRing    = 'Release Ring'
        BtnFetch       = 'Fetch'
        BtnSelectAll   = 'Select All'
        BtnDeselectAll = 'Deselect All'
        BtnDownloadAll = 'Download All'
        BtnBrowse      = 'Import Local Files'
        BtnReset       = 'Reset'
        BtnDownload    = 'Download Selected'
        BtnInstall     = 'Install Apps'
        BtnOpenFolder  = 'Open Download Folder'
        StatusReady    = 'Ready'
        StatusFetch    = 'Fetching package information...'
        StatusNoUrl    = 'Please enter a URL or Product ID.'
        BtnLang        = 'TR'
        LblConn        = 'Connected'
        # Yüklü Uygulamalar sekmesi / Installed Apps tab
        BtnUninstallSelected = 'Uninstall Selected'
        BtnUpdateSelected    = 'Update Selected'
        BtnRescan            = 'Rescan'
        BtnExportList        = 'Export List'
        ExportDialogTitle    = 'Export Installed Apps List'
        ExportFilterCsv      = 'CSV Files (*.csv)|*.csv'
        ExportFilterJson     = 'JSON Files (*.json)|*.json'
        ExportSuccess        = 'Exported {0} apps to: {1}'
        ExportError          = 'Export failed: {0}'
        ExportNoData         = 'No app data to export. Run a scan first.'
        ChkSelectAllInst     = 'Select All'
        ChkShowSystemApps    = 'Show system apps'
        LblRing              = 'Ring:'
        LblInstall           = 'Install:'
        RadAllUsers          = 'All Users'
        RadCurrentUser       = 'Current User'
        ColApplication       = 'Application'
        ColInstalled         = 'Installed Version'
        ColStore             = 'Store Version'
        ColStatus            = 'Status'
        ColVersion           = 'Version'
        ColSize              = 'Size'
        ColPackage           = 'Package'
        # Bağlam Menüleri / Context Menus
        CtxCopyName          = 'Copy File Name'
        CtxCopyVersion       = 'Copy Version'
        CtxCopyUrl           = 'Copy Download URL'
        CtxCopyStoreId       = 'Copy Store ID'
        CtxSelectVer         = 'Select Version...'
        CtxFileInfo          = 'File Information...'
        CtxOpenUrl           = 'Open URL in Browser'
        CtxOpenStore         = 'Open in Microsoft Store'
        CtxOpenFolder        = 'Open Download Folder'
        CtxRetryDl           = 'Retry Download'
        CtxToggle            = 'Select / Deselect'
        CtxInstUninstall     = 'Uninstall Application'
        CtxInstCopyPfn       = 'Copy PackageFamilyName'
        CtxInstCopyName      = 'Copy Name'
        CtxInstCopyVer       = 'Copy Installed Version'
        CtxInstOpenStore     = 'Open in Microsoft Store'
        CtxInstOpenFolder    = 'Open Install Folder'
        # Durum rozetleri / Status badges
        BadgeLatest          = 'LATEST'
        BadgeDep             = 'DEP'
        BadgeOlder           = 'DEPRECATED'
        BadgeUpToDate        = 'UP TO DATE'
        BadgeUpdateAvailable = 'UPDATE AVAILABLE'
        BadgeAhead           = 'AHEAD'
        BadgeChecking        = 'CHECKING'
        BadgeSystem          = 'SYSTEM'
        BadgeNA              = 'N/A'
        BadgeUnknown         = 'UNKNOWN'
        BadgeReady           = 'READY'
        BadgeQueued          = 'QUEUED'
        BadgeExists          = 'EXISTS'
        BadgeComplete        = 'COMPLETE'
        BadgeSideload        = 'SIDELOAD'
        # Durum çubuğu / Status bar
        StatusAppsFound      = '{0} apps found'
        StatusUpdatesAvail   = '{0} update(s) available'
        StatusFetching       = '[{0}/{1}] Fetching Store versions...'
        StatusDoneSummary    = 'Done ({0} up-to-date, {1} updates, {2} N/A)'
        StatusCheckComplete  = 'Store version check complete. {0} update(s) available.'
        StatusInstFound      = '{0} installed app(s) found - fetching Store versions...'
        StatusScanning       = 'Scanning...'
        # Ayarlar sekmesi / Settings tab
        SetGeneral           = 'GENERAL'
        SetDownloads         = 'DOWNLOADS'
        SetInstall           = 'INSTALLATION'
        SetAbout             = 'ABOUT'
        SetLangLabel         = 'Language'
        SetLangSub           = 'UI display language'
        SetThemeLabel        = 'Theme'
        SetThemeSub          = 'Select from 15 different themes'
        SetWaveLabel         = 'Wave Overlay'
        SetWaveSub           = 'Concentric wave background effect'
        SetDlFolderLabel     = 'Default Download Folder'
        SetArchLabel         = 'Architecture'
        SetArchSub           = 'Default package architecture'
        SetRingLabel         = 'Default Ring'
        SetRingSub           = 'Store release ring'
        SetForceReinstallLabel = 'Force Reinstall'
        SetForceReinstallSub   = 'Remove existing version before installing (always reinstall)'
        SetDeleteAfterInstallLabel = 'Delete After Install'
        SetDeleteAfterInstallSub   = 'Delete the downloaded package file after successful installation'
        SetApplyBtn          = 'Apply Settings'
        SetRuntimeLabel      = 'RUNTIME'
        SetTargetOSLabel     = 'TARGET OS'
        # İletişim kutusu düğmeleri / Dialog buttons
        DlgOK                = 'OK'
        DlgCancel            = 'Cancel'
        DlgYes               = 'Yes'
        DlgNo                = 'No'
        BtnChangeDlFolder    = 'Change'
        # İndirilenler sekmesi / Downloads tab
        DlOverallProgress    = 'OVERALL PROGRESS'
        DlSpeed              = 'SPEED'
        DlETA                = 'ETA'
        DlQueued             = 'QUEUED'
        DlInstallerLog       = 'INSTALLER LOG'
        DlNoActivity         = 'No activity yet.'
        # Geçmiş sekmesi sütunları / History tab columns
        ColTime              = 'Time'
        ColResult            = 'Result'
        # Diğer / Misc
        BtnCancel            = '✕ Cancel'
        BtnCancelDownload    = 'Cancel Download'
        BtnCancelling        = 'Cancelling...'
        PhUrl                = 'Paste Store URL, Product ID (e.g. 9NBLGGH4NNS1) or PackageFamilyName (e.g. Microsoft.Paint_8wekyb3d8bbwe)'
        PhInstSearch         = '🔍  Filter installed apps...'
        HistoryEmpty         = 'No history yet. Installed or downloaded packages will appear here.'
        DlEmpty              = 'No downloaded packages found. Fetch and download packages from the Fetch Packages tab.'
        StatusUpdateQueue    = 'Update {0}/{1}: fetching {2}...'
        StatusUpdateQueueDone = 'Update queue complete: {0}/{1} updated successfully'
        StatusUpdateQueueFinished = 'Update queue finished.'
        StatusUpdateQueueProcessed = 'Successfully updated: {0} of {1}'
        UpdateQueueTitle     = 'Updates complete'
        UpdateQueueConfirmMsg = 'Queue {0} app(s) for update via the Fetch tab?'
        UpdateQueueConfirmSub = 'Each app will be fetched, downloaded and installed in sequence.'
        UpdateQueueDetail    = '- {0} ({1} -> {2})'
        UpdateQueueTitle2    = 'Update Selected'
        NoSelectionTitle     = 'No selection'
        NoSelectionMsg       = 'No apps selected. Check the boxes next to apps marked "{0}" first.'
        NoSelectionUninstall = 'No apps selected. Check the boxes next to apps you want to remove first.'
        AdminTitle           = 'Admin privileges recommended'
        AdminMsgUpdate       = "Removing for ALL users requires Administrator.

Without admin rights only current-user install will be removed."
        AdminContinue        = 'Continue anyway?'
        AdminMsgInstall      = "Installation works best when running as Administrator.

Without admin rights only 'current user' installation will work."
        UninstallTitle       = 'Uninstall Application'
        UninstallMsg         = "'{0}' will be completely removed from your computer."
        UninstallPFN         = 'PackageFamilyName: {0}'
        UninstallSelectedTitle = 'Uninstall Selected'
        UninstallSelectedMsg = 'Uninstall {0} app(s)? This action cannot be undone.'
        UninstallResultTitle = 'Uninstall Result'
        UninstallResultMsg   = 'Uninstall complete.'
        UninstallSuccess     = 'Succeeded: {0}'
        UninstallFailed      = 'Failed: {0}'
        InstallResultTitle   = 'Install Result'
        InstallResultSuccess = 'Successfully installed {0} package(s).'
        InstallResultIssues  = 'Installation completed with issues.'
        InstallResultDetails = "Succeeded: {0}
Failed: {1}

Check the list for details."
        MissingDepsTitle     = 'Missing Dependencies'
        MissingDepsMsg       = "Package '{0}' requires missing dependencies. Install anyway?"
        NoPackagesTitle      = 'No packages'
        NoPackagesMsg        = 'No installable packages found.'
        NoPackagesDetails    = "Looked for .appx / .msix / .appxbundle / .msixbundle / .exe / .msi in:
{0}"
        FileInfoTitle        = 'File Information'
        FileInfoMsg          = 'Package details:'
        SelectVerMsg         = 'Select Version dialog - plug in original logic.'
        DlFolderNotFound     = 'Download folder not found: {0}'
        BtnRetryFailed       = 'Retry Failed'
        RetryAttempt         = 'Retry {0}/{1}'
        RetryWait            = 'Waiting {0}s...'
        TipFetch             = 'Fetch package list from Microsoft Store (Enter)'
        TipSelectAll         = 'Check all packages in the list'
        TipDeselectAll       = 'Uncheck all packages'
        TipDownloadAll       = 'Select all and start download'
        TipBrowse            = 'Browse for local .appx/.msix package files'
        TipReset             = 'Clear all results and cancel active operations'
        TipDownload          = 'Download checked packages to the download folder'
        TipInstall           = 'Install downloaded packages on this PC'
        TipOpenFolder        = 'Open the download folder in Explorer'
        TipCancel            = 'Cancel the current fetch / download / install operation'
        TipRescan            = 'Re-scan installed apps and refresh Store versions'
        TipUpdateSelected    = 'Update checked apps that have a newer Store version'
        TipUninstallSelected = 'Uninstall checked apps from this PC'
        TipExportList        = 'Export installed app list to CSV or JSON file'
        TipSelectAllInst     = 'Check or uncheck all installed apps'
        TipShowSystem        = 'Include Windows system components in the list'
        TipTheme             = 'Toggle Dark / Light theme'
        TipLang              = 'Switch between English and Turkish'
        TipCmbPackage        = 'Type or select a Package Family Name, Product ID or Store URL'
        TipCmbArch           = 'Select the processor architecture of the package to fetch'
        TipCmbRing           = 'Select the Store release channel (Retail = stable)'
        TipTxtUrl            = 'Paste a Microsoft Store URL or Product ID here'
        TipInstalledSearch   = 'Type to filter the installed apps list by name'
        # Winget sekmesi / Winget tab
        WingetSearchPh       = 'Search installed packages...'
        WingetRefresh        = '⟳ Refresh'
        WingetShowUpdates    = 'Show Updates Only'
        WingetAllUsers       = 'All Users Scope'
        WingetSelectAll      = 'Select All'
        WingetDeselectAll    = 'Deselect All'
        WingetUpdateSel      = '⬆ Update Selected'
        WingetUpgradeAll     = 'Upgrade All'
        WingetChecking       = 'Checking winget...'
        WingetReady          = 'Ready — click Refresh to load packages'
        WingetNotFound       = "winget not found. Install App Installer from the Store."
        WingetNotAvail       = 'winget not available.'
        WingetRunning        = 'Running winget list...'
        WingetLoadingSub     = 'Scanning installed packages — this may take a few seconds'
        WingetError          = 'Error: could not get winget output.'
        WingetLoaded         = '{0} packages loaded'
        WingetLoadedUpd      = '{0} packages loaded — {1} update(s) available'
        WingetNoPackages     = 'No packages loaded — click Refresh first'
        WingetUpdating       = '[{0}/{1}] Updating...'
        WingetInstalling     = 'Installing...'
        WingetDone           = 'Done: {0} succeeded'
        WingetDoneFail       = 'Done: {0} succeeded, {1} failed'
        WingetCount          = '{0} / {1} packages ({2} selected)'
        WingetCountUpd       = '{0} / {1} packages ({2} selected) — {3} update(s)'
        WingetTipRefresh     = 'Reload installed packages from winget'
        WingetTipShowUpd     = 'Show only packages that have an available update'
        WingetTipAllUsers    = 'Apply operations to all users (requires admin)'
        WingetTipSelectAll   = 'Select all visible packages'
        WingetTipDeselectAll = 'Deselect all packages'
        WingetTipUpdateSel   = 'Upgrade selected packages'
        WingetTipUpgradeAll  = 'Upgrade all packages that have an available update'
        PageWingetSub        = 'winget search & install'
        WingetBadgeUpdate    = '↑ Update Available'
        WingetBadgeDone      = 'Updated ✓'
        WingetBadgeUpToDate  = '✓ Up to Date'
        WingetHideUpdate     = 'Hide Update'
        WingetShowUpdate     = 'Show Update Again'
        WingetBadgeHidden    = '— Hidden'
        InstHideApp          = 'Hide App'
    }
    TR = @{
        AppTitle       = 'Microsoft Store Uygulama Yöneticisi 2.0.3'
        NavFetch       = 'Uygulama İndir'
        NavInstalled   = 'Yüklü Uygulamalar'
        NavDownloads   = 'İndirilenler'
        NavSettings    = 'Ayarlar'
        NavHistory     = 'Geçmiş'
        NavWinget      = 'Winget'
        PageFetch      = 'Store Paketlerini Getir'
        PageFetchSub   = 'Microsoft Store URL, Ürün Kimliği veya Paket Aile Adı yapıştırın'
        PageInstalled  = 'Yüklü Uygulamalar'
        PageInstSub    = 'Yerel olarak yüklü MSIX / APPX paketleri'
        PageDownloads  = 'İndirilenler'
        PageDlSub      = 'Daha önce indirilen paket dosyaları'
        PageSettings   = 'Ayarlar'
        PageSetSub     = 'Uygulama tercihleri ve varsayılanlar'
        PageHistory    = 'Geçmiş'
        PageHistSub    = 'Son paket getirme ve yükleme geçmişi'
        LblUrl         = 'Microsoft Store bağlantısı veya Ürün Kimliği (isteğe bağlı)'
        LblFieldPackage = 'Paket Adı / Ürün Kimliği'
        LblFieldArch    = 'Mimari'
        LblFieldRing    = 'Yayın Kanalı'
        BtnFetch       = 'Getir'
        BtnSelectAll   = 'Tümünü Seç'
        BtnDeselectAll = 'Seçimi Kaldır'
        BtnDownloadAll = 'Tümünü İndir'
        BtnBrowse      = 'Paketlere Gözat'
        BtnReset       = 'Sıfırla'
        BtnDownload    = 'Seçileni İndir'
        BtnInstall     = 'Uygulamaları Kur'
        BtnOpenFolder  = 'İndirme Klasörünü Aç'
        StatusReady    = 'Hazır'
        StatusFetch    = 'Paket bilgileri alınıyor...'
        StatusNoUrl    = 'Lütfen geçerli bir bağlantı veya kimlik girin.'
        BtnLang        = 'EN'
        LblConn        = 'Bağlı'
        # Yüklü Uygulamalar sekmesi / Installed Apps tab
        BtnUninstallSelected = 'Seçileni Kaldır'
        BtnUpdateSelected    = 'Seçileni Güncelle'
        BtnRescan            = 'Yeniden Tara'
        BtnExportList        = 'Listeyi Dışa Aktar'
        ExportDialogTitle    = 'Yüklü Uygulamalar Listesini Dışa Aktar'
        ExportFilterCsv      = 'CSV Dosyaları (*.csv)|*.csv'
        ExportFilterJson     = 'JSON Dosyaları (*.json)|*.json'
        ExportSuccess        = '{0} uygulama dışa aktarıldı: {1}'
        ExportError          = 'Dışa aktarma başarısız: {0}'
        ExportNoData         = 'Dışa aktarılacak veri yok. Önce tarama yapın.'
        ChkSelectAllInst     = 'Tümünü Seç'
        ChkShowSystemApps    = 'Sistem uygulamalarını göster'
        LblRing              = 'Kanal:'
        LblInstall           = 'Kurulum:'
        RadAllUsers          = 'Tüm Kullanıcılar'
        RadCurrentUser       = 'Mevcut Kullanıcı'
        ColApplication       = 'Uygulama'
        ColInstalled         = 'Yüklenen Sürüm'
        ColStore             = 'Mağaza Sürümü'
        ColStatus            = 'Durum'
        ColVersion           = 'Sürüm'
        ColSize              = 'Boyut'
        ColPackage           = 'Paket'
        # Bağlam Menüleri / Context Menus
        CtxCopyName          = 'Dosya Adını Kopyala'
        CtxCopyVersion       = 'Sürüm Bilgisini Kopyala'
        CtxCopyUrl           = 'İndirme Bağlantısını Kopyala'
        CtxCopyStoreId       = 'Mağaza Kimliğini Kopyala'
        CtxSelectVer         = 'Sürüm Seç...'
        CtxFileInfo          = 'Dosya Ayrıntıları...'
        CtxOpenUrl           = 'Tarayıcıda Aç'
        CtxOpenStore         = 'Microsoft Store Uygulamasında Aç'
        CtxOpenFolder        = 'İndirme Klasörünü Aç'
        CtxRetryDl           = 'İndirmeyi Tekrarla'
        CtxToggle            = 'Seç / Seçimi Kaldır'
        CtxInstUninstall     = 'Uygulamayı Kaldır'
        CtxInstCopyPfn       = 'Paket Aile Adını (PFN) Kopyala'
        CtxInstCopyName      = 'Uygulama Adını Kopyala'
        CtxInstCopyVer       = 'Yüklenen Sürümü Kopyala'
        CtxInstOpenStore     = 'Microsoft Store Uygulamasında Aç'
        CtxInstOpenFolder    = 'Dosya Konumunu Aç'
        # Durum rozetleri / Status badges
        BadgeLatest          = 'SON SÜRÜM'
        BadgeDep             = 'EK PAKET'
        BadgeOlder           = 'DEPRECATED'
        BadgeUpToDate        = 'GÜNCEL'
        BadgeUpdateAvailable = 'GÜNCELLEME VAR'
        BadgeAhead           = 'İLERİDE'
        BadgeChecking        = 'KONTROL EDİLİYOR'
        BadgeSystem          = 'SİSTEM'
        BadgeNA              = 'YOK'
        BadgeUnknown         = 'BİLİNMİYOR'
        BadgeReady           = 'HAZIR'
        BadgeQueued          = 'KUYRUKTA'
        BadgeExists          = 'MEVCUT'
        BadgeComplete        = 'TAMAMLANDI'
        BadgeSideload        = 'SIDELOAD'
        # Durum çubuğu / Status bar
        StatusAppsFound      = '{0} uygulama bulundu'
        StatusUpdatesAvail   = '{0} güncelleme mevcut'
        StatusFetching       = '[{0}/{1}] Mağaza sürümleri alınıyor...'
        StatusDoneSummary    = 'Tamamlandı ({0} güncel, {1} güncelleme, {2} yok)'
        StatusCheckComplete  = 'Mağaza sürüm kontrolü tamamlandı. {0} güncelleme mevcut.'
        StatusInstFound      = '{0} yüklü uygulama bulundu - Mağaza sürümleri alınıyor...'
        StatusScanning       = 'Taranıyor...'
        # Ayarlar sekmesi / Settings tab
        SetGeneral           = 'GENEL'
        SetDownloads         = 'İNDİRMELER'
        SetInstall           = 'KURULUM'
        SetAbout             = 'HAKKINDA'
        SetLangLabel         = 'Dil'
        SetLangSub           = 'Arayüz dili'
        SetThemeLabel        = 'Tema'
        SetThemeSub          = '15 farklı tema seçeneği'
        SetWaveLabel         = 'Dalga Efekti'
        SetWaveSub           = 'Konsantrik dalga arka plan efekti'
        SetDlFolderLabel     = 'Varsayılan İndirme Klasörü'
        SetArchLabel         = 'Mimari'
        SetArchSub           = 'Varsayılan paket mimarisi'
        SetRingLabel         = 'Varsayılan Kanal'
        SetRingSub           = 'Store yayın kanalı'
        SetForceReinstallLabel = 'Zorla Yeniden Yükle'
        SetForceReinstallSub   = 'Yüklemeden önce mevcut sürümü kaldır (her zaman yeniden yükle)'
        SetDeleteAfterInstallLabel = 'Kurulumdan Sonra Sil'
        SetDeleteAfterInstallSub   = 'Başarılı kurulumdan sonra indirilen paket dosyasını otomatik sil'
        SetApplyBtn          = 'Ayarları Uygula'
        SetRuntimeLabel      = 'ÇALIŞMA ORTAMI'
        SetTargetOSLabel     = 'HEDEF İŞLETİM SİSTEMİ'
        # İletişim kutusu düğmeleri / Dialog buttons
        DlgOK                = 'Tamam'
        DlgCancel            = 'İptal'
        DlgYes               = 'Evet'
        DlgNo                = 'Hayır'
        BtnChangeDlFolder    = 'Değiştir'
        # İndirilenler sekmesi / Downloads tab
        DlOverallProgress    = 'GENEL İLERLEME'
        DlSpeed              = 'HIZ'
        DlETA                = 'KALAN SÜRE'
        DlQueued             = 'KUYRUK'
        DlInstallerLog       = 'KURULUM KAYDI'
        DlNoActivity         = 'Henüz işlem yok.'
        # Geçmiş sekmesi sütunları / History tab columns
        ColTime              = 'Saat'
        ColResult            = 'Sonuç'
        # Diğer / Misc
        BtnCancel            = '✕ İptal'
        BtnCancelDownload    = 'İndirmeyi Durdur'
        BtnCancelling        = 'Durduruluyor...'
        PhUrl                = 'Store URL, Ürün Kimliği (örn. 9NBLGGH4NNS1) veya PackageFamilyName (örn. Microsoft.Paint_8wekyb3d8bbwe) yapıştırın'
        PhInstSearch         = '🔍  Yüklü uygulamalarda filtrele...'
        HistoryEmpty         = 'Henüz geçmiş yok. Kurulan veya indirilen paketler burada görünecek.'
        DlEmpty              = 'İndirilmiş paket bulunamadı. Uygulama İndir sekmesinden paket getirip indirebilirsiniz.'
        StatusUpdateQueue    = 'Güncelleme {0}/{1}: {2} alınıyor...'
        StatusUpdateQueueDone = 'Güncelleme kuyruğu tamamlandı: {0}/{1} başarıyla güncellendi'
        StatusUpdateQueueFinished = 'Güncelleme kuyruğu bitti.'
        StatusUpdateQueueProcessed = 'Başarıyla güncellenen: {0} / {1}'
        UpdateQueueTitle     = 'Güncellemeler tamamlandı'
        UpdateQueueConfirmMsg = '{0} uygulamayı güncelleme kuyruğuna al?'
        UpdateQueueConfirmSub = 'Her uygulama sırayla indirilip kurulacak.'
        UpdateQueueDetail    = '- {0} ({1} -> {2})'
        UpdateQueueTitle2    = 'Seçileni Güncelle'
        NoSelectionTitle     = 'Seçim yok'
        NoSelectionMsg       = 'Seçili uygulama yok. Önce "{0}" olarak işaretli uygulamaları seçin.'
        NoSelectionUninstall = 'Seçili uygulama yok. Kaldırmak istediğiniz uygulamaları işaretleyin.'
        AdminTitle           = 'Yönetici yetkisi önerilir'
        AdminMsgUpdate       = "TÜM kullanıcılardan kaldırmak için Yönetici gerekir.

Yönetici olmadan yalnızca mevcut kullanıcı kurulumu kaldırılır."
        AdminContinue        = 'Yine de devam et?'
        AdminMsgInstall      = "Kurulum Yönetici olarak çalışıldığında en iyi çalışır.

Yönetici olmadan yalnızca 'mevcut kullanıcı' kurulumu çalışır."
        UninstallTitle       = 'Uygulamayı Kaldır'
        UninstallMsg         = "'{0}' bilgisayarınızdan tamamen kaldırılacak."
        UninstallPFN         = 'PaketAileAdı: {0}'
        UninstallSelectedTitle = 'Seçileni Kaldır'
        UninstallSelectedMsg = '{0} uygulama kaldırılsın mı? Bu işlem geri alınamaz.'
        UninstallResultTitle = 'Kaldırma Sonucu'
        UninstallResultMsg   = 'Kaldırma işlemi tamamlandı.'
        UninstallSuccess     = 'Başarılı: {0}'
        UninstallFailed      = 'Başarısız: {0}'
        InstallResultTitle   = 'Kurulum Sonucu'
        InstallResultSuccess = '{0} paket başarıyla kuruldu.'
        InstallResultIssues  = 'Kurulum sorunlarla tamamlandı.'
        InstallResultDetails = "Başarılı: {0}
Başarısız: {1}

Ayrıntılar için listeyi kontrol edin."
        MissingDepsTitle     = 'Eksik Bağımlılıklar'
        MissingDepsMsg       = "'{0}' paketi eksik bağımlılıklar gerektiriyor. Yine de kur?"
        NoPackagesTitle      = 'Paket yok'
        NoPackagesMsg        = 'Kurulabilir paket bulunamadı.'
        NoPackagesDetails    = ".appx / .msix / .appxbundle / .msixbundle / .exe / .msi arandı:
{0}"
        FileInfoTitle        = 'Dosya Bilgisi'
        FileInfoMsg          = 'Paket ayrıntıları:'
        SelectVerMsg         = 'Sürüm seçimi - orijinal mantık eklenecek.'
        DlFolderNotFound     = 'İndirme klasörü bulunamadı: {0}'
        BtnRetryFailed       = 'Başarısızları Tekrarla'
        RetryAttempt         = 'Deneme {0}/{1}'
        RetryWait            = '{0}s bekleniyor...'
        TipFetch             = 'Microsoft Store paket listesini getir (Enter)'
        TipSelectAll         = 'Listedeki tüm paketleri seç'
        TipDeselectAll       = 'Tüm seçimleri kaldır'
        TipDownloadAll       = 'Tümünü seç ve indirmeyi başlat'
        TipBrowse            = 'Yerel .appx/.msix paket dosyalarına gözat'
        TipReset             = 'Tüm sonuçları temizle ve aktif işlemleri iptal et'
        TipDownload          = 'Seçili paketleri indirme klasörüne indir'
        TipInstall           = 'İndirilen paketleri bu bilgisayara kur'
        TipOpenFolder        = 'İndirme klasörünü Dosya Gezgini nde aç'
        TipCancel            = 'Devam eden işlemi iptal et'
        TipRescan            = 'Yüklü uygulamaları yeniden tara ve Mağaza sürümlerini güncelle'
        TipUpdateSelected    = 'Seçili uygulamaları daha yeni Mağaza sürümüyle güncelle'
        TipUninstallSelected = 'Seçili uygulamaları bu bilgisayardan kaldır'
        TipExportList        = 'Yüklü uygulama listesini CSV veya JSON dosyasına aktar'
        TipSelectAllInst     = 'Tüm yüklü uygulamaları seç veya seçimi kaldır'
        TipShowSystem        = 'Windows sistem bileşenlerini listede göster'
        TipTheme             = 'Koyu / Açık temayı değiştir'
        TipLang              = 'İngilizce ve Türkçe arasında geçiş yap'
        TipCmbPackage        = 'Paket Aile Adı, Ürün Kimliği veya Mağaza URL si girin'
        TipCmbArch           = 'Getirilecek paketin işlemci mimarisini seçin'
        TipCmbRing           = 'Mağaza yayın kanalını seçin (Retail = kararlı)'
        TipTxtUrl            = 'Microsoft Store URL si veya Ürün Kimliği yapıştırın'
        TipInstalledSearch   = 'Yüklü uygulamaları ada göre filtrelemek için yazın'
        # Winget sekmesi / Winget tab
        WingetSearchPh       = 'Yüklü paketlerde ara...'
        WingetRefresh        = '⟳ Yenile'
        WingetShowUpdates    = 'Yalnızca Güncellemeleri Göster'
        WingetAllUsers       = 'Tüm Kullanıcılar'
        WingetSelectAll      = 'Tümünü Seç'
        WingetDeselectAll    = 'Seçimi Kaldır'
        WingetUpdateSel      = '⬆ Seçileni Güncelle'
        WingetUpgradeAll     = 'Tümünü Güncelle'
        WingetChecking       = 'winget kontrol ediliyor...'
        WingetReady          = 'Hazır — paketleri yüklemek için Yenile tıklayın'
        WingetNotFound       = "winget bulunamadı. Store'dan App Installer yükleyin."
        WingetNotAvail       = 'winget kullanılamıyor.'
        WingetRunning        = 'winget list çalışıyor...'
        WingetLoadingSub     = 'Yüklü paketler taranıyor — bu birkaç saniye sürebilir'
        WingetError          = 'Hata: winget çıktısı alınamadı.'
        WingetLoaded         = '{0} paket yüklendi'
        WingetLoadedUpd      = '{0} paket yüklendi — {1} güncelleme mevcut'
        WingetNoPackages     = 'Paket yüklenmedi — önce Yenile tıklayın'
        WingetUpdating       = '[{0}/{1}] güncelleniyor...'
        WingetInstalling     = 'Kuruluyor...'
        WingetDone           = 'Tamamlandı: {0} başarılı'
        WingetDoneFail       = 'Tamamlandı: {0} başarılı, {1} hata'
        WingetCount          = '{0} / {1} paket ({2} seçili)'
        WingetCountUpd       = '{0} / {1} paket ({2} seçili) — {3} güncelleme'
        WingetTipRefresh     = 'Yüklü paketleri winget ile yeniden tara'
        WingetTipShowUpd     = 'Yalnızca güncellemesi olan paketleri göster'
        WingetTipAllUsers    = 'İşlemleri tüm kullanıcılara uygula (yönetici gerektirir)'
        WingetTipSelectAll   = 'Görünen tüm paketleri seç'
        WingetTipDeselectAll = 'Tüm seçimleri kaldır'
        WingetTipUpdateSel   = 'Seçili paketleri güncelle'
        WingetTipUpgradeAll  = 'Güncellemesi olan tüm paketleri güncelle'
        PageWingetSub        = 'winget arama & kurulum'
        WingetBadgeUpdate    = '↑ Güncelleme Var'
        WingetBadgeDone      = 'Güncellendi ✓'
        WingetBadgeUpToDate  = '✓ Güncel'
        WingetHideUpdate     = 'Güncellemeyi Gizle'
        WingetShowUpdate     = 'Güncellemeyi Tekrar Göster'
        WingetBadgeHidden    = '— Gizli'
        InstHideApp          = 'Uygulamayı Gizle'
    }
}
function T($key) { $script:Strings[$script:Lang][$key] }

# ── Veri Modeli / Data Model: PackageItem ────────────────────────────
Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Windows.Media;

public class PackageItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    private void OnChanged(string name) {
        if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(name));
    }

    private bool _isChecked;
    public bool IsChecked { get { return _isChecked; } set { _isChecked = value; OnChanged("IsChecked"); } }

    private string _fileName;
    public string FileName { get { return _fileName; } set { _fileName = value; OnChanged("FileName"); } }

    private string _version;
    public string Version { get { return _version; } set { _version = value; OnChanged("Version"); } }

    private string _sizeText;
    public string SizeText { get { return _sizeText; } set { _sizeText = value; OnChanged("SizeText"); } }

    private string _status;
    public string Status { get { return _status; } set { _status = value; OnChanged("Status"); } }

    private Brush _statusBg;
    public Brush StatusBg { get { return _statusBg; } set { _statusBg = value; OnChanged("StatusBg"); } }

    private Brush _statusFg;
    public Brush StatusFg { get { return _statusFg; } set { _statusFg = value; OnChanged("StatusFg"); } }

    private Brush _rowFg;
    public Brush RowFg { get { return _rowFg; } set { _rowFg = value; OnChanged("RowFg"); } }

    public string Url { get; set; }
    public string StoreId { get; set; }
    public long SizeBytes { get; set; }
}
"@ -ErrorAction SilentlyContinue

# ── Tam Ekran Düzeltmesi / Maximize Fix (WM_GETMINMAXINFO) ──────────
Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

public static class MaximizeHelper {
    private const int WM_GETMINMAXINFO = 0x0024;
    private const uint MONITOR_DEFAULTTONEAREST = 0x00000002;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MINMAXINFO {
        public POINT ptReserved;
        public POINT ptMaxSize;
        public POINT ptMaxPosition;
        public POINT ptMinTrackSize;
        public POINT ptMaxTrackSize;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFO {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    public static void Hook(Window window) {
        var helper = new WindowInteropHelper(window);
        var src = HwndSource.FromHwnd(helper.EnsureHandle());
        if (src != null) {
            src.AddHook(WndProc);
        }
    }

    private static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg == WM_GETMINMAXINFO) {
            MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(lParam, typeof(MINMAXINFO));
            IntPtr monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            if (monitor != IntPtr.Zero) {
                MONITORINFO mi = new MONITORINFO();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                if (GetMonitorInfo(monitor, ref mi)) {
                    RECT work = mi.rcWork;
                    RECT mon  = mi.rcMonitor;
                    mmi.ptMaxPosition.X = Math.Abs(work.Left - mon.Left);
                    mmi.ptMaxPosition.Y = Math.Abs(work.Top  - mon.Top);
                    mmi.ptMaxSize.X     = Math.Abs(work.Right  - work.Left);
                    mmi.ptMaxSize.Y     = Math.Abs(work.Bottom - work.Top);
                    mmi.ptMaxTrackSize.X = mmi.ptMaxSize.X;
                    mmi.ptMaxTrackSize.Y = mmi.ptMaxSize.Y;
                    Marshal.StructureToPtr(mmi, lParam, true);
                }
            }
        }
        return IntPtr.Zero;
    }
}
"@ -ErrorAction SilentlyContinue

# ── WingetItem — INotifyPropertyChanged destekli Winget paket satırı ────────
Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.ComponentModel;

public class WingetItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    private void OnChanged(string name) {
        if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(name));
    }

    private bool _isSelected;
    public bool IsSelected { get { return _isSelected; } set { _isSelected = value; OnChanged("IsSelected"); } }

    private bool _hasUpdate;
    public bool HasUpdate { get { return _hasUpdate; } set { _hasUpdate = value; OnChanged("HasUpdate"); } }

    private bool _isUpdating;
    public bool IsUpdating { get { return _isUpdating; } set { _isUpdating = value; OnChanged("IsUpdating"); OnChanged("SpinnerVisibility"); } }

    private string _statusText;
    public string StatusText { get { return _statusText; } set { _statusText = value; OnChanged("StatusText"); } }

    // SpinnerVisibility: IsUpdating=true ise Visible, degil ise Collapsed
    public string SpinnerVisibility { get { return _isUpdating ? "Visible" : "Collapsed"; } }

    public string Name             { get; set; }
    public string Id               { get; set; }
    public string InstalledVersion { get; set; }

    private string _availableVersion;
    public string AvailableVersion { get { return _availableVersion; } set { _availableVersion = value; OnChanged("AvailableVersion"); } }

    public string Source { get; set; }

    private string _rowStatus = "";
    public string RowStatus { get { return _rowStatus; } set { _rowStatus = value; OnChanged("RowStatus"); OnChanged("RowStatusVisibility"); } }

    private string _rowStatusBg = "#27272A";
    public string RowStatusBg { get { return _rowStatusBg; } set { _rowStatusBg = value; OnChanged("RowStatusBg"); } }

    private string _rowStatusFg = "#A1A1AA";
    public string RowStatusFg { get { return _rowStatusFg; } set { _rowStatusFg = value; OnChanged("RowStatusFg"); } }

    public string RowStatusVisibility { get { return string.IsNullOrEmpty(_rowStatus) ? "Collapsed" : "Visible"; } }
}
"@ -ErrorAction SilentlyContinue

# ── Arayüz Tanımı / UI Definition (XAML) ────────────────────────────
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Microsoft Store App Manager 2.0.3"
    Height="520" Width="840" MinHeight="450" MinWidth="700"
    Background="Transparent"
    WindowStartupLocation="CenterScreen"
    WindowStyle="None"
    ResizeMode="CanResize"
    AllowsTransparency="False"
    FontFamily="Segoe UI">

  <Window.Resources>
    <SolidColorBrush x:Key="AccentBrush"   Color="#F59E0B"/>
    <SolidColorBrush x:Key="AccentHover"   Color="#D97706"/>
    <SolidColorBrush x:Key="AccentPress"   Color="#B45309"/>
    <SolidColorBrush x:Key="SurfaceBrush"  Color="#18181B"/>
    <SolidColorBrush x:Key="SidebarBrush"  Color="#09090B"/>
    <SolidColorBrush x:Key="CardBrush"     Color="#14141A"/>
    <SolidColorBrush x:Key="ListBrush"     Color="#0E0E13"/>
    <SolidColorBrush x:Key="TextPrimary"   Color="#F4F4F5"/>
    <SolidColorBrush x:Key="TextSecondary" Color="#A1A1AA"/>
    <SolidColorBrush x:Key="TextDisabled"  Color="#52525B"/>
    <SolidColorBrush x:Key="RowAlt"        Color="#11111A"/>
    <SolidColorBrush x:Key="BorderColor"   Color="#27272A"/>
    <!-- Theme aware brush'lar (inline hardcoded renklerin yerine) -->
    <SolidColorBrush x:Key="InputBg"       Color="#0E0E13"/>
    <SolidColorBrush x:Key="InputBorder"   Color="#3F3F46"/>
    <SolidColorBrush x:Key="HeaderBg"      Color="#0B0B0F"/>
    <SolidColorBrush x:Key="MenuBg"        Color="#18181B"/>
    <SolidColorBrush x:Key="MenuHover"     Color="#2A2A33"/>

    <!-- ==================== Dark ToolTip Style ==================== -->
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{DynamicResource MenuBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource InputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>

    <!-- Override system colors to prevent white corners in DataGrid scrollbar area -->
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#0B0B0F"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#0B0B0F"/>

    <!-- ==================== ScrollBar Style ==================== -->
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="6"/>
      <Setter Property="Margin" Value="2,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Border Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="true">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="ThumbBorder" Background="{DynamicResource AccentBrush}" CornerRadius="3"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="ThumbBorder" Property="Background" Value="{DynamicResource AccentHover}"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="ThumbBorder" Property="Background" Value="{DynamicResource AccentHover}"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="6"/>
          <Setter Property="Margin" Value="0,2,0,0"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Border Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.Thumb>
                      <Thumb>
                        <Thumb.Template>
                          <ControlTemplate TargetType="Thumb">
                            <Border x:Name="ThumbBorderH" Background="{DynamicResource AccentBrush}" CornerRadius="3"/>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThumbBorderH" Property="Background" Value="{DynamicResource AccentHover}"/>
                              </Trigger>
                              <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="ThumbBorderH" Property="Background" Value="{DynamicResource AccentHover}"/>
                              </Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                  </Track>
                </Border>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- ==================== Custom Title Bar Button Styles ==================== -->
    <Style x:Key="TitleBarButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="{DynamicResource TitleBarFg}"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource MenuHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource MenuHover}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TitleBarCloseButton" TargetType="Button" BasedOn="{StaticResource TitleBarButton}">
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#E81123"/>
          <Setter Property="Foreground" Value="White"/>
        </Trigger>
      </Style.Triggers>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E81123"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C10E1F"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ==================== ContextMenu + MenuItem (Dark Theme) ==================== -->
    <Style TargetType="ContextMenu">
      <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource InputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="2"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="2">
              <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="MenuItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="mb" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}" CornerRadius="4" Margin="1">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ContentPresenter Grid.Column="0"
                                  Content="{TemplateBinding Header}"
                                  ContentSource="Header"
                                  VerticalAlignment="Center"
                                  HorizontalAlignment="Left"
                                  TextElement.Foreground="{TemplateBinding Foreground}"
                                  TextElement.FontSize="{TemplateBinding FontSize}"
                                  TextElement.FontWeight="{TemplateBinding FontWeight}"/>
                <TextBlock Grid.Column="1"
                           Text="{TemplateBinding InputGestureText}"
                           Foreground="#71717A"
                           VerticalAlignment="Center" Margin="16,0,0,0"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="mb" Property="Background" Value="{DynamicResource MenuHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Separator">
      <Setter Property="Background" Value="{DynamicResource InputBorder}"/>
      <Setter Property="Margin" Value="6,4"/>
      <Setter Property="Height" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator">
            <Border Background="{TemplateBinding Background}" Height="1"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Background" Value="{DynamicResource InputBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource InputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid x:Name="templateRoot" Background="Transparent" SnapsToDevicePixels="True">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="checkBoxBorder"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      Background="{TemplateBinding Background}"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      CornerRadius="4" Width="16" Height="16">
                <Grid x:Name="markGrid">
                  <Path x:Name="optionMark"
                        Data="M1,5 L5,9 L13,1"
                        Stroke="{DynamicResource AccentBrush}"
                        StrokeThickness="2"
                        Margin="2" Opacity="0"
                        Stretch="Uniform"/>
                </Grid>
              </Border>
              <ContentPresenter x:Name="contentPresenter" Grid.Column="1" Margin="6,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="optionMark" Property="Opacity" Value="1"/>
                <Setter TargetName="checkBoxBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="checkBoxBorder" Property="BorderBrush" Value="{DynamicResource AccentHover}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccentBtn" TargetType="Button">
      <Setter Property="Background"      Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource HeaderBg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="12,4"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentPress}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource CardBrush}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Background"      Value="{DynamicResource SurfaceBrush}"/>
      <Setter Property="Foreground"      Value="{DynamicResource TextSecondary}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource InputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="8,4"/>
      <Setter Property="FontSize"        Value="10"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource BorderColor}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource MenuHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource CardBrush}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavItem" TargetType="ListBoxItem">
      <Setter Property="Background"    Value="Transparent"/>
      <Setter Property="Foreground"    Value="{DynamicResource TextSecondary}"/>
      <Setter Property="Padding"       Value="8,6"/>
      <Setter Property="Margin"        Value="0,2"/>
      <Setter Property="Cursor"        Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource BorderColor}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource RowAlt}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background"      Value="{DynamicResource InputBg}"/>
      <Setter Property="Foreground"      Value="{DynamicResource TextPrimary}"/>
      <Setter Property="BorderBrush"     Value="{DynamicResource InputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="6,4"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="CaretBrush"      Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="border" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Focusable="false" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="true">
                <Setter Property="BorderBrush" TargetName="border" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsFocused" Value="true">
                <Setter Property="BorderBrush" TargetName="border" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DarkCombo" TargetType="ComboBox">
      <Setter Property="Background"          Value="{DynamicResource InputBg}"/>
      <Setter Property="Foreground"          Value="{DynamicResource TextPrimary}"/>
      <Setter Property="BorderBrush"         Value="{DynamicResource InputBorder}"/>
      <Setter Property="BorderThickness"     Value="1"/>
      <Setter Property="Padding"             Value="6,4"/>
      <Setter Property="FontSize"            Value="10"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="MaxDropDownHeight"   Value="200"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <!-- Tüm alana tıklanabilir ToggleButton -->
              <ToggleButton x:Name="ToggleButton"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                            Focusable="False" ClickMode="Press"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="tb"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="6">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="20"/>
                        </Grid.ColumnDefinitions>
                        <ContentPresenter Grid.Column="0"/>
                        <Path Grid.Column="1"
                              Data="M0,0 L4,4 L8,0"
                              Stroke="#A1A1AA" StrokeThickness="1.5"
                              HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="tb" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                      </Trigger>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="tb" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>

              <!-- Seçili öğeyi gösteren alan -->
              <ContentPresenter x:Name="ContentSite"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="8,0,24,0"
                                VerticalAlignment="Center"
                                HorizontalAlignment="Left"
                                IsHitTestVisible="False"/>

              <!-- Editable mod için TextBox -->
              <TextBox x:Name="PART_EditableTextBox"
                       Margin="6,0,24,0"
                       Background="Transparent"
                       Foreground="{TemplateBinding Foreground}"
                       BorderThickness="0"
                       CaretBrush="{DynamicResource AccentBrush}"
                       Visibility="Hidden"
                       IsReadOnly="{TemplateBinding IsReadOnly}"
                       VerticalAlignment="Center"/>

              <!-- Dropdown popup -->
              <Popup x:Name="Popup"
                     Placement="Bottom"
                     IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True"
                     Focusable="False"
                     PopupAnimation="Slide">
                <Grid SnapsToDevicePixels="True"
                      MinWidth="{TemplateBinding ActualWidth}"
                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <Border Background="{DynamicResource MenuBg}"
                          BorderBrush="{DynamicResource InputBorder}"
                          BorderThickness="1"
                          CornerRadius="6"
                          Margin="0,2,0,0">
                    <ScrollViewer SnapsToDevicePixels="True">
                      <StackPanel IsItemsHost="True"
                                  KeyboardNavigation.DirectionalNavigation="Contained"/>
                    </ScrollViewer>
                  </Border>
                </Grid>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="ContentSite"          Property="Visibility" Value="Hidden"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="gd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4" Margin="2,1">
              <ContentPresenter />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="gd" Property="Background" Value="{DynamicResource BorderColor}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="gd" Property="Background" Value="{DynamicResource AccentBrush}"/>
                <Setter Property="Foreground" Value="{DynamicResource HeaderBg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PkgGrid" TargetType="DataGrid">
      <Setter Property="ClipToBounds" Value="True"/>
      <Setter Property="Background"               Value="{DynamicResource ListBrush}"/>
      <Setter Property="RowBackground"            Value="Transparent"/>
      <Setter Property="AlternatingRowBackground" Value="{DynamicResource RowAlt}"/>
      <Setter Property="Foreground"               Value="{DynamicResource TextPrimary}"/>
      <Setter Property="BorderThickness"          Value="0"/>
      <Setter Property="GridLinesVisibility"      Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource BorderColor}"/>
      <Setter Property="HeadersVisibility"        Value="Column"/>
      <Setter Property="CanUserAddRows"           Value="False"/>
      <Setter Property="CanUserDeleteRows"        Value="False"/>
      <Setter Property="AutoGenerateColumns"      Value="False"/>
      <Setter Property="SelectionMode"            Value="Single"/>
      <Setter Property="FontSize"                 Value="10.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGrid">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    SnapsToDevicePixels="True" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="DG_ScrollViewer" Focusable="false" Background="{TemplateBinding Background}">
                <ScrollViewer.Template>
                  <ControlTemplate TargetType="ScrollViewer">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                      </Grid.RowDefinitions>
                      <DataGridColumnHeadersPresenter x:Name="PART_ColumnHeadersPresenter"
                          Grid.Column="1" Grid.Row="0"
                          Visibility="{Binding HeadersVisibility, ConverterParameter={x:Static DataGridHeadersVisibility.Column}, Converter={x:Static DataGrid.HeadersVisibilityConverter}, RelativeSource={RelativeSource AncestorType={x:Type DataGrid}}}"/>
                      <Border Grid.Column="2" Grid.Row="0" Background="{DynamicResource HeaderBg}"/>
                      <ScrollContentPresenter x:Name="PART_ScrollContentPresenter"
                          Grid.ColumnSpan="2" Grid.Column="0" Grid.Row="1"
                          CanContentScroll="{TemplateBinding CanContentScroll}"/>
                      <ScrollBar x:Name="PART_VerticalScrollBar" Grid.Column="2" Grid.Row="1"
                          Orientation="Vertical"
                          ViewportSize="{TemplateBinding ViewportHeight}"
                          Maximum="{TemplateBinding ScrollableHeight}"
                          Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"
                          Value="{Binding VerticalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"/>
                      <Grid Grid.Column="1" Grid.Row="2">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="{Binding NonFrozenColumnsViewportHorizontalOffset, RelativeSource={RelativeSource AncestorType={x:Type DataGrid}}}"/>
                          <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <ScrollBar x:Name="PART_HorizontalScrollBar" Grid.Column="1"
                            Orientation="Horizontal"
                            ViewportSize="{TemplateBinding ViewportWidth}"
                            Maximum="{TemplateBinding ScrollableWidth}"
                            Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"
                            Value="{Binding HorizontalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"/>
                      </Grid>
                    </Grid>
                  </ControlTemplate>
                </ScrollViewer.Template>
                <ItemsPresenter SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
              </ScrollViewer>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background"      Value="{DynamicResource HeaderBg}"/>
      <Setter Property="Foreground"      Value="{DynamicResource TextSecondary}"/>
      <Setter Property="BorderBrush"     Value="{DynamicResource BorderColor}"/>
      <Setter Property="BorderThickness" Value="0,1,0,1"/>
      <Setter Property="Padding"         Value="8,6"/>
      <Setter Property="FontSize"        Value="9"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridColumnHeader">
            <Border x:Name="hdrBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Left"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{DynamicResource MenuHover}"/>
        </Trigger>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource RowAlt}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="ThinProg" TargetType="ProgressBar">
      <Setter Property="Height"          Value="3"/>
      <Setter Property="Background"      Value="{DynamicResource BorderColor}"/>
      <Setter Property="Foreground"      Value="{DynamicResource AccentBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <Style x:Key="DarkTB" TargetType="TextBox">
      <Setter Property="Background"      Value="{DynamicResource InputBg}"/>
      <Setter Property="Foreground"      Value="{DynamicResource TextPrimary}"/>
      <Setter Property="BorderBrush"     Value="{DynamicResource InputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="8,6"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="CaretBrush"      Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="border"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6"
                    SnapsToDevicePixels="True">
              <Grid>
                <ScrollViewer x:Name="PART_ContentHost" Focusable="false" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
                <!-- Placeholder — Tag property'sinden okunur, metin boşken görünür -->
                <TextBlock x:Name="placeholder"
                           Text="{TemplateBinding Tag}"
                           Foreground="{DynamicResource TextSecondary}"
                           FontSize="{TemplateBinding FontSize}"
                           Margin="{TemplateBinding Padding}"
                           VerticalAlignment="Center"
                           IsHitTestVisible="False"
                           Opacity="0.5"
                           Visibility="Collapsed"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="true">
                <Setter Property="BorderBrush" TargetName="border" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsFocused" Value="true">
                <Setter Property="BorderBrush" TargetName="border" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <!-- Metin boşken placeholder'ı göster -->
              <Trigger Property="Text" Value="">
                <Setter TargetName="placeholder" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="outerWindowBorder" CornerRadius="0" BorderThickness="0"
          Background="{DynamicResource SurfaceBrush}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="36"/>
        <RowDefinition Height="0"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- ==================== Custom Title Bar ==================== -->
      <Grid Grid.Row="0" Background="{DynamicResource TitleBarBg}">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <!-- Title + Icon (dragable area, no IsHitTestVisibleInChrome) -->
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
          <!-- Microsoft Store icon (gerçek SVG path'leri, viewBox 0 0 960 960 -> 18x18) -->
          <Viewbox Width="18" Height="18" Margin="0,0,8,0">
            <Viewbox.Triggers>
              <EventTrigger RoutedEvent="Viewbox.Loaded">
                <BeginStoryboard>
                  <Storyboard RepeatBehavior="Forever">
                    <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushTitle1" Storyboard.TargetProperty="Color" Duration="0:0:8">
                      <DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:8"/>
                    </ColorAnimationUsingKeyFrames>
                    <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushTitle2" Storyboard.TargetProperty="Color" Duration="0:0:8">
                      <DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:8"/>
                    </ColorAnimationUsingKeyFrames>
                    <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushTitle3" Storyboard.TargetProperty="Color" Duration="0:0:8">
                      <DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:8"/>
                    </ColorAnimationUsingKeyFrames>
                    <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushTitle4" Storyboard.TargetProperty="Color" Duration="0:0:8">
                      <DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:8"/>
                    </ColorAnimationUsingKeyFrames>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>
            </Viewbox.Triggers>
            <Canvas Width="960" Height="780">
              <Canvas.RenderTransform>
                <TranslateTransform Y="-15"/>
              </Canvas.RenderTransform>
              <!-- Bag body (mavi gradient) -->
              <Path Data="M814.41,124.83H168.55c-45.92,0-45.92,26.66-45.92,26.66v478.48c0,131.84,139.25,140.73,139.25,140.73h429.59c159.98,0,154.06-131.84,154.06-131.84V158.9c0-41.48-31.11-34.07-31.11-34.07Z">
                <Path.Fill>
                  <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
                    <GradientStop Offset="0"   Color="#0669BC"/>
                    <GradientStop Offset="0.5" Color="#15528E"/>
                    <GradientStop Offset="1"   Color="#243A5F"/>
                  </LinearGradientBrush>
                </Path.Fill>
              </Path>
              <!-- Çanta kulpları (mavi) -->
              <Path Fill="#1AA9F1" Data="F0 M263.01,157.41c0,17.39,14.1,31.49,31.49,31.49s31.47-14.1,31.47-31.49h-62.96ZM640.76,157.41c0,17.39,14.09,31.49,31.48,31.49s31.48-14.1,31.48-31.49h-62.96ZM325.98,157.41v-78.69h-62.96v78.69h62.96ZM325.98,78.72h314.78V15.75h-314.78v62.96ZM640.76,78.72v78.69h62.96v-78.69h-62.96ZM640.76,78.72h62.96c0-34.77-28.19-62.96-62.96-62.96v62.96ZM325.98,78.72V15.75c-34.77,0-62.96,28.19-62.96,62.96h62.96Z"/>
              <!-- Kulp üst dolgu -->
              <Path Fill="#22BCFF" Data="M325.98,15.76h314.78v62.95h-314.78V15.76Z"/>
              <!-- 4 renkli kare (Animated) -->
              <Path Data="M467.64,283.32h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brushTitle1" Color="#F25022"/></Path.Fill></Path>
              <Path Data="M640.78,283.32h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brushTitle2" Color="#7FBA00"/></Path.Fill></Path>
              <Path Data="M640.78,456.44h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brushTitle3" Color="#FFB900"/></Path.Fill></Path>
              <Path Data="M467.64,456.44h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brushTitle4" Color="#00A4EF"/></Path.Fill></Path>
            </Canvas>
          </Viewbox>
          <TextBlock x:Name="txtTitleBar" Text="Microsoft Store App Manager 2.0.3"
                     Foreground="{DynamicResource TitleBarFg}" FontSize="12" FontWeight="SemiBold"
                     VerticalAlignment="Center"/>
        </StackPanel>

        <!-- Window controls (minimize / maximize / close) -->
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="btnMinimize" Style="{StaticResource TitleBarButton}"  Content="&#xE921;" ToolTip="Minimize"/>
          <Button x:Name="btnMaximize" Style="{StaticResource TitleBarButton}"  Content="&#xE922;" ToolTip="Maximize"/>
          <Button x:Name="btnClose"    Style="{StaticResource TitleBarCloseButton}" Content="&#xE8BB;" ToolTip="Close"/>
        </StackPanel>
      </Grid>

      <!-- ==================== Accent Line (tema renginde başlık altı çizgisi) ==================== -->
      <Border x:Name="titleAccentLine" Grid.Row="1" Background="{DynamicResource BorderColor}" Height="2" VerticalAlignment="Stretch" Visibility="Collapsed"/>

      <!-- ==================== Main Content ==================== -->
      <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="160"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- ==================== Modern Wave Overlay ==================== -->
      <Grid x:Name="waveCanvas" Grid.ColumnSpan="2"
            IsHitTestVisible="False"
            Visibility="Collapsed"
            Panel.ZIndex="-1"
            ClipToBounds="True">
        <Grid.OpacityMask>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Offset="0" Color="#00FFFFFF" />
            <GradientStop Offset="0.12" Color="#00FFFFFF" />
            <GradientStop Offset="0.22" Color="#FFFFFFFF" />
          </LinearGradientBrush>
        </Grid.OpacityMask>
        <Viewbox Stretch="Fill" HorizontalAlignment="Stretch" VerticalAlignment="Bottom" Height="250">
          <Canvas Width="1000" Height="250">
            <Path Fill="{DynamicResource AccentBrush}" Data="M 0,100 C 250,200 500,0 1000,100 L 1000,250 L 0,250 Z">
              <Path.OpacityMask>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Offset="0" Color="#00FFFFFF" />
                  <GradientStop Offset="1" Color="#15FFFFFF" />
                </LinearGradientBrush>
              </Path.OpacityMask>
            </Path>
            <Path Fill="{DynamicResource AccentBrush}" Data="M 0,150 C 350,50 650,230 1000,130 L 1000,250 L 0,250 Z">
              <Path.OpacityMask>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Offset="0" Color="#00FFFFFF" />
                  <GradientStop Offset="1" Color="#10FFFFFF" />
                </LinearGradientBrush>
              </Path.OpacityMask>
            </Path>
            <Path Fill="{DynamicResource AccentBrush}" Data="M 0,50 C 300,230 700,-30 1000,70 L 1000,250 L 0,250 Z">
              <Path.OpacityMask>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Offset="0" Color="#00FFFFFF" />
                  <GradientStop Offset="1" Color="#08FFFFFF" />
                </LinearGradientBrush>
              </Path.OpacityMask>
            </Path>
          </Canvas>
        </Viewbox>
      </Grid>

      <!-- ==================== Modern Grid Overlay ==================== -->
      <Grid x:Name="gridCanvas" Grid.ColumnSpan="2"
            IsHitTestVisible="False"
            Visibility="Collapsed"
            Panel.ZIndex="-1"
            ClipToBounds="True">
        <Grid.OpacityMask>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Offset="0" Color="#00FFFFFF" />
            <GradientStop Offset="0.12" Color="#00FFFFFF" />
            <GradientStop Offset="0.22" Color="#FFFFFFFF" />
          </LinearGradientBrush>
        </Grid.OpacityMask>
        <Rectangle Opacity="0.08">
          <Rectangle.OpacityMask>
            <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
              <GradientStop Offset="0" Color="#FFFFFFFF" />
              <GradientStop Offset="0.8" Color="#00FFFFFF" />
            </LinearGradientBrush>
          </Rectangle.OpacityMask>
          <Rectangle.Fill>
            <VisualBrush Viewport="0,0,40,40" ViewportUnits="Absolute" TileMode="Tile">
              <VisualBrush.Visual>
                <Canvas Width="40" Height="40">
                  <!-- Minimalist grid lines -->
                  <Line X1="0" Y1="40" X2="40" Y2="40" Stroke="{DynamicResource AccentBrush}" StrokeThickness="1"/>
                  <Line X1="40" Y1="0" X2="40" Y2="40" Stroke="{DynamicResource AccentBrush}" StrokeThickness="1"/>
                  <Ellipse Width="3" Height="3" Canvas.Left="38.5" Canvas.Top="38.5" Fill="{DynamicResource AccentBrush}"/>
                </Canvas>
              </VisualBrush.Visual>
            </VisualBrush>
          </Rectangle.Fill>
        </Rectangle>
      </Grid>

      <!-- ==================== Watermark Overlay ==================== -->
      <Grid x:Name="watermarkCanvas" Grid.ColumnSpan="2"
            IsHitTestVisible="False"
            Visibility="Visible"
            Panel.ZIndex="-2"
            ClipToBounds="True">
        <!-- Top Header Watermark (Yellow Box Area) -->
        <StackPanel Orientation="Horizontal" VerticalAlignment="Top" HorizontalAlignment="Left" Margin="180,15,0,0">
           <TextBlock Text="Microsoft Store" Foreground="{DynamicResource WatermarkBrandBrush}" FontSize="32" FontWeight="Bold" Margin="0,0,10,0" Opacity="0.12"/>
           <TextBlock Text="App Manager" Foreground="{DynamicResource WatermarkProductBrush}" FontSize="32" FontWeight="Light" Opacity="0.22"/>
        </StackPanel>
      </Grid>

      <Border Grid.Column="0" Background="{DynamicResource SidebarBrush}"
              BorderThickness="0" CornerRadius="0">
        <DockPanel Margin="8,8,8,12">
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <!-- Büyük Microsoft Store kart -->
            <Border Background="{DynamicResource SurfaceBrush}"
                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1"
                    CornerRadius="10" Padding="10,8,10,10" Margin="4,0,4,0">
              <Border.Triggers>
                <EventTrigger RoutedEvent="Border.Loaded">
                  <BeginStoryboard>
                    <Storyboard RepeatBehavior="Forever">
                      <!-- Floating Animation -->
                      <DoubleAnimation Storyboard.TargetName="logoTranslate" 
                                       Storyboard.TargetProperty="Y" 
                                       From="0" To="-4" Duration="0:0:2.5" AutoReverse="True">
                        <DoubleAnimation.EasingFunction>
                          <QuadraticEase EasingMode="EaseInOut"/>
                        </DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <!-- Color Cycling (Swapping Effect) -->
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brush1" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:0"/>
                        <DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:2"/>
                        <DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:4"/>
                        <DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:6"/>
                        <DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brush2" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:0"/>
                        <DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:2"/>
                        <DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:4"/>
                        <DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:6"/>
                        <DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brush3" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:0"/>
                        <DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:2"/>
                        <DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:4"/>
                        <DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:6"/>
                        <DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brush4" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:0"/>
                        <DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:2"/>
                        <DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:4"/>
                        <DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:6"/>
                        <DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                      <!-- Sub Logo Squares Animation -->
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushSub1" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushSub2" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushSub3" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                      <ColorAnimationUsingKeyFrames Storyboard.TargetName="brushSub4" Storyboard.TargetProperty="Color" Duration="0:0:8">
                        <DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:0"/><DiscreteColorKeyFrame Value="#F25022" KeyTime="0:0:2"/><DiscreteColorKeyFrame Value="#7FBA00" KeyTime="0:0:4"/><DiscreteColorKeyFrame Value="#FFB900" KeyTime="0:0:6"/><DiscreteColorKeyFrame Value="#00A4EF" KeyTime="0:0:8"/>
                      </ColorAnimationUsingKeyFrames>
                    </Storyboard>
                  </BeginStoryboard>
                </EventTrigger>
              </Border.Triggers>
              <StackPanel HorizontalAlignment="Center">
                <!-- Büyük Microsoft Store iconu (SVG path'leri, sadece logo bölümü) -->
                <Viewbox x:Name="logoViewbox" Width="80" Height="80" HorizontalAlignment="Center" Margin="0,0,0,6">
                  <Viewbox.RenderTransform>
                    <TranslateTransform x:Name="logoTranslate" Y="0"/>
                  </Viewbox.RenderTransform>
                  <Canvas Width="960" Height="780">
                    <Canvas.RenderTransform>
                      <TranslateTransform Y="-15"/>
                    </Canvas.RenderTransform>
                    <Path Data="M814.41,124.83H168.55c-45.92,0-45.92,26.66-45.92,26.66v478.48c0,131.84,139.25,140.73,139.25,140.73h429.59c159.98,0,154.06-131.84,154.06-131.84V158.9c0-41.48-31.11-34.07-31.11-34.07Z">
                      <Path.Fill>
                        <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
                          <GradientStop Offset="0"   Color="#0669BC"/>
                          <GradientStop Offset="0.5" Color="#15528E"/>
                          <GradientStop Offset="1"   Color="#243A5F"/>
                        </LinearGradientBrush>
                      </Path.Fill>
                    </Path>
                    <Path Fill="#1AA9F1" Data="F0 M263.01,157.41c0,17.39,14.1,31.49,31.49,31.49s31.47-14.1,31.47-31.49h-62.96ZM640.76,157.41c0,17.39,14.09,31.49,31.48,31.49s31.48-14.1,31.48-31.49h-62.96ZM325.98,157.41v-78.69h-62.96v78.69h62.96ZM325.98,78.72h314.78V15.75h-314.78v62.96ZM640.76,78.72v78.69h62.96v-78.69h-62.96ZM640.76,78.72h62.96c0-34.77-28.19-62.96-62.96-62.96v62.96ZM325.98,78.72V15.75c-34.77,0-62.96,28.19-62.96,62.96h62.96Z"/>
                    <Path Fill="#22BCFF" Data="M325.98,15.76h314.78v62.95h-314.78V15.76Z"/>
                    <!-- Animated Squares -->
                    <Path Data="M467.64,283.32h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brush1" Color="#F25022"/></Path.Fill></Path>
                    <Path Data="M640.78,283.32h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brush2" Color="#7FBA00"/></Path.Fill></Path>
                    <Path Data="M640.78,456.44h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brush3" Color="#FFB900"/></Path.Fill></Path>
                    <Path Data="M467.64,456.44h-141.66v141.66h141.66v-141.66Z"><Path.Fill><SolidColorBrush x:Name="brush4" Color="#00A4EF"/></Path.Fill></Path>
                  </Canvas>
                </Viewbox>
                <!-- "Microsoft Store" yazısı (küçük 4 kare + metin) -->
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,4">
                  <Grid Width="14" Height="14" Margin="0,0,5,0">
                    <Grid.RowDefinitions>
                      <RowDefinition Height="*"/>
                      <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Rectangle Grid.Row="0" Grid.Column="0" Margin="0.5"><Rectangle.Fill><SolidColorBrush x:Name="brushSub1" Color="#F25022"/></Rectangle.Fill></Rectangle>
                    <Rectangle Grid.Row="0" Grid.Column="1" Margin="0.5"><Rectangle.Fill><SolidColorBrush x:Name="brushSub2" Color="#7FBA00"/></Rectangle.Fill></Rectangle>
                    <Rectangle Grid.Row="1" Grid.Column="0" Margin="0.5"><Rectangle.Fill><SolidColorBrush x:Name="brushSub4" Color="#00A4EF"/></Rectangle.Fill></Rectangle>
                    <Rectangle Grid.Row="1" Grid.Column="1" Margin="0.5"><Rectangle.Fill><SolidColorBrush x:Name="brushSub3" Color="#FFB900"/></Rectangle.Fill></Rectangle>
                  </Grid>
                  <TextBlock Text="Microsoft Store" Foreground="{DynamicResource TextPrimary}"
                             FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>



          <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0"
                   SelectedIndex="0" ItemContainerStyle="{StaticResource NavItem}">
            <ListBoxItem>
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="12" Height="12" Margin="0,0,8,0" VerticalAlignment="Center">
                  <Path Data="M12,3L2,8V16L12,21L22,16V8L12,3M12,13L4.96,9.5L12,6L19.04,9.5L12,13M18.58,16.5L12,19.74V14.6L19.04,11.12V15.22C19.04,15.75 18.86,16.22 18.58,16.5M5.42,16.5C5.14,16.22 4.96,15.75 4.96,15.22V11.12L12,14.6V19.74L5.42,16.5Z"
                        Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ListBoxItem}}"/>
                </Viewbox>
                <TextBlock x:Name="navFetch" Text="Download Apps" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </ListBoxItem>
            <ListBoxItem>
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="12" Height="12" Margin="0,0,8,0" VerticalAlignment="Center">
                  <Path Data="M9.5,3A6.5,6.5 0 0,1 16,9.5C16,11.11 15.41,12.59 14.44,13.73L14.71,14H15.5L20.5,19L19,20.5L14,15.5V14.71L13.73,14.44C12.59,15.41 11.11,16 9.5,16A6.5,6.5 0 0,1 3,9.5A6.5,6.5 0 0,1 9.5,3M9.5,5C7,5 5,7 5,9.5C5,12 7,14 9.5,14C12,14 14,12 14,9.5C14,7 12,5 9.5,5Z"
                        Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ListBoxItem}}"/>
                </Viewbox>
                <TextBlock x:Name="navInstalled" Text="Installed Apps" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </ListBoxItem>
            <ListBoxItem>
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="12" Height="12" Margin="0,0,8,0" VerticalAlignment="Center">
                  <Path Data="M4,4H20V6H4V4M4,9H20V11H4V9M4,14H14V16H4V14M16.5,13A3.5,3.5 0 0,1 20,16.5A3.5,3.5 0 0,1 16.5,20A3.5,3.5 0 0,1 13,16.5A3.5,3.5 0 0,1 16.5,13M18.35,15.8L16,18.15L14.65,16.8L13.7,17.75L16,20.05L19.3,16.75L18.35,15.8Z"
                        Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ListBoxItem}}"/>
                </Viewbox>
                <TextBlock x:Name="navWinget" Text="Winget" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </ListBoxItem>
            <ListBoxItem>
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="12" Height="12" Margin="0,0,8,0" VerticalAlignment="Center">
                  <Path Data="M5,20H19V18H5M19,9H15V3H9V9H5L12,16L19,9Z"
                        Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ListBoxItem}}"/>
                </Viewbox>
                <TextBlock x:Name="navDownloads" Text="Downloads" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </ListBoxItem>
            <ListBoxItem>
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="12" Height="12" Margin="0,0,8,0" VerticalAlignment="Center">
                  <Path Data="M12,20A8,8 0 0,0 20,12A8,8 0 0,0 12,4A8,8 0 0,0 4,12A8,8 0 0,0 12,20M12,2A10,10 0 0,1 22,12A10,10 0 0,1 12,22C6.47,22 2,17.53 2,12A10,10 0 0,1 12,2M12.5,7V12.25L17,14.92L16.25,16.15L11,13V7H12.5Z"
                        Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ListBoxItem}}"/>
                </Viewbox>
                <TextBlock x:Name="navHistory" Text="History" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </ListBoxItem>
            <ListBoxItem>
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="12" Height="12" Margin="0,0,8,0" VerticalAlignment="Center">
                  <Path Data="M12,15.5A3.5,3.5 0 0,1 8.5,12A3.5,3.5 0 0,1 12,8.5A3.5,3.5 0 0,1 15.5,12A3.5,3.5 0 0,1 12,15.5M19.43,12.97C19.47,12.65 19.5,12.33 19.5,12C19.5,11.67 19.47,11.35 19.43,11.03L21.54,9.37C21.73,9.22 21.78,8.97 21.65,8.76L19.65,5.3C19.5,5.1 19.27,5.03 19.07,5.11L16.59,6.11C16.08,5.71 15.5,5.39 14.88,5.13L14.5,2.42C14.46,2.2 14.27,2.05 14.05,2.05H10.05C9.83,2.05 9.64,2.2 9.6,2.42L9.22,5.13C8.6,5.39 8.02,5.71 7.5,6.11L5.03,5.11C4.83,5.03 4.6,5.1 4.47,5.3L2.47,8.76C2.35,8.97 2.4,9.22 2.59,9.37L4.7,11.03C4.66,11.35 4.63,11.67 4.63,12C4.63,12.33 4.66,12.65 4.7,12.97L2.59,14.63C2.4,14.78 2.35,15.03 2.47,15.24L4.47,18.7C4.6,18.9 4.83,18.97 5.03,18.89L7.5,17.89C8.02,18.29 8.6,18.61 9.22,18.87L9.6,21.58C9.64,21.8 9.83,21.95 10.05,21.95H14.05C14.27,21.95 14.46,21.8 14.5,21.58L14.88,18.87C15.5,18.61 16.08,18.29 16.59,17.89L19.07,18.89C19.27,18.97 19.5,18.9 19.65,18.7L21.65,15.24C21.78,15.03 21.73,14.78 21.54,14.63L19.43,12.97Z"
                        Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ListBoxItem}}"/>
                </Viewbox>
                <TextBlock x:Name="navSettings" Text="Settings" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </ListBoxItem>
          </ListBox>
        </DockPanel>
      </Border>

      <Grid Grid.Column="1" Margin="16,14,16,12">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,15">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <!-- Sadece Yüklü Uygulamalar / Geçmiş gibi alt-sayfa olduğunda
               görünen kompakt başlık. Fetch sekmesinde gizlenebilir ya da
               tutarlılık için her sayfada kalır. -->
          <StackPanel x:Name="pageHeader" Grid.Column="0" VerticalAlignment="Center">
            <TextBlock x:Name="lblPageTitle" Text="Fetch Store Packages"
                       Foreground="{DynamicResource TextPrimary}"
                       FontSize="18" FontWeight="SemiBold"/>
            <TextBlock x:Name="lblPageSub"
                       Text="Paste a Microsoft Store URL, Product ID or Package Family Name"
                       Foreground="{DynamicResource TextSecondary}"
                       FontSize="11" Margin="0,2,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="btnTheme" Content="&#xE793;" Width="36" Height="36"
                    Style="{StaticResource GhostBtn}" Margin="0,0,8,0"
                    FontFamily="Segoe MDL2 Assets" FontSize="14"
                    ToolTip="Toggle Dark / Light appearance"/>
            <Button x:Name="btnLang"  Content="TR" Width="44" Height="36"
                    Style="{StaticResource GhostBtn}" FontWeight="Bold" FontSize="11"
                    ToolTip="Switch between English (EN) and Turkish (TR)"/>
          </StackPanel>
        </Grid>

        <!-- Input card - tutarlı yükseklik, her alana başlık etiketi -->
        <Border x:Name="inputCard" Grid.Row="1" Background="{DynamicResource CardBrush}"
                BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10"
                Padding="14" Margin="0,0,0,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="120"/>
              <ColumnDefinition Width="110"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="32"/>
              <RowDefinition Height="10"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="32"/>
            </Grid.RowDefinitions>

            <!-- Üst sıra başlıkları -->
            <TextBlock x:Name="lblFieldPackage" Grid.Row="0" Grid.Column="0" Text="Package Name / Product ID"
                       Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"
                       Margin="2,0,8,4"/>
            <TextBlock x:Name="lblFieldArch" Grid.Row="0" Grid.Column="1" Text="Architecture"
                       Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"
                       Margin="0,0,8,4"/>
            <TextBlock x:Name="lblFieldRing" Grid.Row="0" Grid.Column="2" Text="Release Ring"
                       Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"
                       Margin="0,0,8,4"/>

            <!-- Üst sıra inputlar -->
            <ComboBox x:Name="cmbPackage" Grid.Row="1" Grid.Column="0" Margin="0,0,8,0"
                      Style="{StaticResource DarkCombo}"
                      IsEditable="True" IsTextSearchEnabled="False"
                      FontSize="11.5" VerticalContentAlignment="Center"
                      ToolTip="Search or select a package name..."/>
            <ComboBox x:Name="cmbArch" Grid.Row="1" Grid.Column="1" Margin="0,0,8,0"
                      Style="{StaticResource DarkCombo}" VerticalContentAlignment="Center"
                      ToolTip="Select the processor architecture (x64 for most modern PCs)">
              <ComboBoxItem Content="x64" IsSelected="True"/>
              <ComboBoxItem Content="x86"/>
              <ComboBoxItem Content="ARM64"/>
              <ComboBoxItem Content="ARM"/>
            </ComboBox>
            <ComboBox x:Name="cmbRing" Grid.Row="1" Grid.Column="2" Margin="0,0,8,0"
                      Style="{StaticResource DarkCombo}" VerticalContentAlignment="Center"
                      ToolTip="Select the Store release channel: Retail (stable), RP (Release Preview), WIS/WIF (Insider)">
              <ComboBoxItem Content="Retail" IsSelected="True"/>
              <ComboBoxItem Content="Preview"/>
              <ComboBoxItem Content="WIS"/>
              <ComboBoxItem Content="WIF"/>
              <ComboBoxItem Content="Slow"/>
              <ComboBoxItem Content="Fast"/>
            </ComboBox>

            <!-- Alt sıra başlığı (URL alanı) -->
            <TextBlock x:Name="lblUrl" Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="3"
                       Text="Microsoft Store URL or Product ID (optional)"
                       Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"
                       Margin="2,0,8,4"/>

            <!-- Alt sıra URL TextBox -->
            <TextBox x:Name="txtUrl" Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="3" Margin="0,0,8,0"
                     Style="{StaticResource DarkTB}" VerticalContentAlignment="Center"
                     Tag="Paste Store URL, Product ID (e.g. 9NBLGGH4NNS1) or PackageFamilyName (e.g. Microsoft.Paint_8wekyb3d8bbwe)"
                     ToolTip="Paste a Microsoft Store URL, Product ID (e.g. 9MSMLRH6LZF3) or PackageFamilyName"/>

            <!-- Sağda tüm yüksekliğe yayılı Fetch butonu -->
            <Button x:Name="btnFetch" Grid.Row="0" Grid.RowSpan="5" Grid.Column="3"
                    Content="Fetch"
                    ToolTip="Fetch packages from Microsoft Store (Enter)"
                    Style="{StaticResource AccentBtn}" VerticalAlignment="Stretch"
                    MinWidth="100" Padding="20,0" FontSize="13" FontWeight="SemiBold"
                    Margin="0,12,0,0"/>
          </Grid>
        </Border>

        <!-- Fetch Packages toolbar (sadece index 0) -->
        <WrapPanel x:Name="fetchToolbar" Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,12">
          <Button x:Name="btnSelectAll"   Content="Select All"       Style="{StaticResource GhostBtn}" Margin="0,0,4,0" ToolTip="Check all packages in the list"/>
          <Button x:Name="btnDeselectAll" Content="Deselect All"     Style="{StaticResource GhostBtn}" Margin="0,0,4,0" ToolTip="Uncheck all packages"/>
          <Button x:Name="btnDownloadAll" Content="Download All"     Style="{StaticResource GhostBtn}" Margin="0,0,4,0" Foreground="{DynamicResource AccentBrush}" ToolTip="Select all and start download"/>
          <Button x:Name="btnRetryFailed" Content="Retry Failed"     Style="{StaticResource GhostBtn}" Margin="0,0,4,0" Foreground="#F59E0B" Visibility="Collapsed" ToolTip="Retry downloading packages that previously failed"/>
          <Button x:Name="btnBrowse"      Content="Browse Packages"  Style="{StaticResource GhostBtn}" Margin="0,0,4,0" ToolTip="Browse for local .appx/.msix package files"/>
          <Button x:Name="btnReset"       Content="Reset"            Style="{StaticResource GhostBtn}" ToolTip="Clear all results and cancel active operations"/>
        </WrapPanel>

        <!-- Installed Apps toolbar (sadece index 1) -->
        <!-- Installed Apps toolbar (sadece index 1) - Fetch sekmesi tarzı kart düzeni -->
        <Grid x:Name="installedToolbar" Grid.Row="2" Margin="0,0,0,12" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- ── ÜST KART: Arama + Filtreler ── -->
          <Border x:Name="installedCard" Grid.Row="0" Background="{DynamicResource CardBrush}"
                  BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10"
                  Padding="12" Margin="0,0,0,8">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="120"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="32"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>

              <!-- Arama -->
              <TextBox x:Name="txtInstalledSearch" Grid.Row="0" Grid.Column="0" Margin="0,0,8,0"
                       Style="{StaticResource DarkTB}" FontSize="11.5" VerticalContentAlignment="Center"
                       Tag="🔍  Filter installed apps..."
                       ToolTip="Type to filter the installed apps list by name"/>
              <ComboBox x:Name="cmbInstalledRing" Grid.Row="0" Grid.Column="1"
                        Style="{StaticResource DarkCombo}" VerticalContentAlignment="Center"
                        ToolTip="Select the Store release channel">
                <ComboBoxItem Content="Retail" IsSelected="True"/>
                <ComboBoxItem Content="Preview"/>
                <ComboBoxItem Content="WIS"/>
                <ComboBoxItem Content="WIF"/>
                <ComboBoxItem Content="Slow"/>
                <ComboBoxItem Content="Fast"/>
              </ComboBox>

              <!-- Alt sıra: Tüm filtreler tek satırda -->
              <StackPanel Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal"
                          VerticalAlignment="Center" Margin="0,10,0,0">
                <CheckBox x:Name="chkInstalledAll" IsThreeState="True"
                          Content="Tümünü Seç" Foreground="{DynamicResource TextSecondary}"
                          FontSize="10" VerticalAlignment="Center" Margin="0,0,16,0"
                          ToolTip="Tümünü işaretle/işaretsiz bırak"/>
                <CheckBox x:Name="chkShowSystemApps"
                          Content="Sistem uygulamaları" Foreground="{DynamicResource TextSecondary}"
                          FontSize="10" VerticalAlignment="Center" Margin="0,0,20,0"
                          ToolTip="Windows sistem bileşenlerini göster"/>
                <TextBlock x:Name="lblInstallLabel" Text="Kurulum:" Foreground="{DynamicResource TextSecondary}"
                           FontSize="10" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <RadioButton x:Name="radAllUsers" Content="Tüm Kullanıcılar"
                             Foreground="{DynamicResource TextPrimary}" FontSize="10"
                             IsChecked="True" Margin="0,0,10,0" VerticalAlignment="Center"/>
                <RadioButton x:Name="radCurrentUser" Content="Mevcut Kullanıcı"
                             Foreground="{DynamicResource TextPrimary}" FontSize="10"
                             VerticalAlignment="Center"/>
              </StackPanel>
            </Grid>
          </Border>

          <!-- ── TAB PROGRESS BAR (Installed sekmesi) ── -->
          <ProgressBar x:Name="progInstalledTab" Grid.Row="1" Style="{StaticResource ThinProg}"
                       Height="3" Value="0" Maximum="100"
                       Margin="0,0,0,6" Visibility="Collapsed"/>

          <!-- ── ALT ŞERIT: Sayaç + Status + Aksiyon Butonları ── -->
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto" MinWidth="80"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <TextBlock x:Name="lblInstalledCount" Grid.Column="0"
                       Text="Scanning..." Foreground="{DynamicResource TextPrimary}"
                       FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"
                       Margin="0,0,12,0" TextTrimming="CharacterEllipsis"/>

            <TextBlock x:Name="lblInstFetchStatus" Grid.Column="1"
                       Text="" Foreground="{DynamicResource TextSecondary}"
                       FontSize="10" VerticalAlignment="Center"
                       TextTrimming="CharacterEllipsis" Margin="0,0,8,0"/>

            <!-- Update Selected (primary action) -->
            <Button x:Name="btnUpdateSelected" Grid.Column="2" Content="Seçileni Güncelle"
                    Style="{StaticResource AccentBtn}" IsEnabled="False" Height="32" Padding="14,0"
                    Margin="0,0,6,0"
                    ToolTip="İşaretli uygulamaları güncellemek üzere kuyruğa al"/>

            <!-- Uninstall Selected (danger) -->
            <Button x:Name="btnUninstallSelected" Grid.Column="3" Content="Seçileni Kaldır"
                    Style="{StaticResource GhostBtn}" IsEnabled="False" Height="32" Padding="14,0"
                    Margin="0,0,6,0"
                    Foreground="#FCA5A5" BorderBrush="#FCA5A5"
                    ToolTip="İşaretli uygulamaları bu bilgisayardan kaldır"/>

            <!-- More (overflow) -->
            <Button x:Name="btnInstMore" Grid.Column="4" Content="⋯"
                    Style="{StaticResource GhostBtn}" Height="32" Width="36" Padding="0"
                    FontSize="14" FontWeight="Bold"
                    Margin="0,0,6,0"
                    ToolTip="Daha fazla">
              <Button.ContextMenu>
                <ContextMenu x:Name="ctxInstMore"
                             Background="{DynamicResource CardBrush}"
                             BorderBrush="{DynamicResource BorderColor}"
                             Foreground="{DynamicResource TextPrimary}">
                  <MenuItem x:Name="ctxInstExportList" Header="Listeyi Dışa Aktar..."
                            Foreground="{DynamicResource TextPrimary}"/>
                </ContextMenu>
              </Button.ContextMenu>
            </Button>

            <!-- Rescan / Cancel (slot paylaşımı — aktif işlem varsa Cancel olur) -->
            <Grid Grid.Column="5">
              <Button x:Name="btnRescan" Content="Yeniden Tara"
                      Style="{StaticResource AccentBtn}" Height="32" Padding="16,0" MinWidth="120"
                      FontWeight="SemiBold"
                      ToolTip="Yüklü uygulamaları yeniden tara"/>
              <Button x:Name="btnInstCancel" Content="✕  İptal"
                      Style="{StaticResource GhostBtn}" Height="32" Padding="16,0" MinWidth="120"
                      FontWeight="SemiBold"
                      Foreground="#FCA5A5" BorderBrush="#FCA5A5"
                      Visibility="Collapsed"
                      ToolTip="Aktif tarama / güncelleme / kaldırma işlemini iptal et"/>
            </Grid>
          </Grid>
          
          <!-- btnExportList legacy (gizli — More menüsünden tetikleniyor) -->
          <Button x:Name="btnExportList" Visibility="Collapsed" Width="0" Height="0"/>
        </Grid>


        <Border Grid.Row="3" Background="{DynamicResource ListBrush}" Margin="0,5,0,0"
                BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="0"
                SnapsToDevicePixels="True" UseLayoutRounding="True" Padding="0,1,0,0">
          <!-- Sekme içerikleri -->
          <Grid>
            <!-- Fetch Packages (index 0) -->
            <DataGrid x:Name="lvPackages" Style="{StaticResource PkgGrid}" Visibility="Visible">
              <DataGrid.ContextMenu>
                <ContextMenu Background="{DynamicResource MenuBg}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1">
                  <MenuItem x:Name="ctxCopyName"    Header="Copy File Name"          Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxCopyVersion" Header="Copy Version"            Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxCopyUrl"     Header="Copy Download URL"       Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxCopyStoreId" Header="Copy Store ID"           Foreground="{DynamicResource TextPrimary}"/>
                  <Separator Background="{DynamicResource InputBorder}"/>
                  <MenuItem x:Name="ctxSelectVer"   Header="Select Version..."       Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxFileInfo"    Header="File Information..."     Foreground="{DynamicResource TextPrimary}"/>
                  <Separator Background="{DynamicResource InputBorder}"/>
                  <MenuItem x:Name="ctxOpenUrl"     Header="Open URL in Browser"     Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxOpenStore"   Header="Open in Microsoft Store" Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxOpenFolder"  Header="Open Download Folder"    Foreground="{DynamicResource TextPrimary}"/>
                  <Separator Background="{DynamicResource InputBorder}"/>
                  <MenuItem x:Name="ctxRetryDl"     Header="Retry Download"          Foreground="#F59E0B" FontWeight="SemiBold"/>
                  <MenuItem x:Name="ctxToggle"      Header="Select / Deselect"       Foreground="{DynamicResource TextPrimary}"/>
                </ContextMenu>
              </DataGrid.ContextMenu>
              <DataGrid.Columns>
                <DataGridTemplateColumn Width="44" MinWidth="44" CanUserResize="False" CanUserSort="False">
                  <DataGridTemplateColumn.Header>
                    <CheckBox x:Name="chkAll" IsThreeState="True" Foreground="{DynamicResource TextSecondary}"/>
                  </DataGridTemplateColumn.Header>
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding IsChecked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                HorizontalAlignment="Center" VerticalAlignment="Center" Margin="4,0"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn Header="Package" Binding="{Binding FileName}" Width="*" MinWidth="120" IsReadOnly="True">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="Padding"           Value="12,10"/>
                      <Setter Property="TextTrimming"      Value="CharacterEllipsis"/>
                      <Setter Property="VerticalAlignment" Value="Center"/>
                      <Setter Property="Foreground"        Value="{Binding RowFg}"/>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="130" MinWidth="90" IsReadOnly="True">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="Padding"           Value="12,10"/>
                      <Setter Property="VerticalAlignment" Value="Center"/>
                      <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Size" Binding="{Binding SizeText}" Width="100" MinWidth="70" IsReadOnly="True">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="Padding"           Value="12,10"/>
                      <Setter Property="VerticalAlignment" Value="Center"/>
                      <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTemplateColumn Header="Status" Width="170" MinWidth="130" IsReadOnly="True">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <Border CornerRadius="5" Padding="8,3" Margin="8,6"
                              Background="{Binding StatusBg}" HorizontalAlignment="Left">
                        <TextBlock Text="{Binding Status}" Foreground="{Binding StatusFg}"
                                   FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
                      </Border>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
              </DataGrid.Columns>
            </DataGrid>

            <!-- Installed Apps (index 1) -->
            <DataGrid x:Name="lvInstalled" Style="{StaticResource PkgGrid}" Visibility="Collapsed">
              <DataGrid.ContextMenu>
                <ContextMenu Background="{DynamicResource MenuBg}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1">
                  <MenuItem x:Name="ctxInstUninstall" Header="Uninstall Application" Foreground="#FCA5A5" FontWeight="Bold"/>
                  <Separator/>
                  <MenuItem x:Name="ctxInstCopyPfn"   Header="Copy PackageFamilyName" Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxInstCopyName"  Header="Copy Name"              Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxInstCopyVer"   Header="Copy Installed Version" Foreground="{DynamicResource TextPrimary}"/>
                  <Separator/>
                  <MenuItem x:Name="ctxInstOpenStore"  Header="Open in Microsoft Store"  Foreground="{DynamicResource TextPrimary}"/>
                  <MenuItem x:Name="ctxInstOpenFolder" Header="Open Install Folder"       Foreground="{DynamicResource TextPrimary}"/>
                  <Separator/>
                  <MenuItem x:Name="ctxInstHideApp"    Header="Hide App"                  Foreground="#FDE68A" FontWeight="SemiBold"/>
                </ContextMenu>
              </DataGrid.ContextMenu>
              <DataGrid.Columns>
                <!-- Checkbox -->
                <DataGridTemplateColumn Width="44" MinWidth="44" CanUserResize="False" CanUserSort="False">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding IsChecked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <!-- Application - esnek genişlik, en az 120 -->
                <DataGridTextColumn Header="Application" Binding="{Binding FileName}" Width="*" MinWidth="120" IsReadOnly="True">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="Padding" Value="12,10"/>
                      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                      <Setter Property="VerticalAlignment" Value="Center"/>
                      <Setter Property="Foreground" Value="{Binding RowFg}"/>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <!-- Installed Version - sabit, en az 100 -->
                <DataGridTextColumn Header="Installed Version" Binding="{Binding Version}" Width="150" MinWidth="110" IsReadOnly="True">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="Padding" Value="12,10"/>
                      <Setter Property="VerticalAlignment" Value="Center"/>
                      <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <!-- Store Version - sabit, en az 100 -->
                <DataGridTextColumn Header="Store Version" Binding="{Binding SizeText}" Width="150" MinWidth="110" IsReadOnly="True">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="Padding" Value="12,10"/>
                      <Setter Property="VerticalAlignment" Value="Center"/>
                      <Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <!-- Status - sabit 110, içeriği HorizontalAlignment="Stretch" ile tam doldur -->
                <DataGridTemplateColumn Header="Status" Width="150" MinWidth="110" IsReadOnly="True">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <Border CornerRadius="5" Padding="8,3" Margin="8,6"
                              Background="{Binding StatusBg}" HorizontalAlignment="Left">
                        <TextBlock Text="{Binding Status}" Foreground="{Binding StatusFg}"
                                   FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
                      </Border>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
              </DataGrid.Columns>
            </DataGrid>

            <!-- Downloads (index 2) -->
            <ScrollViewer x:Name="pnlDownloads" Visibility="Collapsed"
                          VerticalScrollBarVisibility="Auto" Background="Transparent">
              <StackPanel Margin="16">
                <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1"
                        CornerRadius="10" Padding="16" Margin="0,0,0,12">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                      <TextBlock x:Name="lblDlOverall" Text="OVERALL PROGRESS" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold" Margin="0,0,0,4"/>
                      <TextBlock x:Name="lblDlPercent" Text="0%" Foreground="{DynamicResource TextPrimary}" FontSize="28" FontWeight="Bold"/>
                      <ProgressBar x:Name="progDownload" Height="4" Margin="0,8,0,0"
                                   Background="{DynamicResource BorderColor}" Foreground="#F59E0B" BorderThickness="0"
                                   Value="0" Maximum="100"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Margin="24,0" VerticalAlignment="Center">
                      <TextBlock x:Name="lblDlSpeedHdr" Text="SPEED" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"/>
                      <TextBlock x:Name="lblDlSpeed" Text="0 MB/s" Foreground="{DynamicResource TextPrimary}" FontSize="13" FontWeight="SemiBold"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Margin="0,0,24,0" VerticalAlignment="Center">
                      <TextBlock x:Name="lblDlEtaHdr" Text="ETA" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"/>
                      <TextBlock x:Name="lblDlEta" Text="--:--:--" Foreground="{DynamicResource TextPrimary}" FontSize="13" FontWeight="SemiBold"/>
                    </StackPanel>
                    <StackPanel Grid.Column="3" VerticalAlignment="Center">
                      <TextBlock x:Name="lblDlQueuedHdr" Text="QUEUED" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"/>
                      <TextBlock x:Name="lblDlQueued" Text="0 / 0" Foreground="{DynamicResource TextPrimary}" FontSize="13" FontWeight="SemiBold"/>
                    </StackPanel>
                  </Grid>
                </Border>
                <ItemsControl x:Name="dlCards">
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1"
                              CornerRadius="8" Padding="12" Margin="0,0,0,8">
                        <Grid>
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                          </Grid.ColumnDefinitions>
                          <StackPanel>
                            <TextBlock Text="{Binding FileName}" Foreground="{DynamicResource TextPrimary}" FontSize="11" FontWeight="SemiBold"/>
                            <TextBlock Text="{Binding Status}" Foreground="{DynamicResource TextSecondary}" FontSize="10" Margin="0,2,0,4"/>
                            <ProgressBar Height="3" Background="{DynamicResource BorderColor}" Foreground="{Binding StatusBg}"
                                         BorderThickness="0" Value="{Binding SizeBytes}" Maximum="100"/>
                          </StackPanel>
                        </Grid>
                      </Border>
                    </DataTemplate>
                  </ItemsControl.ItemTemplate>
                </ItemsControl>
                <!-- İndirme klasörü boşken gösterilen mesaj / Empty downloads message -->
                <TextBlock x:Name="lblDlEmpty"
                           Text="No downloaded packages found. Fetch and download packages from the Fetch Packages tab."
                           Foreground="{DynamicResource TextSecondary}"
                           FontSize="12" Opacity="0.5"
                           HorizontalAlignment="Center"
                           TextWrapping="Wrap" TextAlignment="Center"
                           Margin="40,32" Visibility="Collapsed"/>
                <!-- Log -->
                <Border Background="{DynamicResource ListBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1"
                        CornerRadius="8" Padding="12" Margin="0,8,0,0">
                  <StackPanel>
                    <TextBlock x:Name="lblInstallerLog" Text="INSTALLER LOG" Foreground="{DynamicResource TextSecondary}" FontSize="9"
                               FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <TextBox x:Name="txtLog" Background="Transparent" Foreground="{DynamicResource TextSecondary}"
                             BorderThickness="0" FontFamily="Consolas" FontSize="10"
                             IsReadOnly="True" TextWrapping="Wrap" MaxHeight="180"
                             Text=""/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Settings (index 3) -->
            <ScrollViewer x:Name="pnlSettings" Visibility="Collapsed"
                          VerticalScrollBarVisibility="Auto" Background="Transparent">
              <StackPanel Margin="16">
                <!-- General -->
                <TextBlock x:Name="lblSetGeneral" Text="GENERAL" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="16" Margin="0,0,0,16">
                  <StackPanel>
                    <Grid Margin="0,0,0,14">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetLang" Text="Language" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetLangSub" Text="UI display language" Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                      </StackPanel>
                      <ComboBox x:Name="cmbSettingsLang" Grid.Column="1" Style="{StaticResource DarkCombo}" Width="100">
                        <ComboBoxItem Content="English" IsSelected="True"/>
                        <ComboBoxItem Content="Türkçe"/>
                      </ComboBox>
                    </Grid>
                    <Separator Background="{DynamicResource BorderColor}" Margin="0,0,0,14"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetTheme" Text="Theme" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetThemeSub" Text="Dark / Light appearance" Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                      </StackPanel>
                      <ComboBox x:Name="cmbSettingsTheme" Grid.Column="1" Style="{StaticResource DarkCombo}" Width="100">
                        <ComboBoxItem Content="Dark" IsSelected="True"/>
                        <ComboBoxItem Content="Light"/>
                        <ComboBoxItem Content="iTunes"/>
                        <ComboBoxItem Content="Intel"/>
                        <ComboBoxItem Content="Dracula"/>
                        <ComboBoxItem Content="Nord"/>
                        <ComboBoxItem Content="Solarized Dark"/>
                        <ComboBoxItem Content="Solarized Light"/>
                        <ComboBoxItem Content="Monokai"/>
                        <ComboBoxItem Content="Synthwave"/>
                        <ComboBoxItem Content="Cyberpunk"/>
                        <ComboBoxItem Content="Gruvbox"/>
                        <ComboBoxItem Content="Tokyo Night"/>
                        <ComboBoxItem Content="Catppuccin"/>
                        <ComboBoxItem Content="GitHub Dark"/>
                      </ComboBox>
                    </Grid>
                    <Separator Background="{DynamicResource BorderColor}" Margin="0,14,0,14"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetWave" Text="Background Overlay" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetWaveSub" Text="Select background effect" Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                      </StackPanel>
                        <ComboBox x:Name="cmbSettingsOverlay" Grid.Column="1" Style="{StaticResource DarkCombo}" Width="100" VerticalAlignment="Center" Margin="12,0,0,0">
                        <ComboBoxItem Content="None" IsSelected="True"/>
                        <ComboBoxItem Content="Wave"/>
                        <ComboBoxItem Content="Grid"/>
                      </ComboBox>
                    </Grid>
                  </StackPanel>
                </Border>
                <!-- Downloads -->
                <TextBlock x:Name="lblSetDownloads" Text="DOWNLOADS" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="16" Margin="0,0,0,16">
                  <StackPanel>
                    <Grid Margin="0,0,0,14">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetDlFolder" Text="Default Download Folder" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblDlFolder" Text="" Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                      </StackPanel>
                      <Button x:Name="btnChangeDlFolder" Grid.Column="1" Content=""
                              Style="{StaticResource GhostBtn}" Width="70"/>
                    </Grid>
                    <Separator Background="{DynamicResource BorderColor}" Margin="0,0,0,14"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetArch" Text="Architecture" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetArchSub" Text="Default package architecture" Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                      </StackPanel>
                      <ComboBox x:Name="cmbSettingsArch" Grid.Column="1" Style="{StaticResource DarkCombo}" Width="100">
                        <ComboBoxItem Content="x64" IsSelected="True"/>
                        <ComboBoxItem Content="x86"/>
                        <ComboBoxItem Content="ARM64"/>
                        <ComboBoxItem Content="ARM"/>
                      </ComboBox>
                    </Grid>
                    <Separator Background="{DynamicResource BorderColor}" Margin="0,14,0,14"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetRing" Text="Default Ring" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetRingSub" Text="Store release ring" Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                      </StackPanel>
                      <ComboBox x:Name="cmbSettingsRing" Grid.Column="1" Style="{StaticResource DarkCombo}" Width="100">
                        <ComboBoxItem Content="Retail" IsSelected="True"/>
                        <ComboBoxItem Content="Preview"/>
                        <ComboBoxItem Content="WIS"/>
                        <ComboBoxItem Content="WIF"/>
                        <ComboBoxItem Content="Slow"/>
                        <ComboBoxItem Content="Fast"/>
                      </ComboBox>
                    </Grid>
                  </StackPanel>
                </Border>
                <!-- Installation -->
                <TextBlock x:Name="lblSetInstall" Text="INSTALLATION" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="16" Margin="0,0,0,16">
                  <StackPanel>
                    <Grid Margin="0,0,0,14">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetForceReinstall" Text="Force Reinstall" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetForceReinstallSub" Text="Remove existing version before installing (always reinstall)" Foreground="{DynamicResource TextSecondary}" FontSize="10" TextWrapping="Wrap" MaxWidth="420"/>
                      </StackPanel>
                      <CheckBox x:Name="chkForceReinstall" Grid.Column="1" VerticalAlignment="Center" Margin="12,0,0,0"/>
                    </Grid>
                    <Separator Background="{DynamicResource BorderColor}" Margin="0,0,0,14"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetDeleteAfterInstall" Text="Delete After Install" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetDeleteAfterInstallSub" Text="Delete the downloaded package file after successful installation" Foreground="{DynamicResource TextSecondary}" FontSize="10" TextWrapping="Wrap" MaxWidth="420"/>
                      </StackPanel>
                      <CheckBox x:Name="chkDeleteAfterInstall" Grid.Column="1" VerticalAlignment="Center" Margin="12,0,0,0"/>
                    </Grid>
                  </StackPanel>
                </Border>
                <!-- Apply Settings Button -->
                <Button x:Name="btnApplySettings"
                        Content=""
                        Style="{StaticResource AccentBtn}"
                        HorizontalAlignment="Stretch"
                        Padding="0,12"
                        FontSize="13"
                        Margin="0,0,0,16"/>
                <!-- Winget Tools -->
                <TextBlock x:Name="lblSetWingetHdr" Text="WINGET" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="16" Margin="0,0,0,16">
                  <StackPanel>
                    <Grid Margin="0,0,0,12">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetWingetUpdate" Text="Winget Güncelle" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblSetWingetUpdateSub" Text="Hash mismatch hatalarını önlemek için winget'i en son sürüme günceller" Foreground="{DynamicResource TextSecondary}" FontSize="10" TextWrapping="Wrap" MaxWidth="380"/>
                      </StackPanel>
                      <Button x:Name="btnUpdateWinget" Grid.Column="1" Content="⬆ Güncelle" Style="{StaticResource AccentBtn}" Padding="16,6" FontSize="11" VerticalAlignment="Center" Margin="12,0,0,0"/>
                    </Grid>
                    <Separator Background="{DynamicResource BorderColor}" Margin="0,0,0,12"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <StackPanel>
                        <TextBlock x:Name="lblSetWingetVersion" Text="Mevcut Versiyon" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblWingetVersionVal" Text="Kontrol ediliyor..." Foreground="{DynamicResource TextSecondary}" FontSize="10"/>
                      </StackPanel>
                      <Button x:Name="btnCheckWingetVersion" Grid.Column="1" Content="↻ Kontrol Et" Style="{StaticResource GhostBtn}" Padding="12,6" FontSize="11" VerticalAlignment="Center" Margin="12,0,0,0"/>
                    </Grid>
                    <TextBlock x:Name="lblWingetUpdateStatus" Text="" Foreground="#86EFAC" FontSize="10" Margin="0,10,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
                    <ProgressBar x:Name="progWingetUpdate" Style="{StaticResource ThinProg}" Value="0" Maximum="100"
                                 Margin="0,6,0,0" Visibility="Collapsed"/>
                  </StackPanel>
                </Border>
                <!-- About -->
                <TextBlock x:Name="lblSetAbout" Text="ABOUT" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="16">
                  <StackPanel>
                    <TextBlock Text="Microsoft Store App Manager" Foreground="{DynamicResource TextPrimary}" FontSize="14" FontWeight="Bold"/>
                    <TextBlock Text="v3.1.3  ·  WPF Edition" Foreground="{DynamicResource TextSecondary}" FontSize="11" Margin="0,4,0,8"/>
                    <TextBlock x:Name="lblSetRuntimeHdr" Text="RUNTIME" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"/>
                    <TextBlock x:Name="lblRuntime" Text="PowerShell 5.1" Foreground="{DynamicResource TextPrimary}" FontSize="11" Margin="0,2,0,8"/>
                    <TextBlock x:Name="lblSetTargetOS" Text="TARGET OS" Foreground="{DynamicResource TextSecondary}" FontSize="9" FontWeight="SemiBold"/>
                    <TextBlock Text="Windows 10 / 11" Foreground="{DynamicResource TextPrimary}" FontSize="11" Margin="0,2,0,0"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>


            <!-- Winget (index 5) -->
            <Grid x:Name="pnlWinget" Visibility="Collapsed" Margin="16,12,16,12">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>

              <!-- Row 0: Ana toolbar — Arama · Source · Yenile · Güncelle -->
              <Border Grid.Row="0" Background="{DynamicResource CardBrush}" CornerRadius="8" Margin="0,0,0,8" Padding="12,10">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox x:Name="txtWingetQuery" Grid.Column="0" Height="32"
                           Style="{StaticResource DarkTB}" VerticalContentAlignment="Center"
                           Tag="Yüklü paketlerde ara..."/>
                  <ComboBox x:Name="cmbWingetSource" Grid.Column="1" Width="120" Height="32" Margin="8,0,0,0"
                            Style="{StaticResource DarkCombo}"
                            ToolTip="Kaynak filtresi (winget / msstore / tümü)"/>
                  <Button x:Name="btnWingetRefresh" Grid.Column="2" Content="↻ Yenile"
                          Style="{StaticResource GhostBtn}" Height="32" MinWidth="90" Padding="12,0" Margin="8,0,0,0"
                          ToolTip="Paket listesini yeniden yükle"/>
                  <Button x:Name="btnWingetUpgrade" Grid.Column="3" Content="⬆ Tümünü Güncelle"
                          Style="{StaticResource AccentBtn}" Height="32" MinWidth="170" Padding="14,0" Margin="8,0,0,0" IsEnabled="False"
                          ToolTip="Bekleyen güncellemeleri yükle (seçim varsa sadece seçilenler)"/>
                </Grid>
              </Border>

              <!-- Row 1: Filtre satırı + sayaç -->
              <Grid Grid.Row="1" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <CheckBox x:Name="chkWingetShowUpdates" Grid.Column="0" Content="Yalnızca Güncellemeleri Göster"
                          Foreground="{DynamicResource TextSecondary}" FontSize="11" VerticalAlignment="Center"/>
                <CheckBox x:Name="chkWingetAllUsers" Grid.Column="1" Content="Tüm Kullanıcılar"
                          Foreground="{DynamicResource TextSecondary}" FontSize="11" Margin="16,0,0,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="lblWingetCount" Grid.Column="2" Text="0 paket"
                           Foreground="{DynamicResource TextSecondary}" FontSize="11"
                           VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
              </Grid>

              <!-- Row 2: Progress + status (tek satırda) -->
              <Grid Grid.Row="2" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ProgressBar x:Name="progWinget" Grid.Column="0" Style="{StaticResource ThinProg}" Value="0" Maximum="100"
                             Height="3" VerticalAlignment="Center" Visibility="Collapsed"/>
                <TextBlock x:Name="lblWingetStatus" Grid.Column="1" Text=""
                           Foreground="{DynamicResource TextSecondary}" FontSize="11"
                           VerticalAlignment="Center" Margin="12,0,0,0" TextTrimming="CharacterEllipsis"/>
              </Grid>

              <!-- DataGrid with CheckBox + Loading Overlay -->
              <Border Grid.Row="3" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1"
                      CornerRadius="8" ClipToBounds="True">
              <Grid>
              <DataGrid x:Name="lvWinget" Style="{StaticResource PkgGrid}"
                        IsReadOnly="False" SelectionMode="Extended" CanUserSortColumns="True" AutoGenerateColumns="False">
                <DataGrid.ContextMenu>
                  <ContextMenu Background="{DynamicResource MenuBg}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1">
                    <MenuItem x:Name="ctxWingetCopyId"    Header="Copy ID"              Foreground="{DynamicResource TextPrimary}"/>
                    <MenuItem x:Name="ctxWingetCopyName"  Header="Copy Name"            Foreground="{DynamicResource TextPrimary}"/>
                    <Separator Background="{DynamicResource InputBorder}"/>
                    <MenuItem x:Name="ctxWingetHide"      Header="Hide Update"          Foreground="#FDE68A" FontWeight="SemiBold"/>
                  </ContextMenu>
                </DataGrid.ContextMenu>
                <DataGrid.RowStyle>
                  <Style TargetType="DataGridRow">
                    <Setter Property="Background" Value="Transparent"/>
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding HasUpdate}" Value="True">
                        <Setter Property="Background" Value="#18A78BFF"/>
                      </DataTrigger>
                    </Style.Triggers>
                  </Style>
                </DataGrid.RowStyle>
                <DataGrid.Columns>
                  <DataGridCheckBoxColumn Binding="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="40">
                    <DataGridCheckBoxColumn.HeaderTemplate>
                      <DataTemplate>
                        <CheckBox x:Name="chkWingetHeader" IsChecked="False" IsThreeState="True"
                                  VerticalAlignment="Center" HorizontalAlignment="Center"/>
                      </DataTemplate>
                    </DataGridCheckBoxColumn.HeaderTemplate>
                    <DataGridCheckBoxColumn.ElementStyle>
                      <Style TargetType="CheckBox">
                        <Setter Property="HorizontalAlignment" Value="Center"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                      </Style>
                    </DataGridCheckBoxColumn.ElementStyle>
                    <DataGridCheckBoxColumn.EditingElementStyle>
                      <Style TargetType="CheckBox">
                        <Setter Property="HorizontalAlignment" Value="Center"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                      </Style>
                    </DataGridCheckBoxColumn.EditingElementStyle>
                  </DataGridCheckBoxColumn>
                  <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="2*" MinWidth="120" IsReadOnly="True">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock">
                        <Setter Property="Padding" Value="8,10"/>
                        <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                        <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                      </Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="Id" Binding="{Binding Id}" Width="*" MinWidth="100" IsReadOnly="True">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock">
                        <Setter Property="Padding" Value="8,10"/>
                        <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                        <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                        <Setter Property="FontFamily" Value="Consolas"/>
                        <Setter Property="FontSize" Value="11"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                      </Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="Installed" Binding="{Binding InstalledVersion}" Width="100" MinWidth="80" IsReadOnly="True">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock">
                        <Setter Property="Padding" Value="8,10"/>
                        <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                      </Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTemplateColumn Header="Available" Width="120" MinWidth="90" IsReadOnly="True" SortMemberPath="AvailableVersion">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0">
                          <!-- Spinner: guncelleme sirasinda goster -->
                          <TextBlock Text="{Binding StatusText}" Visibility="{Binding SpinnerVisibility}"
                                     FontFamily="Consolas" FontSize="13" Foreground="#A78BFA"
                                     VerticalAlignment="Center" Margin="0,0,5,0"/>
                          <!-- Versiyon metni -->
                          <TextBlock VerticalAlignment="Center">
                            <TextBlock.Style>
                              <Style TargetType="TextBlock">
                                <Setter Property="Text" Value="{Binding AvailableVersion}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/>
                                <Setter Property="FontWeight" Value="Normal"/>
                                <Setter Property="FontSize" Value="12"/>
                                <Style.Triggers>
                                  <DataTrigger Binding="{Binding HasUpdate}" Value="True">
                                    <Setter Property="Foreground" Value="#A78BFA"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                  </DataTrigger>
                                </Style.Triggers>
                              </Style>
                            </TextBlock.Style>
                          </TextBlock>
                        </StackPanel>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="Durum" Width="160" IsReadOnly="True" SortMemberPath="RowStatus">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <Border CornerRadius="4" Padding="6,2" Margin="8,5"
                                Background="{Binding RowStatusBg}"
                                Visibility="{Binding RowStatusVisibility}"
                                HorizontalAlignment="Left">
                          <TextBlock Text="{Binding RowStatus}" Foreground="{Binding RowStatusFg}"
                                     FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        </Border>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="Source" Binding="{Binding Source}" Width="70" MinWidth="60" IsReadOnly="True">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock">
                        <Setter Property="Padding" Value="8,10"/>
                        <Setter Property="Foreground" Value="{DynamicResource TextDisabled}"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                      </Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                </DataGrid.Columns>
              </DataGrid>

              <!-- Loading Overlay - DataGrid uzerinde spinner + metin -->
              <Border x:Name="pnlWingetLoading" Visibility="Collapsed"
                      Background="{DynamicResource ListBrush}"
                      HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Orientation="Vertical">
                  <!-- Donen spinner halkasi -->
                  <Grid Width="56" Height="56" HorizontalAlignment="Center" Margin="0,0,0,18">
                    <Ellipse Width="56" Height="56" Stroke="{DynamicResource BorderColor}" StrokeThickness="4" Opacity="0.3"/>
                    <Path x:Name="pathWingetSpinner" Stroke="#A78BFA" StrokeThickness="4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                          Data="M 28,4 A 24,24 0 0 1 51.5,32"
                          RenderTransformOrigin="0.5,0.5">
                      <Path.RenderTransform>
                        <RotateTransform x:Name="rtWingetSpinner" Angle="0"/>
                      </Path.RenderTransform>
                      <Path.Triggers>
                        <EventTrigger RoutedEvent="Path.Loaded">
                          <BeginStoryboard>
                            <Storyboard RepeatBehavior="Forever">
                              <DoubleAnimation Storyboard.TargetName="rtWingetSpinner"
                                               Storyboard.TargetProperty="Angle"
                                               From="0" To="360" Duration="0:0:0.9"/>
                            </Storyboard>
                          </BeginStoryboard>
                        </EventTrigger>
                      </Path.Triggers>
                    </Path>
                  </Grid>
                  <TextBlock x:Name="lblWingetLoading" Text="Yükleniyor..."
                             Foreground="{DynamicResource TextPrimary}" FontSize="13" FontWeight="SemiBold"
                             HorizontalAlignment="Center" Margin="0,0,0,6"/>
                  <TextBlock x:Name="lblWingetLoadingSub" Text="Yüklü paketler taranıyor — bu birkaç saniye sürebilir"
                             Foreground="{DynamicResource TextSecondary}" FontSize="11"
                             HorizontalAlignment="Center" TextAlignment="Center" MaxWidth="360" TextWrapping="Wrap"/>
                  <!-- Pulse noktalari -->
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,16,0,0">
                    <Ellipse Width="6" Height="6" Margin="3,0" Fill="#A78BFA">
                      <Ellipse.Triggers>
                        <EventTrigger RoutedEvent="Ellipse.Loaded">
                          <BeginStoryboard>
                            <Storyboard RepeatBehavior="Forever">
                              <DoubleAnimation Storyboard.TargetProperty="Opacity" From="0.25" To="1.0" Duration="0:0:0.6" AutoReverse="True"/>
                            </Storyboard>
                          </BeginStoryboard>
                        </EventTrigger>
                      </Ellipse.Triggers>
                    </Ellipse>
                    <Ellipse Width="6" Height="6" Margin="3,0" Fill="#A78BFA">
                      <Ellipse.Triggers>
                        <EventTrigger RoutedEvent="Ellipse.Loaded">
                          <BeginStoryboard>
                            <Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.2">
                              <DoubleAnimation Storyboard.TargetProperty="Opacity" From="0.25" To="1.0" Duration="0:0:0.6" AutoReverse="True"/>
                            </Storyboard>
                          </BeginStoryboard>
                        </EventTrigger>
                      </Ellipse.Triggers>
                    </Ellipse>
                    <Ellipse Width="6" Height="6" Margin="3,0" Fill="#A78BFA">
                      <Ellipse.Triggers>
                        <EventTrigger RoutedEvent="Ellipse.Loaded">
                          <BeginStoryboard>
                            <Storyboard RepeatBehavior="Forever" BeginTime="0:0:0.4">
                              <DoubleAnimation Storyboard.TargetProperty="Opacity" From="0.25" To="1.0" Duration="0:0:0.6" AutoReverse="True"/>
                            </Storyboard>
                          </BeginStoryboard>
                        </EventTrigger>
                      </Ellipse.Triggers>
                    </Ellipse>
                  </StackPanel>
                </StackPanel>
              </Border>
              </Grid>
              </Border>
            </Grid>
            <!-- History (index 4) -->
            <Grid>
              <DataGrid x:Name="lvHistory" Style="{StaticResource PkgGrid}" Visibility="Collapsed">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Time"    Binding="{Binding Version}"  Width="75" IsReadOnly="True">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock"><Setter Property="Padding" Value="12,10"/><Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/></Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="Package" Binding="{Binding FileName}" Width="2*" IsReadOnly="True">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock"><Setter Property="Padding" Value="12,10"/><Setter Property="Foreground" Value="{Binding RowFg}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="Size"    Binding="{Binding SizeText}" Width="90" IsReadOnly="True">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock"><Setter Property="Padding" Value="12,10"/><Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/><Setter Property="HorizontalAlignment" Value="Right"/></Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTemplateColumn Header="Result" Width="120" IsReadOnly="True">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <Border CornerRadius="5" Padding="8,3" Margin="8,6"
                                Background="{Binding StatusBg}" HorizontalAlignment="Left">
                          <TextBlock Text="{Binding Status}" Foreground="{Binding StatusFg}"
                                     FontSize="11" FontWeight="Medium"/>
                        </Border>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
              <!-- Geçmiş boşken gösterilen mesaj / Empty history message -->
              <TextBlock x:Name="lblHistoryEmpty"
                         Text="Henüz geçmiş yok. Kurulan veya indirilen paketler burada görünecek."
                         Foreground="{DynamicResource TextSecondary}"
                         FontSize="12" Opacity="0.5"
                         HorizontalAlignment="Center" VerticalAlignment="Center"
                         TextWrapping="Wrap" TextAlignment="Center"
                         Margin="40,0" Visibility="Collapsed"/>
            </Grid>

          </Grid>
        </Border>

        <StackPanel x:Name="statusBar" Grid.Row="4" Margin="0,10,0,0">
          <ProgressBar x:Name="progMain" Style="{StaticResource ThinProg}" Value="0" Maximum="100"/>
          <TextBlock x:Name="lblStatus" Text="Ready" FontSize="11" Margin="0,5,0,0"
                     Foreground="{DynamicResource TextSecondary}"/>
        </StackPanel>

        <Grid x:Name="bottomBar" Grid.Row="5" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="btnDownload"   Grid.Column="0" Content="Download Selected"
                  Style="{StaticResource AccentBtn}" Margin="0,0,8,0" IsEnabled="False"
                  ToolTip="Download checked packages to the download folder"/>
          <Button x:Name="btnInstall"    Grid.Column="1" Content="Install Apps"
                  Style="{StaticResource GhostBtn}"  Margin="0,0,8,0" IsEnabled="False"
                  ToolTip="Install downloaded packages on this PC"/>
          <Button x:Name="btnOpenFolder" Grid.Column="2" Content="Open Download Folder"
                  Style="{StaticResource GhostBtn}"  Margin="0,0,8,0"
                  ToolTip="Open the download folder in Windows Explorer"/>
          <Button x:Name="btnCancel"     Grid.Column="3" Content="✕ Cancel"
                  Style="{StaticResource GhostBtn}"
                  Foreground="#FCA5A5" BorderBrush="#FCA5A5"
                  Visibility="Collapsed" MinWidth="90"
                  ToolTip="Cancel the current operation"/>
        </Grid>
      </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ── Kontrolleri Bağlama / Bind Controls ─────────────────────────────────
$reader = New-Object System.Xml.XmlNodeReader $xaml
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.Forms.MessageBox]::Show("XAML yüklenirken hata:`n$($_.Exception.Message)", "Hata", 'OK', 'Error')
    return
}

# ── WindowChrome Yapılandırması / WindowChrome Configuration ───────────
try {
    $chrome = New-Object System.Windows.Shell.WindowChrome
    $chrome.CaptionHeight         = 36
    $chrome.ResizeBorderThickness = New-Object System.Windows.Thickness 6
    $chrome.CornerRadius          = New-Object System.Windows.CornerRadius 0
    $chrome.GlassFrameThickness   = New-Object System.Windows.Thickness 0
    $chrome.UseAeroCaptionButtons = $false
    [System.Windows.Shell.WindowChrome]::SetWindowChrome($window, $chrome)
} catch {
}

# ── İsimlendirilmiş Kontrolleri Bul / Find Named Controls ────────────
$script:Controls = @{}
$xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $name = $_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
    if (-not $name) { $name = $_.Name }
    if ($name) {
        $ctrl = $window.FindName($name)
        if ($ctrl) { $script:Controls[$name] = $ctrl }
    }
}

$named = @(
    'NavList',
    'navFetch','navInstalled','navDownloads','navSettings','navHistory',
    'lblPageTitle','lblPageSub','lblUrl',
    'lblFieldPackage','lblFieldArch','lblFieldRing','pageHeader',
    'btnTheme','btnLang',
    'cmbPackage','cmbArch','cmbRing','txtUrl','btnFetch',
    'fetchToolbar','installedToolbar','inputCard',
    'btnSelectAll','btnDeselectAll','btnDownloadAll','btnBrowse','btnReset',
    'cmbInstalledRing','btnRescan','btnUpdateSelected','btnUninstallSelected','btnExportList',
    'lblInstalledCount','lblInstFetchStatus','txtInstalledSearch',
    'lblRingLabel','lblInstallLabel',
    'chkInstalledAll','chkShowSystemApps','radAllUsers','radCurrentUser',
    'ctxInstUninstall','ctxInstCopyPfn','ctxInstCopyName','ctxInstCopyVer','ctxInstOpenStore','ctxInstOpenFolder',
    'lvPackages','lvInstalled','pnlDownloads','pnlSettings','lvHistory',
    'chkAll',
    'ctxCopyName','ctxCopyVersion','ctxCopyUrl','ctxCopyStoreId',
    'ctxSelectVer','ctxFileInfo','ctxOpenUrl','ctxOpenStore','ctxOpenFolder','ctxRetryDl','ctxToggle',
    'btnRetryFailed',
    'progMain','lblStatus',
    'btnDownload','btnInstall','btnOpenFolder','btnCancel',
    'lblDlPercent','progDownload','lblDlSpeed','lblDlEta','lblDlQueued','dlCards','txtLog',
    'cmbSettingsLang','lblDlFolder','btnChangeDlFolder','lblRuntime','btnApplySettings','cmbSettingsTheme','cmbSettingsArch','cmbSettingsRing',
    'outerWindowBorder','titleAccentLine','txtTitleBar','btnMinimize','btnMaximize','btnClose',
    'lblSetGeneral','lblSetDownloads','lblSetAbout','lblSetInstall',
    'lblSetLang','lblSetLangSub','lblSetTheme','lblSetThemeSub',
    'lblSetDlFolder','lblSetArch','lblSetArchSub','lblSetRing','lblSetRingSub',
    'lblSetRuntimeHdr','lblSetTargetOS',
    'lblSetForceReinstall','lblSetForceReinstallSub','chkForceReinstall',
    'lblSetDeleteAfterInstall','lblSetDeleteAfterInstallSub','chkDeleteAfterInstall',
    'lblDlOverall','lblDlSpeedHdr','lblDlEtaHdr','lblDlQueuedHdr','lblInstallerLog',
    'lblHistoryEmpty','lblDlEmpty',
    'waveCanvas','gridCanvas','watermarkCanvas','cmbSettingsOverlay','lblSetWave','lblSetWaveSub',
    'bottomBar','statusBar',
    'pnlWinget','txtWingetQuery','btnWingetRefresh','chkWingetShowUpdates','chkWingetAllUsers',
    'cmbWingetSource','btnWingetUpgrade','btnWingetUpdateSelected',
    'lvWinget','lblWingetStatus','lblWingetCount','progWinget','lblWingetEmpty',
    'pnlWingetLoading','lblWingetLoading','lblWingetLoadingSub',
    'btnUpdateWinget','btnCheckWingetVersion','lblWingetVersionVal','lblWingetUpdateStatus','progWingetUpdate',
    'lblSetWingetUpdate','lblSetWingetUpdateSub','lblSetWingetVersion','lblSetWingetHdr',
    'ctxInstHideApp',
    'ctxWingetCopyId','ctxWingetCopyName','ctxWingetHide'
)
foreach ($n in $named) {
    $c = $window.FindName($n)
    if ($c) { Set-Variable -Name $n -Value $c -Scope Script }
}

# ── Seçim İzleme / Selection Tracking ──────────────────────────────
$script:RightClickHandler = [System.Windows.Input.MouseButtonEventHandler]{
    param($src, $e)
    $depObj = $e.OriginalSource -as [System.Windows.DependencyObject]
    while ($depObj -and $depObj.GetType().Name -ne 'DataGridRow') {
        if ($depObj -is [System.Windows.ContentElement]) {
            $depObj = [System.Windows.ContentOperations]::GetParent($depObj)
        } elseif ($depObj -is [System.Windows.Media.Visual] -or $depObj -is [System.Windows.Media.Media3D.Visual3D]) {
            $depObj = [System.Windows.Media.VisualTreeHelper]::GetParent($depObj)
        } else {
            break
        }
    }
    if ($depObj -and $depObj.GetType().Name -eq 'DataGridRow') {
        $sender.SelectedItem = $depObj.DataContext
    }
}
if ($lvPackages) { $lvPackages.Add_PreviewMouseRightButtonDown($script:RightClickHandler) }
if ($lvInstalled) { $lvInstalled.Add_PreviewMouseRightButtonDown($script:RightClickHandler) }

# ── Başlık Çubuğu Düğmeleri / Title Bar Buttons ───────────────────
foreach ($btn in @($btnMinimize, $btnMaximize, $btnClose)) {
    if ($btn) {
        [System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($btn, $true)
    }
}

if ($btnMinimize) {
    $btnMinimize.Add_Click({
        $window.WindowState = [System.Windows.WindowState]::Minimized
    })
}
if ($btnMaximize) {
    $btnMaximize.Add_Click({
        if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $window.WindowState = [System.Windows.WindowState]::Normal
        } else {
            $window.WindowState = [System.Windows.WindowState]::Maximized
        }
    })

    $window.Add_StateChanged({
        if ($btnMaximize) {
            if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
                $btnMaximize.Content = [char]0xE923  # Restore icon
                $btnMaximize.ToolTip = 'Restore'
            } else {
                $btnMaximize.Content = [char]0xE922  # Maximize icon
                $btnMaximize.ToolTip = 'Maximize'
            }
        }
    })
}
if ($btnClose) {
    $btnClose.Add_Click({ $window.Close() })
}


# Pencere yüklendiğinde WM_GETMINMAXINFO hook'unu kur / Hook WM_GETMINMAXINFO on window load
$window.Add_SourceInitialized({
    try { [MaximizeHelper]::Hook($window) } catch {}
})

# ── Özel Tema İletişim Kutusu / Custom Theme Dialog ──────────────────────
function Show-CustomMessageBox {
    param(
        [string]$Title   = 'Notice',
        [string]$Message = '',
        [ValidateSet('Info','Warning','Error','Question','Success')] [string]$Icon = 'Info',
        [ValidateSet('OK','OKCancel','YesNo','YesNoCancel')] [string]$Buttons = 'OK',
        [string]$Details = ''  # İsteğe bağlı ek detay (liste vb.) / Optional extra detail (list etc.)
    )

    # Renkler / Colors
    $cfg = switch ($Icon) {
        'Warning'  { @{ Color='#F59E0B'; Glyph=[char]0xE7BA } }   # Uyarı üçgeni / Warning triangle
        'Error'    { @{ Color='#EF4444'; Glyph=[char]0xEA39 } }   # Hata X / Error X
        'Question' { @{ Color='#64B4FF'; Glyph=[char]0xE9CE } }   # Soru işareti / Question mark
        'Success'  { @{ Color='#22C55E'; Glyph=[char]0xE930 } }   # Onay işareti / Check
        default    { @{ Color='#64B4FF'; Glyph=[char]0xE946 } }   # Bilgi / Info
    }

    $xamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DlgTitle" Background="Transparent" WindowStyle="None"
        ResizeMode="NoResize" AllowsTransparency="True"
        WindowStartupLocation="CenterOwner"
        SizeToContent="Height" Width="440"
        FontFamily="Segoe UI">
  <Border Background="{DynamicResource MenuBg}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1" CornerRadius="10">
    <Grid Margin="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Title bar (drag area) -->
      <Border x:Name="bdTitle" Grid.Row="0" Background="{DynamicResource HeaderBg}" CornerRadius="10,10,0,0" Padding="14,10">
        <TextBlock x:Name="tbTitle" Text="DLG_TITLE" Foreground="{DynamicResource TextPrimary}" FontSize="12" FontWeight="SemiBold"/>
      </Border>

      <!-- Content -->
      <Grid Grid.Row="1" Margin="20,18">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" x:Name="tbIcon" Text="?" FontFamily="Segoe MDL2 Assets"
                   FontSize="30" Foreground="#ICON_COLOR" VerticalAlignment="Top" Margin="0,0,16,0"/>
        <StackPanel Grid.Column="1">
          <TextBlock x:Name="tbMessage" Text="DLG_MSG" Foreground="{DynamicResource TextPrimary}" FontSize="12"
                     TextWrapping="Wrap" LineHeight="18"/>
          <ScrollViewer x:Name="svDetails" MaxHeight="220" VerticalScrollBarVisibility="Auto"
                        HorizontalScrollBarVisibility="Disabled" Margin="0,8,0,0" Visibility="Collapsed">
            <TextBlock x:Name="tbDetails" Text="" Foreground="{DynamicResource TextSecondary}" FontSize="11"
                       TextWrapping="Wrap" LineHeight="16"/>
          </ScrollViewer>
        </StackPanel>
      </Grid>

      <!-- Buttons -->
      <Border Grid.Row="2" Background="{DynamicResource SidebarBrush}" CornerRadius="0,0,10,10" Padding="14,12">
        <StackPanel x:Name="spBtns" Orientation="Horizontal" HorizontalAlignment="Right"/>
      </Border>
    </Grid>
  </Border>
</Window>
"@

    $xamlText = $xamlText.Replace('DLG_TITLE',  [System.Security.SecurityElement]::Escape($Title))
    $xamlText = $xamlText.Replace('DLG_MSG',    [System.Security.SecurityElement]::Escape($Message))
    $xamlText = $xamlText.Replace('#ICON_COLOR', $cfg.Color)

    $dlgXaml = [xml]$xamlText
    $dlgReader = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg = [Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window
    # Tema uyumu için - iletişim kutusu ana pencere ResourceDictionary'sini paylaşır / Share main window ResourceDictionary for theme compatibility
    foreach ($k in $window.Resources.Keys) {
        try { $dlg.Resources[$k] = $window.Resources[$k] } catch {}
    }

    $tbIcon    = $dlg.FindName('tbIcon')
    $tbMessage = $dlg.FindName('tbMessage')
    $tbDetails = $dlg.FindName('tbDetails')
    $svDetails = $dlg.FindName('svDetails')
    $spBtns    = $dlg.FindName('spBtns')
    $bdTitle   = $dlg.FindName('bdTitle')

    $tbIcon.Text = $cfg.Glyph
    $tbMessage.Text = $Message
    if (-not [string]::IsNullOrEmpty($Details)) {
        $tbDetails.Text = $Details
        if ($svDetails) { $svDetails.Visibility = 'Visible' }
    }

    # Başlık çubuğu sürükleme / Title bar drag
    $bdTitle.Add_MouseLeftButtonDown({ param($s,$e) if ($e.ChangedButton -eq 'Left') { $dlg.DragMove() } }.GetNewClosure())

    # Düğme oluşturucu / Button factory
    $script:__dlgResult = 'Cancel'
    $script:__dlgInstance = $dlg
    $mkBtn = {
        param($text, $val, $isPrimary)
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $text
        $btn.MinWidth = 90
        $btn.Height = 30
        $btn.Margin = '4,0,0,0'
        $btn.Padding = '12,0'
        $btn.FontSize = 11
        $btn.BorderThickness = '1'
        $btn.Cursor = 'Hand'
        $btn.Tag = $val
        if ($isPrimary) {
            # Fallback for Accent resources if not present
            if ($window.Resources.Contains('AccentBg')) {
                $btn.Background  = $window.Resources['AccentBg']
                $btn.Foreground  = $window.Resources['AccentFg']
                $btn.BorderBrush = $window.Resources['AccentBg']
                $btn.FontWeight  = 'SemiBold'
            } else {
                $btn.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFromString($cfg.Color)
                $btn.Foreground  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0B0B0F')
                $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($cfg.Color)
                $btn.FontWeight  = 'SemiBold'
            }
        } else {
            if ($window.Resources.Contains('InputBg')) {
                $btn.Background  = $window.Resources['InputBg']
                $btn.Foreground  = $window.Resources['TextPrimary']
                $btn.BorderBrush = $window.Resources['InputBorder']
            } else {
                $btn.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#27272A')
                $btn.Foreground  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E4E4E7')
                $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3F3F46')
            }
        }
        $btn.Add_Click({
            param($src, $e)
            $script:__dlgResult = $src.Tag
            try { $script:__dlgInstance.DialogResult = $true } catch {}
            $script:__dlgInstance.Close()
        })
        $spBtns.Children.Add($btn) | Out-Null
    }

    $tOK     = T 'DlgOK'
    $tCancel = T 'DlgCancel'
    $tYes    = T 'DlgYes'
    $tNo     = T 'DlgNo'
    switch ($Buttons) {
        'OK'          { & $mkBtn $tOK     'OK'     $true }
        'OKCancel'    { & $mkBtn $tCancel 'Cancel' $false; & $mkBtn $tOK  'OK'  $true }
        'YesNo'       { & $mkBtn $tNo     'No'     $false; & $mkBtn $tYes 'Yes' $true }
        'YesNoCancel' { & $mkBtn $tCancel 'Cancel' $false; & $mkBtn $tNo  'No'  $false; & $mkBtn $tYes 'Yes' $true }
    }

    [void]$dlg.ShowDialog()
    return $script:__dlgResult
}

# ── UI Pump Yardımcısı - uzun senkron döngülerde UI'ı duyarlı tut / Keep UI responsive in long sync loops ──

function Invoke-DispatcherPump {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Action]{ $frame.Continue = $false }
    ) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ── DataGrid Veri Kaynağı / DataGrid Data Source ───────────────────────
$script:Packages = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$lvPackages.ItemsSource = $script:Packages

# ── Onay Kutusu Seçim İzleyicisi / CheckBox Selection Tracker ──────────────────────────────────
$script:PackageItemPropChanged = {
    param($src, $e)
    if ($e.PropertyName -eq 'IsChecked') {
        if (Get-Command Update-ActionButtonsState -ErrorAction SilentlyContinue) {
            Update-ActionButtonsState
        }
    }
}
$script:Packages.Add_CollectionChanged({
    param($src, $e)
    if ($e.NewItems) {
        foreach ($it in $e.NewItems) {
            try { $it.add_PropertyChanged($script:PackageItemPropChanged) } catch {}
        }
    }
    if ($e.OldItems) {
        foreach ($it in $e.OldItems) {
            try { $it.remove_PropertyChanged($script:PackageItemPropChanged) } catch {}
        }
    }

    if (Get-Command Update-ActionButtonsState -ErrorAction SilentlyContinue) {
        Update-ActionButtonsState
    }
})

# ── Paket Listesi / Package Catalog ───────────────────────────────────────
$PackageList = ConvertFrom-Csv @'
Identity,Family
5319275A.WhatsAppDesktop,https://apps.microsoft.com/detail/9NKSQGP7F2NH
Adobe Acrobat Reader DC,https://apps.microsoft.com/detail/XPDP273C0XHQH2
Amazon.AmazonAppstore,https://apps.microsoft.com/detail/9NJHK44TTKSX
AMD.AMDRadeonSoftware,https://apps.microsoft.com/detail/9NZ1BJQN6BHL
AppControl Manager,https://apps.microsoft.com/detail/9PNG1JDDTGP8
AppleInc.iTunes,https://apps.microsoft.com/detail/9PB2MZ1ZMB1S
AppleInc.AppleDevices,https://apps.microsoft.com/detail/9NP83LWLPZ9K
Blender,https://apps.microsoft.com/detail/9PP3C07GTVRH
AppleInc.AppleMusicWin,https://apps.microsoft.com/detail/9PFHDD62MXS1
AdobeSystemsIncorporated.AdobePhotoshopExpress,https://apps.microsoft.com/detail/9WZDNCRFJ27N
Blender 3.6 LTS,https://apps.microsoft.com/detail/9PF6NVNS3F0P
Clipchamp.Clipchamp,https://apps.microsoft.com/detail/9P1J8S7CCWWT
CrystalDiskInfo,https://apps.microsoft.com/detail/XP8K4RGX25G3GM
GIMP,https://apps.microsoft.com/detail/9pnsjclxdz0v
GitHub Repo Downloader,https://apps.microsoft.com/detail/9nxp5h39xz49
Intel® Graphics Command Center,https://apps.microsoft.com/detail/9PLFNLNT3G5G
Intel® Graphics Command Center (Beta),https://apps.microsoft.com/detail/9NMR79ZTJFTC
Intel® Graphics Software,https://apps.microsoft.com/detail/9P8K5G2MWW6Z
IrfanView,https://apps.microsoft.com/detail/9nl0r0jnnzm0
IrfanView64,https://apps.microsoft.com/detail/9pjz3btl5pv6
Microsoft.AV1VideoExtension,https://apps.microsoft.com/detail/9MVZQVXJBQ9V
Microsoft.BingNews,https://apps.microsoft.com/detail/9WZDNCRFHVFW
Microsoft.BingTranslator,https://apps.microsoft.com/detail/9WZDNCRFJ3PG
Microsoft.BingWeather,https://apps.microsoft.com/detail/9WZDNCRFJ3Q2
Microsoft.Copilot,https://apps.microsoft.com/detail/XP9CXNGPPJ97XX
Microsoft.Cortana,https://apps.microsoft.com/detail/9nblggh4nns1
Microsoft.D3DMappingLayers,https://apps.microsoft.com/detail/9NQPSL29BFFF
Microsoft.DesktopAppInstaller,https://apps.microsoft.com/detail/9NBLGGH4NNS1
Microsoft.DirectXRuntime,Microsoft.DirectXRuntime_8wekyb3d8bbwe
Microsoft.GamingApp,https://apps.microsoft.com/detail/9MV0B5HZVK9Z
Microsoft.GamingServices,https://apps.microsoft.com/detail/9MWPM2CQNLHN
Microsoft.Getstarted,https://apps.microsoft.com/detail/9P7BP5VNWKX5
Microsoft.HEIFImageExtension,https://apps.microsoft.com/detail/9PMMSR1CGPWG
Microsoft.HEVCVideoExtension,https://apps.microsoft.com/detail/9N4WGH0Z6VHQ
Microsoft.Microsoft3DViewer,https://apps.microsoft.com/detail/9NBLGGH42THS
Microsoft.MicrosoftFamily,https://apps.microsoft.com/detail/9NBLGGH4RRL1
Microsoft.MicrosoftJournal,https://apps.microsoft.com/detail/9N318R854RHH
Microsoft.MicrosoftOfficeHub,https://apps.microsoft.com/detail/9WZDNCRD29V9
Microsoft.MicrosoftOneDrive,https://apps.microsoft.com/detail/9WZDNCRFJ1P3
Microsoft.MicrosoftPCManager,https://apps.microsoft.com/detail/9PM860492SZD
Microsoft.MicrosoftSolitaireCollection,https://apps.microsoft.com/detail/9WZDNCRFHWD2
Microsoft.MicrosoftStickyNotes,https://apps.microsoft.com/detail/9NBLGGH4QGHW
Microsoft.MinecraftEducation,https://apps.microsoft.com/detail/9NBLGGH4R2R6
Microsoft.MixedReality.Portal,https://apps.microsoft.com/detail/9NG1H8B3ZC7M
Microsoft.MPEG2VideoExtension,https://apps.microsoft.com/detail/9N95Q1ZZPMH4
Microsoft.Office.Excel,https://apps.microsoft.com/detail/9WZDNCRFJBH3
Microsoft.Office.OneNote,https://apps.microsoft.com/detail/9WZDNCRFHVJL
Microsoft.Office.PowerPoint,https://apps.microsoft.com/detail/9WZDNCRFJBH1
Microsoft.Office.Word,https://apps.microsoft.com/detail/9WZDNCRFJB9S
Microsoft.OutlookForWindows,https://apps.microsoft.com/detail/9NRX63209R7B
Microsoft.Paint,https://apps.microsoft.com/detail/9NBLGGH5FV99
Microsoft.PowerAutomateDesktop,https://apps.microsoft.com/detail/9NFTCH6J7FHV
Microsoft.PowerShell,https://apps.microsoft.com/detail/9MZ1SNWT0N5D
Microsoft.PowerToys,https://apps.microsoft.com/detail/XP89DCGQ3K6VLD
Microsoft.RawImageExtension,https://apps.microsoft.com/detail/9NCTDW2W1BH8
Microsoft.RemoteDesktop,https://apps.microsoft.com/detail/9WZDNCRFJ3PS
Microsoft.ScreenSketch,https://apps.microsoft.com/detail/9MZ95KL8MR0L
Microsoft.Services.Store.Engagement,Microsoft.Services.Store.Engagement_8wekyb3d8bbwe
Microsoft.SkypeApp,https://apps.microsoft.com/detail/9WZDNCRFJ364
Microsoft.StorePurchaseApp,https://apps.microsoft.com/detail/9NBLGGH4LS1F
Microsoft.SysinternalsSuite,https://apps.microsoft.com/detail/9P7KNL5RWT25
Microsoft.Teams,https://apps.microsoft.com/detail/XP8BT8DW290MPQ
Microsoft.Todos,https://apps.microsoft.com/detail/9NBLGGH5R558
Microsoft.VisualStudioCode,https://apps.microsoft.com/detail/XP9KHM4BK9FZ7Q
Microsoft.VP9VideoExtensions,https://apps.microsoft.com/detail/9N4D0MSMP0PT
Microsoft.WebMediaExtensions,https://apps.microsoft.com/detail/9N5TDP8VCMHS
Microsoft.WebpImageExtension,https://apps.microsoft.com/detail/9PG2DK419DRG
Microsoft.Whiteboard,https://apps.microsoft.com/detail/9MSPC6MP8FM4
Microsoft.WidgetsPlatformRuntime,https://apps.microsoft.com/detail/9N3RK8ZV2ZR8
Microsoft.WinDbg,https://apps.microsoft.com/detail/9PGJGD53TN86
Microsoft.WindowsAlarms,https://apps.microsoft.com/detail/9WZDNCRFJ3PR
Microsoft.WindowsCalculator,https://apps.microsoft.com/detail/9WZDNCRFHVN5
Microsoft.WindowsCamera,https://apps.microsoft.com/detail/9WZDNCRFJBBG
Microsoft.WindowsCommunicationsApps,https://apps.microsoft.com/detail/9WZDNCRFHVQM
Microsoft.WindowsConfigurationDesigner,https://apps.microsoft.com/detail/9NBLGGH4TX22
Microsoft.WindowsDefenderApplicationGuard,Microsoft.WindowsDefenderApplicationGuard_8wekyb3d8bbwe
Microsoft.WindowsDevHome,https://apps.microsoft.com/detail/9N8MHTPHNGVV
Microsoft.WindowsFeedbackHub,https://apps.microsoft.com/detail/9NBLGGH4R32N
Microsoft.WindowsHDRCalibration,https://apps.microsoft.com/detail/9N7F2SM5D1LR
Microsoft.WindowsNotepad,https://apps.microsoft.com/detail/9MSMLRH6LZF3
Microsoft.WindowsPhotos,https://apps.microsoft.com/detail/9WZDNCRFJBH4
Microsoft.WindowsScan,https://apps.microsoft.com/detail/9WZDNCRFJ3PV
Microsoft.WindowsSoundRecorder,https://apps.microsoft.com/detail/9WZDNCRFJ3P2
Microsoft.WindowsStore,https://apps.microsoft.com/detail/9WZDNCRFJBMP
Microsoft.WindowsSubsystemForAndroid,https://apps.microsoft.com/detail/9NJHK44TTKSX
Microsoft.WindowsTerminal,https://apps.microsoft.com/detail/9N0DX20HK701
Microsoft.XboxGamingOverlay,https://apps.microsoft.com/detail/9NZKPSTSNW4P
Microsoft.YourPhone,https://apps.microsoft.com/detail/9NMPJ99VJBWV
Microsoft.ZuneMusic,https://apps.microsoft.com/detail/9WZDNCRFJ3PT
Microsoft.ZuneVideo,https://apps.microsoft.com/detail/9WZDNCRFJ3P2
MicrosoftCorporationII.QuickAssist,https://apps.microsoft.com/detail/9P7BP5VNWKX5
MicrosoftWindows.Client.WebExperience,https://apps.microsoft.com/detail/9MSSGKG348SP
Mozilla.Firefox,https://apps.microsoft.com/detail/9NZVDKPMR9RD
Netflix,https://apps.microsoft.com/detail/9wzdncrfj3tj
NVIDIA.NVIDIAControlPanel,https://apps.microsoft.com/detail/9NF8H0H7WMLT
PuTTY,https://apps.microsoft.com/detail/XPFNZKSKLBP7RJ
Python Install Manager,https://apps.microsoft.com/detail/9nq7512cxl7t
PythonSoftwareFoundation.Python.3.11,https://apps.microsoft.com/detail/9NRWMJP3717K
PythonSoftwareFoundation.Python.3.12,https://apps.microsoft.com/detail/9ncvdn91xzqp
PythonSoftwareFoundation.Python.3.13,https://apps.microsoft.com/detail/9PNR1N2PRH88
Rufus,https://apps.microsoft.com/detail/9pc3h3v7q9ch
SpotifyAB.SpotifyMusic,https://apps.microsoft.com/detail/9NCBCSZSJRSB
Telegram Desktop,https://apps.microsoft.com/detail/9nztwsqntd0s
Telegram for Windows (Unigram),https://apps.microsoft.com/detail/9n97zckpd60q
Visual Studio Code - Insiders,https://apps.microsoft.com/detail/XP8LFCZM790F6B
Visual Studio Community,https://apps.microsoft.com/detail/XPDCFJDKLZJLP8
VLC,https://apps.microsoft.com/detail/XPDM1ZW6815MQM
VLC UWP,https://apps.microsoft.com/detail/9NBLGGH4VVNH
Zoom Workplace,https://apps.microsoft.com/detail/XP99J3KP4XZ4VV

'@

# ComboBox'a paket listesini yükle / Load package list into ComboBox
$script:AllPackageIdentities = @($PackageList | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Identity) } | ForEach-Object { $_.Identity })
foreach ($id in $script:AllPackageIdentities) { [void]$cmbPackage.Items.Add($id) }


$script:ComboSuppressFilter = $false
$cmbPackage.Add_SelectionChanged({
    if ($script:ComboSuppressFilter) { return }
    if ($cmbPackage.SelectedItem -and -not [string]::IsNullOrWhiteSpace($cmbPackage.SelectedItem.ToString())) {
        if ($txtUrl) { $txtUrl.Clear() }
    }
})

# Enter ile getir / Trigger fetch on Enter
$cmbPackage.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return -or $e.Key -eq [System.Windows.Input.Key]::Enter) {
        $btnFetch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

$txtUrl.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return -or $e.Key -eq [System.Windows.Input.Key]::Enter) {
        $btnFetch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

$cmbPackage.Add_KeyUp({
    if ($script:ComboSuppressFilter) { return }
    $typed = $cmbPackage.Text
    if ([string]::IsNullOrEmpty($typed)) {
        $script:ComboSuppressFilter = $true
        $cmbPackage.Items.Clear()
        foreach ($id in $script:AllPackageIdentities) { [void]$cmbPackage.Items.Add($id) }
        $script:ComboSuppressFilter = $false
        return
    }
    $filtered = @($script:AllPackageIdentities | Where-Object { $_ -match [regex]::Escape($typed) })
    $script:ComboSuppressFilter = $true
    $sel = $cmbPackage.SelectionStart
    $cmbPackage.Items.Clear()
    foreach ($id in $filtered) { [void]$cmbPackage.Items.Add($id) }
    $cmbPackage.Text = $typed
    $cmbPackage.SelectionStart = $sel
    $script:ComboSuppressFilter = $false
    if ($filtered.Count -gt 0 -and -not $cmbPackage.IsDropDownOpen) {
        $cmbPackage.IsDropDownOpen = $true
    }
})

# ── Yardımcılar / Helpers ─────────────────────────────────────────────
function Set-Status([string]$msg) {
    if ($lblStatus) { $lblStatus.Text = $msg }
}


# ── PID izleme: cancel sırasında child process'leri öldürmek için ─────────
$script:ChildPids = [System.Collections.Generic.HashSet[int]]::new()
function Register-ChildPid {
    param([Parameter(Mandatory=$true)][int]$ProcessId)
    try {
        if ($ProcessId -gt 0) { [void]$script:ChildPids.Add($ProcessId) }
    } catch {}
}
function Stop-AllChildPids {
    if (-not $script:ChildPids -or $script:ChildPids.Count -eq 0) { return }
    $pidsToKill = @($script:ChildPids)
    $script:ChildPids.Clear()
    foreach ($childId in $pidsToKill) {
        try {
            # Alt-process ağacını da öldür (taskkill /T /F)
            Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/F','/T','/PID',"$childId") `
                -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        try { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# ── Rescan'ı senkron olarak temiz şekilde durdur (re-entrancy guard için) ──
function Stop-InstalledRescan {
    param([int]$TimeoutMs = 1500)
    if ($script:instStoreTimer) {
        try { $script:instStoreTimer.Stop() } catch {}
        $script:instStoreTimer = $null
    }
    if ($script:instStoreRunspaces) {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        foreach ($rs in @($script:instStoreRunspaces)) {
            try { $rs.PS.BeginStop($null, $null) } catch {}
        }
        while ([DateTime]::UtcNow -lt $deadline -and $script:instStoreRunspaces.Count -gt 0) {
            $finished = @($script:instStoreRunspaces | Where-Object { $_.Handle.IsCompleted })
            foreach ($rs in $finished) {
                try { $rs.PS.EndInvoke($rs.Handle) | Out-Null } catch {}
                try { $rs.PS.Dispose() } catch {}
                [void]$script:instStoreRunspaces.Remove($rs)
            }
            if ($script:instStoreRunspaces.Count -gt 0) { Start-Sleep -Milliseconds 50 }
        }
        foreach ($rs in @($script:instStoreRunspaces)) {
            try { $rs.PS.Dispose() } catch {}
        }
        $script:instStoreRunspaces.Clear()
    }
    if ($script:instStorePool) {
        $poolToDispose = $script:instStorePool
        $script:instStorePool = $null
        [System.Threading.Tasks.Task]::Run([System.Action]{
            try { $poolToDispose.Close(); $poolToDispose.Dispose() } catch {}
        }) | Out-Null
    }
    $script:cancelRescan = $false
}

# ── Tab başına özel progress göster/gizle / Per-tab progress show/hide ──
# ── Tab başına özel progress göster/gizle / Per-tab progress show/hide ──
function Show-TabProgress {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Fetch','Installed','Winget','History','Settings')]
        [string]$Tab,
        [string]$Message = '',
        [int]$Percent = -1,
        [bool]$Indeterminate = $true
    )
    $bar = $null; $lbl = $null
    switch ($Tab) {
        'Fetch'     { $bar = $progDownload;     $lbl = $lblStatus }
        'Installed' { $bar = $progInstalledTab; $lbl = $lblInstFetchStatus }
        'Winget'    { $bar = $progWinget;       $lbl = $lblWingetStatus }
        'History'   { $bar = $progMain;         $lbl = $lblStatus }
        'Settings'  { $bar = $progWingetUpdate; $lbl = $lblWingetUpdateStatus }
    }
    if ($bar) {
        $bar.Visibility = 'Visible'
        if ($Indeterminate -or $Percent -lt 0) {
            $bar.IsIndeterminate = $true
        } else {
            $bar.IsIndeterminate = $false
            $bar.Maximum = 100
            $bar.Value   = [Math]::Max(0, [Math]::Min(100, $Percent))
        }
    }
    if ($lbl -and $Message) { $lbl.Text = $Message }
}
function Hide-TabProgress {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Fetch','Installed','Winget','History','Settings')]
        [string]$Tab
    )
    $bar = $null; $lbl = $null
    switch ($Tab) {
        'Fetch'     { $bar = $progDownload;     $lbl = $lblStatus }
        'Installed' { $bar = $progInstalledTab; $lbl = $lblInstFetchStatus }
        'Winget'    { $bar = $progWinget;       $lbl = $lblWingetStatus }
        'History'   { $bar = $progMain;         $lbl = $lblStatus }
        'Settings'  { $bar = $progWingetUpdate; $lbl = $lblWingetUpdateStatus }
    }
    if ($bar) { $bar.IsIndeterminate = $false; $bar.Value = 0; $bar.Visibility = 'Collapsed' }
    if ($lbl) { $lbl.Text = '' }
}
function Show-Cancel {
    param([string]$OpKey = 'default')
    if (-not $script:ActiveOpKeys) { $script:ActiveOpKeys = [System.Collections.Generic.HashSet[string]]::new() }
    [void]$script:ActiveOpKeys.Add($OpKey)
    # Installed sekmesindeysek: Rescan slot'unu Cancel ile değiştir
    $isInstalledTab = ($NavList -and $NavList.SelectedIndex -eq 1)
    if ($isInstalledTab -and $btnInstCancel -and $btnRescan) {
        $btnRescan.Visibility     = 'Collapsed'
        $btnInstCancel.Visibility = 'Visible'
        $btnInstCancel.IsEnabled  = $true
        $btnInstCancel.Content    = if ($script:Lang -eq 'TR') { '✕  İptal' } else { '✕  Cancel' }
    } else {
        if ($btnCancel) { $btnCancel.Visibility = 'Visible'; $btnCancel.IsEnabled = $true; $btnCancel.Content = (T 'BtnCancel') }
    }
    Update-ActionButtonsState
}
function Hide-Cancel {
    param([string]$OpKey = 'default')
    if (-not $script:ActiveOpKeys) { $script:ActiveOpKeys = [System.Collections.Generic.HashSet[string]]::new() }
    [void]$script:ActiveOpKeys.Remove($OpKey)
    if ($script:ActiveOpKeys.Count -gt 0) {
        # Başka aktif işlem var — butonu gizleme, ama tekrar etkinleştir
        $isInstalledTab = ($NavList -and $NavList.SelectedIndex -eq 1)
        if ($isInstalledTab -and $btnInstCancel) {
            $btnInstCancel.IsEnabled = $true
            $btnInstCancel.Content   = if ($script:Lang -eq 'TR') { '✕  İptal' } else { '✕  Cancel' }
        } elseif ($btnCancel) {
            $btnCancel.IsEnabled = $true; $btnCancel.Content = (T 'BtnCancel')
        }
        return
    }
    # Tüm işlemler bitti — Rescan slot'unu geri getir, global cancel'ı gizle
    if ($btnInstCancel) { $btnInstCancel.Visibility = 'Collapsed' }
    if ($btnRescan)     { $btnRescan.Visibility     = 'Visible' }
    if ($btnCancel)     { $btnCancel.Visibility     = 'Collapsed' }
    Update-ActionButtonsState
}
function Format-Size([long]$bytes) {
    if ($bytes -le 0) { return '-' }
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N2} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

# Tema metin rengi / Theme foreground brush
function Get-PrimaryFgBrush {
    $palette = $script:Themes[$script:CurrentTheme]
    $hex = if ($palette.TextPrimary) { $palette.TextPrimary } else { '#F4F4F5' }
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}
function Get-SecondaryFgBrush {
    $palette = $script:Themes[$script:CurrentTheme]
    $hex = if ($palette.TextSecondary) { $palette.TextSecondary } else { '#A1A1AA' }
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

# ── Yükleme Animasyonu / Loading Spinner ────────────────────────────
$script:spinnerFrames = @([char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838,
                          [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827,
                          [char]0x2807, [char]0x280F)

$script:spinnerSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($f in $script:spinnerFrames) { [void]$script:spinnerSet.Add([string]$f) }
[void]$script:spinnerSet.Add('...')
$script:spinnerIdx = 0
$script:spinnerTimer = $null


function Test-IsPendingFetch {
    param([string]$sv)
    if ([string]::IsNullOrEmpty($sv)) { return $true }
    return $script:spinnerSet.Contains($sv)
}

function Start-InstSpinner {
    if ($script:spinnerTimer) {
        $script:spinnerTimer.Start()
        return
    }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(100)
    $t.Add_Tick({
        $script:spinnerIdx = ($script:spinnerIdx + 1) % $script:spinnerFrames.Length
        $frame = [string]$script:spinnerFrames[$script:spinnerIdx]
        if (-not $script:InstalledApps) { return }

        foreach ($app in $script:InstalledApps) {
            if (Test-IsPendingFetch $app.SizeText) {
                $app.SizeText = $frame
            }
        }
    })
    $script:spinnerTimer = $t
    $t.Start()
}

function Stop-InstSpinner {
    if ($script:spinnerTimer) {
        try { $script:spinnerTimer.Stop() } catch {}
    }
    # Kalan spinner'ları temizle / Clear remaining spinners
    if ($script:InstalledApps) {
        foreach ($app in $script:InstalledApps) {
            if (Test-IsPendingFetch $app.SizeText) {
                $app.SizeText = 'N/A'
            }
        }
    }
}
function Set-StatusBadge {
    param([object]$item, [string]$text, [string]$bgHex = '#27272A', [string]$fgHex = '#A1A1AA')
    $item.Status   = $text

    # Yeşil (tamamlandı) durumunu AccentBrush rengiyle değiştir / Replace green (complete) with AccentBrush color
    if ($bgHex -eq '#14532D' -and $fgHex -eq '#86EFAC') {
        try {
            $accentHex = $script:Themes[$script:CurrentTheme].AccentBrush
            $accentRaw = [System.Windows.Media.ColorConverter]::ConvertFromString($accentHex)
            $ac = [System.Windows.Media.Color]$accentRaw
            # Arka plan: accent rengin %15 saydamlıkta koyu tonu
            $bgColor = [System.Windows.Media.Color]::FromArgb(40, $ac.R, $ac.G, $ac.B)
            # Ön plan: accent rengin kendisi
            $item.StatusBg = [System.Windows.Media.SolidColorBrush]::new($bgColor)
            $item.StatusFg = [System.Windows.Media.SolidColorBrush]::new($ac)
            return
        } catch {}
    }

    if ($script:CurrentTheme -in @('Light','iTunes','Solarized Light')) {
        $bgHex = switch -Wildcard ($bgHex) {
            '#2D2612' { '#FEF3C7' }  # yellow -> light yellow
            '#14532D' { '#DCFCE7' }  # green -> light green
            '#450A0A' { '#FEE2E2' }  # red -> light red
            '#1E3A5F' { '#DBEAFE' }  # blue -> light blue
            '#27272A' { '#F4F4F5' }  # gray -> light gray
            '#2A2419' { '#FEF3C7' }  # amber -> light amber
            default   { '#F4F4F5' }
        }
        $fgHex = switch -Wildcard ($fgHex) {
            '#FDE68A' { '#92400E' }  # yellow -> dark amber
            '#86EFAC' { '#14532D' }  # green -> dark green
            '#FCA5A5' { '#991B1B' }  # red -> dark red
            '#64B4FF' { '#1D4ED8' }  # blue -> dark blue
            '#A1A1AA' { '#52525B' }  # gray -> dark gray
            '#71717A' { '#3F3F46' }  # gray -> darker gray
            '#22C55E' { '#15803D' }  # green -> dark green
            '#A5B4FC' { '#4338CA' }  # indigo -> dark indigo
            default   { '#18181B' }
        }
    }
    $item.StatusBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($bgHex))
    $item.StatusFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($fgHex))
}
function Update-ActionButtonsState {
    $totalCount = 0
    $selCount = 0
    $canDownloadCount = 0
    $canInstallCount = 0

    if ($script:Packages) {
        $totalCount = $script:Packages.Count
        $selected = @($script:Packages | Where-Object { $_.IsChecked })
        $selCount = $selected.Count
        
        # Web adresi olanlar indirilebilir / Those with web URLs can be downloaded
        $canDownloadCount = ($selected | Where-Object { $_.Url -match '^https?://' }).Count
        
        # Yerel dosyası olanlar veya başarıyla inenler kurulabilir / Those with local files or successful downloads can be installed
        $canInstallCount = ($selected | Where-Object { 
            $_.Status -match 'MAIN APP|DEPENDENCY|DOWNLOADED|EXISTS|COMPLETE' -or
            ($_.Url -and $_.Url -notmatch '^https?://' -and (Test-Path $_.Url -ErrorAction SilentlyContinue))
        }).Count
    }
    
    $isBusy = (
        ($btnCancel     -and $btnCancel.Visibility     -eq 'Visible') -or
        ($btnInstCancel -and $btnInstCancel.Visibility -eq 'Visible')
    )

    if ($btnDownload)    { $btnDownload.IsEnabled    = (-not $isBusy -and $canDownloadCount -gt 0) }
    if ($btnInstall)     { $btnInstall.IsEnabled     = (-not $isBusy -and $canInstallCount -gt 0) }
    if ($btnSelectAll)   { $btnSelectAll.IsEnabled   = (-not $isBusy -and $totalCount -gt 0) }
    if ($btnDeselectAll) { $btnDeselectAll.IsEnabled = (-not $isBusy -and $totalCount -gt 0) }
    if ($btnDownloadAll) { $btnDownloadAll.IsEnabled = (-not $isBusy -and $totalCount -gt 0) }
    if ($btnFetch)       { $btnFetch.IsEnabled       = (-not $isBusy) }
    if ($btnReset)       { $btnReset.IsEnabled       = (-not $isBusy) }

    # Başlık onay kutusu durumunu senkronize et / Synchronize header checkbox state
    if ($chkAll -and -not $script:_suppressHeader) {
        $script:_suppressHeader = $true
        try {
            if ($totalCount -eq 0) {
                $chkAll.IsChecked = $false
            } elseif ($selCount -eq 0) {
                $chkAll.IsChecked = $false
            } elseif ($selCount -eq $totalCount) {
                $chkAll.IsChecked = $true
            } else {
                $chkAll.IsChecked = $null
            }
            if ($isBusy) { $chkAll.IsEnabled = $false } else { $chkAll.IsEnabled = $true }
        } catch {}
        $script:_suppressHeader = $false
    }
}

# ── Dil Uygula / Apply Language ─────────────────────────────────────────
function Set-Language {
    $s = $script:Strings[$script:Lang]
    if (-not $script:window) { return }   # window henüz oluşturulmadıysa atla
    $script:window.Title    = $s.AppTitle
    if ($script:txtTitleBar) { $script:txtTitleBar.Text = $s.AppTitle }
    $navFetch.Text          = $s.NavFetch
    $navInstalled.Text      = $s.NavInstalled
    $navDownloads.Text      = $s.NavDownloads
    $navSettings.Text       = $s.NavSettings
    $navHistory.Text        = $s.NavHistory
    if ($navWinget) { $navWinget.Text = $s.NavWinget }
    $lblUrl.Text            = $s.LblUrl
    if ($lblFieldPackage) { $lblFieldPackage.Text = $s.LblFieldPackage }
    if ($lblFieldArch)    { $lblFieldArch.Text    = $s.LblFieldArch }
    if ($lblFieldRing)    { $lblFieldRing.Text    = $s.LblFieldRing }
    $btnFetch.Content       = $s.BtnFetch
    $btnSelectAll.Content   = $s.BtnSelectAll
    $btnDeselectAll.Content = $s.BtnDeselectAll
    $btnDownloadAll.Content = $s.BtnDownloadAll
    $btnBrowse.Content      = $s.BtnBrowse
    $btnReset.Content       = $s.BtnReset
    if ($btnRetryFailed) { $btnRetryFailed.Content = $s.BtnRetryFailed }
    $btnDownload.Content    = $s.BtnDownload
    $btnInstall.Content     = $s.BtnInstall
    $btnOpenFolder.Content  = $s.BtnOpenFolder
    $btnLang.Content        = $s.BtnLang
    if ($lblStatus.Text -eq 'Ready' -or $lblStatus.Text -eq 'Hazır') {
        $lblStatus.Text = $s.StatusReady
    }

    # Yüklü Uygulamalar sekmesi / Installed apps tab
    if ($btnUninstallSelected) { $btnUninstallSelected.Content = $s.BtnUninstallSelected }
    if ($btnUpdateSelected)    { $btnUpdateSelected.Content    = $s.BtnUpdateSelected }
    if ($btnRescan)            { $btnRescan.Content            = $s.BtnRescan }
    if ($btnExportList)        { $btnExportList.Content        = $s.BtnExportList }
    if ($chkInstalledAll)      { $chkInstalledAll.Content      = $s.ChkSelectAllInst }
    if ($chkShowSystemApps)    { $chkShowSystemApps.Content    = $s.ChkShowSystemApps }
    if ($lblRingLabel)         { $lblRingLabel.Text            = $s.LblRing }
    if ($lblInstallLabel)      { $lblInstallLabel.Text         = $s.LblInstall }
    if ($radAllUsers)          { $radAllUsers.Content          = $s.RadAllUsers }
    if ($radCurrentUser)       { $radCurrentUser.Content       = $s.RadCurrentUser }

    # Geçmiş sekmesi sütun başlıkları / Column headers - History
    if ($lvHistory -and $lvHistory.Columns.Count -ge 4) {
        $lvHistory.Columns[0].Header = $s.ColTime
        $lvHistory.Columns[1].Header = $s.ColPackage
        $lvHistory.Columns[2].Header = $s.ColSize
        $lvHistory.Columns[3].Header = $s.ColResult
    }
    # Yüklü Uygulamalar sekmesi sütun başlıkları / Column headers - Installed
    if ($lvInstalled -and $lvInstalled.Columns.Count -ge 5) {

        $lvInstalled.Columns[1].Header = $s.ColApplication
        $lvInstalled.Columns[2].Header = $s.ColInstalled
        $lvInstalled.Columns[3].Header = $s.ColStore
        $lvInstalled.Columns[4].Header = $s.ColStatus
    }
    # İndirme sekmesi sütun başlıkları / Column headers - Fetch
    if ($lvPackages -and $lvPackages.Columns.Count -ge 5) {
        $lvPackages.Columns[4].Header = $s.ColStatus
    }

    # Bağlam menüleri / Context menus
    if ($ctxCopyName)    { $ctxCopyName.Header    = $s.CtxCopyName }
    if ($ctxCopyVersion) { $ctxCopyVersion.Header = $s.CtxCopyVersion }
    if ($ctxCopyUrl)     { $ctxCopyUrl.Header     = $s.CtxCopyUrl }
    if ($ctxCopyStoreId) { $ctxCopyStoreId.Header = $s.CtxCopyStoreId }
    if ($ctxSelectVer)   { $ctxSelectVer.Header   = $s.CtxSelectVer }
    if ($ctxFileInfo)    { $ctxFileInfo.Header    = $s.CtxFileInfo }
    if ($ctxOpenUrl)     { $ctxOpenUrl.Header     = $s.CtxOpenUrl }
    if ($ctxOpenStore)   { $ctxOpenStore.Header   = $s.CtxOpenStore }
    if ($ctxOpenFolder)  { $ctxOpenFolder.Header  = $s.CtxOpenFolder }
    if ($ctxRetryDl)     { $ctxRetryDl.Header     = $s.CtxRetryDl }
    if ($ctxToggle)      { $ctxToggle.Header      = $s.CtxToggle }

    if ($ctxInstUninstall) { $ctxInstUninstall.Header = $s.CtxInstUninstall }
    if ($ctxInstCopyPfn)   { $ctxInstCopyPfn.Header   = $s.CtxInstCopyPfn }
    if ($ctxInstCopyName)  { $ctxInstCopyName.Header  = $s.CtxInstCopyName }
    if ($ctxInstCopyVer)   { $ctxInstCopyVer.Header   = $s.CtxInstCopyVer }
    if ($ctxInstOpenStore) { $ctxInstOpenStore.Header = $s.CtxInstOpenStore }
    if ($ctxInstOpenFolder){ $ctxInstOpenFolder.Header = $s.CtxInstOpenFolder }

    # Durum rozetlerini çevir / Translate status badges
    $badgeMap = @{
        'UP TO DATE'       = $s.BadgeUpToDate
        'GÜNCEL'           = $s.BadgeUpToDate
        'UPDATE AVAILABLE' = $s.BadgeUpdateAvailable
        'GÜNCELLEME VAR'   = $s.BadgeUpdateAvailable
        'AHEAD'            = $s.BadgeAhead
        'İLERİDE'          = $s.BadgeAhead
        'CHECKING'         = $s.BadgeChecking
        'KONTROL EDİLİYOR' = $s.BadgeChecking
        'SYSTEM'           = $s.BadgeSystem
        'SİSTEM'           = $s.BadgeSystem
        'N/A'              = $s.BadgeNA
        'YOK'              = $s.BadgeNA
        'UNKNOWN'          = $s.BadgeUnknown
        'BİLİNMİYOR'       = $s.BadgeUnknown
        'READY'            = $s.BadgeReady
        'HAZIR'            = $s.BadgeReady
        'QUEUED'           = $s.BadgeQueued
        'KUYRUKTA'         = $s.BadgeQueued
        'EXISTS'           = $s.BadgeExists
        'MEVCUT'           = $s.BadgeExists
        'COMPLETE'         = $s.BadgeComplete
        'TAMAMLANDI'       = $s.BadgeComplete
        'SIDELOAD'         = $s.BadgeSideload
        # Fetch sekmesi rozetleri / Fetch tab badges
        'LATEST'           = $s.BadgeLatest
        'EN YENİ'          = $s.BadgeLatest
        'SON SÜRÜM'        = $s.BadgeLatest
        'DEP'              = $s.BadgeDep
        'BAĞIMLILIK'       = $s.BadgeDep
        'EK PAKET'         = $s.BadgeDep
        'OLDER'            = $s.BadgeOlder
    }
    if ($script:InstalledApps) {
        foreach ($item in $script:InstalledApps) {
            if ($item.Status -and $badgeMap.ContainsKey($item.Status)) {
                $item.Status = $badgeMap[$item.Status]
            }
        }
    }
    if ($script:Packages) {
        foreach ($item in $script:Packages) {
            if ($item.Status -and $badgeMap.ContainsKey($item.Status)) {
                $item.Status = $badgeMap[$item.Status]
            }
        }
    }

    Set-SettingsTabTexts

    # Placeholder metinleri / Placeholder texts
    if ($txtUrl)             { $txtUrl.Tag             = $s.PhUrl }
    if ($txtInstalledSearch) { $txtInstalledSearch.Tag = $s.PhInstSearch }
    if ($lblHistoryEmpty)    { $lblHistoryEmpty.Text   = $s.HistoryEmpty }
    if ($lblDlEmpty)         { $lblDlEmpty.Text        = $s.DlEmpty }

    # Tooltip metinleri / Tooltip texts
    if ($btnFetch)             { $btnFetch.ToolTip             = $s.TipFetch }
    if ($btnSelectAll)         { $btnSelectAll.ToolTip         = $s.TipSelectAll }
    if ($btnDeselectAll)       { $btnDeselectAll.ToolTip       = $s.TipDeselectAll }
    if ($btnDownloadAll)       { $btnDownloadAll.ToolTip       = $s.TipDownloadAll }
    if ($btnBrowse)            { $btnBrowse.ToolTip            = $s.TipBrowse }
    if ($btnReset)             { $btnReset.ToolTip             = $s.TipReset }
    if ($btnDownload)          { $btnDownload.ToolTip          = $s.TipDownload }
    if ($btnInstall)           { $btnInstall.ToolTip           = $s.TipInstall }
    if ($btnOpenFolder)        { $btnOpenFolder.ToolTip        = $s.TipOpenFolder }
    if ($btnCancel)            { $btnCancel.ToolTip            = $s.TipCancel }
    if ($btnRescan)            { $btnRescan.ToolTip            = $s.TipRescan }
    if ($btnUpdateSelected)    { $btnUpdateSelected.ToolTip    = $s.TipUpdateSelected }
    if ($btnUninstallSelected) { $btnUninstallSelected.ToolTip = $s.TipUninstallSelected }
    if ($btnExportList)        { $btnExportList.ToolTip        = $s.TipExportList }
    if ($chkInstalledAll)      { $chkInstalledAll.ToolTip      = $s.TipSelectAllInst }
    if ($chkShowSystemApps)    { $chkShowSystemApps.ToolTip    = $s.TipShowSystem }
    if ($btnTheme)             { $btnTheme.ToolTip             = $s.TipTheme }
    if ($btnLang)              { $btnLang.ToolTip              = $s.TipLang }
    if ($cmbPackage)           { $cmbPackage.ToolTip           = $s.TipCmbPackage }
    if ($cmbArch)              { $cmbArch.ToolTip              = $s.TipCmbArch }
    if ($cmbRing)              { $cmbRing.ToolTip              = $s.TipCmbRing }
    if ($txtUrl)               { $txtUrl.ToolTip               = $s.TipTxtUrl }
    if ($txtInstalledSearch)   { $txtInstalledSearch.ToolTip   = $s.TipInstalledSearch }

    # Winget sekmesi / Winget tab
    if ($txtWingetQuery)       { $txtWingetQuery.Tag           = $s.WingetSearchPh }
    if ($btnWingetRefresh)     { $btnWingetRefresh.Content     = $s.WingetRefresh
                                 $btnWingetRefresh.ToolTip     = $s.WingetTipRefresh }
    if ($chkWingetShowUpdates) { $chkWingetShowUpdates.Content = $s.WingetShowUpdates
                                 $chkWingetShowUpdates.ToolTip = $s.WingetTipShowUpd }
    if ($chkWingetAllUsers)    { $chkWingetAllUsers.Content    = $s.WingetAllUsers
                                 $chkWingetAllUsers.ToolTip    = $s.WingetTipAllUsers }
    # btnWingetSelectAll / btnWingetDeselectAll kaldırıldı — header checkbox toggle ediyor
    # btnWingetUpgrade içeriği Update-WingetActionButtons içinde dinamik olarak ayarlanıyor
    # Winget sütun başlıkları / Winget column headers
    if ($lvWinget -and $lvWinget.Columns.Count -ge 7) {
        $lvWinget.Columns[1].Header = $s.ColApplication
        $lvWinget.Columns[2].Header = 'Id'
        $lvWinget.Columns[3].Header = $s.ColInstalled
        $lvWinget.Columns[4].Header = $s.ColStore
        $lvWinget.Columns[5].Header = $s.ColStatus
        $lvWinget.Columns[6].Header = $s.ColSource
    }
    if ($ctxInstHideApp)   { $ctxInstHideApp.Header   = $s.InstHideApp }
    if ($ctxWingetHide) { $ctxWingetHide.Header = $s.WingetHideUpdate }

    # Winget sayaç metnini yenile / Refresh Winget count text
    if ($script:WingetReady) { Update-WingetCount }
    # Winget badge metinlerini dile gore guncelle
    if ($script:WingetAllPackages) {
        foreach ($pkg in $script:WingetAllPackages) {
            if ($pkg.HasUpdate) {
                $pkg.RowStatus = (T 'WingetBadgeUpdate')
            } elseif ($pkg.InstalledVersion -and $pkg.InstalledVersion -ne '—') {
                $pkg.RowStatus = (T 'WingetBadgeUpToDate')
            }
        }
    }
    Set-PageHeader
}


function Set-SettingsTabTexts {
    $s = $script:Strings[$script:Lang]

    if ($btnApplySettings) { $btnApplySettings.Content = $s.SetApplyBtn }


    if ($lblSetGeneral)  { $lblSetGeneral.Text  = $s.SetGeneral }
    if ($lblSetDownloads){ $lblSetDownloads.Text = $s.SetDownloads }
    if ($lblSetAbout)    { $lblSetAbout.Text     = $s.SetAbout }
    if ($lblSetLang)     { $lblSetLang.Text      = $s.SetLangLabel }
    if ($lblSetLangSub)  { $lblSetLangSub.Text   = $s.SetLangSub }
    if ($lblSetTheme)    { $lblSetTheme.Text     = $s.SetThemeLabel }
    if ($lblSetThemeSub) { $lblSetThemeSub.Text  = $s.SetThemeSub }
    if ($lblSetDlFolder) { $lblSetDlFolder.Text  = $s.SetDlFolderLabel }
    if ($lblSetArch)     { $lblSetArch.Text      = $s.SetArchLabel }
    if ($lblSetArchSub)  { $lblSetArchSub.Text   = $s.SetArchSub }
    if ($lblSetRing)     { $lblSetRing.Text      = $s.SetRingLabel }
    if ($lblSetRingSub)  { $lblSetRingSub.Text   = $s.SetRingSub }
    if ($lblSetInstall)  { $lblSetInstall.Text   = $s.SetInstall }
    if ($lblSetForceReinstall)    { $lblSetForceReinstall.Text    = $s.SetForceReinstallLabel }
    if ($lblSetForceReinstallSub) { $lblSetForceReinstallSub.Text = $s.SetForceReinstallSub }
    if ($lblSetDeleteAfterInstall)    { $lblSetDeleteAfterInstall.Text    = $s.SetDeleteAfterInstallLabel }
    if ($lblSetDeleteAfterInstallSub) { $lblSetDeleteAfterInstallSub.Text = $s.SetDeleteAfterInstallSub }
    if ($lblSetWave)    { $lblSetWave.Text    = $s.SetWaveLabel }
    if ($lblSetWaveSub) { $lblSetWaveSub.Text = $s.SetWaveSub }
    if ($lblSetRuntimeHdr) { $lblSetRuntimeHdr.Text = $s.SetRuntimeLabel }
    if ($lblSetTargetOS) { $lblSetTargetOS.Text  = $s.SetTargetOSLabel }


    if ($lblDlOverall)   { $lblDlOverall.Text    = $s.DlOverallProgress }
    if ($lblDlSpeedHdr)  { $lblDlSpeedHdr.Text   = $s.DlSpeed }
    if ($lblDlEtaHdr)    { $lblDlEtaHdr.Text     = $s.DlETA }
    if ($lblDlQueuedHdr) { $lblDlQueuedHdr.Text  = $s.DlQueued }
    if ($lblInstallerLog){ $lblInstallerLog.Text  = $s.DlInstallerLog }


    if ($btnChangeDlFolder) { $btnChangeDlFolder.Content = if ($s.ContainsKey('BtnChangeDlFolder')) { $s.BtnChangeDlFolder } else { if ($script:Lang -eq 'TR') { 'Değiştir' } else { 'Change' } } }


    if ($txtLog -and ([string]::IsNullOrEmpty($txtLog.Text) -or $txtLog.Text -eq 'No activity yet.' -or $txtLog.Text -eq 'Henüz işlem yok.')) {
        $txtLog.Text = $s.DlNoActivity
    }
}

function Set-PageHeader {
    $s = $script:Strings[$script:Lang]
    switch ($NavList.SelectedIndex) {
        0 { $lblPageTitle.Text = $s.PageFetch;     $lblPageSub.Text = $s.PageFetchSub }
        1 { $lblPageTitle.Text = $s.PageInstalled; $lblPageSub.Text = $s.PageInstSub }
        2 { $lblPageTitle.Text = $s.NavWinget;     $lblPageSub.Text = $s.WingetSearchPh }
        3 { $lblPageTitle.Text = $s.PageDownloads; $lblPageSub.Text = $s.PageDlSub }
        4 { $lblPageTitle.Text = $s.PageHistory;   $lblPageSub.Text = $s.PageHistSub }
        5 { $lblPageTitle.Text = $s.PageSettings;  $lblPageSub.Text = $s.PageSetSub }
    }

    if ($pageHeader) {
        $pageHeader.Visibility = if ($NavList.SelectedIndex -eq 0) { 'Collapsed' } else { 'Visible' }
    }

    if ($watermarkCanvas) {
        $watermarkCanvas.Visibility = if ($NavList.SelectedIndex -eq 0) { 'Visible' } else { 'Collapsed' }
    }
}

# ── Sekme Fonksiyonları / Tab Functions ───────────────────────────────
$script:History = New-Object System.Collections.ObjectModel.ObservableCollection[object]

function Update-InstalledActionButtons {
    $totalCount = if ($script:InstalledApps) { $script:InstalledApps.Count } else { 0 }
    $selCount = if ($totalCount -gt 0) { ($script:InstalledApps | Where-Object { $_.IsChecked }).Count } else { 0 }

    # Aktif işlem var mı? (rescan / update / uninstall / download / install)
    $isBusy = (
        ($btnCancel     -and $btnCancel.Visibility     -eq 'Visible') -or
        ($btnInstCancel -and $btnInstCancel.Visibility -eq 'Visible')
    )

    if ($btnUninstallSelected) { $btnUninstallSelected.IsEnabled = (-not $isBusy -and $selCount -gt 0) }

    $updatable = 0
    if ($totalCount -gt 0) {
        $updatable = @($script:InstalledApps | Where-Object {
            $_.IsChecked -and $_.Status -ne (T 'BadgeSideload') -and $_.Status -ne (T 'BadgeSystem') -and $_.Status -ne (T 'BadgeChecking')
        }).Count
    }
    if ($btnUpdateSelected) { $btnUpdateSelected.IsEnabled = (-not $isBusy -and $updatable -gt 0) }
    if ($btnInstMore)       { $btnInstMore.IsEnabled       = (-not $isBusy) }
    if ($chkShowSystemApps) { $chkShowSystemApps.IsEnabled = (-not $isBusy) }
    if ($cmbInstalledRing)  { $cmbInstalledRing.IsEnabled  = (-not $isBusy) }
    if ($txtInstalledSearch){ $txtInstalledSearch.IsEnabled= (-not $isBusy) }
    if ($radAllUsers)       { $radAllUsers.IsEnabled       = (-not $isBusy) }
    if ($radCurrentUser)    { $radCurrentUser.IsEnabled    = (-not $isBusy) }

    if ($chkInstalledAll -and -not $script:_suppressInstHeader) {
        $script:_suppressInstHeader = $true
        try {
            if ($totalCount -eq 0 -or $selCount -eq 0) {
                $chkInstalledAll.IsChecked = $false
            } elseif ($selCount -eq $totalCount) {
                $chkInstalledAll.IsChecked = $true
            } else {
                $chkInstalledAll.IsChecked = $null
            }
            $chkInstalledAll.IsEnabled = (-not $isBusy)
        } catch {}
        $script:_suppressInstHeader = $false
    }
}

function Import-InstalledApps {
    # ── Re-entrancy guard: önceki rescan henüz bitmediyse temiz şekilde durdur ──
    Stop-InstalledRescan -TimeoutMs 1500
    $script:InstalledApps = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $lvInstalled.ItemsSource = $script:InstalledApps


    $script:InstalledItemPropChanged = {
        param($src, $e)
        if ($e.PropertyName -eq 'IsChecked') {
            if (Get-Command Update-InstalledActionButtons -ErrorAction SilentlyContinue) {
                Update-InstalledActionButtons
            }
        }
    }
    $script:InstalledApps.Add_CollectionChanged({
        param($src, $e)
        if ($e.NewItems) {
            foreach ($it in $e.NewItems) {
                try { $it.add_PropertyChanged($script:InstalledItemPropChanged) } catch {}
            }
        }
        if ($e.OldItems) {
            foreach ($it in $e.OldItems) {
                try { $it.remove_PropertyChanged($script:InstalledItemPropChanged) } catch {}
            }
        }
        if (Get-Command Update-InstalledActionButtons -ErrorAction SilentlyContinue) {
            Update-InstalledActionButtons
        }
    })

    if ($lblInstalledCount) { $lblInstalledCount.Text = (T 'StatusScanning') }
    if ($lblInstFetchStatus) { $lblInstFetchStatus.Text = "" }

    $systemPkgPatterns = 'LanguageExperiencePack|LanguageFeatures|WinAppRuntime|WindowsAppRuntime|MicrosoftCorporationII\.WinAppRuntime|Microsoft\.SecHealthUI|Microsoft\.SecHealth|Windows\.CBSPreview|NcsiUwpApp|DesktopAppInstaller|Microsoft\.DesktopAppInstaller|Microsoft\.Copilot|Microsoft\.549981C3F5F10|Microsoft\.Windows\.Cortana|Microsoft\.Winget\.|Microsoft\.UI\.Xaml|Microsoft\.VCLibs|Microsoft\.NET\.Native|Microsoft\.DirectXRuntime|Microsoft\.Services\.Store|Microsoft\.AsyncTextService|Microsoft\.BioEnrollment|Microsoft\.CredDialogHost|Microsoft\.ECApp|Microsoft\.LockApp|Microsoft\.MicrosoftEdge\.Stable|Microsoft\.Windows\.Apprep|Microsoft\.Windows\.AssignedAccessLockApp|Microsoft\.Windows\.CallingShellApp|Microsoft\.Windows\.CapturePicker|Microsoft\.Windows\.CloudExperienceHost|Microsoft\.Windows\.ContentDeliveryManager|Microsoft\.Windows\.Holographic|Microsoft\.Windows\.NarratorQuickStart|Microsoft\.Windows\.OOBENetworkCaptivePortal|Microsoft\.Windows\.OOBENetworkConnectionFlow|Microsoft\.Windows\.ParentalControls|Microsoft\.Windows\.PeopleExperienceHost|Microsoft\.Windows\.PinningConfirmationDialog|Microsoft\.Windows\.PrintQueueActionCenter|Microsoft\.Windows\.SecHealthUI|Microsoft\.Windows\.ShellExperienceHost|Microsoft\.Windows\.StartMenuExperienceHost|Microsoft\.Windows\.XGpuEjectDialog|Microsoft\.XboxGameCallableUI|Windows\.CBSPreview|Windows\.PrintDialog'

    # ── Eski → Yeni paket adı eşleme tablosu (alias haritası) ─────────────────
    # Windows'ta gömülü gelen eski adlı uygulamalar yeni adla güncellenemez.
    # Bu harita eski PFN temel adını yeni kurulacak paket adına bağlar.
    # Güncelleme denetiminde eski adla yüklü paket bulunursa önce kaldırılır,
    # sonra yeni canonical adıyla mağazadan indirilip kurulur.
    # / Legacy-to-canonical package name alias map.
    # Built-in apps shipped with Windows under old names cannot be updated in-place.
    # Keys are lowercase old base names; values are canonical (new) package base names.
    $script:PkgAliasMap = @{
        'microsoft.windowsclient.webexperience' = 'MicrosoftWindows.Client.WebExperience'
        'microsoft.quickassist'                 = 'MicrosoftCorporationII.QuickAssist'
        'msteams'                               = 'Microsoft.Teams'
        'microsoft.mspaint'                     = 'Microsoft.Paint'
        'microsoft.photoslegacy'                = 'Microsoft.WindowsPhotos'
    }
    # Canonical PFN haritası: alias map'te hedef olan canonical base name → bilinen tam PFN
    # Sistemde henüz kurulu olmayan canonical paketler için Get-AppxPackage yetersiz kalır;
    # bu harita bilinen Publisher ID'leri sabit olarak tanımlar.
    # / Canonical PFN map: base name → known full PackageFamilyName for packages not yet installed.
    $script:CanonicalPfnMap = @{
        'microsoftwindows.client.webexperience' = 'MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy'
        'microsoftcorporationii.quickassist'    = 'MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe'
        'microsoft.teams'                       = 'MSTeams_8wekyb3d8bbwe'
        'microsoft.paint'                       = 'Microsoft.Paint_8wekyb3d8bbwe'
        'microsoft.windowsphotos'               = 'Microsoft.Windows.Photos_8wekyb3d8bbwe'
    }
    # Ters arama: canonical ad (küçük harf) → kaldırılacak eski paket adları listesi
    # / Reverse lookup: canonical base name (lowercase) -> old package names to remove first
    $script:PkgLegacyNames = @{
        'microsoftwindows.client.webexperience' = @('Microsoft.WindowsClient.WebExperience')
        'microsoftcorporationii.quickassist'    = @('Microsoft.QuickAssist')
        'microsoft.teams'                       = @('MSTeams')
        'microsoft.paint'                       = @('Microsoft.MSPaint')
        'microsoft.windowsphotos'               = @('Microsoft.PhotosLegacy')
    }
    # ──────────────────────────────────────────────────────────────────────────

    try {
        $seen = @{}   # PFN -> en yüksek [Version]
        $apps = [System.Collections.ArrayList]@()
        $appMap = @{}  # PFN -> PSCustomObject (güncelleme için)
        $showSystem = $false

        # Gizlenen uygulamalar listesi
        $ignoredApps = if ($script:AppSettings -and $script:AppSettings.InstalledIgnoredApps) {
            @($script:AppSettings.InstalledIgnoredApps)
        } else { @() }
        if ($chkShowSystemApps -and $chkShowSystemApps.IsChecked) { $showSystem = $true }


        $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'


        # ─────────────────────────────────────────────────────────────────────────────
        # SÜRÜM TESPİTİ — KÖK NEDEN VE ÇÖZÜM
        # Microsoft Store uygulamaları (BingWeather, Xbox, GamingApp vb.) genellikle
        # bir .appxbundle / .msixbundle olarak teslim edilir ve sistemde İKİ kayıt oluşur:
        #
        #   1) Bundle (üst paket)   →  PackageType=Bundle, IsBundle=$true
        #      InstallLocation:  ...\Microsoft.BingWeather_2016.1014.23.3280_neutral_~_...
        #      Manifest:         AppxMetadata\AppxBundleManifest.xml
        #      Version:          2016.1014.23.3280   ← MAĞAZADA GÖRÜNEN SÜRÜM BUDUR
        #
        #   2) Main (mimariye özel) →  PackageType=Main,   IsBundle=$false
        #      InstallLocation:  ...\Microsoft.BingWeather_4.54.63040.0_x64__...
        #      Manifest:         AppxManifest.xml
        #      Version:          4.54.63040.0        ← İÇ PAKET SÜRÜMÜ (mağaza ile karşılaştırılmamalı)
        #
        # Eski kod: `Get-AppxPackage -PackageTypeFilter Main,Bundle` çağrısı bazı Windows
        # sürümlerinde -AllUsers ile birlikte yalnızca Main entry'sini döndürüyor; bu yüzden
        # AppxManifest.xml'den okunan iç sürüm (4.54...) gösteriliyor ve mağaza bundle
        # sürümüyle (2016...) eşleşmediği için "Güncelleme Var" yanılsaması oluşuyor.
        #
        # Çözüm: Main ve Bundle paketlerini AYRI ayrı çekiyor, PFN bazlı bir Bundle haritası
        # kuruyoruz. Bir Main paketin karşılığı bir Bundle varsa SÜRÜM Bundle'dan alınır
        # (bu mağaza karşılaştırmasıyla bire bir uyumludur). Bundle yoksa Main sürümü kullanılır.
        # / Root cause & fix: Store apps are bundles; the displayed "installed version" must be
        # the parent bundle's version (which Store compares against), not the inner package's
        # version inside AppxManifest.xml. We now query Main and Bundle separately and prefer
        # the Bundle version whenever a bundle parent exists for the given PackageFamilyName.
        # ─────────────────────────────────────────────────────────────────────────────

        $mainPkgs = @(Get-AppxPackage -AllUsers -PackageTypeFilter Main -ErrorAction SilentlyContinue | Where-Object {
            $_.IsFramework -eq $false -and -not [string]::IsNullOrWhiteSpace($_.PackageFamilyName)
        })
        $bundlePkgs = @(Get-AppxPackage -AllUsers -PackageTypeFilter Bundle -ErrorAction SilentlyContinue | Where-Object {
            $_.IsFramework -eq $false -and -not [string]::IsNullOrWhiteSpace($_.PackageFamilyName)
        })

        # PFN → Bundle paketi haritası (gerçek/mağaza sürümünü buradan alacağız)
        # / PFN → Bundle map (this is where the real "store-matching" version lives)
        $bundleMap = @{}
        foreach ($b in $bundlePkgs) {
            # Aynı PFN için birden fazla Bundle olabilir (nadir); en yüksek sürümü tut
            # / Multiple bundles for same PFN may exist (rare); keep the highest
            try { $bv = [Version]$b.Version } catch { $bv = [Version]'0.0.0.0' }
            if (-not $bundleMap.ContainsKey($b.PackageFamilyName)) {
                $bundleMap[$b.PackageFamilyName] = $b
            } else {
                try { $existingV = [Version]$bundleMap[$b.PackageFamilyName].Version } catch { $existingV = [Version]'0.0.0.0' }
                if ($bv -gt $existingV) { $bundleMap[$b.PackageFamilyName] = $b }
            }
        }

        # Bundle'a karşılık gelen Main olmayan (öksüz) paketleri de listeye ekle — bazı mağaza
        # uygulamaları yalnızca Bundle kaydıyla görünür ve karşılık gelen Main yoktur.
        # / Include orphan bundles that have no matching Main entry — some Store apps
        # only register as Bundle without an explicit Main package.
        $mainPfnSet = @{}
        foreach ($m in $mainPkgs) { $mainPfnSet[$m.PackageFamilyName] = $true }
        $orphanBundles = @($bundlePkgs | Where-Object { -not $mainPfnSet.ContainsKey($_.PackageFamilyName) })

        $allUserApps = @($mainPkgs) + @($orphanBundles)

        # YEDEK manifest okuyucu — yalnızca Get-AppxPackage hiç sürüm vermezse kullanılır.
        # Önce Bundle manifesti aranır; yoksa AppxManifest'e düşülür.
        # / FALLBACK manifest reader — used only when Get-AppxPackage returns no version.
        # Tries the bundle manifest first, then falls back to the inner package manifest.
        $script:GetManifestVersion = {
            param($installLoc)
            if ([string]::IsNullOrWhiteSpace($installLoc) -or -not (Test-Path -LiteralPath $installLoc)) { return $null }
            $candidates = @(
                (Join-Path $installLoc 'AppxMetadata\AppxBundleManifest.xml'),
                (Join-Path $installLoc 'AppxBundleManifest.xml'),
                (Join-Path $installLoc 'AppxManifest.xml')
            )
            foreach ($p in $candidates) {
                if (Test-Path -LiteralPath $p) {
                    try {
                        [xml]$xml = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
                        $idNode = $xml.SelectSingleNode("//*[local-name()='Identity']")
                        if ($idNode -and $idNode.Version) { return [string]$idNode.Version }
                    } catch {}
                }
            }
            return $null
        }

        foreach ($a in $allUserApps) {
            $key = $a.PackageFamilyName

            # Sistem paketlerini filtrele / Filter system packages
            $isSystem = $false
            if ($key -match $systemPkgPatterns -or $a.Name -match $systemPkgPatterns) { $isSystem = $true }
            if (-not $isSystem -and $a.Name -match $guidPattern) { $isSystem = $true }
            if (-not $isSystem) {
                try {
                    if ($a.SignatureKind -eq 'System') { $isSystem = $true }
                } catch {}
            }
            if (-not $isSystem -and $a.InstallLocation -and $a.InstallLocation -match 'SystemApps|WindowsApps\\Microsoft\.') {
                if ($a.Publisher -match 'Microsoft' -and $a.IsBundle -eq $false) {
                    if ($a.InstallLocation -match '\\SystemApps\\') { $isSystem = $true }
                }
            }

            if ($isSystem -and -not $showSystem) { continue }

            # Gizlenen uygulamaları atla (PFN bazlı)
            if ($ignoredApps.Count -gt 0 -and $ignoredApps -contains $a.PackageFamilyName) { continue }

            # Aynı PFN tekrar gelirse atla / Skip duplicate PFNs
            if ($seen.ContainsKey($key)) { continue }

            # ── Mağaza ile karşılaştırılacak GERÇEK kurulu sürümü belirle ──────────
            # 1) Bu PFN için bir Bundle paketi varsa → onun sürümünü kullan (mağaza bunu görür)
            # 2) Yoksa → mevcut paketin Get-AppxPackage Version'ını kullan
            # 3) Get-AppxPackage hiç sürüm vermezse (nadir) → manifest dosyasından oku
            # / Determine the EFFECTIVE installed version that the Store compares against:
            #   1) If a Bundle exists for this PFN, use the Bundle's Version
            #   2) Otherwise, use this package's own Version (from Get-AppxPackage)
            #   3) Last resort: read from the on-disk manifest
            $effectivePkg      = $a
            $effectiveIsBundle = [bool]$a.IsBundle
            if ($bundleMap.ContainsKey($key)) {
                $effectivePkg      = $bundleMap[$key]
                $effectiveIsBundle = $true
            }

            $rawVer = $effectivePkg.Version
            if ([string]::IsNullOrWhiteSpace($rawVer)) {
                try { $rawVer = & $script:GetManifestVersion $effectivePkg.InstallLocation } catch {}
            }
            $curVer = try { [Version]$rawVer } catch { [Version]'0.0.0.0' }

            # Developer/sideload imzalı paket mi? / Is this a developer/sideload-signed package?
            # CN=Microsoft Corporation publisher'lı paketler Developer imzalı olsa da
            # gerçek Microsoft uygulamalarıdır (Copilot, PowerToys vb.) — sideload sayılmaz.
            # / Packages with CN=Microsoft Corporation are genuine Microsoft apps even if
            # SignatureKind=Developer (e.g. Copilot, PowerToys) — not treated as sideload.
            $isDeveloper = $false
            try {
                if ($a.SignatureKind -eq 'Developer') {
                    $pub = [string]$a.Publisher
                    if ($pub -notmatch 'CN=Microsoft Corporation') {
                        $isDeveloper = $true
                    }
                }
            } catch {}

            $seen[$key] = $curVer
            $entry = [PSCustomObject]@{
                Name              = $a.Name
                Version           = $curVer.ToString()
                PackageFamilyName = $key
                Architecture      = if ($a.Architecture) { $a.Architecture } else { 'Unknown' }
                StoreVersion      = '...'
                IsSystem          = $isSystem
                IsBundle          = $effectiveIsBundle
                IsDeveloper       = $isDeveloper
            }
            [void]$apps.Add($entry)
            $appMap[$key] = $entry
        }
        $apps = $apps | Sort-Object @{E={$_.IsSystem}}, Name

        foreach ($app in $apps) {
            $item = New-Object PackageItem
            Add-Member -InputObject $item -NotePropertyName 'IsSystemRow' -NotePropertyValue ([bool]$app.IsSystem)
            $item.FileName = if (-not [string]::IsNullOrWhiteSpace($app.Name)) { $app.Name } else { ($app.PackageFamilyName -split '_')[0] }
            $item.Version  = $app.Version
            $item.SizeText = '...'
            $item.Url      = $app.PackageFamilyName
            if ($app.IsSystem) {
                Set-StatusBadge $item (T 'BadgeSystem') '#1E1B4B' '#A5B4FC'
                $item.RowFg = Get-SecondaryFgBrush
            } else {
                Set-StatusBadge $item (T 'BadgeChecking') '#27272A' '#A1A1AA'
                $item.RowFg = Get-PrimaryFgBrush
            }
            $item.IsChecked = $false
            $script:InstalledApps.Add($item)
        }

        if ($lblInstalledCount) {
            $lblInstalledCount.Text = ((T 'StatusAppsFound') -f $apps.Count)
        }
        Set-Status ((T 'StatusInstFound') -f $apps.Count)
        Start-InstSpinner

        # Mağaza sürümlerini arka planda al (paralel çalışma alanları) / Fetch store versions in background (parallel runspaces)
        $ring = if ($cmbInstalledRing -and $cmbInstalledRing.SelectedItem) {
            switch ($cmbInstalledRing.SelectedItem.Content) {
                'Retail'{'Retail'}; 'Preview'{'RP'}; 'WIS'{'WIS'}; 'WIF'{'WIF'}; 'Slow'{'Slow'}; 'Fast'{'Fast'}; default{'Retail'}
            }
        } else { 'Retail' }

        # UI verisi için ortak sözlük / Shared dictionary for UI data
        $script:instStoreDict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
        $script:instStoreRing = $ring

        # RunspacePool - 4 paralel istek (aşırı yüklenmeyi önlemek için) / 4 parallel requests (to prevent overload)
        $poolMax = [Math]::Min($apps.Count, 4)
        if ($poolMax -lt 1) { $poolMax = 1 }
        $script:instStorePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $poolMax)
        $script:instStorePool.Open()
        $script:instStoreRunspaces = [System.Collections.ArrayList]::new()
        # Sistem uygulamalarını atla / Skip system apps
        $appsToCheck = @($apps | Where-Object { -not $_.IsSystem -and -not $_.IsDeveloper })
        foreach ($sysApp in @($apps | Where-Object { $_.IsSystem })) {
            $script:instStoreDict[$sysApp.PackageFamilyName] = 'N/A'
        }
        foreach ($devApp in @($apps | Where-Object { $_.IsDeveloper })) {
            $script:instStoreDict[$devApp.PackageFamilyName] = 'SIDELOAD'
        }
        $script:instStoreTotal = $appsToCheck.Count

        foreach ($app in $appsToCheck) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $script:instStorePool
            [void]$ps.AddScript({
                param($pfn, $ring, $sharedDict, $installedArch, $installedVerStr, $aliasMap, $canonicalPfnMap)
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                try {
                    # PFN'den temel adı çıkar / Extract baseName from PFN
                    $pfnParts = $pfn -split '_'
                    $baseName = if ($pfnParts.Count -ge 1) { $pfnParts[0] } else { $pfn }

                    # ── Alias çözümleme: eski adlı paket → yeni canonical ad ──────────
                    # Yüklü paket eski bir adla geliyorsa (Windows gömülü sürümü),
                    # mağazada yeni canonical adıyla aranır.
                    # / Alias resolution: look up legacy names in Store under canonical name.
                    $lookupBase = $baseName
                    if ($aliasMap -and $aliasMap.ContainsKey($baseName.ToLowerInvariant())) {
                        $lookupBase = $aliasMap[$baseName.ToLowerInvariant()]
                    }
                    $expectedBase = $lookupBase
                    # ──────────────────────────────────────────────────────────────────

                    # Yüklü mimariyi rg-adguard dosya adı formatına çevir
                    # (Get-AppxPackage 'X64' döner; dosya adında 'x64' geçer)
                    # / Normalize installed architecture for filename matching
                    $archLc = if ($installedArch) { $installedArch.ToString().ToLowerInvariant() } else { '' }
                    if ($archLc -eq 'x86' -or $archLc -eq 'x64' -or $archLc -eq 'arm' -or $archLc -eq 'arm64' -or $archLc -eq 'neutral') {
                        # ok
                    } else { $archLc = '' }
                    # Yüklenen Sürümün major numarası — şema eşleştirme için
                    # / Major of installed version — used for schema matching
                    $installedMajor = -1
                    if ($installedVerStr) {
                        try { $installedMajor = ([Version]$installedVerStr).Major } catch {}
                    }

                    # Canonical PFN'yi mağaza sorgusu için belirle
                    # / Determine the PFN to use for Store query
                    $lookupPfn = if ($lookupBase -ne $baseName) {
                        # Önce bilinen PFN haritasına bak / Check known PFN map first
                        $knownPfn = if ($canonicalPfnMap -and $canonicalPfnMap.ContainsKey($lookupBase.ToLowerInvariant())) {
                            $canonicalPfnMap[$lookupBase.ToLowerInvariant()]
                        } else { $null }

                        if ($knownPfn) {
                            $knownPfn
                        } else {
                            # Haritada yoksa sistemde ara (henüz kurulu olabilir)
                            # / Not in map: query system (may already be installed under new name)
                            $canonicalPkg = Get-AppxPackage -AllUsers -Name "$lookupBase*" -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($canonicalPkg) { $canonicalPkg.PackageFamilyName } else { $null }
                        }
                    } else { $pfn }

                    # Sorgu türü ve URL'yi belirle
                    # / Determine query type and URL for rg-adguard
                    $enc = if ($lookupPfn) {
                        [Uri]::EscapeDataString($lookupPfn)
                    } else {
                        [Uri]::EscapeDataString($lookupBase)
                    }
                    $queryType = if ($lookupPfn) { 'PackageFamilyName' } else { 'ProductId' }
                    $body = "type=$queryType&url=$enc&ring=$ring&lang=en-US"
                    $bb   = [System.Text.Encoding]::UTF8.GetBytes($body)
                    
                    $html = $null
                    $retryCount = 3
                    for ($i = 0; $i -lt $retryCount; $i++) {
                        try {
                            $req  = [System.Net.HttpWebRequest]::Create('https://store.rg-adguard.net/api/GetFiles')
                            $req.Method      = 'POST'
                            $req.ContentType = 'application/x-www-form-urlencoded'
                            $req.ContentLength = $bb.Length
                            $req.Timeout     = 20000
                            $req.UserAgent   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
                            $req.Referer     = 'https://store.rg-adguard.net/'
                            $req.Accept      = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
                            $req.Headers.Add('Accept-Language', 'en-US,en;q=0.5')
                            $rs = $req.GetRequestStream(); $rs.Write($bb,0,$bb.Length); $rs.Close()
                            $resp = $req.GetResponse()
                            $rdr  = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                            $html = $rdr.ReadToEnd(); $rdr.Close(); $resp.Close()

                            if ($html) { break }
                        } catch {
                            if ($i -eq ($retryCount - 1)) { throw }
                            Start-Sleep -Milliseconds (Get-Random -Minimum 1000 -Maximum 2000)
                        }
                    }

                    if (-not $html) { throw "No HTML response" }
                    $links = [regex]::Matches($html, '<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>')

                    # Sürüm adaylarını topla — dosya adından sürüm + mimari + bundle olup olmadığını çıkar
                    # / Collect version candidates — extract version, architecture, isBundle from filename
                    # Örnek dosya adları:
                    #   Microsoft.BingWeather_4.54.63040.0_x64__8wekyb3d8bbwe.appx           → arch=x64, isBundle=$false
                    #   Microsoft.BingWeather_2016.1014.23.3280_neutral_~_8wekyb3d8bbwe.appxbundle → arch=neutral, isBundle=$true
                    $candidates = @()
                    foreach ($lk in $links) {
                        $fn = $lk.Groups[2].Value.Trim()
                        if ($fn -match 'BlockMap|\.eappx|\.emsix') { continue }
                        if ($fn -notmatch '\.(appx|appxbundle|msix|msixbundle)$') { continue }
                        $fnParts = $fn -split '_'; if ($fnParts.Count -lt 3) { continue }
                        # Ana paket temel adı eşleşmesini doğrula / Verify main package base name match
                        if ($fnParts[0] -ne $expectedBase) { continue }

                        $vstr = $fnParts[1]
                        $archStr = $fnParts[2].ToLowerInvariant()
                        try {
                            $v = [Version]$vstr
                            $isBundle = $fn -match '\.(appxbundle|msixbundle)$'
                            $candidates += [PSCustomObject]@{
                                FileName = $fn
                                Version  = $v
                                VerStr   = $vstr
                                Arch     = $archStr
                                IsBundle = $isBundle
                            }
                        } catch {}
                    }

                    # ─────────────────────────────────────────────────────────────────────
                    # MAĞAZA SÜRÜMÜ SEÇİMİ — v5 (inner-matched-bundle-anchor)
                    #
                    # Sorun: rg-adguard BingWeather için hem 4.54.x hem 2016.x bundle döndürür.
                    # [Version] karşılaştırmasında 2016 > 4 olduğundan "en yüksek bundle"
                    # yanlış şemayı seçer. installedMajor anchor'ı ise ScreenSketch gibi
                    # uygulamalarda yüklü eski sürümü (2018.x) anchor yaparak güncellemeyi gizler.
                    #
                    # Çözüm: İç paket versiyonlarıyla eşleşen bundle'ları bul.
                    # Eşleşen bundle'lar arasından en yükseğini al.
                    # Eşleşen yoksa (sadece bundle var, iç paket yok) en yüksek bundle'ı al.
                    # Hem modern (Major<2000) hem legacy (Major>=2000) varsa modern tercih.
                    #
                    # BingWeather: hem 4.54.x hem 2016.x → modern 4.54.x tercih edilir ✓
                    # ScreenSketch: sadece 2018.x-2022.x → hepsi legacy → en yüksek 2022.x ✓
                    # Clipchamp: sadece bundle var → en yüksek bundle 4.5.x ✓
                    # ─────────────────────────────────────────────────────────────────────
                    $nonBundles  = @($candidates | Where-Object { -not $_.IsBundle })
                    $bundlesOnly = @($candidates | Where-Object { $_.IsBundle })
                    $best = $null

                    # Yardımcı: aktif şemayı seç (sürüm sayısı çok olan kazanır)
                    # Helper: pick active schema by version count, tiebreak with year>=2024
                    $pickActiveSchema = {
                        param($pool)
                        if (-not $pool -or $pool.Count -eq 0) { return $pool }
                        $modern = @($pool | Where-Object { $_.Version.Major -lt 2000 })
                        $legacy = @($pool | Where-Object { $_.Version.Major -ge 2000 })
                        if ($modern.Count -eq 0) { return $legacy }
                        if ($legacy.Count -eq 0) { return $modern }
                        if ($modern.Count -gt $legacy.Count) { return $modern }
                        if ($legacy.Count -gt $modern.Count) { return $legacy }
                        # Eşit sayıda — legacy en yüksek major>=2024 ise legacy seç
                        $legacyTopMajor = ($legacy | Sort-Object Version -Descending | Select-Object -First 1).Version.Major
                        if ($legacyTopMajor -ge 2024) { return $legacy }
                        return $modern
                    }

                    if ($bundlesOnly.Count -gt 0) {
                        # İç paket versiyonları kümesi
                        $innerVerSet = @($nonBundles | ForEach-Object { $_.Version }) | Select-Object -Unique

                        # İç paket versiyonuyla eşleşen bundle'lar (2016.x gibi eski schema'ları eler)
                        $matchedBundles = @($bundlesOnly | Where-Object { $innerVerSet -contains $_.Version })

                        # Eşleşen yoksa tüm bundle'ları kullan (sadece bundle olan paketler)
                        $anchorPool = if ($matchedBundles.Count -gt 0) { $matchedBundles } else { $bundlesOnly }

                        # Aktif şemayı seç (BingWeather→modern, 3DViewer→legacy vs.)
                        $anchorPool = & $pickActiveSchema $anchorPool

                        # En yüksek versiyonlu bundle'ı seç
                        $topBundle = $anchorPool | Sort-Object Version -Descending | Select-Object -First 1
                        $topVer    = $topBundle.Version

                        # O versiyonda arch-filtered iç paket var mı?
                        $sameVerInner = @($nonBundles | Where-Object { $_.Version -eq $topVer })
                        if ($sameVerInner.Count -gt 0) {
                            if ($archLc -and $archLc -ne 'neutral') {
                                $m = @($sameVerInner | Where-Object { $_.Arch -eq $archLc })
                                if ($m.Count -gt 0) { $best = $m[0] }
                            }
                            if (-not $best) {
                                $m = @($sameVerInner | Where-Object { $_.Arch -eq 'neutral' })
                                if ($m.Count -gt 0) { $best = $m[0] }
                            }
                            if (-not $best) { $best = $sameVerInner[0] }
                        } else {
                            # Eşleşen iç paket yok → bundle sürümünü kullan
                            $best = $topBundle
                        }
                    } elseif ($nonBundles.Count -gt 0) {
                        # 4) Hiç bundle yok → iç paketler arasında seç
                        # Aktif şemayı seç
                        $nonBundlesFiltered = & $pickActiveSchema $nonBundles
                        if ($archLc -and $archLc -ne 'neutral') {
                            $m = @($nonBundlesFiltered | Where-Object { $_.Arch -eq $archLc })
                            if ($m.Count -gt 0) { $best = $m | Sort-Object Version -Descending | Select-Object -First 1 }
                        }
                        if (-not $best) {
                            $m = @($nonBundlesFiltered | Where-Object { $_.Arch -eq 'neutral' })
                            if ($m.Count -gt 0) { $best = $m | Sort-Object Version -Descending | Select-Object -First 1 }
                        }
                        if (-not $best) {
                            $best = $nonBundlesFiltered | Sort-Object Version -Descending | Select-Object -First 1
                        }
                    }

                    if ($best) {
                        $sharedDict[$pfn] = $best.VerStr
                    } else {
                        $sharedDict[$pfn] = 'N/A'
                    }
                } catch {
                    $sharedDict[$pfn] = 'N/A'
                }
            })
            [void]$ps.AddParameters(@{
                pfn             = $app.PackageFamilyName
                ring            = $ring
                sharedDict      = $script:instStoreDict
                installedArch   = $app.Architecture
                installedVerStr = $app.Version
                aliasMap        = $script:PkgAliasMap
                canonicalPfnMap = $script:CanonicalPfnMap
            })
            $handle = $ps.BeginInvoke()
            [void]$script:instStoreRunspaces.Add([PSCustomObject]@{ PS=$ps; Handle=$handle; PFN=$app.PackageFamilyName })
        }

        # İptal bayrağını sıfırla ve Cancel butonunu göster / Reset cancel flag and show Cancel button
        $script:cancelRescan = $false
        Show-Cancel -OpKey 'rescan'

        # UI güncelleme zamanlayıcısı / UI update timer
        $script:instStoreTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:instStoreTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:instStoreTimer.Add_Tick({
            # İptal kontrolü / Cancel check
            if ($script:cancelRescan) {
                $script:instStoreTimer.Stop()
                if ($lblInstFetchStatus) {
                    $lblInstFetchStatus.Text = if ($script:Lang -eq 'TR') { 'İptal ediliyor...' } else { 'Cancelling...' }
                }
                # Tüm aktif runspace'leri asenkron durdur (BeginStop UI'ı bloklamaz)
                foreach ($rs in @($script:instStoreRunspaces)) {
                    try { $rs.PS.BeginStop($null, $null) } catch {}
                }
                $script:instStoreRunspaces.Clear()
                # Pool.Close() bloklayıcı — arka planda dispose et / Pool.Close() blocks — dispose on background thread
                $poolToDispose = $script:instStorePool
                $script:instStorePool = $null
                [System.Threading.Tasks.Task]::Run([System.Action]{
                    try { $poolToDispose.Close(); $poolToDispose.Dispose() } catch {}
                }) | Out-Null
                if ($lblInstFetchStatus) {
                    $lblInstFetchStatus.Text = if ($script:Lang -eq 'TR') { 'Denetim iptal edildi.' } else { 'Scan cancelled.' }
                }
                Hide-Cancel -OpKey 'rescan'
                Stop-InstSpinner
                return
            }

            # Tamamlanan çalışma alanlarını topla / Collect completed runspaces
            $completed = @($script:instStoreRunspaces | Where-Object { $_.Handle.IsCompleted })
            foreach ($rs in $completed) {
                try { $rs.PS.EndInvoke($rs.Handle) | Out-Null } catch {}
                try { $rs.PS.Dispose() } catch {}
                [void]$script:instStoreRunspaces.Remove($rs)
            }

            # Arayüzü güncelle / Update UI
            foreach ($item in $script:InstalledApps) {
                if (-not (Test-IsPendingFetch $item.SizeText)) { continue }  # zaten işlendi
                if ($item.Status -eq 'SYSTEM') {
                    # Sistem uygulamalarını atla, sadece SizeText'i güncelle / Skip system apps, only update SizeText
                    $item.SizeText = 'N/A'
                    continue
                }
                $pfn = $item.Url
                $sv = $null
                if ($script:instStoreDict.TryGetValue($pfn, [ref]$sv) -and $sv) {
                    $item.SizeText = $sv
                    if ($sv -eq 'SIDELOAD') {
                        Set-StatusBadge $item (T 'BadgeSideload') '#1C1917' '#A8A29E'
                        $item.SizeText = '-'
                        $item.RowFg = Get-PrimaryFgBrush
                        $item.IsChecked = $false
                    } elseif ($sv -eq 'N/A' -or [string]::IsNullOrEmpty($sv)) {
                        Set-StatusBadge $item (T 'BadgeNA') '#27272A' '#71717A'
                        $item.RowFg = Get-PrimaryFgBrush
                        $item.IsChecked = $false
                    } else {
                        try {
                            $iv  = [Version]$item.Version
                            $svv = [Version]$sv

                            # ── Sürüm şeması farklarını gider / Resolve version schema differences ──────────────────────────
                            # Bir taraf yıl-bazlı (Major >= 2000), diğer semver (Major < 2000) ise
                            # şema geçişi: yıl-bazlı olan taraf her zaman daha yenidir.
                            $ivIsYear  = $iv.Major  -ge 2000
                            $svvIsYear = $svv.Major -ge 2000
                            $majorDiff = [Math]::Abs($iv.Major - $svv.Major)
                            if ($majorDiff -gt 100 -and ($ivIsYear -xor $svvIsYear)) {
                                # Şema geçişi / Schema transition
                                if ($svvIsYear) {
                                    # Mağaza yıl-bazlı → güncelleme var / Store is year-based → update available
                                    Set-StatusBadge $item (T 'BadgeUpdateAvailable') '#2D2612' '#FDE68A'
                                    $item.RowFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString(
                                        $(if ($script:CurrentTheme -in @('Light','iTunes')) { '#92400E' } else { '#FDE68A' })
                                    ))
                                    $item.IsChecked = $true
                                } else {
                                    # Yüklü yıl-bazlı, mağaza semver'e döndü → güncel say
                                    Set-StatusBadge $item (T 'BadgeUpToDate') '#14532D' '#86EFAC'
                                    $item.RowFg = Get-PrimaryFgBrush
                                    $item.IsChecked = $false
                                }
                            } elseif ($majorDiff -gt 100) {
                                # Her iki taraf aynı şemada ama major farkı büyük (nadir)
                                if ($iv.Major -lt $svv.Major -or ($iv.Major -eq $svv.Major -and [Version]::new(0,$iv.Minor,$iv.Build,$iv.Revision) -lt [Version]::new(0,$svv.Minor,$svv.Build,$svv.Revision))) {
                                    Set-StatusBadge $item (T 'BadgeUpdateAvailable') '#2D2612' '#FDE68A'
                                    $item.RowFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString(
                                        $(if ($script:CurrentTheme -in @('Light','iTunes')) { '#92400E' } else { '#FDE68A' })
                                    ))
                                    $item.IsChecked = $true
                                } else {
                                    Set-StatusBadge $item (T 'BadgeUpToDate') '#14532D' '#86EFAC'
                                    $item.RowFg = Get-PrimaryFgBrush
                                    $item.IsChecked = $false
                                }
                            } elseif ($iv -lt $svv) {
                                Set-StatusBadge $item (T 'BadgeUpdateAvailable') '#2D2612' '#FDE68A'
                                $item.RowFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString(
                                    $(if ($script:CurrentTheme -in @('Light','iTunes')) { '#92400E' } else { '#FDE68A' })
                                ))
                                $item.IsChecked = $true
                            } else {
                                Set-StatusBadge $item (T 'BadgeUpToDate') '#14532D' '#86EFAC'
                                $item.RowFg = Get-PrimaryFgBrush
                                $item.IsChecked = $false
                            }
                        } catch {
                            Set-StatusBadge $item (T 'BadgeUnknown') '#27272A' '#A1A1AA'
                            $item.IsChecked = $false
                        }
                    }
                }
            }

            # İlerleme durumunu hesapla / Calculate progress
            $done = ($script:InstalledApps | Where-Object { -not (Test-IsPendingFetch $_.SizeText) }).Count
            $total = $script:instStoreTotal
            if ($lblInstFetchStatus) {
                $lblInstFetchStatus.Text = ((T 'StatusFetching') -f $done, $total)
            }

            # Tüm runspace'ler bitti mi? / Are all runspaces finished?
            if ($script:instStoreRunspaces.Count -eq 0) {
                $script:instStoreTimer.Stop()
                try { $script:instStorePool.Close(); $script:instStorePool.Dispose() } catch {}

                $updateCount = @($script:InstalledApps | Where-Object { $_.Status -eq (T 'BadgeUpdateAvailable') }).Count
                $naCount     = @($script:InstalledApps | Where-Object { $_.Status -eq (T 'BadgeNA') }).Count
                $okCount     = @($script:InstalledApps | Where-Object { $_.Status -eq (T 'BadgeUpToDate') }).Count

                if ($lblInstalledCount) {
                    $lblInstalledCount.Text = ((T 'StatusAppsFound') -f $script:InstalledApps.Count) + '  |  ' + ((T 'StatusUpdatesAvail') -f $updateCount)
                }
                if ($lblInstFetchStatus) {
                    $lblInstFetchStatus.Text = ((T 'StatusDoneSummary') -f $okCount, $updateCount, $naCount)
                }
                Update-InstalledActionButtons
                Set-Status ((T 'StatusCheckComplete') -f $updateCount)
                Hide-Cancel -OpKey 'rescan'
                Stop-InstSpinner
            }
        })
        $script:instStoreTimer.Start()

    } catch {
        Set-Status "Error: $($_.Exception.Message)"
        if ($lblInstalledCount) { $lblInstalledCount.Text = "Error scanning apps" }
    }
}

function Import-DownloadedFiles {
    $script:DlFiles = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    if ($dlCards) { $dlCards.ItemsSource = $script:DlFiles }
    $dlSearchRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($script:DownloadFolder) -and (Test-Path $script:DownloadFolder)) {
        $dlSearchRoots += $script:DownloadFolder
    }
    $desktopDl = Join-Path ([Environment]::GetFolderPath('Desktop')) 'StoreDownload'
    if ((Test-Path $desktopDl) -and $desktopDl -ne $script:DownloadFolder) {
        $dlSearchRoots += $desktopDl
    }
    $dlRoot = if ($dlSearchRoots.Count -gt 0) { $dlSearchRoots[0] } else { $script:DownloadFolder }
    if ($dlSearchRoots.Count -eq 0) {
        if ($lblDlPercent) { $lblDlPercent.Text = '0%' }
        if ($lblDlQueued)  { $lblDlQueued.Text  = '0 / 0' }
        if ($txtLog)       { $txtLog.Text = ((T 'DlFolderNotFound') -f $dlRoot) }
        return
    }

    $files = @($dlSearchRoots | ForEach-Object {
        Get-ChildItem $_ -Recurse -File -Include *.appx,*.appxbundle,*.msix,*.msixbundle,*.exe,*.msi -ErrorAction SilentlyContinue
    }) | Sort-Object LastWriteTime -Descending

    $totalSize = 0L
    foreach ($f in $files) {
        $item = New-Object PackageItem
        $item.FileName  = $f.Name
        $item.SizeText  = Format-Size $f.Length
        $item.SizeBytes = 100L  # progress 100% (already downloaded)
        $item.Url       = $f.FullName
        $item.Version   = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        Set-StatusBadge $item 'Complete' '#14532D' '#86EFAC'
        $item.RowFg = Get-PrimaryFgBrush
        $script:DlFiles.Add($item)
        $totalSize += $f.Length
    }

    if ($lblDlQueued)  { $lblDlQueued.Text  = "0 / $($files.Count)" }
    if ($progDownload) { $progDownload.Value = if ($files.Count -gt 0) { 100 } else { 0 } }
    if ($lblDlPercent) { $lblDlPercent.Text  = if ($files.Count -gt 0) { '100%' } else { '0%' } }
    if ($lblDlSpeed)   { $lblDlSpeed.Text    = Format-Size $totalSize }
    if ($lblDlEta)     { $lblDlEta.Text      = "$($files.Count) file(s)" }

    # Boş durum mesajı / Empty state message
    if ($lblDlEmpty) { $lblDlEmpty.Visibility = if ($files.Count -eq 0) { 'Visible' } else { 'Collapsed' } }

    # Log
    if ($txtLog) {
        $rootsList = $dlSearchRoots -join ', '
        $logLines = @("$($script:Strings[$script:Lang].PageDownloads): $rootsList", "Total: $($files.Count) file(s), $(Format-Size $totalSize)", "")
        foreach ($f in ($files | Select-Object -First 20)) {
            $logLines += "$($f.LastWriteTime.ToString('HH:mm:ss'))  [OK]  $($f.Name)  ($(Format-Size $f.Length))"
        }
        if ($files.Count -gt 20) { $logLines += "... and $($files.Count - 20) more" }
        $txtLog.Text = $logLines -join "`n"
    }
}

function Update-HistoryEmptyState {
    if ($lblHistoryEmpty) {
        $lblHistoryEmpty.Visibility = if ($script:History.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    }
}

function Import-History {
    $lvHistory.ItemsSource = $script:History
    Update-HistoryEmptyState
}

function Add-HistoryEntry([string]$pkg, [string]$size, [string]$result, [string]$bgHex, [string]$fgHex) {
    $item = New-Object PackageItem
    $item.Version  = (Get-Date -Format 'HH:mm:ss')
    $item.FileName = $pkg
    $item.SizeText = $size
    $item.RowFg    = Get-PrimaryFgBrush
    Set-StatusBadge $item $result $bgHex $fgHex
    $script:History.Insert(0, $item)
    Update-HistoryEmptyState
}

# Ayar işleyicileri / Settings handlers
if ($btnRescan) {
    $btnRescan.Add_Click({
        # Çift tıklama koruması: rescan zaten çalışıyorsa hiçbir şey yapma
        if ($script:ActiveOpKeys -and $script:ActiveOpKeys.Contains('rescan')) { return }
        Import-InstalledApps
    })
}

if ($chkShowSystemApps) {
    $chkShowSystemApps.Add_Click({
        # Değiştirilince listeyi yeniden yükle / Reload list on toggle
        Import-InstalledApps
    })
}
if ($chkInstalledAll) {
    $script:_suppressInstHeader = $false
    $chkInstalledAll.Add_Click({
        if ($script:_suppressInstHeader) { return }
        $script:_suppressInstHeader = $true
        try {
            if ($chkInstalledAll.IsChecked -eq $false) {
                foreach ($i in $script:InstalledApps) { $i.IsChecked = $false }
            } else {
                $chkInstalledAll.IsChecked = $true
                foreach ($i in $script:InstalledApps) { $i.IsChecked = $true }
            }
        } catch {}
        $script:_suppressInstHeader = $false
        if (Get-Command Update-InstalledActionButtons -ErrorAction SilentlyContinue) {
            Update-InstalledActionButtons
        }
    })
}
if ($txtInstalledSearch) {
    $txtInstalledSearch.Add_TextChanged({
        $q = $txtInstalledSearch.Text.Trim().ToLowerInvariant()
        if ([string]::IsNullOrEmpty($q)) {
            $lvInstalled.ItemsSource = $script:InstalledApps
        } else {
            $filtered = $script:InstalledApps | Where-Object { $_.FileName.ToLowerInvariant().Contains($q) }
            $lvInstalled.ItemsSource = $filtered
        }
    })
}
if ($btnUpdateSelected) {
    $btnUpdateSelected.Add_Click({
        # Gizlenenler ListView'da yok ama defansif filtre — settings'ten gizli olanları her durumda atla
        $ignoredHidden = if ($script:AppSettings -and $script:AppSettings.InstalledIgnoredApps) { @($script:AppSettings.InstalledIgnoredApps) } else { @() }
        $sel = @($script:InstalledApps | Where-Object { $_.IsChecked -and ($ignoredHidden.Count -eq 0 -or $ignoredHidden -notcontains $_.Url) })
        if ($sel.Count -eq 0) {
            Show-CustomMessageBox -Title (T 'NoSelectionTitle') -Icon Info -Buttons OK `
                -Message ((T 'NoSelectionMsg') -f (T 'BadgeUpdateAvailable')) | Out-Null
            return
        }

        # Kullanıcıya kuyruğu açıkla / Explain queue to user
        $names = @($sel | ForEach-Object { ((T 'UpdateQueueDetail') -f $_.FileName, $_.Version, $_.SizeText) }) -join "`n"
        $res   = Show-CustomMessageBox -Title (T 'UpdateQueueTitle2') -Icon Question -Buttons OKCancel `
                  -Message (((T 'UpdateQueueConfirmMsg') -f $sel.Count) + "`n`n" + (T 'UpdateQueueConfirmSub')) `
                  -Details $names
        if ($res -ne 'OK') { return }

        # Kuyruğa ekle / Add to queue
        $script:UpdateQueue = [System.Collections.Queue]::new()
        foreach ($a in $sel) {
            $script:UpdateQueue.Enqueue([PSCustomObject]@{
                PackageFamilyName = $a.Url
                AppName           = $a.FileName
                InstalledVersion  = $a.Version
                StoreVersion      = $a.SizeText
            })
        }
        $script:UpdateQueueTotal = $sel.Count
        $script:UpdateQueueDone  = 0
        $script:UpdateQueueSuccess = 0

        # Fetch sekmesine geç / Switch to Fetch tab
        $NavList.SelectedIndex = 0
        Start-NextUpdateInQueue
    })
}

# ── Güncelleme kuyruğundan sonraki uygulamayı işle / Process next app from update queue ──────────────────────────
function Start-NextUpdateInQueue {
    # İptal edilirse kuyruğu boşalt ve sessizce çık
    if ($script:cancelDownload -or $script:cancelInstall -or $script:cancelRescan) {
        if ($script:UpdateQueue) { try { $script:UpdateQueue.Clear() } catch {} }
        $script:UpdateQueueTotal   = 0
        $script:UpdateQueueDone    = 0
        $script:UpdateQueueSuccess = 0
        if ($lblInstFetchStatus) { $lblInstFetchStatus.Text = '' }
        Hide-TabProgress -Tab Installed
        return
    }
    if (-not $script:UpdateQueue -or $script:UpdateQueue.Count -eq 0) {
        # Kuyruk bitti / Queue finished
        if ($script:UpdateQueueTotal -gt 0) {
            Set-Status ((T 'StatusUpdateQueueDone') -f $script:UpdateQueueSuccess, $script:UpdateQueueTotal)
            if ($lblInstFetchStatus) { $lblInstFetchStatus.Text = '' }
            Hide-TabProgress -Tab Installed
            Show-CustomMessageBox -Title (T 'UpdateQueueTitle') -Icon Success -Buttons OK `
                -Message (T 'StatusUpdateQueueFinished') `
                -Details ((T 'StatusUpdateQueueProcessed') -f $script:UpdateQueueSuccess, $script:UpdateQueueTotal) | Out-Null
        }
        $script:UpdateQueueTotal = 0
        $script:UpdateQueueDone  = 0
        $script:UpdateQueueSuccess = 0
        return
    }

    $next = $script:UpdateQueue.Dequeue()
    $script:UpdateQueueDone++

    # Ana durum çubuğuna ve Yüklü Uygulamalar fetch durumuna yaz / Write to main status bar and Installed Apps fetch status
    $msg = (T 'StatusUpdateQueue') -f $script:UpdateQueueDone, $script:UpdateQueueTotal, $next.AppName
    Set-Status $msg
    if ($lblInstFetchStatus) { $lblInstFetchStatus.Text = $msg }

    # Tab progress: kuyruk ilerlemesini göster (1/5, 2/5, ...)
    if ($script:UpdateQueueTotal -gt 0) {
        $pct = [int](($script:UpdateQueueDone / $script:UpdateQueueTotal) * 100)
        Show-TabProgress -Tab Installed -Message $msg -Indeterminate $false -Percent $pct
    }

    # ── Alias çözümleme: eski adlı paket varsa yeni canonical adıyla fetch et ────
    # / Alias resolution: if the queued PFN is a legacy name, fetch the canonical package instead.
    $nextPfn       = $next.PackageFamilyName
    $nextBaseName  = ($nextPfn -split '_')[0]
    $canonicalBase = $null
    if ($script:PkgAliasMap -and $script:PkgAliasMap.ContainsKey($nextBaseName.ToLowerInvariant())) {
        $canonicalBase = $script:PkgAliasMap[$nextBaseName.ToLowerInvariant()]
    }

    if ($canonicalBase) {
        # Eski (gömülü) paket var — önce onu kaldır, sonra yeni adıyla kur
        # / Legacy (built-in) package found — remove it first, then install under new name
        Set-Status ("Eski sürüm kaldırılıyor: $nextBaseName -> $canonicalBase")
        try { Uninstall-StoreApp -PackageFamilyName $nextPfn -AppName $next.AppName } catch {}

        # Canonical PFN'yi bul (yeni ad henüz kurulu olmayabilir) / Find canonical PFN (may not be installed yet)
        $canonicalPkg = Get-AppxPackage -AllUsers -Name "$canonicalBase*" -ErrorAction SilentlyContinue | Select-Object -First 1
        $fetchTarget = if ($canonicalPkg) { $canonicalPkg.PackageFamilyName } else {
            # PackageList'teki URL'yi kullan / Use URL from PackageList
            $canonicalEntry = $PackageList | Where-Object { ($_.Identity -split '_')[0] -eq $canonicalBase } | Select-Object -First 1
            if ($canonicalEntry -and $canonicalEntry.Family -match '^https?://') { $canonicalEntry.Family } else { $canonicalBase }
        }
        $cmbPackage.Text = $fetchTarget
    } else {
        # Normal güncelleme — eski adla yüklüyse ve yeni adı canonical listede varsa
        # önce eski paketleri kaldır / Normal update — if canonical, remove any legacy old-name packages first
        if ($script:PkgLegacyNames -and $script:PkgLegacyNames.ContainsKey($nextBaseName.ToLowerInvariant())) {
            $legacyBases = $script:PkgLegacyNames[$nextBaseName.ToLowerInvariant()]
            foreach ($legacyBase in $legacyBases) {
                $legacyPkg = Get-AppxPackage -AllUsers -Name "$legacyBase*" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($legacyPkg) {
                    Set-Status ("Eski sürüm kaldırılıyor: $legacyBase")
                    try { Uninstall-StoreApp -PackageFamilyName $legacyPkg.PackageFamilyName -AppName $legacyBase } catch {}
                }
            }
        }
        $cmbPackage.Text = $nextPfn
    }
    $txtUrl.Text = ''

    # Otomatik indirme / Auto fetch
    if ($btnFetch.IsEnabled) {
        $btnFetch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }

    # Otomatik indirme ve yüklemeyi tetikle / Trigger auto download and install
    $script:AutoDownloadAfterFetch = $true
    $script:AutoInstallAfterDownload = $true
}

# ─── Uygulama kaldırma işlemi / Uninstall application ─────────────────────
function Uninstall-StoreApp {
    param(
        [Parameter(Mandatory=$true)][string]$PackageFamilyName,
        [Parameter(Mandatory=$true)][string]$AppName
    )
    $r = [PSCustomObject]@{
        Success        = $false
        RemovedAny     = $false
        StillInstalled = $false
        Errors         = New-Object System.Collections.ArrayList
        Message        = ''
    }

    # ── Adım 0: İlgili çalışan işlemleri zorla kapat / Step 0: Force-kill related processes ──
    try {
        # AppName ve PackageFamilyName'den kısa isim türet / Derive short name
        $shortName = ($PackageFamilyName -split '_')[0]
        # İşlem adlarını kısa isim ve AppName'den üret / Build candidate process names
        $procCandidates = @(
            $AppName,
            $shortName,
            ($AppName  -replace '\s',''),
            ($shortName -replace '\s','')
        ) | Select-Object -Unique

        foreach ($candidate in $procCandidates) {
            try {
                Get-Process -Name $candidate -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            } catch {}
        }
        # Wildcard ile de dene / Also try wildcard
        try {
            Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like "*$shortName*" -or $_.Name -like "*$AppName*"
            } | Stop-Process -Force -ErrorAction SilentlyContinue
        } catch {}
        Start-Sleep -Milliseconds 800
    } catch {}

    # ── Adım 1: PackageFullName ile doğrudan AllUsers kaldırma (birincil) / Step 1: Direct AllUsers removal by PackageFullName (primary) ──
    try {
        $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                  Where-Object { $_.PackageFamilyName -eq $PackageFamilyName })

        # PackageFamilyName ile bulunamazsa wildcard ile ara / Wildcard fallback if exact match fails
        if ($pkgs.Count -eq 0) {
            $pfnBase = ($PackageFamilyName -split '_')[0]
            $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*$pfnBase*" })
        }

        foreach ($pkg in $pkgs) {
            # Strateji A: AllUsers + PackageFullName / Strategy A: AllUsers + PackageFullName
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                $r.RemovedAny = $true
                continue
            } catch {
                [void]$r.Errors.Add("AllUsers: $($_.Exception.Message)")
            }

            # Strateji B: Mevcut kullanıcı / Strategy B: Current user
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                $r.RemovedAny = $true
                continue
            } catch {
                [void]$r.Errors.Add("CurrentUser: $($_.Exception.Message)")
            }

            # Strateji C: PackageFamilyName ile kaldır / Strategy C: Remove by PackageFamilyName
            try {
                Remove-AppxPackage -Package $pkg.PackageFamilyName -AllUsers -ErrorAction Stop
                $r.RemovedAny = $true
                continue
            } catch {
                [void]$r.Errors.Add("PFN-AllUsers: $($_.Exception.Message)")
            }

            # Strateji D: Paket adı ile / Strategy D: By package Name property
            try {
                $byName = Get-AppxPackage -AllUsers -Name $pkg.Name -ErrorAction SilentlyContinue
                if ($byName) {
                    Remove-AppxPackage -Package $byName.PackageFullName -AllUsers -ErrorAction Stop
                    $r.RemovedAny = $true
                    continue
                }
            } catch {
                [void]$r.Errors.Add("ByName: $($_.Exception.Message)")
            }
        }
    } catch {
        [void]$r.Errors.Add("Pkg enum: $($_.Exception.Message)")
    }

    # ── Adım 2: Provisioned paketi kaldır (yeniden kurulumu engelle) / Step 2: Remove provisioned package (prevent reprovisioning) ──
    try {
        $pfnBase = ($PackageFamilyName -split '_')[0]
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                  Where-Object { $_.PackageName -and (($_.PackageName -split '_')[0] -like "*$pfnBase*") })
        foreach ($pp in $prov) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
                $r.RemovedAny = $true
            } catch {
                [void]$r.Errors.Add("Prov: $($_.Exception.Message)")
            }
        }
    } catch {}

    # ── Adım 3: Son kontrol - hâlâ kurulu mu? / Step 3: Final check ──
    Start-Sleep -Milliseconds 500
    try {
        $pfnBase = ($PackageFamilyName -split '_')[0]
        $check = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                   Where-Object {
                       $_.PackageFamilyName -eq $PackageFamilyName -or
                       $_.Name -like "*$pfnBase*"
                   })
        if ($check.Count -gt 0) { $r.StillInstalled = $true }
    } catch {}

    if (-not $r.StillInstalled) {
        $r.Success = $true
        $r.Message = "Uninstalled: $AppName"
    } else {
        $errTxt = if ($r.Errors.Count -gt 0) { $r.Errors[0] } else { "System-protected or access denied" }
        if ($errTxt.Length -gt 120) { $errTxt = $errTxt.Substring(0, 120) + "..." }
        $r.Message = "Failed: $errTxt"
    }
    return $r
}

# ─── Bağlam menüsü: Kaldır / Context menu: Uninstall ─────────────────────
if ($ctxInstUninstall) {
    $ctxInstUninstall.Add_Click({
        $target = $lvInstalled.SelectedItem
        if (-not $target) { return }

        $appName = $target.FileName
        $pfn     = $target.Url
        if ([string]::IsNullOrWhiteSpace($pfn)) {
            Set-Status "No PackageFamilyName for this item."
            return
        }

        $res = Show-CustomMessageBox -Title (T 'UninstallTitle') -Icon Warning -Buttons YesNo `
                -Message ((T 'UninstallMsg') -f $appName) `
                -Details ((T 'UninstallPFN') -f $pfn)
        if ($res -ne 'Yes') { return }

        Set-Status "Uninstalling: $appName..."
        Set-StatusBadge $target 'UNINSTALLING' '#2A2419' '#FDE68A'

        $result = Uninstall-StoreApp -PackageFamilyName $pfn -AppName $appName

        if ($result.Success) {
            # Listeden çıkar / Remove from list
            try { [void]$script:InstalledApps.Remove($target) } catch {}
            if ($lblInstalledCount) {
                $lblInstalledCount.Text = ((T 'StatusAppsFound') -f $script:InstalledApps.Count)
            }
            Set-Status $result.Message
            Add-HistoryEntry $appName '-' 'Uninstalled' '#450A0A' '#FCA5A5'
        } else {
            Set-StatusBadge $target 'UNINSTALL FAILED' '#450A0A' '#FCA5A5'
            Set-Status $result.Message
        }
    })
}

if ($ctxInstHideApp) {
    $ctxInstHideApp.Add_Click({
        $target = $lvInstalled.SelectedItem
        if (-not $target) { return }
        $pfn = $target.Url  # PackageFamilyName Url alanında saklanıyor
        if ([string]::IsNullOrWhiteSpace($pfn)) { return }
        # InstalledIgnoredApps listesine ekle
        if (-not $script:AppSettings.InstalledIgnoredApps) { $script:AppSettings.InstalledIgnoredApps = @() }
        if ($script:AppSettings.InstalledIgnoredApps -notcontains $pfn) {
            $script:AppSettings.InstalledIgnoredApps = @($script:AppSettings.InstalledIgnoredApps) + $pfn
        }
        Save-AppSettings
        # Listeden anında kaldır
        try { [void]$script:InstalledApps.Remove($target) } catch {}
        if ($lblInstalledCount) {
            $lblInstalledCount.Text = ((T 'StatusAppsFound') -f $script:InstalledApps.Count)
        }
        Set-Status ((T 'InstHideApp') + ": $($target.FileName)")
        # Buton state'lerini yenile (seçili sayacı vb.)
        if (Get-Command Update-InstalledActionButtons -ErrorAction SilentlyContinue) { Update-InstalledActionButtons }
    })
}

# ─── Seçilenleri Kaldır / Uninstall Selected (batch) ─────────────────────────────────────
if ($btnUninstallSelected) {
    $btnUninstallSelected.Add_Click({
        # Gizlenenler ListView'da yok ama defansif filtre — settings'ten gizli olanları her durumda atla
        $ignoredHidden = if ($script:AppSettings -and $script:AppSettings.InstalledIgnoredApps) { @($script:AppSettings.InstalledIgnoredApps) } else { @() }
        $sel = @($script:InstalledApps | Where-Object { $_.IsChecked -and ($ignoredHidden.Count -eq 0 -or $ignoredHidden -notcontains $_.Url) })
        if ($sel.Count -eq 0) {
            Show-CustomMessageBox -Title (T 'NoSelectionTitle') -Icon Info -Buttons OK `
                -Message (T 'NoSelectionUninstall') | Out-Null
            return
        }

        # Yönetici kontrolü / Admin check
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            $warnRes = Show-CustomMessageBox -Title (T 'AdminTitle') -Icon Warning -Buttons YesNo `
                -Message (T 'AdminMsgUpdate') `
                -Details (T 'AdminContinue')
            if ($warnRes -ne 'Yes') { return }
        }

        # Onay / Confirmation
        $names = @($sel | ForEach-Object { " - $($_.FileName)" }) -join "`n"
        $res   = Show-CustomMessageBox -Title (T 'UninstallSelectedTitle') -Icon Warning -Buttons YesNo `
                  -Message ((T 'UninstallSelectedMsg') -f $sel.Count) `
                  -Details $names
        if ($res -ne 'Yes') { return }

        $btnUninstallSelected.IsEnabled = $false
        $btnUpdateSelected.IsEnabled    = $false
        $btnRescan.IsEnabled            = $false

        $total      = $sel.Count
        $successCnt = 0
        $failCnt    = 0
        $current    = 0
        $toRemove   = New-Object System.Collections.ArrayList

        Show-TabProgress -Tab Installed -Message ((T 'BtnUninstallSelected') + ' 0/' + $total) -Indeterminate $false -Percent 0

        foreach ($item in $sel) {
            $current++
            $appName = $item.FileName
            $pfn     = $item.Url
            $msg = ("$(T 'BtnUninstallSelected') {0}/{1}: {2}..." -f $current, $total, $appName)
            Set-Status $msg
            $pct = [int](($current / $total) * 100)
            Show-TabProgress -Tab Installed -Message $msg -Indeterminate $false -Percent $pct
            Set-StatusBadge $item 'UNINSTALLING' '#2A2419' '#FDE68A'
            # Arayüzün yenilenmesine izin ver / Allow UI to refresh
            $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

            if ([string]::IsNullOrWhiteSpace($pfn)) {
                Set-StatusBadge $item 'NO PFN' '#450A0A' '#FCA5A5'
                $failCnt++
                continue
            }

            $result = Uninstall-StoreApp -PackageFamilyName $pfn -AppName $appName

            if ($result.Success) {
                $successCnt++
                [void]$toRemove.Add($item)
                Add-HistoryEntry $appName '-' 'Uninstalled' '#450A0A' '#FCA5A5'
            } else {
                Set-StatusBadge $item 'UNINSTALL FAILED' '#450A0A' '#FCA5A5'
                $failCnt++
            }
        }

        # Başarıyla kaldırılanları listeden çıkar / Remove successfully uninstalled from list
        foreach ($it in $toRemove) {
            try { [void]$script:InstalledApps.Remove($it) } catch {}
        }
        if ($lblInstalledCount) {
            $lblInstalledCount.Text = ((T 'StatusAppsFound') -f $script:InstalledApps.Count)
        }

        $btnUninstallSelected.IsEnabled = $true
        $btnUpdateSelected.IsEnabled    = $true
        $btnRescan.IsEnabled            = $true
        Hide-TabProgress -Tab Installed
        Set-Status (((T 'UninstallResultMsg') + " {0}/{1}") -f $successCnt, ($successCnt + $failCnt))

        $iconType = if ($failCnt -gt 0) { 'Warning' } else { 'Success' }
        Show-CustomMessageBox -Title (T 'UninstallResultTitle') -Icon $iconType -Buttons OK `
            -Message (T 'UninstallResultMsg') `
            -Details (((T 'UninstallSuccess') -f $successCnt) + "`n" + ((T 'UninstallFailed') -f $failCnt)) | Out-Null
    })
}

# ─── Bağlam menüsü: Kopyalama yardımcıları / Context menu: Copy helpers ─────────────────────────────────────
if ($ctxInstCopyPfn) {
    $ctxInstCopyPfn.Add_Click({
        $target = $lvInstalled.SelectedItem
        if ($target -and $target.Url) {
            [System.Windows.Clipboard]::SetText($target.Url)
            Set-Status "Copied PFN: $($target.Url)"
        }
    })
}
if ($ctxInstCopyName) {
    $ctxInstCopyName.Add_Click({
        $target = $lvInstalled.SelectedItem
        if ($target -and $target.FileName) {
            [System.Windows.Clipboard]::SetText($target.FileName)
            Set-Status "Copied name: $($target.FileName)"
        }
    })
}
if ($ctxInstCopyVer) {
    $ctxInstCopyVer.Add_Click({
        $target = $lvInstalled.SelectedItem
        if ($target -and $target.Version) {
            [System.Windows.Clipboard]::SetText($target.Version)
            Set-Status "Copied version: $($target.Version)"
        }
    })
}
if ($ctxInstOpenStore) {
    $ctxInstOpenStore.Add_Click({
        $target = $lvInstalled.SelectedItem
        if (-not $target) { return }

        $pfn  = $target.Url
        $name = $target.FileName

        try {
            if (-not [string]::IsNullOrWhiteSpace($pfn)) {
                # Ürün sayfasını aç / Open product page
                Start-Process "ms-windows-store://pdp/?PFN=$pfn"
            } elseif (-not [string]::IsNullOrWhiteSpace($name)) {
                # Görünen adla ara / Fallback: search by display name
                Start-Process "ms-windows-store://search/?query=$([Uri]::EscapeDataString($name))"
            }
        } catch { Set-Status "Mağaza açılamadı: $($_.Exception.Message)" }
    })
}

if ($ctxInstOpenFolder) {
    $ctxInstOpenFolder.Add_Click({
        $target = $lvInstalled.SelectedItem
        if ($target -and $target.FileName) {
            try {
                # Kurulum konumunu bul / Find install location
                $pkg = Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq $target.FileName } | Select-Object -First 1
                if (-not $pkg) { $pkg = Get-AppxPackage | Where-Object { $_.Name -eq $target.FileName } | Select-Object -First 1 }
                if ($pkg -and $pkg.InstallLocation -and (Test-Path $pkg.InstallLocation)) {
                    Start-Process explorer.exe $pkg.InstallLocation
                } else {
                    Set-Status "Install folder not found for: $($target.FileName)"
                }
            } catch {
                Set-Status "Error: $($_.Exception.Message)"
            }
        }
    })
}

# ─── Export List butonu / Export List button ──────────────────────────────────
if ($btnExportList) {
    $btnExportList.Add_Click({
        # Veri var mı kontrol et / Check if data exists
        if (-not $script:InstalledApps -or $script:InstalledApps.Count -eq 0) {
            Set-Status (T 'ExportNoData')
            return
        }

        # SaveFileDialog — JSON varsayılan / JSON is default
        Add-Type -AssemblyName Microsoft.Win32

        $dlg             = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Title       = (T 'ExportDialogTitle')
        $dlg.Filter      = "$(T 'ExportFilterJson')|$(T 'ExportFilterCsv')|All Files (*.*)|*.*"
        $dlg.FilterIndex = 1
        $dlg.FileName    = "InstalledApps_$(Get-Date -Format 'yyyyMMdd_HHmm')"
        $dlg.DefaultExt  = '.json'

        $result = $dlg.ShowDialog()
        if (-not $result) { return }

        $outPath = $dlg.FileName
        $ext     = [System.IO.Path]::GetExtension($outPath).ToLowerInvariant()

        try {
            # PackageList'ten hızlı arama için hashtable: AppBaseName → apps.microsoft.com URL
            # Build fast lookup: AppBaseName → apps.microsoft.com URL
            $pkgLookup = @{}
            if ($PackageList) {
                foreach ($entry in $PackageList) {
                    $id  = $entry.Identity.Trim()
                    $fam = $entry.Family.Trim()
                    if ($id -and $fam -match '^https?://') {
                        $pkgLookup[$id] = $fam
                    }
                }
            }

            # Her uygulama için veri satırı oluştur / Build data rows
            $rows = @(foreach ($item in $script:InstalledApps) {
                $pfn      = [string]$item.Url
                $appName  = [string]$item.FileName
                $instVer  = [string]$item.Version
                $rawStore = [string]$item.SizeText
                $storeVer = if ($rawStore -match '^\.+$' -or [string]::IsNullOrWhiteSpace($rawStore)) { '' } else { $rawStore }
                $status   = [string]$item.Status

                # PFN'den temel adı çıkar: "Microsoft.Paint_8wekyb3d8bbwe" → "Microsoft.Paint"
                $baseName = if ($pfn -match '^([^_]+)_') { $Matches[1] } else { $pfn }

                # PackageList'te ara → apps.microsoft.com/detail/XXXX URL'si
                # Lookup in PackageList for apps.microsoft.com URL
                $storeUrl = if ($pkgLookup.ContainsKey($baseName)) {
                    $pkgLookup[$baseName]
                } elseif ($pkgLookup.ContainsKey($appName)) {
                    $pkgLookup[$appName]
                } elseif (-not [string]::IsNullOrWhiteSpace($pfn) -and $pfn -notmatch '^https?://') {
                    # Tabloda yoksa ms-windows-store protokol URL'si üret / Fallback
                    "ms-windows-store://pdp/?PFN=$pfn"
                } else { '' }

                [PSCustomObject]@{
                    AppName           = $appName
                    PackageFamilyName = $pfn
                    InstalledVersion  = $instVer
                    StoreVersion      = $storeVer
                    Status            = $status
                    StoreUrl          = $storeUrl
                }
            })

            # ── JSON ──────────────────────────────────────────────────────────────
            if ($ext -eq '.json') {
                $jsonArr = @(foreach ($r in $rows) {
                    [ordered]@{
                        AppName           = $r.AppName
                        PackageFamilyName = $r.PackageFamilyName
                        InstalledVersion  = $r.InstalledVersion
                        StoreVersion      = $r.StoreVersion
                        Status            = $r.Status
                        StoreUrl          = $r.StoreUrl
                    }
                })
                $json      = $jsonArr | ConvertTo-Json -Depth 3
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)

            # ── CSV ───────────────────────────────────────────────────────────────
            } else {
                $esc   = { param([string]$v) '"' + ($v -replace '"', '""') + '"' }
                $lines = [System.Collections.Generic.List[string]]::new()
                $lines.Add('"AppName","PackageFamilyName","InstalledVersion","StoreVersion","Status","StoreUrl"')
                foreach ($r in $rows) {
                    $lines.Add((@(
                        (& $esc $r.AppName),
                        (& $esc $r.PackageFamilyName),
                        (& $esc $r.InstalledVersion),
                        (& $esc $r.StoreVersion),
                        (& $esc $r.Status),
                        (& $esc $r.StoreUrl)
                    ) -join ','))
                }
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllLines($outPath, $lines.ToArray(), $utf8NoBom)
            }

            Set-Status ((T 'ExportSuccess') -f $rows.Count, $outPath)
            Start-Process explorer.exe "/select,`"$outPath`""

        } catch {
            Set-Status ((T 'ExportError') -f $_.Exception.Message)
        }
    })
}

if ($btnApplySettings) {
    $btnApplySettings.Add_Click({
        # Dil
        if ($cmbSettingsLang) {
            $script:Lang = if ($cmbSettingsLang.SelectedIndex -eq 0) { 'EN' } else { 'TR' }
        }
        # Tema / Theme
        if ($cmbSettingsTheme) {
            $themeName = switch ($cmbSettingsTheme.SelectedIndex) {
                0 { 'Dark' }
                1 { 'Light' }
                2 { 'iTunes' }
                3 { 'Intel' }
                4 { 'Dracula' }
                5 { 'Nord' }
                6 { 'Solarized Dark' }
                7 { 'Solarized Light' }
                8 { 'Monokai' }
                9 { 'Synthwave' }
                10 { 'Cyberpunk' }
                11 { 'Gruvbox' }
                12 { 'Tokyo Night' }
                13 { 'Catppuccin' }
                14 { 'GitHub Dark' }
                default { 'Dark' }
            }
            Set-AppTheme -ThemeName $themeName
        }
        # Dalga Overlay / Wave Overlay
        if ($cmbSettingsOverlay -and $cmbSettingsOverlay.SelectedItem) {
            $ovType = Get-ComboContentString $cmbSettingsOverlay.SelectedItem
            Set-BackgroundOverlay -OverlayType $ovType
        }
        # Mimari — tüm sayfalarda senkronize et / Sync Arch across all pages
        if ($cmbSettingsArch -and $cmbSettingsArch.SelectedItem) {
            $archStr = Get-ComboContentString $cmbSettingsArch.SelectedItem
            if ($archStr) { Sync-ArchSelection -ArchLabel $archStr }
        }
        # Kanal — tüm sayfalarda senkronize et / Sync Ring across all pages
        if ($cmbSettingsRing -and $cmbSettingsRing.SelectedItem) {
            $ringStr = Get-ComboContentString $cmbSettingsRing.SelectedItem
            if ($ringStr) { Sync-RingSelection -RingLabel $ringStr }
        }
        # Zorla yeniden yükle / Force reinstall
        if ($chkForceReinstall) {
            $script:AppSettings.ForceReinstall = [bool]$chkForceReinstall.IsChecked
        }
        # Kurulumdan sonra sil / Delete after install
        if ($chkDeleteAfterInstall) {
            $script:AppSettings.DeleteAfterInstall = [bool]$chkDeleteAfterInstall.IsChecked
        }
        # Dili uygula / Apply language
        Set-Language
        # Kaydet / Save
        Save-AppSettings
        $statusMsg = if ($script:Lang -eq 'TR') { 'Ayarlar uygulandı.' } else { 'Settings applied.' }
        Set-Status $statusMsg
    })
}

if ($btnChangeDlFolder) {
    $btnChangeDlFolder.Add_Click({
        $fd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fd.SelectedPath = $script:DownloadFolder
        if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:DownloadFolder = $fd.SelectedPath
            if ($lblDlFolder) { $lblDlFolder.Text = $script:DownloadFolder }
            Save-AppSettings
        }
    })
}
if ($cmbSettingsLang) {
    $cmbSettingsLang.Add_SelectionChanged({
        if ($script:InitInProgress) { return }
        $script:Lang = if ($cmbSettingsLang.SelectedIndex -eq 0) { 'EN' } else { 'TR' }
        Set-Language
        Save-AppSettings
    })
}

# NOT: Ring/Arch ComboBox'ları için Add_SelectionChanged handler'ları ContentRendered
# içinde, açılış tamamlandıktan SONRA bağlanır (aşağıda). Böylece açılış sırasında
# combo'lar doldurulurken Save-AppSettings asla tetiklenmez.
# NOTE: Ring/Arch SelectionChanged handlers are attached LATER inside ContentRendered,
# after init completes. This guarantees no Save during startup combo population.

if ($chkForceReinstall) {
    $chkForceReinstall.Add_Click({
        if ($script:InitInProgress) { return }
        $script:AppSettings.ForceReinstall = [bool]$chkForceReinstall.IsChecked
        Save-AppSettings
    })
}
if ($chkDeleteAfterInstall) {
    $chkDeleteAfterInstall.Add_Click({
        if ($script:InitInProgress) { return }
        $script:AppSettings.DeleteAfterInstall = [bool]$chkDeleteAfterInstall.IsChecked
        Save-AppSettings
    })
}
function Get-WingetVersionInfo {
    try {
        $out = winget --version 2>&1 | Out-String
        $ver = ($out -split "`r?`n" | Where-Object { $_ -match 'v[\d.]+' } | Select-Object -First 1).Trim()
        return $ver
    } catch { return 'Bulunamadı' }
}

# ── Winget Güncelle buton handler'ları Settings sekmesi açılınca bağlanır ────
# (bkz. NavList.Add_SelectionChanged idx=5 bloğu)

$NavList.Add_SelectionChanged({
    Set-PageHeader
    # Sekme görünürlüğü / Tab visibility
    $idx = $NavList.SelectedIndex
    $lvPackages.Visibility  = if ($idx -eq 0) { 'Visible' } else { 'Collapsed' }
    $lvInstalled.Visibility = if ($idx -eq 1) { 'Visible' } else { 'Collapsed' }
    if ($pnlWinget) { $pnlWinget.Visibility = if ($idx -eq 2) { 'Visible' } else { 'Collapsed' } }
    $pnlDownloads.Visibility= if ($idx -eq 3) { 'Visible' } else { 'Collapsed' }
    $lvHistory.Visibility   = if ($idx -eq 4) { 'Visible' } else { 'Collapsed' }
    $pnlSettings.Visibility = if ($idx -eq 5) { 'Visible' } else { 'Collapsed' }
    if ($lblHistoryEmpty)   { $lblHistoryEmpty.Visibility = if ($idx -eq 4 -and $script:History.Count -eq 0) { 'Visible' } else { 'Collapsed' } }

    $fetchToolbar.Visibility     = if ($idx -eq 0) { 'Visible' } else { 'Collapsed' }
    $installedToolbar.Visibility = if ($idx -eq 1) { 'Visible' } else { 'Collapsed' }
    $inputCard.Visibility        = if ($idx -eq 0) { 'Visible' } else { 'Collapsed' }
    if ($statusBar) { $statusBar.Visibility = if ($idx -eq 0) { 'Visible' } else { 'Collapsed' } }
    # Alt bar: sadece Fetch (0) sekmesinde göster — ama btnCancel her zaman kendi visibility'sini korur
    if ($bottomBar) {
        $bottomBar.Visibility = if ($idx -eq 0) { 'Visible' } else { 'Collapsed' }
        # btnCancel aktif bir islem varsa her sekmede gorunmeli
        if ($btnCancel -and $btnCancel.Visibility -eq 'Visible') {
            $bottomBar.Visibility = 'Visible'
        }
    }
    if ($idx -eq 1 -and $lvInstalled.Items.Count -eq 0) { Import-InstalledApps }
    if ($idx -eq 2) { Initialize-WingetTab }
    if ($idx -eq 3) { Import-DownloadedFiles }
    if ($idx -eq 5) {
        $lblDlFolder.Text = $script:DownloadFolder
        $lblRuntime.Text = "PowerShell $($PSVersionTable.PSVersion)"
        # Combo'ları ayarlardan yükle — sync flag'leriyle event döngüsünü engelle
        $script:SyncingRing = $true
        $script:SyncingArch = $true
        try {
            if ($cmbSettingsLang)  { $cmbSettingsLang.SelectedIndex  = if ($script:Lang -eq 'EN') { 0 } else { 1 } }
            if ($cmbSettingsTheme) {
                $cmbSettingsTheme.SelectedIndex = switch ($script:CurrentTheme) {
                    'Dark'   { 0 }
                    'Light'  { 1 }
                    'iTunes' { 2 }
                    'Intel'  { 3 }
                    'Dracula'{ 4 }
                    'Nord'   { 5 }
                    'Solarized Dark' { 6 }
                    'Solarized Light' { 7 }
                    'Monokai' { 8 }
                    'Synthwave' { 9 }
                    'Cyberpunk' { 10 }
                    'Gruvbox' { 11 }
                    'Tokyo Night' { 12 }
                    'Catppuccin' { 13 }
                    'GitHub Dark' { 14 }
                    default  { 0 }
                }
            }
            if ($cmbSettingsArch)  {
                $ai = @('x64','x86','ARM64','ARM').IndexOf($script:AppSettings.DefaultArch)
                if ($ai -ge 0) { $cmbSettingsArch.SelectedIndex = $ai }
            }
            if ($cmbSettingsRing)  {
                $ri = @('Retail','Preview','WIS','WIF','Slow','Fast').IndexOf($script:AppSettings.DefaultRing)
                if ($ri -ge 0) { $cmbSettingsRing.SelectedIndex = $ri }
            }
            if ($chkForceReinstall) {
                $chkForceReinstall.IsChecked = [bool]$script:AppSettings.ForceReinstall
            }
            if ($cmbSettingsOverlay) {
                $currentOv = 'None'
                if ($waveCanvas -and $waveCanvas.Visibility -eq [System.Windows.Visibility]::Visible) { $currentOv = 'Wave' }
                elseif ($gridCanvas -and $gridCanvas.Visibility -eq [System.Windows.Visibility]::Visible) { $currentOv = 'Grid' }
                $ovIdx = @('None','Wave','Grid').IndexOf($currentOv)
                if ($ovIdx -ge 0) { $cmbSettingsOverlay.SelectedIndex = $ovIdx }
            }
        } finally {
            $script:SyncingRing = $false
            $script:SyncingArch = $false
        }

        # ── Winget sürüm göster + butonları bağla (Settings sekmesi her açılınca) ──
        if ($lblWingetVersionVal) { $lblWingetVersionVal.Text = '⟳ Kontrol ediliyor...' }
        if ($lblWingetUpdateStatus) { $lblWingetUpdateStatus.Visibility = 'Collapsed' }

        # Sürüm kontrolü (runspace — UI thread'i bloklamaz)
        $script:_wgVerRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:_wgVerRS.Open()
        $script:_wgVerPS = [System.Management.Automation.PowerShell]::Create()
        $script:_wgVerPS.Runspace = $script:_wgVerRS
        [void]$script:_wgVerPS.AddScript({ (winget --version 2>&1) -join '' })
        $script:_wgVerHandle = $script:_wgVerPS.BeginInvoke()
        $script:_wgVerPollTmr = New-Object System.Windows.Threading.DispatcherTimer
        $script:_wgVerPollTmr.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:_wgVerPollTmr.Add_Tick({
            if (-not $script:_wgVerHandle.IsCompleted) { return }
            $script:_wgVerPollTmr.Stop()
            try {
                $v = $script:_wgVerPS.EndInvoke($script:_wgVerHandle) | Select-Object -First 1
                $script:_wgVerPS.Dispose(); $script:_wgVerRS.Close(); $script:_wgVerRS.Dispose()
                if ($lblWingetVersionVal) {
                    $lblWingetVersionVal.Text = if ($v -match 'v[\d.]+') { $v.Trim() } else { 'Bulunamadı' }
                }
            } catch { if ($lblWingetVersionVal) { $lblWingetVersionVal.Text = 'Hata' } }
        })
        $script:_wgVerPollTmr.Start()

        # Kontrol Et butonu — sadece bir kez bağla
        if ($btnCheckWingetVersion -and -not $script:_wgCheckBound) {
            $script:_wgCheckBound = $true
            $btnCheckWingetVersion.Add_Click({
                if ($lblWingetVersionVal)   { $lblWingetVersionVal.Text = '⟳ Kontrol ediliyor...' }
                if ($lblWingetUpdateStatus) { $lblWingetUpdateStatus.Visibility = 'Collapsed' }
                $script:_wgCkRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $script:_wgCkRS.Open()
                $script:_wgCkPS = [System.Management.Automation.PowerShell]::Create(); $script:_wgCkPS.Runspace = $script:_wgCkRS
                [void]$script:_wgCkPS.AddScript({ (winget --version 2>&1) -join '' })
                $script:_wgCkHandle = $script:_wgCkPS.BeginInvoke()
                $script:_wgCkTmr = New-Object System.Windows.Threading.DispatcherTimer
                $script:_wgCkTmr.Interval = [TimeSpan]::FromMilliseconds(200)
                $script:_wgCkTmr.Add_Tick({
                    if (-not $script:_wgCkHandle.IsCompleted) { return }
                    $script:_wgCkTmr.Stop()
                    try {
                        $v2 = $script:_wgCkPS.EndInvoke($script:_wgCkHandle) | Select-Object -First 1
                        $script:_wgCkPS.Dispose(); $script:_wgCkRS.Close(); $script:_wgCkRS.Dispose()
                        if ($lblWingetVersionVal) {
                            $lblWingetVersionVal.Text = if ($v2 -match 'v[\d.]+') { $v2.Trim() } else { 'Bulunamadı' }
                        }
                    } catch { if ($lblWingetVersionVal) { $lblWingetVersionVal.Text = 'Hata' } }
                })
                $script:_wgCkTmr.Start()
            })
        }

        # Güncelle butonu — sadece bir kez bağla
        if ($btnUpdateWinget -and -not $script:_wgUpdBound) {
            $script:_wgUpdBound = $true
            $btnUpdateWinget.Add_Click({
                $btnUpdateWinget.IsEnabled  = $false
                $script:_wgLogFile = [System.IO.Path]::Combine($env:TEMP, "wg_upd_$PID.txt")
                '' | Set-Content $script:_wgLogFile -Encoding UTF8 -Force
                $mkBrush = { param($c) [System.Windows.Media.BrushConverter]::new().ConvertFromString($c) }

                if ($lblWingetUpdateStatus) {
                    $lblWingetUpdateStatus.Text       = '⟳ Adım 1/4 — başlatılıyor...'
                    $lblWingetUpdateStatus.Foreground = (& $mkBrush '#FDE68A')
                    $lblWingetUpdateStatus.Visibility = 'Visible'
                }
                if ($progWingetUpdate) { $progWingetUpdate.Value = 0; $progWingetUpdate.Visibility = 'Collapsed' }
                if ($lblWingetVersionVal) { $lblWingetVersionVal.Text = 'Güncelleniyor...' }

                # Güncelleme işi runspace'te çalışır, ilerleme log dosyasına yazılır
                $script:_wgUpdRS2 = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                $script:_wgUpdRS2.Open()
                $script:_wgUpdPS2 = [System.Management.Automation.PowerShell]::Create()
                $script:_wgUpdPS2.Runspace = $script:_wgUpdRS2
                [void]$script:_wgUpdPS2.AddScript({
                    param($lf)
                    function WLog { param($m) Add-Content $lf -Value $m -Encoding UTF8 -Force }

                    # ── Winget mevcut mu? Yoksa CLI adımlarını (1-3) atla, direkt GitHub'a (4) git ──
                    $wingetExists = $false
                    try {
                        $cmd = Get-Command winget -ErrorAction SilentlyContinue
                        if ($cmd) { $wingetExists = $true }
                    } catch { $wingetExists = $false }

                    if (-not $wingetExists) {
                        WLog 'PROG:⟳ Winget yüklü değil — GitHub üzerinden kurulum yapılacak...'
                    }

                    # ── Adım 1-3: Winget CLI ile güncelleme (winget yüklüyse) ──
                    if ($wingetExists) {
                        try {
                            WLog 'PROG:⟳ Adım 1/4 — winget kaynağından güncelleme deneniyor...'
                            $null = winget upgrade --id Microsoft.DesktopAppInstaller --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1
                            if ($LASTEXITCODE -eq 0) { WLog 'OK:✔ Winget başarıyla güncellendi! Uygulamayı yeniden başlatın.'; return }
                        } catch {
                            WLog "PROG:⟳ Adım 1 atlandı: $($_.Exception.Message -replace '[\r\n]+',' ')"
                        }

                        try {
                            WLog 'PROG:⟳ Adım 2/4 — msstore kaynağından deneniyor...'
                            $null = winget upgrade --id Microsoft.DesktopAppInstaller --source msstore --silent --accept-source-agreements --accept-package-agreements 2>&1
                            if ($LASTEXITCODE -eq 0) { WLog 'OK:✔ Winget (msstore) güncellendi! Uygulamayı yeniden başlatın.'; return }
                        } catch {
                            WLog "PROG:⟳ Adım 2 atlandı: $($_.Exception.Message -replace '[\r\n]+',' ')"
                        }

                        try {
                            WLog 'PROG:⟳ Adım 3/4 — Store ürün ID ile deneniyor...'
                            $null = winget upgrade --id 9NBLGGH4NNS1 --silent --accept-source-agreements --accept-package-agreements 2>&1
                            if ($LASTEXITCODE -eq 0) { WLog 'OK:✔ Winget Store üzerinden güncellendi! Uygulamayı yeniden başlatın.'; return }
                        } catch {
                            WLog "PROG:⟳ Adım 3 atlandı: $($_.Exception.Message -replace '[\r\n]+',' ')"
                        }
                    }

                    # ── Adım 4: GitHub'dan indir ve kur (her zaman dener — winget yoksa da) ──
                    try {
                        $stepLabel = if ($wingetExists) { 'Adım 4/4' } else { 'Adım 1/1' }
                        WLog "PROG:⟳ $stepLabel — GitHub son sürüm indiriliyor..."
                        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
                        $hdrs = @{ 'User-Agent' = 'Mozilla/5.0 MSAM-Updater' }
                        $rel  = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers $hdrs -ErrorAction Stop

                        # Önce ana .msixbundle, sonra Bağımlılıklar (License/VCLibs/UI.Xaml) — sırayla kur
                        $mainAsset = $rel.assets | Where-Object { $_.name -match '\.msixbundle$' } | Select-Object -First 1
                        $licAsset  = $rel.assets | Where-Object { $_.name -match 'License.*\.xml$'   } | Select-Object -First 1

                        if (-not $mainAsset) {
                            WLog 'FAIL:✘ GitHub release içinde .msixbundle bulunamadı.'
                            return
                        }

                        # Ortak indirici fonksiyon (gerçek zamanlı progress'li)
                        $downloadFile = {
                            param($url, $outPath, $label, $approxSizeMB)
                            $req = [System.Net.HttpWebRequest]::Create($url)
                            $req.UserAgent = 'Mozilla/5.0 MSAM-Updater'
                            $req.Timeout = 600000; $req.ReadWriteTimeout = 600000
                            $resp     = $req.GetResponse()
                            $total    = $resp.ContentLength
                            $stream   = $resp.GetResponseStream()
                            $fs       = [System.IO.File]::Create($outPath)
                            $buf      = New-Object byte[] 65536
                            $recv     = 0
                            $sw       = [System.Diagnostics.Stopwatch]::StartNew()
                            try {
                                while ($true) {
                                    $read = $stream.Read($buf, 0, $buf.Length)
                                    if ($read -le 0) { break }
                                    $fs.Write($buf, 0, $read); $recv += $read
                                    if ($recv % 524288 -lt 65536) {
                                        $pct     = if ($total -gt 0) { [int]($recv * 100 / $total) } else { 0 }
                                        $recvMB  = [math]::Round($recv / 1MB, 1)
                                        $totalMB = if ($total -gt 0) { [math]::Round($total / 1MB, 1) } else { $approxSizeMB }
                                        $elapsed = $sw.Elapsed.TotalSeconds
                                        $speed   = if ($elapsed -gt 0.5) { [math]::Round($recv / $elapsed / 1MB, 1) } else { 0 }
                                        WLog "PROG:⟳ $label`: $recvMB / $totalMB MB ($pct%) — $speed MB/s"
                                    }
                                }
                            } finally {
                                $fs.Close(); $stream.Close(); $resp.Close(); $sw.Stop()
                            }
                        }

                        # 1) Bağımlılıkları indir/kur — VCLibs ve UI.Xaml (Win10 + bazı Win11 için zorunlu)
                        $depFiles = @()
                        try {
                            $arch = switch -regex ($env:PROCESSOR_ARCHITECTURE) {
                                '64'    { 'x64' }
                                'ARM64' { 'arm64' }
                                default { 'x86' }
                            }

                            # VCLibs
                            $vcUrl  = "https://aka.ms/Microsoft.VCLibs.$arch.14.00.Desktop.appx"
                            $vcPath = "$env:TEMP\Microsoft.VCLibs.$arch.14.00.Desktop.appx"
                            WLog "PROG:⟳ Bağımlılık indiriliyor: VCLibs ($arch)..."
                            try {
                                & $downloadFile $vcUrl $vcPath 'VCLibs' 4
                                $depFiles += $vcPath
                            } catch {
                                WLog "PROG:⟳ VCLibs indirilemedi (atlanıyor): $($_.Exception.Message -replace '[\r\n]+',' ')"
                            }

                            # UI.Xaml 2.8.x — winget-cli releases'da genelde ek asset olarak bulunur
                            $xamlAsset = $rel.assets | Where-Object { $_.name -match 'Microsoft\.UI\.Xaml.*\.appx$' } | Select-Object -First 1
                            if ($xamlAsset) {
                                $xamlPath = "$env:TEMP\$($xamlAsset.name)"
                                WLog "PROG:⟳ Bağımlılık indiriliyor: $($xamlAsset.name)..."
                                try {
                                    & $downloadFile $xamlAsset.browser_download_url $xamlPath 'UI.Xaml' ([math]::Round($xamlAsset.size / 1MB, 1))
                                    $depFiles += $xamlPath
                                } catch {
                                    WLog "PROG:⟳ UI.Xaml indirilemedi (atlanıyor): $($_.Exception.Message -replace '[\r\n]+',' ')"
                                }
                            }
                        } catch {
                            WLog "PROG:⟳ Bağımlılıklar atlandı: $($_.Exception.Message -replace '[\r\n]+',' ')"
                        }

                        # 2) Ana paketi indir
                        $sz     = [math]::Round($mainAsset.size / 1MB, 1)
                        WLog "PROG:⟳ İndiriliyor: $($mainAsset.name) ($sz MB)..."
                        $dlPath = "$env:TEMP\winget_upd.msixbundle"
                        & $downloadFile $mainAsset.browser_download_url $dlPath 'İndiriliyor' $sz

                        # 3) License (varsa, provisioning için)
                        $licPath = $null
                        if ($licAsset) {
                            try {
                                $licPath = "$env:TEMP\$($licAsset.name)"
                                $wc = New-Object System.Net.WebClient
                                $wc.Headers.Add('User-Agent','Mozilla/5.0 MSAM-Updater')
                                $wc.DownloadFile($licAsset.browser_download_url, $licPath)
                                $wc.Dispose()
                            } catch { $licPath = $null }
                        }

                        # 4) Kurulum — Add-AppxPackage bağımlılıklarla birlikte
                        WLog 'PROG:⟳ İndirme tamamlandı, paket kuruluyor...'
                        try {
                            if ($depFiles.Count -gt 0) {
                                Add-AppxPackage -Path $dlPath -DependencyPath $depFiles -ForceApplicationShutdown -ErrorAction Stop
                            } else {
                                Add-AppxPackage -Path $dlPath -ForceApplicationShutdown -ErrorAction Stop
                            }
                        } catch {
                            # AllUsers / provisioning fallback (winget hiç yoksa makul deneme)
                            $msg = $_.Exception.Message
                            WLog "PROG:⟳ Add-AppxPackage başarısız: $($msg -replace '[\r\n]+',' ') — provisioning ile deneniyor..."
                            try {
                                if ($licPath -and (Test-Path $licPath)) {
                                    Add-AppxProvisionedPackage -Online -PackagePath $dlPath -DependencyPackagePath $depFiles -LicensePath $licPath -ErrorAction Stop | Out-Null
                                } else {
                                    Add-AppxProvisionedPackage -Online -PackagePath $dlPath -DependencyPackagePath $depFiles -SkipLicense -ErrorAction Stop | Out-Null
                                }
                            } catch {
                                throw  # dış catch'e taşır
                            }
                        }

                        # Temizlik
                        Remove-Item $dlPath -Force -ErrorAction SilentlyContinue
                        if ($licPath) { Remove-Item $licPath -Force -ErrorAction SilentlyContinue }
                        foreach ($df in $depFiles) { Remove-Item $df -Force -ErrorAction SilentlyContinue }

                        $verb = if ($wingetExists) { 'güncellendi' } else { 'kuruldu' }
                        WLog "OK:✔ Winget $($rel.tag_name) GitHub'dan $verb! Uygulamayı yeniden başlatın."
                        return
                    } catch {
                        WLog "FAIL:✘ GitHub kurulumu başarısız: $($_.Exception.Message -replace '[\r\n]+',' ')"
                        WLog 'FAIL:✘ Microsoft Store → App Installer uygulamasını manuel kurun/güncelleyin.'
                    }
                }).AddArgument($script:_wgLogFile)

                $script:_wgUpdHandle2 = $script:_wgUpdPS2.BeginInvoke()

                # 300ms'de bir log'u oku, UI'ı güncelle
                $script:_wgUpdPollTmr = New-Object System.Windows.Threading.DispatcherTimer
                $script:_wgUpdPollTmr.Interval = [TimeSpan]::FromMilliseconds(300)
                $script:_wgUpdPollTmr.Add_Tick({
                    # Canlı ilerleme: son log satırını oku
                    try {
                        $lines = [System.IO.File]::ReadAllLines($script:_wgLogFile, [System.Text.Encoding]::UTF8)
                        $last  = $lines | Where-Object { $_ } | Select-Object -Last 1
                        if ($last -and $lblWingetUpdateStatus) {
                            $mkB2 = { param($c) [System.Windows.Media.BrushConverter]::new().ConvertFromString($c) }
                            $txt  = $last -replace '^(PROG:|OK:|FAIL:)',''
                            $fg   = if ($last -match '^FAIL:') { '#FCA5A5' } elseif ($last -match '^OK:') { '#86EFAC' } else { '#FDE68A' }
                            $lblWingetUpdateStatus.Text       = $txt
                            $lblWingetUpdateStatus.Foreground = (& $mkB2 $fg)
                            $lblWingetUpdateStatus.Visibility = 'Visible'
                            # Progress bar: log'dan yüzde parse et
                            if ($progWingetUpdate) {
                                if ($last -match '\((\d+)%\)') {
                                    $progWingetUpdate.Value      = [int]$matches[1]
                                    $progWingetUpdate.Visibility = 'Visible'
                                } elseif ($last -match '^OK:|^FAIL:') {
                                    $progWingetUpdate.Value      = if ($last -match '^OK:') { 100 } else { 0 }
                                    $progWingetUpdate.Visibility = 'Collapsed'
                                }
                            }
                        }
                    } catch { }

                    if (-not $script:_wgUpdHandle2.IsCompleted) { return }
                    $script:_wgUpdPollTmr.Stop()
                    try {
                        $script:_wgUpdPS2.EndInvoke($script:_wgUpdHandle2) | Out-Null
                        $script:_wgUpdPS2.Dispose()
                        $script:_wgUpdRS2.Close(); $script:_wgUpdRS2.Dispose()
                    } catch { }
                    try { Remove-Item $script:_wgLogFile -Force -ErrorAction SilentlyContinue } catch { }

                    # Sürümü tazele
                    $script:_wgFnRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $script:_wgFnRS.Open()
                    $script:_wgFnPS = [System.Management.Automation.PowerShell]::Create(); $script:_wgFnPS.Runspace = $script:_wgFnRS
                    [void]$script:_wgFnPS.AddScript({ (winget --version 2>&1) -join '' })
                    $script:_wgFnHandle = $script:_wgFnPS.BeginInvoke()
                    $script:_wgFnTmr = New-Object System.Windows.Threading.DispatcherTimer
                    $script:_wgFnTmr.Interval = [TimeSpan]::FromMilliseconds(300)
                    $script:_wgFnTmr.Add_Tick({
                        if (-not $script:_wgFnHandle.IsCompleted) { return }
                        $script:_wgFnTmr.Stop()
                        try {
                            $vf = $script:_wgFnPS.EndInvoke($script:_wgFnHandle) | Select-Object -First 1
                            $script:_wgFnPS.Dispose(); $script:_wgFnRS.Close(); $script:_wgFnRS.Dispose()
                            if ($lblWingetVersionVal) {
                                $lblWingetVersionVal.Text = if ($vf -match 'v[\d.]+') { $vf.Trim() } else { 'Bulunamadı' }
                            }
                        } catch { }
                    })
                    $script:_wgFnTmr.Start()
                    if ($btnUpdateWinget) { $btnUpdateWinget.IsEnabled = $true }
                })
                $script:_wgUpdPollTmr.Start()
            })
        }
    }
    if ($idx -eq 4) { Import-History }
})

$btnLang.Add_Click({
    $script:Lang = if ($script:Lang -eq 'EN') { 'TR' } else { 'EN' }
    Set-Language
})

# ─── Tema Paletleri / Theme Palettes ───────────────────────────────────
$script:Themes = @{
    'Dark' = @{
        AccentBrush   = '#F59E0B'; AccentHover = '#D97706'; AccentPress = '#B45309'
        SurfaceBrush  = '#18181B'; SidebarBrush = '#09090B'; CardBrush = '#14141A'
        ListBrush     = '#0E0E13'; TextPrimary = '#F4F4F5'; TextSecondary = '#A1A1AA'
        TextDisabled  = '#52525B'; RowAlt = '#11111A'; BorderColor = '#27272A'
        InputBg       = '#0E0E13'; InputBorder = '#3F3F46'; HeaderBg = '#0B0B0F'
        MenuBg        = '#18181B'; MenuHover = '#2A2A33'; TitleBarBg = '#0B0B0F'; TitleBarFg = '#D4D4D8'
        WatermarkBrandBrush = '#F4F4F5'; WatermarkProductBrush = '#F59E0B'
    }
    'Light' = @{
        AccentBrush   = '#D97706'; AccentHover = '#B45309'; AccentPress = '#92400E'
        SurfaceBrush  = '#FFFFFF'; SidebarBrush = '#F4F4F5'; CardBrush = '#FAFAFA'
        ListBrush     = '#FFFFFF'; TextPrimary = '#18181B'; TextSecondary = '#52525B'
        TextDisabled  = '#A1A1AA'; RowAlt = '#F4F4F5'; BorderColor = '#D4D4D8'
        InputBg       = '#FFFFFF'; InputBorder = '#D4D4D8'; HeaderBg = '#E4E4E7'
        MenuBg        = '#FFFFFF'; MenuHover = '#F4F4F5'; TitleBarBg = '#E4E4E7'; TitleBarFg = '#18181B'
        WatermarkBrandBrush = '#18181B'; WatermarkProductBrush = '#D97706'
    }
    'iTunes' = @{
        AccentBrush   = '#007AFF'; AccentHover = '#0062CC'; AccentPress = '#004FB3'
        SurfaceBrush  = '#F5F5F7'; SidebarBrush = '#EBEBEB'; CardBrush = '#FFFFFF'
        ListBrush     = '#FFFFFF'; TextPrimary = '#1D1D1F'; TextSecondary = '#86868B'
        TextDisabled  = '#C7C7CC'; RowAlt = '#F4F5F8'; BorderColor = '#D1D1D6'
        InputBg       = '#FFFFFF'; InputBorder = '#C7C7CC'; HeaderBg = '#F6F6F6'
        MenuBg        = '#FFFFFF'; MenuHover = '#EAEAEA'; TitleBarBg = '#EAEAEA'; TitleBarFg = '#1D1D1F'
        WatermarkBrandBrush = '#1D1D1F'; WatermarkProductBrush = '#007AFF'
    }
    'Intel' = @{
        AccentBrush   = '#00C7FD'; AccentHover = '#00A8D8'; AccentPress = '#007FAA'
        SurfaceBrush  = '#0A0A0F'; SidebarBrush = '#060608'; CardBrush = '#0E0E15'
        ListBrush     = '#0B0B12'; TextPrimary = '#E8EAF0'; TextSecondary = '#8BB8D4'
        TextDisabled  = '#3A3D48'; RowAlt = '#0C0C14'; BorderColor = '#1A1C24'
        InputBg       = '#0B0B12'; InputBorder = '#252830'; HeaderBg = '#070709'
        MenuBg        = '#0E0E15'; MenuHover = '#161820'; TitleBarBg = '#070709'; TitleBarFg = '#00C7FD'
        WatermarkBrandBrush = '#E8EAF0'; WatermarkProductBrush = '#00C7FD'
    }
    'Dracula' = @{
        AccentBrush   = '#BD93F9'; AccentHover = '#D6ACFF'; AccentPress = '#9D73D9'
        SurfaceBrush  = '#282A36'; SidebarBrush = '#21222C'; CardBrush = '#44475A'
        ListBrush     = '#282A36'; TextPrimary = '#F8F8F2'; TextSecondary = '#C4B5F4'
        TextDisabled  = '#6272A4'; RowAlt = '#343746'; BorderColor = '#6272A4'
        InputBg       = '#282A36'; InputBorder = '#6272A4'; HeaderBg = '#21222C'
        MenuBg        = '#282A36'; MenuHover = '#44475A'; TitleBarBg = '#21222C'; TitleBarFg = '#BD93F9'
        WatermarkBrandBrush = '#F8F8F2'; WatermarkProductBrush = '#BD93F9'
    }
    'Nord' = @{
        AccentBrush   = '#88C0D0'; AccentHover = '#8FBCBB'; AccentPress = '#81A1C1'
        SurfaceBrush  = '#2E3440'; SidebarBrush = '#242933'; CardBrush = '#3B4252'
        ListBrush     = '#2E3440'; TextPrimary = '#D8DEE9'; TextSecondary = '#A3B1C6'
        TextDisabled  = '#4C566A'; RowAlt = '#3B4252'; BorderColor = '#4C566A'
        InputBg       = '#2E3440'; InputBorder = '#4C566A'; HeaderBg = '#242933'
        MenuBg        = '#2E3440'; MenuHover = '#3B4252'; TitleBarBg = '#242933'; TitleBarFg = '#88C0D0'
        WatermarkBrandBrush = '#D8DEE9'; WatermarkProductBrush = '#88C0D0'
    }
    'Solarized Dark' = @{
        AccentBrush   = '#268BD2'; AccentHover = '#2AA198'; AccentPress = '#D33682'
        SurfaceBrush  = '#002B36'; SidebarBrush = '#073642'; CardBrush = '#073642'
        ListBrush     = '#002B36'; TextPrimary = '#EEE8D5'; TextSecondary = '#93A1A1'
        TextDisabled  = '#586E75'; RowAlt = '#073642'; BorderColor = '#586E75'
        InputBg       = '#002B36'; InputBorder = '#586E75'; HeaderBg = '#073642'
        MenuBg        = '#002B36'; MenuHover = '#073642'; TitleBarBg = '#073642'; TitleBarFg = '#268BD2'
        WatermarkBrandBrush = '#EEE8D5'; WatermarkProductBrush = '#268BD2'
    }
    'Solarized Light' = @{
        AccentBrush   = '#268BD2'; AccentHover = '#2AA198'; AccentPress = '#D33682'
        SurfaceBrush  = '#FDF6E3'; SidebarBrush = '#EEE8D5'; CardBrush = '#EEE8D5'
        ListBrush     = '#FDF6E3'; TextPrimary = '#073642'; TextSecondary = '#586E75'
        TextDisabled  = '#93A1A1'; RowAlt = '#EEE8D5'; BorderColor = '#DED8C4'
        InputBg       = '#FDF6E3'; InputBorder = '#B4AE9A'; HeaderBg = '#EEE8D5'
        MenuBg        = '#FDF6E3'; MenuHover = '#EEE8D5'; TitleBarBg = '#EEE8D5'; TitleBarFg = '#268BD2'
        WatermarkBrandBrush = '#073642'; WatermarkProductBrush = '#268BD2'
    }
    'Monokai' = @{
        AccentBrush   = '#FD971F'; AccentHover = '#A6E22E'; AccentPress = '#E6DB74'
        SurfaceBrush  = '#272822'; SidebarBrush = '#1E1F1C'; CardBrush = '#3E3D32'
        ListBrush     = '#272822'; TextPrimary = '#F8F8F2'; TextSecondary = '#CFCFC2'
        TextDisabled  = '#75715E'; RowAlt = '#3E3D32'; BorderColor = '#75715E'
        InputBg       = '#272822'; InputBorder = '#75715E'; HeaderBg = '#1E1F1C'
        MenuBg        = '#272822'; MenuHover = '#3E3D32'; TitleBarBg = '#1E1F1C'; TitleBarFg = '#FD971F'
        WatermarkBrandBrush = '#F8F8F2'; WatermarkProductBrush = '#FD971F'
    }
    'Synthwave' = @{
        AccentBrush   = '#36F9F6'; AccentHover = '#F92AAD'; AccentPress = '#FCE566'
        SurfaceBrush  = '#2B213A'; SidebarBrush = '#241B2F'; CardBrush = '#262335'
        ListBrush     = '#2B213A'; TextPrimary = '#FFFFFF'; TextSecondary = '#C9A7E8'
        TextDisabled  = '#848BBD'; RowAlt = '#262335'; BorderColor = '#5A4D7A'
        InputBg       = '#2B213A'; InputBorder = '#5A4D7A'; HeaderBg = '#241B2F'
        MenuBg        = '#2B213A'; MenuHover = '#362B4A'; TitleBarBg = '#241B2F'; TitleBarFg = '#36F9F6'
        WatermarkBrandBrush = '#FFFFFF'; WatermarkProductBrush = '#36F9F6'
    }
    'Cyberpunk' = @{
        AccentBrush   = '#E50050'; AccentHover = '#FF1A66'; AccentPress = '#00FFFF'
        SurfaceBrush  = '#090A0F'; SidebarBrush = '#020203'; CardBrush = '#12141F'
        ListBrush     = '#090A0F'; TextPrimary = '#EDEDF0'; TextSecondary = '#8A8FB5'
        TextDisabled  = '#51556B'; RowAlt = '#12141F'; BorderColor = '#24283B'
        InputBg       = '#020203'; InputBorder = '#3A3F5C'; HeaderBg = '#020203'
        MenuBg        = '#090A0F'; MenuHover = '#1A1D2D'; TitleBarBg = '#020203'; TitleBarFg = '#E50050'
        WatermarkBrandBrush = '#EDEDF0'; WatermarkProductBrush = '#E50050'
    }
    'Gruvbox' = @{
        AccentBrush   = '#FE8019'; AccentHover = '#FABD2F'; AccentPress = '#B8BB26'
        SurfaceBrush  = '#282828'; SidebarBrush = '#1D2021'; CardBrush = '#3C3836'
        ListBrush     = '#282828'; TextPrimary = '#EBDBB2'; TextSecondary = '#FABD2F'
        TextDisabled  = '#928374'; RowAlt = '#3C3836'; BorderColor = '#928374'
        InputBg       = '#282828'; InputBorder = '#928374'; HeaderBg = '#1D2021'
        MenuBg        = '#282828'; MenuHover = '#3C3836'; TitleBarBg = '#1D2021'; TitleBarFg = '#FE8019'
        WatermarkBrandBrush = '#EBDBB2'; WatermarkProductBrush = '#FE8019'
    }
    'Tokyo Night' = @{
        AccentBrush   = '#BB9AF7'; AccentHover = '#7AA2F7'; AccentPress = '#F7768E'
        SurfaceBrush  = '#1A1B26'; SidebarBrush = '#16161E'; CardBrush = '#24283B'
        ListBrush     = '#1A1B26'; TextPrimary = '#C0CAF5'; TextSecondary = '#7AA2F7'
        TextDisabled  = '#565F89'; RowAlt = '#24283B'; BorderColor = '#414868'
        InputBg       = '#1A1B26'; InputBorder = '#414868'; HeaderBg = '#16161E'
        MenuBg        = '#1A1B26'; MenuHover = '#24283B'; TitleBarBg = '#16161E'; TitleBarFg = '#BB9AF7'
        WatermarkBrandBrush = '#C0CAF5'; WatermarkProductBrush = '#BB9AF7'
    }
    'Catppuccin' = @{
        AccentBrush   = '#CBA6F7'; AccentHover = '#F5C2E7'; AccentPress = '#F38BA8'
        SurfaceBrush  = '#1E1E2E'; SidebarBrush = '#181825'; CardBrush = '#313244'
        ListBrush     = '#1E1E2E'; TextPrimary = '#CDD6F4'; TextSecondary = '#89B4FA'
        TextDisabled  = '#6C7086'; RowAlt = '#313244'; BorderColor = '#45475A'
        InputBg       = '#1E1E2E'; InputBorder = '#45475A'; HeaderBg = '#181825'
        MenuBg        = '#1E1E2E'; MenuHover = '#313244'; TitleBarBg = '#181825'; TitleBarFg = '#CBA6F7'
        WatermarkBrandBrush = '#CDD6F4'; WatermarkProductBrush = '#CBA6F7'
    }
    'GitHub Dark' = @{
        AccentBrush   = '#2F81F7'; AccentHover = '#58A6FF'; AccentPress = '#79C0FF'
        SurfaceBrush  = '#0D1117'; SidebarBrush = '#010409'; CardBrush = '#161B22'
        ListBrush     = '#0D1117'; TextPrimary = '#C9D1D9'; TextSecondary = '#58A6FF'
        TextDisabled  = '#8B949E'; RowAlt = '#161B22'; BorderColor = '#30363D'
        InputBg       = '#0D1117'; InputBorder = '#30363D'; HeaderBg = '#010409'
        MenuBg        = '#0D1117'; MenuHover = '#161B22'; TitleBarBg = '#010409'; TitleBarFg = '#2F81F7'
        WatermarkBrandBrush = '#C9D1D9'; WatermarkProductBrush = '#2F81F7'
    }
}
$script:CurrentTheme = 'Dark'

function Set-AppTheme {
    param([string]$ThemeName)
    if (-not $script:Themes.ContainsKey($ThemeName)) { return }
    $palette = $script:Themes[$ThemeName]
    $script:CurrentTheme = $ThemeName

    # Kaynak fırçalarını güncelle / Update resource brushes
    foreach ($key in $palette.Keys) {
        try {
            $rawColor = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
            $color    = [System.Windows.Media.Color]$rawColor
            $newBrush = [System.Windows.Media.SolidColorBrush]::new($color)
            $newBrush.Freeze()
            $window.Resources[$key] = $newBrush
        } catch {}
    }

    # Pencere arka planı / Window background
    try {
        $rawColor = [System.Windows.Media.ColorConverter]::ConvertFromString($palette.SurfaceBrush)
        $color    = [System.Windows.Media.Color]$rawColor
        $bgBrush  = [System.Windows.Media.SolidColorBrush]::new($color)
        $bgBrush.Freeze()
        $window.Background = $bgBrush
    } catch {}

    # Dış pencere çerçevesi ve accent çizgisi — BorderColor ile uyumlu / Match inner border color
    try {
        $borderRaw   = [System.Windows.Media.ColorConverter]::ConvertFromString($palette.BorderColor)
        $borderColor = [System.Windows.Media.Color]$borderRaw
        $borderBrush = [System.Windows.Media.SolidColorBrush]::new($borderColor)
        $borderBrush.Freeze()
        if ($outerWindowBorder) { $outerWindowBorder.BorderBrush = $borderBrush }
        if ($titleAccentLine)   { $titleAccentLine.Background    = $borderBrush }
    } catch {}

    # DataGrid köşe düzeltmesi / DataGrid corner fix (SystemColors)
    try {
        $hdrColor = [System.Windows.Media.ColorConverter]::ConvertFromString($palette.HeaderBg)
        $hdrBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]$hdrColor)
        $hdrBrush.Freeze()
        $window.Resources[[System.Windows.SystemColors]::ControlBrushKey] = $hdrBrush
        $hdrBrush2 = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]$hdrColor)
        $hdrBrush2.Freeze()
        $window.Resources[[System.Windows.SystemColors]::WindowBrushKey] = $hdrBrush2
    } catch {}

    # Yeniden çiz / Force redraw
    try { $window.UpdateLayout() } catch {}

    # Satır renklerini güncelle / Update row foreground colors
    $updateRowFg = {
        param($collection)
        if (-not $collection) { return }
        foreach ($item in $collection) {
            try {
                $isSystem = $false
                if ($item.PSObject.Properties['IsSystemRow']) {
                    $isSystem = [bool]$item.IsSystemRow
                } else {
                    # Geriye dönük uyumluluk için fırça renginden tahmin et / Guess from brush color for backward compatibility
                    $cHex = ""
                    try { $cHex = $item.RowFg.Color.ToString() } catch {}
                    if ($cHex -match 'A1A1AA|52525B|839496|89B4FA') { $isSystem = $true }
                }

                if ($isSystem) {
                    $item.RowFg = Get-SecondaryFgBrush
                } else {
                    $item.RowFg = Get-PrimaryFgBrush
                }

                # Özel renkli satırlar (örn. Güncelleme var) için ek mantık buraya gelebilir
                # Additional logic for specifically colored rows can go here
            } catch {}
        }
    }
    & $updateRowFg $script:Packages
    & $updateRowFg $script:InstalledApps
    & $updateRowFg $script:History

    # Tema düğmesinde SVG ikon ve ipucu göster / Show SVG icon and tooltip in theme button
    if ($btnTheme) {
        $allThemes = @('Dark','Light','iTunes','Intel','Dracula','Nord','Solarized Dark','Solarized Light','Monokai','Synthwave','Cyberpunk','Gruvbox','Tokyo Night','Catppuccin','GitHub Dark')
        $idx = $allThemes.IndexOf($ThemeName)
        if ($idx -lt 0) { $idx = 0 }
        $nextIdx = ($idx + 1) % $allThemes.Count
        $nextName = $allThemes[$nextIdx]

        # Her tema için özel SVG Path Data (Material Design 24x24)
        $svgPaths = @{
            'Dark'            = 'M12,7c-2.76,0-5,2.24-5,5s2.24,5,5,5s5-2.24,5-5S14.76,7,12,7z M2,13h2c0.55,0,1-0.45,1-1s-0.45-1-1-1H2c-0.55,0-1,0.45-1,1S1.45,13,2,13z M20,13h2c0.55,0,1-0.45,1-1s-0.45-1-1-1h-2c-0.55,0-1,0.45-1,1S19.45,13,20,13z M11,2v2c0,0.55,0.45,1,1,1s1-0.45,1-1V2c0-0.55-0.45-1-1-1S11,1.45,11,2z M11,20v2c0,0.55,0.45,1,1,1s1-0.45,1-1v-2c0-0.55-0.45-1-1-1C11.45,19,11,19.45,11,20z M5.99,4.58c-0.39-0.39-1.03-0.39-1.41,0c-0.39,0.39-0.39,1.03,0,1.41l1.06,1.06c0.39,0.39,1.03,0.39,1.41,0s0.39-1.03,0-1.41L5.99,4.58z M18.36,16.95c-0.39-0.39-1.03-0.39-1.41,0c-0.39,0.39-0.39,1.03,0,1.41l1.06,1.06c0.39,0.39,1.03,0.39,1.41,0c0.39-0.39,0.39-1.03,0-1.41L18.36,16.95z M19.42,5.99c0.39-0.39,0.39-1.03,0-1.41c-0.39-0.39-1.03-0.39-1.41,0l-1.06,1.06c-0.39,0.39-0.39,1.03,0,1.41s1.03,0.39,1.41,0L19.42,5.99z M7.05,18.36c0.39-0.39,0.39-1.03,0-1.41c-0.39-0.39-1.03-0.39-1.41,0l-1.06,1.06c-0.39,0.39-0.39,1.03,0,1.41s1.03,0.39,1.41,0L7.05,18.36z'
            'Light'           = 'M12,3v10.55c-0.59-0.34-1.27-0.55-2-0.55c-2.21,0-4,1.79-4,4s1.79,4,4,4s4-1.79,4-4V7h4V3H12z'
            'iTunes'          = 'M6,4h12v16H6V4z M17,2H7C5.9,2,5,2.9,5,4v16c0,1.1,0.9,2,2,2h10c1.1,0,2-0.9,2-2V4C19,2.9,18.1,2,17,2z'
            'Intel'           = 'M12,3c-4.97,0-9,4.03-9,9s4.03,9,9,9s9-4.03,9-9c0-0.46-0.04-0.92-0.1-1.36c-0.98,1.37-2.58,2.26-4.4,2.26c-3.03,0-5.5-2.47-5.5-5.5c0-1.82,0.89-3.42,2.26-4.4C12.92,3.04,12.46,3,12,3z'
            'Dracula'         = 'M12,2c-5.33,4.55-8,8.48-8,11.8c0,4.98,3.8,8.2,8,8.2s8-3.22,8-8.2C20,10.48,17.33,6.55,12,2z M12,20c-3.35,0-6-2.57-6-6.2c0-2.34,1.95-5.44,6-9.14c4.05,3.7,6,6.79,6,9.14C18,17.43,15.35,20,12,20z'
            'Nord'            = 'M12,17.27L18.18,21l-1.64-7.03L22,9.24l-7.19-0.61L12,2L9.19,8.63L2,9.24l5.46,4.73L5.82,21L12,17.27z'
            'Solarized Dark'  = 'M12,4.5C7,4.5,2.73,7.61,1,12c1.73,4.39,6,7.5,11,7.5s9.27-3.11,11-7.5C21.27,7.61,17,4.5,12,4.5z M12,17c-2.76,0-5-2.24-5-5s2.24-5,5-5s5,2.24,5,5S14.76,17,12,17z M12,9c-1.66,0-3,1.34-3,3s1.34,3,3,3s3-1.34,3-3S13.66,9,12,9z'
            'Solarized Light' = 'M9.4,16.6L4.8,12l4.6-4.6L8,6l-6,6l6,6L9.4,16.6z M14.6,16.6l4.6-4.6l-4.6-4.6L16,6l6,6l-6,6L14.6,16.6z'
            'Monokai'         = 'M8,5v14l11-7L8,5z'
            'Synthwave'       = 'M21,6H3C1.9,6,1,6.9,1,8v8c0,1.1,0.9,2,2,2h18c1.1,0,2-0.9,2-2V8C23,6.9,22.1,6,21,6z M11,13H8v3H6v-3H3v-2h3V8h2v3h3V13z M15.5,15c-0.83,0-1.5-0.67-1.5-1.5s0.67-1.5,1.5-1.5s1.5,0.67,1.5,1.5S16.33,15,15.5,15z M19.5,12c-0.83,0-1.5-0.67-1.5-1.5S18.67,9,19.5,9S21,9.67,21,10.5S20.33,12,19.5,12z'
            'Cyberpunk'       = 'M12,2v20c5.52,0,10-4.48,10-10S17.52,2,12,2z'
            'Gruvbox'         = 'M12,2C6.48,2,2,6.48,2,12s4.48,10,10,10s10-4.48,10-10S17.52,2,12,2z M11,19.93c-3.95-0.49-7-3.85-7-7.93c0-0.62,0.08-1.21,0.21-1.79L9,15v1c0,1.1,0.9,2,2,2V19.93z M17.9,17.39c-0.26-0.81-1-1.39-1.9-1.39h-1v-3c0-0.55-0.45-1-1-1H8v-2h2c0.55,0,1-0.45,1-1V7h2c1.1,0,2-0.9,2-2v-0.41C17.92,5.77,20,8.65,20,12C20,14.08,19.21,15.98,17.9,17.39z'
            'Tokyo Night'     = 'M12,21.35l-1.45-1.32C5.4,15.36,2,12.28,2,8.5C2,5.42,4.42,3,7.5,3c1.74,0,3.41,0.81,4.5,2.09C13.09,3.81,14.76,3,16.5,3C19.58,3,22,5.42,22,8.5c0,3.78-3.4,6.86-8.55,11.54L12,21.35z'
            'Catppuccin'      = 'M14,2H6C4.9,2,4.01,2.9,4.01,4L4,20c0,1.1,0.89,2,1.99,2H18c1.1,0,2-0.9,2-2V8L14,2z M13,9V3.5L18.5,9H13z'
            'GitHub Dark'     = 'M12,2C6.49,2,2,6.49,2,12s4.49,10,10,10c1.38,0,2.5-1.12,2.5-2.5c0-0.61-0.23-1.21-0.64-1.67c-0.08-0.09-0.13-0.21-0.13-0.33c0-0.28,0.22-0.5,0.5-0.5H16c3.31,0,6-2.69,6-6C22,6.04,17.51,2,12,2z M6.5,11.5C5.67,11.5,5,10.83,5,10s0.67-1.5,1.5-1.5S8,9.17,8,10S7.33,11.5,6.5,11.5z M9.5,7.5C8.67,7.5,8,6.83,8,6s0.67-1.5,1.5-1.5S11,5.17,11,6S10.33,7.5,9.5,7.5z M14.5,7.5C13.67,7.5,13,6.83,13,6s0.67-1.5,1.5-1.5S16,5.17,16,6S15.33,7.5,14.5,7.5z M17.5,11.5C16.67,11.5,16,10.83,16,10s0.67-1.5,1.5-1.5S19,9.17,19,10S18.33,11.5,17.5,11.5z'
        }

        $currentSvg = $svgPaths[$ThemeName]
        if (-not $currentSvg) { $currentSvg = $svgPaths['GitHub Dark'] }

        # SVG'yi Ana Uygulama ikon mantığıyla oluşturuyoruz (Viewbox > Canvas > Path)
        # Butonun metin rengini inherit etmesi için Binding kullanıyoruz (böylece hover'da renk değiştirir)
        $xaml = @"
<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="18" Height="18" Margin="0">
    <Canvas Width="24" Height="24">
        <Path Data="$currentSvg" Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" />
    </Canvas>
</Viewbox>
"@
        try {
            $parsedIcon = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
            $btnTheme.Content = $parsedIcon
            $btnTheme.ToolTip = "Switch to $nextName theme"
        } catch {}
    }

    # Background overlays (Wave/Dots) are theme-aware via DynamicResource AccentBrush in XAML.
}

$btnTheme.Add_Click({
    $allThemes = @('Dark','Light','iTunes','Intel','Dracula','Nord','Solarized Dark','Solarized Light','Monokai','Synthwave','Cyberpunk','Gruvbox','Tokyo Night','Catppuccin','GitHub Dark')
    $idx = $allThemes.IndexOf($script:CurrentTheme)
    if ($idx -lt 0) { $idx = 0 }
    $nextIdx = ($idx + 1) % $allThemes.Count
    $next = $allThemes[$nextIdx]
    Set-AppTheme -ThemeName $next
    Save-AppSettings
})

# ─── Arka Plan Overlay Yönetimi / Background Overlay Management ───────────────────────
function Set-BackgroundOverlay {
    param([string]$OverlayType)
    if (-not $waveCanvas -or -not $gridCanvas) { return }
    $waveCanvas.Visibility      = [System.Windows.Visibility]::Collapsed
    $gridCanvas.Visibility      = [System.Windows.Visibility]::Collapsed
    
    if ($OverlayType -eq 'Wave') { $waveCanvas.Visibility = [System.Windows.Visibility]::Visible }
    elseif ($OverlayType -eq 'Grid') { $gridCanvas.Visibility = [System.Windows.Visibility]::Visible }
}

# ─── Sistem teması algılama / System theme detection (AppsUseLightTheme) ──
function Get-SystemTheme {
    try {
        $key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $v = (Get-ItemProperty -Path $key -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ($v -eq 1) { return 'Light' } else { return 'Dark' }
    } catch {
        return 'Dark'  # varsayılan / default
    }
}

$btnFetch.Add_Click({
    # cmbPackage veya txtUrl'den girdi al / Get input from cmbPackage or txtUrl
    $rawInput = $cmbPackage.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($rawInput)) { $rawInput = $txtUrl.Text.Trim() }
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Set-Status ($script:Strings[$script:Lang].StatusNoUrl)
        return
    }

    # PackageList'ten Family URL'sini çözümle / Resolve Family URL from PackageList
    $resolvedUrl = $rawInput
    $matchedPkg = $PackageList | Where-Object { $_.Identity.Trim() -eq $rawInput } | Select-Object -First 1
    if ($matchedPkg) { $resolvedUrl = $matchedPkg.Family.Trim() }
    # Mağazada açmak için orijinal girdiyi sakla / Save original input to open in Store
    $script:lastFetchedInput = $resolvedUrl

    Set-Status ($script:Strings[$script:Lang].StatusFetch)
    $progMain.IsIndeterminate = $true
    $script:dlSuccess = 0 # Yeni arama yapıldığı için önceki indirme durumunu sıfırla / Reset previous download state due to new search
    Show-Cancel -OpKey 'fetch'

    # Geleneksel mağaza aramasını kullan / Use legacy store search
    if ($UseOriginalBusinessLogic -and (Get-Command Get-StorePackages -ErrorAction SilentlyContinue)) {
        try {
            $arch = ($cmbArch.SelectedItem.Content)
            $ring = ($cmbRing.SelectedItem.Content)
            $results = Get-StorePackages -Url $resolvedUrl -Arch $arch -Ring $ring
            $script:Packages.Clear()
            foreach ($r in $results) {
                $item = New-Object PackageItem
                $item.FileName = $r.FileName
                $item.Version  = $r.Version
                $item.SizeBytes= [long]$r.Size
                $item.SizeText = Format-Size $item.SizeBytes
                $item.Url      = $r.Url
                $item.StoreId  = $r.StoreId
                Set-StatusBadge $item 'Ready' '#1F2A19' '#A7F3A0'
                $script:Packages.Add($item)
            }
            Set-Status ("Fetched {0} package(s)" -f $script:Packages.Count)
        } catch {
            Set-Status "Error: $($_.Exception.Message)"
        }
    } else {
        # Gerçek mağaza indirme işlemi / Actual Store fetch
        $script:Packages.Clear()
        $arch = if ($cmbArch.SelectedItem) { $cmbArch.SelectedItem.Content } else { 'x64' }
        $ring = if ($cmbRing.SelectedItem) {
            switch ($cmbRing.SelectedItem.Content) { 'Retail'{'Retail'}; 'Preview'{'RP'}; 'WIS'{'WIS'}; 'WIF'{'WIF'}; 'Slow'{'Slow'}; 'Fast'{'Fast'}; default{'Retail'} }
        } else { 'Retail' }

        $script:fetchJob = Start-Job -ScriptBlock {
            param($fetchUrl, $arch, $ring)
            Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

            # ── rg-adguard POST helper ────────────────────────────────────
            function Invoke-RgAdguard {
                param([string]$FetchUrl, [string]$Type, [string]$Ring)
                $enc  = [System.Web.HttpUtility]::UrlEncode($FetchUrl)
                $body = "type=$Type&url=$enc&ring=$Ring&lang=en-US"
                $bb   = [System.Text.Encoding]::UTF8.GetBytes($body)

                $req = [System.Net.HttpWebRequest]::Create('https://store.rg-adguard.net/api/GetFiles')
                $req.Method        = 'POST'
                $req.ContentType   = 'application/x-www-form-urlencoded'
                $req.ContentLength = $bb.Length
                $req.UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
                $req.Referer       = 'https://store.rg-adguard.net/'
                $req.Accept        = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
                $req.Headers.Add('Accept-Language', 'en-US,en;q=0.5')
                $req.Timeout       = 60000

                $rs = $req.GetRequestStream(); $rs.Write($bb,0,$bb.Length); $rs.Close()
                $resp = $req.GetResponse()
                $rdr  = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $h    = $rdr.ReadToEnd(); $rdr.Close(); $resp.Close()
                return $h
            }

            # Zarf - arayüz iş parçacığında teşhis için / Envelope - for diagnostics in UI thread
            $envelope = [PSCustomObject]@{
                Items         = @()
                HtmlLen       = 0
                LinkCount     = 0
                RawLinkCount  = 0
                UsedType      = ''
                UsedRing      = ''
                Error         = $null
            }

            try {
                # ── Seçili ayarlarla mağaza bağlantılarını getir / Fetch store links with selected settings ──
                $actualUrl = $fetchUrl
                $ftype = if ($fetchUrl -match '(?i)/detail/([A-Z0-9]{9,20})') {
                    $actualUrl = $Matches[1]   # sadece ProductId gönder / send only ProductId
                    'ProductId'
                } elseif ($fetchUrl -match '^[A-Z0-9]{9,20}$') {
                    'ProductId'
                } elseif ($fetchUrl -match '^https?://') {
                    'url'
                } else {
                    'PackageFamilyName'
                }
                $ringVal = switch ($ring) { 'Retail'{'Retail'}; 'RP'{'RP'}; 'WIF'{'WIF'}; 'WIS'{'WIS'}; default{'Retail'} }

                $html = Invoke-RgAdguard -FetchUrl $actualUrl -Type $ftype -Ring $ringVal
                $envelope.HtmlLen  = $html.Length
                $envelope.UsedType = $ftype
                $envelope.UsedRing = $ringVal

                $links = [regex]::Matches($html, '<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>')
                $envelope.RawLinkCount = $links.Count

                # ── Yeniden deneme: Retail değilse ve hiç bağlantı yoksa Retail dene / Retry: if not Retail and no links, try Retail ──
                if ($links.Count -eq 0 -and $ringVal -ne 'Retail') {
                    $html2 = Invoke-RgAdguard -FetchUrl $actualUrl -Type $ftype -Ring 'Retail'
                    $links2 = [regex]::Matches($html2, '<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>')
                    if ($links2.Count -gt 0) {
                        $html  = $html2
                        $links = $links2
                        $envelope.UsedRing     = 'Retail (fallback)'
                        $envelope.HtmlLen      = $html.Length
                        $envelope.RawLinkCount = $links.Count
                    }
                }

                # ── HAM bağlantı toplama / RAW link collection ──────────────────────────────────────
                $rawList = New-Object System.Collections.ArrayList

                foreach ($lk in $links) {
                    $fn  = $lk.Groups[2].Value -replace '<[^>]*>',''
                    try { $fn = [System.Web.HttpUtility]::HtmlDecode($fn.Trim()) } catch { $fn = $fn.Trim() }
                    $url = $lk.Groups[1].Value

                    # Geçersiz uzantıları filtrele / Filter invalid extensions
                    if ($fn -match 'BlockMap|\.eappx|\.emsix') { continue }
                    if ($fn -notmatch '\.(appx|appxbundle|msix|msixbundle|exe|msi)$') { continue }

                    $isInstaller = $fn -match '\.(exe|msi)$'
                    $parts       = $fn -split '_'
                    if (-not $isInstaller -and $parts.Count -lt 2) { continue }

                    $baseName = if ($parts.Count -ge 1 -and $parts[0]) { $parts[0] } else {
                        [System.IO.Path]::GetFileNameWithoutExtension($fn)
                    }

                    # Sürüm çıkarımı (3 aşamalı yedek) / Version extraction (3-step fallback)
                    $ver = [Version]'0.0.0.0'
                    if ($fn -match '_(\d+(?:\.\d+)+)_') { try { $ver = [Version]$Matches[1] } catch {} }
                    elseif ($parts.Count -ge 2)        { try { $ver = [Version]$parts[1] } catch {} }
                    elseif ($fn -match '(\d+(?:\.\d+){1,3})') { try { $ver = [Version]$Matches[1] } catch {} }

                    $isBundle = $fn -match '\.(appxbundle|msixbundle)$'
                    $isDep    = (-not $isInstaller) -and ($baseName -match 'VCLibs|NET\.Native|WinJS|UI\.Xaml|WinAppRuntime|WindowsAppRuntime')

                    # HEAD isteği ile boyut (isteğe bağlı) / Size via HEAD request (optional)
                    $size = 0L
                    try {
                        $rq2 = [System.Net.HttpWebRequest]::Create($url)
                        $rq2.Method    = 'HEAD'
                        $rq2.Timeout   = 8000
                        $rq2.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                        $rp2 = $rq2.GetResponse()
                        $size = $rp2.ContentLength
                        $rp2.Close()
                    } catch {}

                    [void]$rawList.Add([PSCustomObject]@{
                        FileName    = $fn
                        Url         = $url
                        Version     = $ver
                        BaseName    = $baseName
                        IsDep       = $isDep
                        IsBundle    = $isBundle
                        IsInstaller = $isInstaller
                        Size        = $size
                    })
                }

                $envelope.Items     = $rawList.ToArray()
                $envelope.LinkCount = $rawList.Count
            }
            catch {
                $envelope.Error = $_.Exception.Message
            }

            return $envelope
        } -ArgumentList $resolvedUrl, $arch, $ring

        $script:fetchTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:fetchTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:fetchTimer.Add_Tick({
            $j = $script:fetchJob
            if (-not $j) { $script:fetchTimer.Stop(); return }
            if ($j.State -eq 'Completed') {
                $script:fetchTimer.Stop()
                # Zarfı al - PowerShell işleri nesneyi dizi içinde sarar / Get envelope - PowerShell jobs wrap object in array
                $jobOutput = @(Receive-Job $j); Remove-Job $j; $script:fetchJob = $null
                $envelope  = $null
                if ($jobOutput.Count -gt 0) {
                    $envelope = $jobOutput[0]
                    # Bazen PSCustomObject, bazen Deserialized.PSCustomObject olur / Sometimes it's PSCustomObject, sometimes Deserialized.PSCustomObject
                }
                $script:Packages.Clear()

                # Zarf yapısı kontrolü / Envelope structure check
                if (-not $envelope -or -not $envelope.PSObject.Properties['Items']) {
                    Set-Status "Fetch returned invalid envelope. Output type: $($jobOutput.GetType().Name)"
                    $progMain.IsIndeterminate = $false; $btnFetch.IsEnabled = $true; return
                }

                if ($envelope.Error) {
                    Set-Status "Fetch error: $($envelope.Error)"
                    $progMain.IsIndeterminate = $false; $btnFetch.IsEnabled = $true; return
                }

                $rawResults = @($envelope.Items)
                if ($rawResults.Count -eq 0) {
                    $diag = "No packages found. HTML=$($envelope.HtmlLen) bytes, raw links=$($envelope.RawLinkCount), type=$($envelope.UsedType), ring=$($envelope.UsedRing)"
                    if ($envelope.HtmlLen -eq 0) {
                        $diag = "rg-adguard returned empty response. Check URL/network."
                    } elseif ($envelope.RawLinkCount -eq 0) {
                        $diag = "rg-adguard found no packages for this URL/ring. Try different ring or verify URL."
                    }
                    Set-Status $diag
                    $progMain.IsIndeterminate = $false; Hide-Cancel -OpKey 'fetch'; return
                }

                # Arka plan işi sonuçlarını normalleştir / Normalize background job results
                $results = @(
                    foreach ($ri in $rawResults) {
                        $v = [Version]'0.0.0.0'
                        try { $v = [Version]($ri.Version.ToString()) } catch {}
                        [PSCustomObject]@{
                            FileName    = [string]$ri.FileName
                            Url         = [string]$ri.Url
                            Version     = $v
                            BaseName    = [string]$ri.BaseName
                            IsDep       = [bool]$ri.IsDep
                            IsBundle    = [bool]$ri.IsBundle
                            IsInstaller = [bool]$ri.IsInstaller
                            Size        = [long]$ri.Size
                        }
                    }
                )

                # ── Paketleri mimari ve türe göre kategorize et / Categorize packages by arch and type ─────────────
                $selArch = if ($cmbArch.SelectedItem) { $cmbArch.SelectedItem.Content.ToString() } else { 'x64' }
                # Mimari regex filtresi / Arch regex filter
                $archPattern = "_$([regex]::Escape($selArch))(?=[_.])"

                # Aday listelerini grupla / Group candidate lists
                $mainCandidates = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]'
                $depCandidates  = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]'

                foreach ($r in $results) {
                    $bn = $r.BaseName
                    if ([string]::IsNullOrWhiteSpace($bn)) { continue }
                    if ($r.IsDep) {
                        if (-not $depCandidates.ContainsKey($bn)) {
                            $depCandidates[$bn] = New-Object 'System.Collections.Generic.List[object]'
                        }
                        $depCandidates[$bn].Add($r)
                    } else {
                        if (-not $mainCandidates.ContainsKey($bn)) {
                            $mainCandidates[$bn] = New-Object 'System.Collections.Generic.List[object]'
                        }
                        $mainCandidates[$bn].Add($r)
                    }
                }

                $allItems = New-Object 'System.Collections.Generic.List[object]'

                # ── ANA paketler: her temel ad için en güncel olanı bul / MAIN packages: separate latest for each baseName ───────────
                foreach ($bn in @($mainCandidates.Keys)) {
                    $entries = @($mainCandidates[$bn])

                    # Yükleyicileri (.exe/.msi) ayrı tut - her zaman göster / Keep installers (.exe/.msi) separate - always show
                    $installerEntries = @($entries | Where-Object { $_.IsInstaller })
                    $pkgEntries       = @($entries | Where-Object { -not $_.IsInstaller })

                    # Bundle'lar mimari bağımsızdır — her zaman dahil et / Bundles are arch-agnostic — always include
                    $bundleEntries = @($pkgEntries | Where-Object { $_.IsBundle })
                    $innerEntries  = @($pkgEntries | Where-Object { -not $_.IsBundle })

                    # Mimari filtresini yalnızca iç paketlere uygula / Apply arch filter only to inner packages
                    $matchList = @($innerEntries | Where-Object { $_.FileName -match $archPattern })
                    if ($matchList.Count -eq 0) {
                        $matchList = @($innerEntries | Where-Object { $_.FileName -match '_neutral(?=[_.])' })
                    }
                    if ($matchList.Count -eq 0) {
                        $matchList = @($innerEntries)
                    }

                    # ── Bundle-anchored sürüm seçimi ──────────────────────────────────────
                    # Sorun: rg-adguard hem eski iç paketleri (2.0.0.310_x64) hem de yeni
                    # bundle'ları (4.54.63040.0, 2016.1014.23.3280) döndürür.
                    # Numerik olarak 2016.x > 4.x olduğundan "en yüksek" seçimi yanlış bundle'ı
                    # işaret eder. Doğru anchor: iç paket sürümüyle eşleşen bundle.
                    #
                    # Algoritma:
                    #   1) İç paket varsa → en yüksek iç paket sürümünü anchor al
                    #      o sürümde bundle varsa bundle'ı da ekle
                    #   2) İç paket yoksa → iç paket sürümüyle eşleşen bundle'ı bul
                    #      eşleşen yoksa en yüksek bundle'ı kullan (son çare)
                    # / Bundle-anchored version selection: prefer inner package version as
                    # anchor to avoid old-schema bundles (2016.x) being picked over newer
                    # inner packages (4.54.x).
                    # ─────────────────────────────────────────────────────────────────────
                    $selectedInner   = @()
                    $selectedBundles = @()

                    # ── Anchor sürümünü belirle ───────────────────────────────────────────
                    # rg-adguard hem iç paketleri (2.0.0.310_x64, 4.54.x) hem de birden
                    # fazla bundle şeması (4.54.x ve 2016.x) döndürebilir. Numerik olarak
                    # 2016.x > 4.x olduğundan naif "en yüksek" seçimi yanlış bundle'ı işaret eder.
                    #
                    # Yeni karar ağacı:
                    #   • Bundle yoksa → en yüksek iç paket sürümü
                    #   • İç paket yoksa → en yüksek bundle sürümü (TEK-TİP şema varsayımı;
                    #     ScreenSketch gibi yıl-tabanlı şema kullanan uygulamalarda doğru)
                    #   • Her ikisi de varsa:
                    #       1) En yüksek iç paket sürümünde bundle varsa → o anchor
                    #       2) Yoksa: iç paket major'larıyla aynı major'da bundle'lar arasında
                    #          en yüksek (eski şema 2016.x bundle'ını eler)
                    #       3) Hiç eşleşme yoksa → en yüksek iç paket sürümü
                    # / Anchor version selection: inner-matched-bundle (v5)
                    #   İç paket versiyonuyla eşleşen bundle'lar arasından en yükseği.
                    #   Eşleşen yoksa tüm bundle'lar arasından en yükseği.
                    #   BingWeather: 4.54.x iç paket → 4.54.x bundle ✓ (2016.x elenir)
                    #   ScreenSketch: 2022.x,2021.x,2018.x → hepsi eşleşiyor → 2022.x ✓
                    # ─────────────────────────────────────────────────────────────────────
                    $anchorVer = $null
                    if ($bundleEntries.Count -gt 0) {
                        # İç paket versiyonlarıyla eşleşen bundle'ları bul
                        $innerVerSet    = @($innerEntries | ForEach-Object { $_.Version }) | Select-Object -Unique
                        $matchedBundles = @($bundleEntries | Where-Object { $innerVerSet -contains $_.Version })
                        $anchorPool     = if ($matchedBundles.Count -gt 0) { $matchedBundles } else { $bundleEntries }

                        # AKTİF-ŞEMA SEÇİMİ — sürüm sayısı çok olan kazanır
                        # rg-adguard hem yıl-bazlı (2016.x, 2025.x) hem semver (4.54.x, 1.26.x)
                        # döndürebilir. Doğru cevap uygulamaya göre değişir:
                        #   BingWeather/YourPhone: yıl→semver geçiş → modern aktif
                        #   3DViewer/OfficeHub/RemoteDesktop/ZuneVideo: semver→yıl → legacy aktif
                        # Heuristic: hangi havuzda daha çok sürüm varsa o aktif (Microsoft
                        # düzenli yayın yaptığı şemada en çok sürüme sahiptir).
                        # Eşitlik halinde legacy major≥2024 ise legacy.
                        # / Active schema picker: pool with more versions wins.
                        $modernPool = @($anchorPool | Where-Object { $_.Version.Major -lt 2000 })
                        $legacyPool = @($anchorPool | Where-Object { $_.Version.Major -ge 2000 })
                        if ($modernPool.Count -gt 0 -and $legacyPool.Count -gt 0) {
                            if ($modernPool.Count -gt $legacyPool.Count) {
                                $anchorPool = $modernPool
                            } elseif ($legacyPool.Count -gt $modernPool.Count) {
                                $anchorPool = $legacyPool
                            } else {
                                # Eşit — legacy en yüksek major>=2024 ise legacy seç
                                $legacyTopMajor = ($legacyPool | Sort-Object Version -Descending | Select-Object -First 1).Version.Major
                                $anchorPool = if ($legacyTopMajor -ge 2024) { $legacyPool } else { $modernPool }
                            }
                        }

                        $anchorVer      = ($anchorPool | Sort-Object Version -Descending | Select-Object -First 1).Version
                        $selectedBundles = @($bundleEntries | Where-Object { $_.Version -eq $anchorVer })
                        $selectedInner   = @($matchList   | Where-Object { $_.Version -eq $anchorVer })
                    } elseif ($matchList.Count -gt 0) {
                        # Bundle yok → en yüksek arch-filtered iç paket
                        # Aktif şema seçimi burada da uygula
                        $modernInners = @($matchList | Where-Object { $_.Version.Major -lt 2000 })
                        $legacyInners = @($matchList | Where-Object { $_.Version.Major -ge 2000 })
                        $innerPool    = $matchList
                        if ($modernInners.Count -gt 0 -and $legacyInners.Count -gt 0) {
                            if ($modernInners.Count -gt $legacyInners.Count) {
                                $innerPool = $modernInners
                            } elseif ($legacyInners.Count -gt $modernInners.Count) {
                                $innerPool = $legacyInners
                            } else {
                                $legacyTopMajor = ($legacyInners | Sort-Object Version -Descending | Select-Object -First 1).Version.Major
                                $innerPool = if ($legacyTopMajor -ge 2024) { $legacyInners } else { $modernInners }
                            }
                        }

                        $anchorVer     = ($innerPool | Sort-Object Version -Descending | Select-Object -First 1).Version
                        $selectedInner = @($matchList | Where-Object { $_.Version -eq $anchorVer })
                    }

                    # archFiltered = anchor sürümündeki paketler (LATEST) +
                    #                geri kalan tüm arch-filtered iç paketler ve bundle'lar (OLDER)
                    # Eski sürümler seçili olmadan gösterilir.
                    # / archFiltered = anchor-version packages (LATEST) +
                    #                  all remaining arch-filtered inner + bundles (OLDER, unchecked)
                    $latestVer = if ($anchorVer) { $anchorVer } else { [Version]'0.0.0.0' }

                    # Anchor dışındaki iç paketler (arch filtreli) — OLDER
                    $olderInner   = @($matchList   | Where-Object { $_.Version -ne $anchorVer })
                    # Anchor dışındaki bundle'lar — OLDER (2016.x gibi eski şema dahil)
                    $olderBundles = @($bundleEntries | Where-Object { $_.Version -ne $anchorVer })

                    $archFiltered = @($selectedInner) + @($selectedBundles) +
                                    @($olderInner)    + @($olderBundles)    + @($installerEntries)
                    if ($archFiltered.Count -eq 0) { continue }

                    foreach ($e in ($archFiltered | Sort-Object Version -Descending)) {
                        $cat = if ($e.Version -eq $latestVer) { 'latest' } else { 'old' }
                        $allItems.Add([PSCustomObject]@{ Entry=$e; Category=$cat })
                    }
                }

                # ── BAĞIMLILIK paketleri: aynı aşamalı mimari filtresi / DEPENDENCY packages: same cascading arch filter ─────────
                foreach ($bn in @($depCandidates.Keys)) {
                    $entries = @($depCandidates[$bn])

                    $matchList = @($entries | Where-Object { $_.FileName -match $archPattern })
                    if ($matchList.Count -eq 0) {
                        $matchList = @($entries | Where-Object { $_.FileName -match '_neutral(?=[_.])' })
                    }
                    if ($matchList.Count -eq 0) {
                        $matchList = @($entries)
                    }
                    if ($matchList.Count -eq 0) { continue }

                    $latestEntry = $matchList | Sort-Object Version -Descending | Select-Object -First 1
                    $latestVer   = if ($latestEntry) { $latestEntry.Version } else { [Version]'0.0.0.0' }

                    foreach ($e in ($matchList | Sort-Object Version -Descending)) {
                        $cat = if ($e.Version -eq $latestVer) { 'dep' } else { 'old' }
                        $allItems.Add([PSCustomObject]@{ Entry=$e; Category=$cat })
                    }
                }

                # ── Sıralama: En Güncel > Bağımlılık > Eski, ardından isim / Sorting: Latest > Dep > Older, then name ─────────────
                $catOrder = @{ 'latest'=0; 'dep'=1; 'old'=2 }
                $sorted = $allItems | Sort-Object `
                    @{E = { $catOrder[$_.Category] }}, `
                    @{E = { $_.Entry.FileName }}

                foreach ($it in $sorted) {
                    $r   = $it.Entry
                    $cat = $it.Category
                    $statusFg  = switch ($cat) { 'latest'{'#22C55E'}; 'dep'{'#64B4FF'}; default{'#71717A'} }
                    $statusBg  = switch ($cat) { 'latest'{'#14532D'}; 'dep'{'#1E3A5F'}; default{'#27272A'} }
                    $statusTxt = switch ($cat) { 'latest'{T 'BadgeLatest'}; 'dep'{T 'BadgeDep'}; default{T 'BadgeOlder'} }
                    $rowFgHex  = if ($cat -eq 'old') { '#71717A' } else { $null }

                    $item = New-Object PackageItem
                    $item.FileName  = $r.FileName
                    $item.Version   = $r.Version.ToString()
                    $item.SizeText  = if ($r.Size -gt 0) { Format-Size $r.Size } else { '-' }
                    $item.Url       = $r.Url
                    $item.SizeBytes = [long]$r.Size
                    $item.IsChecked = ($cat -ne 'old')
                    $item.RowFg     = if ($rowFgHex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($rowFgHex)) } else { Get-PrimaryFgBrush }
                    Set-StatusBadge $item $statusTxt $statusBg $statusFg
                    $script:Packages.Add($item)
                }

                # Ring metnini kullanıcıya göstermek için arayüzden yeniden oku / Re-read ring text from UI to show to user
                $selRingTxt = if ($cmbRing.SelectedItem) { $cmbRing.SelectedItem.Content.ToString() } else { 'Retail' }
                Set-Status ("$($script:Packages.Count) package(s) found [arch=$selArch, ring=$selRingTxt]")
                $progMain.IsIndeterminate = $false; $progMain.Value = 100
                Hide-Cancel -OpKey 'fetch'

                # ── Güncelleme kuyruğu zinciri: otomatik Tümünü İndir / Update queue chain: automatic Download All ──────
                if ($script:AutoDownloadAfterFetch -and $script:Packages.Count -gt 0) {
                    $script:AutoDownloadAfterFetch = $false
                    # En Güncel ve Bağımlılık onay kutuları zaten otomatik olarak işaretli / Latest + Dep checkboxes are already auto-checked
                    $window.Dispatcher.BeginInvoke([Action]{
                        $btnDownload.RaiseEvent(
                            [System.Windows.RoutedEventArgs]::new(
                                [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
                } elseif ($script:AutoDownloadAfterFetch) {
                    # Fetch hiç paket bulamadı - kuyruktaki sonraki uygulamaya geç / Fetch found no packages - move to next app in queue
                    $script:AutoDownloadAfterFetch = $false
                    $script:AutoInstallAfterDownload = $false
                    if ($script:UpdateQueue -and $script:UpdateQueue.Count -gt 0) {
                        Start-Sleep -Milliseconds 500
                        Start-NextUpdateInQueue
                    }
                }
            } elseif ($j.State -eq 'Failed') {
                $script:fetchTimer.Stop()
                $err = $j.ChildJobs[0].JobStateInfo.Reason.Message
                Remove-Job $j; $script:fetchJob = $null
                Set-Status "Fetch error: $err"
                $progMain.IsIndeterminate = $false; Hide-Cancel -OpKey 'fetch'
                # Güncelleme kuyruğu varsa sonraki uygulamaya geç / If update queue exists, move to next app
                if ($script:AutoDownloadAfterFetch) {
                    $script:AutoDownloadAfterFetch = $false
                    $script:AutoInstallAfterDownload = $false
                    if ($script:UpdateQueue -and $script:UpdateQueue.Count -gt 0) {
                        Start-NextUpdateInQueue
                    }
                }
            }
        })
        $script:fetchTimer.Start()
        return
    }
})

$btnSelectAll.Add_Click({
    foreach ($p in $script:Packages) { $p.IsChecked = $true }
    Update-ActionButtonsState
})
$btnDeselectAll.Add_Click({
    foreach ($p in $script:Packages) { $p.IsChecked = $false }
    Update-ActionButtonsState
})
$btnDownloadAll.Add_Click({
    foreach ($p in $script:Packages) { $p.IsChecked = $true }
    Update-ActionButtonsState
    $btnDownload.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
})


# ── Bağımlılık paketlerini tanımla / Define dependency packages ───────────────────────
$script:DependencyPatterns = @(
    'Microsoft\.VCLibs\.',
    'Microsoft\.UI\.Xaml\.',
    'Microsoft\.NET\.Native\.Framework',
    'Microsoft\.NET\.Native\.Runtime',
    'Microsoft\.Services\.Store\.Engagement',
    'Microsoft\.WindowsAppRuntime\.',
    'Microsoft\.DirectXRuntime',
    'Microsoft\.Advertising\.Xaml',
    'Microsoft\.NET\.CoreRuntime',
    'Microsoft\.WinJS\.'
)

function Test-IsDependency {
    param([string]$fileName)
    if ([string]::IsNullOrWhiteSpace($fileName)) { return $false }
    foreach ($pat in $script:DependencyPatterns) {
        if ($fileName -match $pat) { return $true }
    }
    return $false
}

$btnBrowse.Add_Click({
    $fd = New-Object System.Windows.Forms.OpenFileDialog
    $fd.Multiselect = $true
    $fd.Filter = "Package files|*.appx;*.appxbundle;*.msix;*.msixbundle|All files|*.*"
    if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $depCount = 0
        $mainCount = 0
        foreach ($f in $fd.FileNames) {
            $fi = Get-Item $f
            $item = New-Object PackageItem
            $item.FileName = $fi.Name
            $item.SizeBytes= $fi.Length
            $item.SizeText = Format-Size $fi.Length
            $item.Url      = $fi.FullName

            # Görünür metin rengi / Visible text color
            $item.RowFg = Get-PrimaryFgBrush

            # Dosya adından sürüm bilgisini çıkar / Extract version info from filename
            $version = $null
            $parts = $fi.BaseName -split '_'
            if ($parts.Count -ge 2) {
                $vStr = $parts[1]
                # 4 oktet x.y.z.w olmalı / Must be 4 octets x.y.z.w
                if ($vStr -match '^\d+\.\d+\.\d+\.\d+$') {
                    $version = $vStr
                }
            }
            # Gerekirse manifestten oku / Read from manifest if needed
            if (-not $version -and $fi.Extension -match 'appx|msix|bundle') {
                try {
                    $mi = Get-PackageManifestInfo -PackageFile $fi
                    if ($mi.Identity -and $mi.Identity.Version) {
                        $version = $mi.Identity.Version
                    }
                } catch {}
            }
            $item.Version = if ($version) { $version } else { '-' }

            # Bağımlılık mı, ana uygulama mı? / Is it a dependency or main app?
            if (Test-IsDependency $fi.Name) {
                Set-StatusBadge $item 'DEPENDENCY' '#1E3A5F' '#93C5FD'
                $item.IsChecked = $true   # Bağımlılıkları varsayılan seç / Dependencies selected by default
                $depCount++
            } else {
                Set-StatusBadge $item 'MAIN APP' '#14532D' '#86EFAC'
                $item.IsChecked = $true
                $mainCount++
            }
            $script:Packages.Add($item)
        }
        if ($lvPackages) { $lvPackages.Items.Refresh() }
        Update-ActionButtonsState
        # Kullanıcıya hem ana uygulama hem bağımlılık sayısını göster / Show both main app and dependency count to user
        $msg = ("Added {0} file(s): {1} app(s), {2} dependency" -f ($depCount + $mainCount), $mainCount, $depCount)
        Set-Status $msg
    }
})

$btnReset.Add_Click({
    # ── Fetch işlemini durdur / Stop any active fetch ────────────────────────
    if ($script:fetchTimer) { $script:fetchTimer.Stop() }
    if ($script:fetchJob) { Stop-Job $script:fetchJob -ErrorAction SilentlyContinue; Remove-Job $script:fetchJob -ErrorAction SilentlyContinue; $script:fetchJob = $null }

    # ── Aktif indirmeleri durdur / Stop any active downloads ─────────────────
    $script:cancelDownload = $true
    $script:cancelInstall  = $true
    if ($script:dlRunspaces -and $script:dlRunspaces.Count -gt 0) {
        foreach ($rs in @($script:dlRunspaces)) {
            try { $rs.PS.Stop() } catch {}
            try { $rs.PS.Dispose() } catch {}
        }
        $script:dlRunspaces.Clear()
    }
    if ($script:dlPool) { try { $script:dlPool.Close(); $script:dlPool.Dispose() } catch {}; $script:dlPool = $null }
    if ($script:dlTimer) { $script:dlTimer.Stop() }

    # ── Güncelleme kuyruğunu temizle / Clear update queue ────────────────────
    if ($script:UpdateQueue) { $script:UpdateQueue.Clear() }
    $script:UpdateQueueTotal          = 0
    $script:UpdateQueueDone           = 0
    $script:AutoDownloadAfterFetch    = $false
    $script:AutoInstallAfterDownload  = $false

    # ── UI ve durum değişkenlerini sıfırla / Reset UI and state variables ────
    $txtUrl.Text = ''
    $cmbPackage.Text = ''
    $script:Packages.Clear()
    $script:lastPackagePath = $null
    if ($script:DlFiles) { $script:DlFiles.Clear() }
    if ($lblDlEmpty) { $lblDlEmpty.Visibility = 'Collapsed' }  # indirme başlayınca gizle
    if ($txtLog) { $txtLog.Text = (T 'DlNoActivity') }
    if ($lvPackages) { $lvPackages.Items.Refresh() }
    Update-ActionButtonsState
    $progMain.Value = 0
    $progMain.IsIndeterminate = $false
    $btnReset.Content = (T 'BtnReset')
    $btnReset.IsEnabled = $true
    if ($btnFetch) { $btnFetch.IsEnabled = $true }
    if ($btnRetryFailed) { $btnRetryFailed.Visibility = 'Collapsed' }
    $script:cancelDownload = $false
    $script:cancelInstall  = $false
    # Reset yalnızca fetch/download/install işlemlerini temizler (rescan'a dokunmaz)
    Hide-Cancel -OpKey 'fetch'
    Hide-Cancel -OpKey 'download'
    Hide-Cancel -OpKey 'install'
    Set-Status ($script:Strings[$script:Lang].StatusReady)
})

# ── İptal düğmesi: Fetch / Download / Install işlemlerini iptal eder / Cancel button: Cancels Fetch / Download / Install operations ──
if ($btnCancel) {
    $btnCancel.Add_Click({
        $btnCancel.IsEnabled = $false
        $btnCancel.Content = (T 'BtnCancelling')

        # ── Global iptal: tüm aktif işlemleri sonlandır ─────────────────────────
        # 1) Update Queue varsa boşalt
        if ($script:UpdateQueue) {
            try { $script:UpdateQueue.Clear() } catch {}
            $script:UpdateQueueTotal   = 0
            $script:UpdateQueueDone    = 0
            $script:UpdateQueueSuccess = 0
        }
        # 2) Spawn edilmiş child process'leri (winget, makeappx vb.) öldür
        Stop-AllChildPids


        if (-not $script:ActiveOpKeys) { $script:ActiveOpKeys = [System.Collections.Generic.HashSet[string]]::new() }

        $currentTab = $NavList.SelectedIndex
        # 0 = Fetch, 1 = Installed (rescan), diğer sekmeler fetch/download/install kapsamında değil

        switch ($currentTab) {
            0 {
                # Fetch sekmesi: fetch ve/veya download/install iptal et
                if ($script:ActiveOpKeys.Contains('fetch')) {
                    if ($script:fetchTimer) { $script:fetchTimer.Stop() }
                    if ($script:fetchJob) {
                        Stop-Job $script:fetchJob -ErrorAction SilentlyContinue
                        Remove-Job $script:fetchJob -ErrorAction SilentlyContinue
                        $script:fetchJob = $null
                    }
                    if ($btnFetch) { $btnFetch.IsEnabled = $true }
                    Hide-Cancel -OpKey 'fetch'
                }
                if ($script:ActiveOpKeys.Contains('download')) {
                    $script:cancelDownload = $true
                }
                if ($script:ActiveOpKeys.Contains('install')) {
                    $script:cancelInstall = $true
                }
            }
            1 {
                # Installed sekmesi: sadece rescan iptal et, download/install'a dokunma
                if ($script:ActiveOpKeys.Contains('rescan')) {
                    $script:cancelRescan = $true
                }
            }
            2 {
                # Winget sekmesi: batch güncelleme iptal et
                if ($script:ActiveOpKeys.Contains('winget')) {
                    $script:cancelWinget = $true
                    # Worker'a cancel flag dosyasını yaz (Start-Job scope ayrı olduğundan
                    # dosya üzerinden iletişim kuruyoruz)
                    try {
                        if ($script:_wBatchTmpCancel) {
                            [System.IO.File]::WriteAllText($script:_wBatchTmpCancel, 'cancel')
                        }
                    } catch { }
                    # Mevcut winget process'ini de sonlandır (indirme anında dursun)
                    try {
                        Get-Process -Name 'winget' -ErrorAction SilentlyContinue |
                            Stop-Process -Force -ErrorAction SilentlyContinue
                    } catch { }
                    if ($lblWingetStatus) {
                        $lblWingetStatus.Text = if ($script:Lang -eq 'TR') { 'İptal ediliyor...' } else { 'Cancelling...' }
                    }
                }
            }
            default {
                # Diğer sekmeler için aktif olan her şeyi iptal et
                if ($script:ActiveOpKeys.Contains('rescan'))   { $script:cancelRescan   = $true }
                if ($script:ActiveOpKeys.Contains('download')) { $script:cancelDownload = $true }
                if ($script:ActiveOpKeys.Contains('install'))  { $script:cancelInstall  = $true }
                if ($script:ActiveOpKeys.Contains('fetch')) {
                    if ($script:fetchTimer) { $script:fetchTimer.Stop() }
                    if ($script:fetchJob) {
                        Stop-Job $script:fetchJob -ErrorAction SilentlyContinue
                        Remove-Job $script:fetchJob -ErrorAction SilentlyContinue
                        $script:fetchJob = $null
                    }
                    if ($btnFetch) { $btnFetch.IsEnabled = $true }
                    Hide-Cancel -OpKey 'fetch'
                }
            }
        }

        $progMain.IsIndeterminate = $false
        Set-Status (if ($script:Lang -eq 'TR') { 'İşlem iptal edildi.' } else { 'Operation cancelled.' })
        # Her aktif işlem kendi döngüsünde bayrağı fark edip Hide-Cancel ile kendini temizler.
    })
}

# ── Installed sekmesi cancel butonu (slot içinde Rescan'ın yerini alır) ────
if ($btnInstCancel) {
    $btnInstCancel.Add_Click({
        if ($btnInstCancel) {
            $btnInstCancel.IsEnabled = $false
            $btnInstCancel.Content   = if ($script:Lang -eq 'TR') { 'İptal ediliyor...' } else { 'Cancelling...' }
        }
        # Rescan iptal
        if ($script:ActiveOpKeys -and $script:ActiveOpKeys.Contains('rescan')) {
            $script:cancelRescan = $true
        }
        # Update Queue boşalt
        if ($script:UpdateQueue) {
            try { $script:UpdateQueue.Clear() } catch {}
            $script:UpdateQueueTotal   = 0
            $script:UpdateQueueDone    = 0
            $script:UpdateQueueSuccess = 0
        }
        # Aktif download/install varsa onları da iptal et
        if ($script:ActiveOpKeys -and $script:ActiveOpKeys.Contains('download')) { $script:cancelDownload = $true }
        if ($script:ActiveOpKeys -and $script:ActiveOpKeys.Contains('install'))  { $script:cancelInstall  = $true }
        # Spawn edilmiş child process'leri kapat
        Stop-AllChildPids
        if ($lblInstFetchStatus) { $lblInstFetchStatus.Text = if ($script:Lang -eq 'TR') { 'İptal ediliyor...' } else { 'Cancelling...' } }
    })
}

# ── Installed sekmesi More butonu (overflow menü) ─────────────────────────
if ($btnInstMore -and $ctxInstMore) {
    $btnInstMore.Add_Click({
        $ctxInstMore.PlacementTarget = $btnInstMore
        $ctxInstMore.IsOpen = $true
    })
}
if ($ctxInstExportList -and $btnExportList) {
    $ctxInstExportList.Add_Click({
        # Eski Export butonunun click event'ini tetikle
        $btnExportList.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    })
}




$script:_suppressHeader = $false
$chkAll.Add_Click({
    # Olayı yoksay / Ignore event
    if ($script:_suppressHeader) { return }

    # Tümünü seç / Select all
    $script:_suppressHeader = $true
    try {
        if ($chkAll.IsChecked -eq $false) {
            foreach ($p in $script:Packages) { $p.IsChecked = $false }
        } else {
            $chkAll.IsChecked = $true
            foreach ($p in $script:Packages) { $p.IsChecked = $true }
        }
    } catch {}
    $script:_suppressHeader = $false
    Update-ActionButtonsState
})

# Context Menu
function Get-SelectedItem { return $lvPackages.SelectedItem }

$ctxCopyName.Add_Click({    $it = Get-SelectedItem; if ($it) { [Windows.Clipboard]::SetText($it.FileName) } })
$ctxCopyVersion.Add_Click({ $it = Get-SelectedItem; if ($it) { [Windows.Clipboard]::SetText($it.Version) } })
$ctxCopyUrl.Add_Click({     $it = Get-SelectedItem; if ($it -and $it.Url) { [Windows.Clipboard]::SetText($it.Url) } })
$ctxCopyStoreId.Add_Click({ $it = Get-SelectedItem; if ($it -and $it.StoreId) { [Windows.Clipboard]::SetText($it.StoreId) } })
$ctxToggle.Add_Click({      $it = Get-SelectedItem; if ($it) { $it.IsChecked = -not $it.IsChecked; Update-ActionButtonsState } })
$ctxOpenUrl.Add_Click({     $it = Get-SelectedItem; if ($it -and $it.Url) { Start-Process $it.Url } })
$ctxOpenStore.Add_Click({
    $it = Get-SelectedItem
    if (-not $it) { return }

    $storeUrl = $null

    # 1) PFN veya ProductId / 1) PFN or ProductId
    $src = $script:lastFetchedInput
    if (-not [string]::IsNullOrWhiteSpace($src)) {
        # URL biçimi / URL format
        if ($src -match '(?i)/detail/([A-Z0-9]{9,20})') {
            $storeUrl = "ms-windows-store://pdp/?ProductId=$($Matches[1])"
        # ProductId parametresi / ProductId parameter
        } elseif ($src -match '(?i)[?&]ProductId=([A-Z0-9]{9,20})') {
            $storeUrl = "ms-windows-store://pdp/?ProductId=$($Matches[1])"
        # Doğrudan ProductId / Direct ProductId
        } elseif ($src -match '^[A-Z0-9][A-Z0-9]{8,19}$') {
            $storeUrl = "ms-windows-store://pdp/?ProductId=$src"
        # PFN biçimi / PFN format
        } elseif ($src -match '^[A-Za-z0-9.\-]+_[a-z0-9]{8,}$') {
            $storeUrl = "ms-windows-store://pdp/?PFN=$src"
        # İsimle ara / Search by name
        } else {
            $storeUrl = "ms-windows-store://search/?query=$([Uri]::EscapeDataString($src))"
        }
    }

    # 2) Dosya adından PFN / 2) PFN from filename
    if (-not $storeUrl -and -not [string]::IsNullOrWhiteSpace($it.FileName)) {
        $parts = $it.FileName -split '_'
        if ($parts.Count -ge 2) {
            $pubHash = [System.IO.Path]::GetFileNameWithoutExtension($parts[-1])
            if (-not [string]::IsNullOrWhiteSpace($pubHash) -and $pubHash -ne '~') {
                $storeUrl = "ms-windows-store://pdp/?PFN=$($parts[0])_$pubHash"
            }
        }
    }

    # 3) İsimle ara / 3) Search by display name
    if (-not $storeUrl -and -not [string]::IsNullOrWhiteSpace($it.FileName)) {
        $storeUrl = "ms-windows-store://search/?query=$([Uri]::EscapeDataString($it.FileName))"
    }

    if ($storeUrl) { try { Start-Process $storeUrl } catch { Set-Status "Mağaza açılamadı: $($_.Exception.Message)" } }
})
$ctxOpenFolder.Add_Click({
    $it = Get-SelectedItem
    if ($it) {
        $filePath = $null
        if ($script:dlPackagePath -and (Test-Path $script:dlPackagePath)) {
            $candidate = Join-Path $script:dlPackagePath $it.FileName
            if (Test-Path $candidate) { $filePath = $candidate }
        }
        if (-not $filePath -and $script:lastPackagePath -and (Test-Path $script:lastPackagePath)) {
            $candidate = Join-Path $script:lastPackagePath $it.FileName
            if (Test-Path $candidate) { $filePath = $candidate }
        }
        if ($filePath) {
            # Dosyayı Explorer'da seç ve vurgula / Select and highlight file in Explorer
            Start-Process explorer.exe ("/select,`"$filePath`"")
        } elseif ($script:dlPackagePath -and (Test-Path $script:dlPackagePath)) {
            Start-Process explorer.exe $script:dlPackagePath
        } elseif ($script:lastPackagePath -and (Test-Path $script:lastPackagePath)) {
            Start-Process explorer.exe $script:lastPackagePath
        } else {
            if (Test-Path $script:DownloadFolder) { Start-Process explorer.exe $script:DownloadFolder }
        }
    }
})
$ctxSelectVer.Add_Click({   Show-CustomMessageBox -Title $window.Title -Icon Info -Buttons OK -Message 'Select Version dialog - plug in original logic.' | Out-Null })
$ctxFileInfo.Add_Click({
    $it = Get-SelectedItem
    if ($it) {
        $details = @"
Name:    $($it.FileName)
Version: $($it.Version)
Size:    $($it.SizeText)
URL:     $($it.Url)
StoreId: $($it.StoreId)
"@
        Show-CustomMessageBox -Title (T 'FileInfoTitle') -Icon Info -Buttons OK `
            -Message (T 'FileInfoMsg') -Details $details | Out-Null
    }
})

# Download / Install
$script:cancelDownload = $false
$script:dlJobs = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

$btnDownload.Add_Click({
    $sel = @($script:Packages | Where-Object { $_.IsChecked })
    if ($sel.Count -eq 0) { Set-Status "No items selected."; return }
    if ($btnRetryFailed) { $btnRetryFailed.Visibility = 'Collapsed' }

    # İndirme hedefini ayarla / Set download destination
    $dlRoot = if (-not [string]::IsNullOrWhiteSpace($script:DownloadFolder)) {
        $script:DownloadFolder
    } else {
        Join-Path ([Environment]::GetFolderPath('Desktop')) 'StoreDownload'
    }
    if (-not (Test-Path $dlRoot)) {
        try { New-Item -ItemType Directory -Path $dlRoot -Force | Out-Null } catch {}
    }
    $rawInput = $cmbPackage.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($rawInput)) { $rawInput = $txtUrl.Text.Trim() }
    # Klasör adı: PFN ise sadece temel adı (Publisher Hash kısmını at), URL ise son path segmenti
    # / Folder name: for PFN use only the base name (strip publisher hash suffix), for URLs use last path segment
    $folderName = if ($rawInput -match '^https?://') {
        # URL → son path segmenti (örn. 9MSSGKG348SP)
        ($rawInput -split '/' | Where-Object { $_ } | Select-Object -Last 1) -replace '[\\/:*?"<>|]','_'
    } elseif ($rawInput -match '_[0-9a-zA-Z]{13}$') {
        # PackageFamilyName formatı: "Publisher.AppName_publisherhash" → sadece temel adı al
        ($rawInput -split '_')[0] -replace '[\\/:*?"<>|]','_'
    } else {
        # Serbest metin / ProductId / base name — olduğu gibi kullan
        ($rawInput -replace '[\\/:*?"<>|]','_').Trim('_')
    }
    if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = "StorePackages_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
    $packagePath = Join-Path $dlRoot $folderName
    if (-not (Test-Path $packagePath)) { New-Item -ItemType Directory -Path $packagePath -Force | Out-Null }
    $script:lastPackagePath = $packagePath

    # ── Durumu script kapsamına al / Move state to script scope ──
    $script:cancelDownload    = $false
    $script:dlPackagePath     = $packagePath
    $script:dlTotal           = $sel.Count
    $script:dlDone            = 0
    $script:dlSuccess         = 0
    # İlerleme durumunu izle / Track progress
    $script:dlProgress        = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $script:dlLastSampleTime  = $null
    $script:dlLastSampleBytes = 0L

    # Günlüğü başlat / Start log
    if ($txtLog) {
        $ts = (Get-Date -Format 'HH:mm:ss')
        $txtLog.Text = "$ts  [INFO]  Starting download of $($sel.Count) package(s) -> $packagePath`n"
    }

    Show-Cancel -OpKey 'download'
    $progMain.Value         = 0

    # İndirmeler için çalışma alanı / Runspaces for downloads
    $script:dlPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($script:dlTotal, 4))
    $script:dlPool.Open()
    $script:dlRunspaces = [System.Collections.ArrayList]::new()

    foreach ($item in $sel) {
        $fn   = $item.FileName
        $url  = $item.Url
        $dest = Join-Path $packagePath $fn

        if (Test-Path $dest) {
            $existingSize = (Get-Item $dest).Length
            # Eksik dosyayı yeniden indir / Redownload incomplete file
            if ($item.SizeBytes -gt 0 -and $existingSize -ne $item.SizeBytes) {
                try { Remove-Item $dest -Force -ErrorAction SilentlyContinue } catch {}
            } else {
                $item.Status = 'EXISTS'
                $item.StatusBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#14532D'))
                $item.StatusFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#86EFAC'))
                $script:dlDone++; $script:dlSuccess++
                continue
            }
        }
        if ([string]::IsNullOrWhiteSpace($url)) {
            Set-StatusBadge $item 'No URL' '#450A0A' '#FCA5A5'
            $script:dlDone++; continue
        }

        Set-StatusBadge $item 'Queued' '#27272A' '#A1A1AA'

        # İndirme işlemini sıraya al / Queue download operation

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $script:dlPool
        [void]$ps.AddScript({
            param($url, $dest, $fn, $progressDict, $cancelFlag, $maxRetries)
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            [System.Net.ServicePointManager]::DefaultConnectionLimit = 16
            $result = @{ FileName=$fn; Success=$false; Error=''; SizeBytes=0L; Attempts=0 }

            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                $result.Attempts = $attempt
                if ($cancelFlag.Value) {
                    $result.Error = 'Cancelled'
                    return $result
                }

                # Yeniden deneme bekleme süresi / Retry backoff wait
                if ($attempt -gt 1) {
                    $waitSec = [Math]::Pow(2, $attempt)  # 4s, 8s
                    $progressDict[$fn] = [PSCustomObject]@{
                        BytesDone  = 0L
                        BytesTotal = 0L
                        Percent    = 0
                        Started    = $true
                        RetryInfo  = "Retry $attempt/$maxRetries - wait ${waitSec}s"
                    }
                    Start-Sleep -Seconds $waitSec
                    if ($cancelFlag.Value) {
                        $result.Error = 'Cancelled'
                        return $result
                    }
                }

                try {
                    $req = [System.Net.HttpWebRequest]::Create($url)
                    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                    $req.Timeout = 30000           # 30s bağlantı zaman aşımı / connection timeout
                    $req.ReadWriteTimeout = 30000   # 30s okuma zaman aşımı / read timeout
                    $req.KeepAlive = $true
                    $req.AllowAutoRedirect = $true
                    $req.MaximumAutomaticRedirections = 10
                    $resp       = $req.GetResponse()
                    $totalBytes = $resp.ContentLength

                    # Başlangıç durumu / Initial state
                    $retryTxt = if ($attempt -gt 1) { " (attempt $attempt)" } else { '' }
                    $progressDict[$fn] = [PSCustomObject]@{
                        BytesDone  = 0L
                        BytesTotal = $totalBytes
                        Percent    = 0
                        Started    = $true
                        RetryInfo  = $retryTxt
                    }

                    $respStream = $resp.GetResponseStream()
                    $respStream.ReadTimeout = 30000
                    $fileStream = [System.IO.File]::Create($dest)
                    $buffer     = New-Object byte[] 262144  # 256 KB tampon / 256 KB buffer
                    $dlBytes    = 0L
                    $lastUpdate = [DateTime]::UtcNow
                    $lastBytes  = 0L
                    $stallStart = $null
                    $wasCancelled = $false
                    while (($read = $respStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        # İptal kontrolü / Cancel check
                        if ($cancelFlag.Value) {
                            $wasCancelled = $true
                            break
                        }
                        $fileStream.Write($buffer,0,$read); $dlBytes += $read

                        # Takılma kontrolü - 30s boyunca ilerleme yoksa bağlantıyı kes / Stall detection - abort if no progress for 30s
                        $now = [DateTime]::UtcNow
                        if ($dlBytes -eq $lastBytes) {
                            if ($null -eq $stallStart) { $stallStart = $now }
                            elseif (($now - $stallStart).TotalSeconds -ge 30) {
                                throw "Download stalled for 30 seconds"
                            }
                        } else {
                            $stallStart = $null
                            $lastBytes = $dlBytes
                        }

                        # İlerlemeyi kaydet / Record progress
                        if (($now - $lastUpdate).TotalMilliseconds -ge 150) {
                            $pct = if ($totalBytes -gt 0) { [int]($dlBytes*100/$totalBytes) } else { 0 }
                            $progressDict[$fn] = [PSCustomObject]@{
                                BytesDone  = $dlBytes
                                BytesTotal = $totalBytes
                                Percent    = $pct
                                Started    = $true
                                RetryInfo  = $retryTxt
                            }
                            $lastUpdate = $now
                        }
                    }
                    $fileStream.Close(); $respStream.Close(); $resp.Close()

                    if ($wasCancelled) {
                        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
                        $result.Error = 'Cancelled'
                        return $result
                    }

                    # Boyut doğrulama / Size validation
                    if ($totalBytes -gt 0 -and $dlBytes -ne $totalBytes) {
                        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
                        throw "Incomplete download: got $dlBytes of $totalBytes bytes"
                    }

                    # Son ilerleme güncellemesi / Final progress update
                    $progressDict[$fn] = [PSCustomObject]@{
                        BytesDone  = $dlBytes
                        BytesTotal = $totalBytes
                        Percent    = 100
                        Started    = $true
                        RetryInfo  = ''
                    }

                    $result.SizeBytes = $dlBytes
                    $result.Success = $true
                    return $result
                } catch {
                    $result.Error = $_.Exception.Message
                    if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
                    # Son deneme değilse devam et / Continue if not last attempt
                    if ($attempt -lt $maxRetries) {
                        $progressDict[$fn] = [PSCustomObject]@{
                            BytesDone  = 0L
                            BytesTotal = 0L
                            Percent    = 0
                            Started    = $true
                            RetryInfo  = "Failed, retrying ($attempt/$maxRetries)..."
                        }
                    }
                }
            }
            return $result
        })
        [void]$ps.AddParameters(@{ url=$url; dest=$dest; fn=$fn; progressDict=$script:dlProgress; cancelFlag=([ref]$script:cancelDownload); maxRetries=3 })
        $handle = $ps.BeginInvoke()
        [void]$script:dlRunspaces.Add([PSCustomObject]@{ PS=$ps; Handle=$handle; Item=$item; FileName=$fn; Url=$url })
    }

    # ── Boyut formatlayıcı (zamanlayıcı içinde kullanmak için) / Size formatter (for use inside timer) ──
    $script:dlFormatBytes = {
        param([long]$b)
        if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
        if ($b -ge 1MB) { return "{0:N2} MB" -f ($b / 1MB) }
        if ($b -ge 1KB) { return "{0:N1} KB" -f ($b / 1KB) }
        return "$b B"
    }

    # Poll timer
    $script:dlTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:dlTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:dlTimer.Add_Tick({
        # ── Bitmiş çalışma alanlarını topla / Collect finished runspaces ──
        $completed = @($script:dlRunspaces | Where-Object { $_.Handle.IsCompleted })
        foreach ($rs in $completed) {
            try {
                $res = $rs.PS.EndInvoke($rs.Handle)
                $rs.PS.Dispose()
                [void]$script:dlRunspaces.Remove($rs)
                $script:dlDone++
                $itm = $rs.Item
                if ($script:cancelDownload) {
                    Set-StatusBadge $itm 'Cancelled' '#27272A' '#A1A1AA'
                    # Yarım kalmış dosyayı sil / Delete partial file
                    $partialDest = Join-Path $script:dlPackagePath $rs.FileName
                    if (Test-Path $partialDest) {
                        try { Remove-Item $partialDest -Force -ErrorAction SilentlyContinue } catch {}
                    }
                } elseif ($res.Success) {
                    $sz = if ($res.SizeBytes -gt 0) { Format-Size $res.SizeBytes } else { '-' }
                    $itm.SizeText = $sz
                    Set-StatusBadge $itm "DOWNLOADED" '#14532D' '#86EFAC'
                    $script:dlSuccess++
                    Add-HistoryEntry $res.FileName $sz 'Downloaded' '#14532D' '#86EFAC'
                    # Günlüğü güncelle / Update log
                    if ($txtLog) {
                        $ts = (Get-Date -Format 'HH:mm:ss')
                        $txtLog.Text = "$ts  [OK]  $($res.FileName)  ($sz)`n" + $txtLog.Text
                    }
                    # Tamamlanmış dosyayı ilerleme sözlüğünden temizle / Clear finished file from progress dict
                    $null = $script:dlProgress.TryRemove($rs.FileName, [ref]$null)
                } else {
                    $errDetail = if ($res.Error) { $res.Error } else { 'Unknown error' }
                    $attempts = if ($res.Attempts) { $res.Attempts } else { 1 }
                    Set-StatusBadge $itm ("FAILED ({0}x)" -f $attempts) '#450A0A' '#FCA5A5'
                    $null = $script:dlProgress.TryRemove($rs.FileName, [ref]$null)
                    # Hata günlüğü / Error log
                    if ($txtLog) {
                        $ts = (Get-Date -Format 'HH:mm:ss')
                        $txtLog.Text = "$ts  [FAIL]  $($rs.FileName)  -> $errDetail`n" + $txtLog.Text
                    }
                }
            } catch {
                $script:dlDone++
                [void]$script:dlRunspaces.Remove($rs)
            }
        }

        # ── Aktif öğeler için ilerlemeyi göster + toplamları hesapla / Show progress for active items + calculate totals ──
        $aggDone  = 0L
        $aggTotal = 0L
        $activeCount = 0
        foreach ($rs in @($script:dlRunspaces)) {
            $fn = $rs.FileName
            $prog = $null
            if ($script:dlProgress.TryGetValue($fn, [ref]$prog) -and $prog) {
                # Yeniden deneme bilgisi / Retry info
                $retryInfo = if ($prog.RetryInfo) { $prog.RetryInfo } else { '' }
                if ($retryInfo -and $prog.BytesDone -eq 0 -and $prog.BytesTotal -le 0) {
                    # Yeniden deneme bekleme durumu / Retry waiting state
                    Set-StatusBadge $rs.Item $retryInfo '#2A2419' '#FDE68A'
                    $activeCount++
                } else {
                    $done = & $script:dlFormatBytes $prog.BytesDone
                    $retryTag = if ($retryInfo) { " $retryInfo" } else { '' }
                    if ($prog.BytesTotal -gt 0) {
                        # Boyut biliniyor / Size known
                        $tot = & $script:dlFormatBytes $prog.BytesTotal
                        Set-StatusBadge $rs.Item ("{0}% - {1}/{2}{3}" -f $prog.Percent, $done, $tot, $retryTag) '#1E3A5F' '#93C5FD'
                        $aggDone  += [long]$prog.BytesDone
                        $aggTotal += [long]$prog.BytesTotal
                        $activeCount++
                    } elseif ($prog.BytesDone -gt 0) {
                        # Boyut bilinmiyor / Size unknown
                        Set-StatusBadge $rs.Item ("{0} downloaded{1}" -f $done, $retryTag) '#1E3A5F' '#93C5FD'
                        $aggDone  += [long]$prog.BytesDone
                        $activeCount++
                    } else {
                        # Bağlanıyor / Connecting
                        Set-StatusBadge $rs.Item ('Starting...' + $retryTag) '#1E3A5F' '#93C5FD'
                        $activeCount++
                    }
                }
            }
            # Kuyrukta bekle / Wait in queue
        }

        # ── Hız hesabı (son örnekten beri geçen süre) / Speed calculation (elapsed time since last sample) ──
        $now = [DateTime]::UtcNow
        $speedTxt = ''
        if ($null -ne $script:dlLastSampleTime) {
            $elapsed = ($now - $script:dlLastSampleTime).TotalSeconds
            if ($elapsed -ge 0.4) {
                # Anlık hız hesabı / Instant speed calc
                $diff = $aggDone - [long]$script:dlLastSampleBytes
                if ($diff -lt 0) { $diff = 0 }
                $bps = $diff / $elapsed
                if ($bps -gt 0) {
                    $speedTxt = ' - ' + (& $script:dlFormatBytes ([long]$bps)) + '/s'
                }
                $script:dlLastSampleTime  = $now
                $script:dlLastSampleBytes = $aggDone
            }
        } else {
            $script:dlLastSampleTime  = $now
            $script:dlLastSampleBytes = $aggDone
        }

        # ── İlerleme çubuğunu güncelle / Update progress bar ──
        $finishedPct = if ($script:dlTotal -gt 0) { ($script:dlDone * 100.0 / $script:dlTotal) } else { 0 }
        $activePct   = 0.0
        if ($activeCount -gt 0 -and $aggTotal -gt 0) {
            $activePct = (($aggDone * 100.0 / $aggTotal) * $activeCount) / $script:dlTotal
        }
        $progMain.Value = [Math]::Min(100, [Math]::Round($finishedPct + $activePct))

        # ── Durum çubuğunu güncelle / Update status bar ──
        $activeActual = $script:dlRunspaces.Count
        $queuedCount  = $activeActual - $activeCount
        if ($activeActual -gt 0 -and $aggTotal -gt 0) {
            $aggDoneTxt  = & $script:dlFormatBytes $aggDone
            $aggTotalTxt = & $script:dlFormatBytes $aggTotal
            $queuedTxt   = if ($queuedCount -gt 0) { ", queued: $queuedCount" } else { '' }
            Set-Status ("Downloading - done: {0}/{1}, active: {2}{3} - {4}/{5}{6}" -f `
                $script:dlDone, $script:dlTotal, $activeCount, $queuedTxt, $aggDoneTxt, $aggTotalTxt, $speedTxt)
        } elseif ($activeActual -gt 0) {
            $queuedTxt   = if ($queuedCount -gt 0) { ", queued: $queuedCount" } else { '' }
            Set-Status ("Downloading - done: {0}/{1}, active: {2}{3}" -f `
                $script:dlDone, $script:dlTotal, $activeCount, $queuedTxt)
        }

        # ── Tüm indirmeler bitti mi? / Are all downloads finished? ──
        if ($script:dlRunspaces.Count -eq 0) {
            $script:dlTimer.Stop()
            $script:dlLastSampleTime  = $null
            $script:dlLastSampleBytes = 0L
            try { $script:dlPool.Close(); $script:dlPool.Dispose() } catch {}
            $btnReset.Content = (T 'BtnReset')
            Hide-Cancel -OpKey 'download'
            $progMain.Value = 100
            $failCount = $script:dlTotal - $script:dlSuccess
            if ($failCount -gt 0) {
                Set-Status ("{0}/{1} downloaded, {2} failed -> {3}" -f $script:dlSuccess, $script:dlTotal, $failCount, $script:dlPackagePath)
                # Başarısızları tekrarla butonu göster / Show retry failed button
                if ($btnRetryFailed) { $btnRetryFailed.Visibility = 'Visible' }
            } else {
                Set-Status ("{0}/{1} downloaded -> {2}" -f $script:dlSuccess, $script:dlTotal, $script:dlPackagePath)
            }

            # ── Güncelleme kuyruğu zinciri: otomatik Yükle / Update queue chain: automatic Install Apps ────────
            if ($script:AutoInstallAfterDownload -and $script:dlSuccess -gt 0) {
                $script:AutoInstallAfterDownload = $false
                $window.Dispatcher.BeginInvoke([Action]{
                    $btnInstall.RaiseEvent(
                        [System.Windows.RoutedEventArgs]::new(
                            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
            } elseif ($script:AutoInstallAfterDownload) {
                # İndirme başarısız - sonraki uygulamaya geç / Download failed - move to next app
                $script:AutoInstallAfterDownload = $false
                if ($script:UpdateQueue -and $script:UpdateQueue.Count -gt 0) {
                    Start-NextUpdateInQueue
                }
            }
        }
    })

    if ($script:dlRunspaces.Count -gt 0) {
        $script:dlTimer.Start()
    } else {
        # Hepsi zaten vardı
        try { $script:dlPool.Close(); $script:dlPool.Dispose() } catch {}
        $btnReset.Content = (T 'BtnReset')
        Hide-Cancel -OpKey 'download'
        $progMain.Value = 100
        Set-Status ("{0}/{1} file(s) ready -> {2}" -f $script:dlSuccess, $script:dlTotal, $script:dlPackagePath)
    }
})

# ── Başarısızları Tekrarla / Retry Failed ─────────────────────────────
if ($btnRetryFailed) {
    $btnRetryFailed.Add_Click({
        # Başarısız öğeleri seç ve yeniden indirmeyi tetikle / Select failed items and trigger re-download
        $failedItems = @($script:Packages | Where-Object { $_.Status -match 'FAILED' })
        if ($failedItems.Count -eq 0) {
            Set-Status (if ($script:Lang -eq 'TR') { 'Tekrarlanacak başarısız öğe yok.' } else { 'No failed items to retry.' })
            return
        }
        # Tüm seçimleri kaldır, sadece başarısızları seç / Deselect all, select only failed
        foreach ($p in $script:Packages) { $p.IsChecked = $false }
        foreach ($f in $failedItems) {
            $f.IsChecked = $true
            Set-StatusBadge $f 'RETRY' '#2A2419' '#FDE68A'
        }
        $btnRetryFailed.Visibility = 'Collapsed'
        # İndirme butonunu tetikle / Trigger download button
        $btnDownload.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    })
}

# ── Sağ tık: Tekrar İndir / Context menu: Retry Download ──────────
if ($ctxRetryDl) {
    $ctxRetryDl.Add_Click({
        $it = Get-SelectedItem
        if (-not $it -or -not $it.Url) { return }
        # Sadece bu öğeyi seç / Select only this item
        foreach ($p in $script:Packages) { $p.IsChecked = $false }
        $it.IsChecked = $true
        Set-StatusBadge $it 'RETRY' '#2A2419' '#FDE68A'
        # İndirme butonunu tetikle / Trigger download button
        $btnDownload.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    })
}

# ─── Kurulum yardımcıları / Installation helpers ───────

# WinRT Dağıtım API'si tek seferlik yükleme bayrağı / WinRT Deployment API one-time initialization flag
$script:DeploymentApiReady = $false

function Initialize-DeploymentApi {
    if ($script:DeploymentApiReady) { return $true }
    try {
        [void][Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]
        [void][Windows.Management.Deployment.AddPackageOptions,Windows.Management.Deployment,ContentType=WindowsRuntime]
        [void][Windows.Management.Deployment.DeploymentResult,Windows.Management.Deployment,ContentType=WindowsRuntime]
        [void][Windows.Foundation.Uri,Windows.Foundation,ContentType=WindowsRuntime]
        $script:DeploymentApiReady = $true
        return $true
    } catch {
        $script:DeploymentApiReady = $false
        return $false
    }
}

# Manifesti okur ve kimlik + bağımlılık listesini döner / Reads manifest and returns identity + dep list
function Get-PackageManifestInfo {
    param([System.IO.FileInfo]$PackageFile)
    $r = @{
        Architecture = 'Unknown'
        MinOSVersion = 'Unknown'
        Dependencies = @()
        Identity     = $null
    }
    if ($PackageFile.Extension -notmatch 'appx|msix|bundle') { return $r }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($PackageFile.FullName)
        $mEntry = $zip.Entries | Where-Object {
            $_.FullName -eq 'AppxManifest.xml' -or
            $_.FullName -eq 'AppxBundleManifest.xml' -or
            $_.FullName -eq 'AppxMetadata/AppxBundleManifest.xml'
        } | Select-Object -First 1
        if ($mEntry) {
            $rdr = New-Object System.IO.StreamReader($mEntry.Open())
            $xml = [xml]$rdr.ReadToEnd(); $rdr.Close()

            $idNode = $xml.SelectSingleNode("//*[local-name()='Identity']")
            if ($idNode) {
                $r.Identity = [PSCustomObject]@{
                    Name      = $idNode.GetAttribute('Name')
                    Publisher = $idNode.GetAttribute('Publisher')
                    Version   = $idNode.GetAttribute('Version')
                    Arch      = $idNode.GetAttribute('ProcessorArchitecture')
                }
                if ($r.Identity.Arch) { $r.Architecture = $r.Identity.Arch }
            }

            $tdf = $xml.SelectSingleNode("//*[local-name()='TargetDeviceFamily']")
            if ($tdf) {
                $minVer = $tdf.GetAttribute('MinVersion')
                if ($minVer) { $r.MinOSVersion = $minVer }
            }

            $depNodes = $xml.SelectNodes("//*[local-name()='PackageDependency']")
            $seen = @{}
            foreach ($dn in $depNodes) {
                $dName = $dn.GetAttribute('Name')
                $dMinV = $dn.GetAttribute('MinVersion')
                if (-not $dName) { continue }
                $key = "$dName|$dMinV"
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $r.Dependencies += [PSCustomObject]@{
                    Name       = $dName
                    MinVersion = $dMinV
                }
            }
        }
        $zip.Dispose()
    } catch {}
    return $r
}

# TrustedInstaller gerekli mi / Needs TrustedInstaller
function Test-PackageNeedsElevation {
    param([string]$FilePath)
    if ($FilePath -notmatch '\.(appx|msix|appxbundle|msixbundle)$') { return $false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)

        $checkManifestXml = {
            param($xml)
            $elevatedCaps = @('localSystemServices','packagedServices','backgroundMediaRecording',
                              'slapiQueryLicenseValue','unvirtualizedResources','modifiableApp')
            $capNodes = $xml.SelectNodes("//*[local-name()='Capability']")
            foreach ($cap in $capNodes) {
                if ($elevatedCaps -contains $cap.GetAttribute('Name')) { return $true }
            }
            $svcNodes = $xml.SelectNodes("//*[local-name()='Service']")
            if ($svcNodes.Count -gt 0) { return $true }
            return $false
        }

        if ($FilePath -match '\.(appxbundle|msixbundle)$') {
            # Bundle: alt paket manifest'ini kontrol et / Bundle: check child package manifest
            $bundleMan = $zip.Entries | Where-Object {
                $_.FullName -eq 'AppxBundleManifest.xml' -or
                $_.FullName -eq 'AppxMetadata/AppxBundleManifest.xml'
            } | Select-Object -First 1
            if ($bundleMan) {
                $rdr = New-Object System.IO.StreamReader($bundleMan.Open())
                $bxml = [xml]$rdr.ReadToEnd(); $rdr.Close()
                $pkgNode = $bxml.SelectNodes("//*[local-name()='Package']") |
                           Where-Object { $_.GetAttribute('Type') -eq 'application' } |
                           Select-Object -First 1
                if ($pkgNode) {
                    $childName = $pkgNode.GetAttribute('FileName')
                    $childEntry = $zip.Entries | Where-Object { $_.Name -eq $childName } | Select-Object -First 1
                    if ($childEntry) {
                        $childStream = $childEntry.Open()
                        $childZip = [System.IO.Compression.ZipArchive]::new($childStream)
                        $mEntry = $childZip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
                        if ($mEntry) {
                            $rdr2 = New-Object System.IO.StreamReader($mEntry.Open())
                            $xml = [xml]$rdr2.ReadToEnd(); $rdr2.Close()
                            $res = & $checkManifestXml $xml
                            $childZip.Dispose(); $childStream.Dispose(); $zip.Dispose()
                            return $res
                        }
                        $childZip.Dispose(); $childStream.Dispose()
                    }
                }
            }
        } else {
            $mEntry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
            if ($mEntry) {
                $rdr = New-Object System.IO.StreamReader($mEntry.Open())
                $xml = [xml]$rdr.ReadToEnd(); $rdr.Close()
                $zip.Dispose()
                return (& $checkManifestXml $xml)
            }
        }
        $zip.Dispose()
    } catch {}
    return $false
}

# WinRT asenkron işlemini bekler, ilerlemeyi akış olarak verir / Waits for WinRT async operation, streams progress
function Wait-DeploymentOperation {
    param($Operation, [string]$PkgName, $Item)
    $lastPct = -1
    while ($Operation.Status -eq 0) {  # Started
        Start-Sleep -Milliseconds 200
        try {
            $prog = $Operation.Progress
            if ($prog -and $prog.percentage) {
                $pct = [int]$prog.percentage
                if ($pct -ne $lastPct) {
                    $lastPct = $pct
                    if ($Item) { Set-StatusBadge $Item ("COM {0}%" -f $pct) '#1E3A5F' '#93C5FD' }
                }
            }
        } catch {}
    }
    switch ($Operation.Status) {
        1 { return $Operation.GetResults() }  # Completed
        2 { throw 'Deployment cancelled' }
        3 {
            $res = $null
            try { $res = $Operation.GetResults() } catch {}
            $errTxt = if ($res -and $res.ErrorText) { $res.ErrorText } else { 'Deployment error' }
            $hr = if ($Operation.ErrorCode) { '0x{0:X8}' -f $Operation.ErrorCode.HResult } else { '' }
            throw ("{0} {1}" -f $errTxt, $hr).Trim()
        }
        default { throw "Unknown deployment status: $($Operation.Status)" }
    }
}

# Strateji 1: WinRT PackageManager COM API / Strategy 1: WinRT PackageManager COM API
function Remove-InstalledForReinstall {
    <#
        Force Reinstall özelliği için yardımcı fonksiyon.
        Pakete ait Yüklenen Sürümü (sürümden bağımsız olarak) kaldırır ki temiz bir
        yeniden yükleme yapılabilsin. Add-AppxPackage 'ForceUpdateFromAnyVersion'
        ile yüksek/düşük sürümleri zorla geçer ama AYNI sürüm zaten yüklüyse
        0x80073D06 / 0x80073CFB döner — gerçek "yeniden yükle" için önce kaldırmak gerekir.

        Yalnızca Identity.Name eşleşen kullanıcı/sistem paketini kaldırır.
        Sistem korumalı / framework paketleri için çağrılmamalıdır.
    #>
    param([string]$PackageName)
    if ([string]::IsNullOrWhiteSpace($PackageName)) { return @{Removed=$false; Reason='No name'} }
    try {
        $pkgs = @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)
        if ($pkgs.Count -eq 0) { return @{Removed=$false; Reason='Not installed'} }
        $removedAny = $false
        $errMsg = ''
        foreach ($p in $pkgs) {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                $removedAny = $true
            } catch {
                # AllUsers fallback (bazı paketler için gerekir)
                try {
                    Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                    $removedAny = $true
                } catch {
                    $errMsg = $_.Exception.Message
                }
            }
        }
        return @{Removed=$removedAny; Reason=$errMsg}
    } catch {
        return @{Removed=$false; Reason=$_.Exception.Message}
    }
}

function Invoke-ComDeployInstall {
    param([string]$PackagePath, [string[]]$DependencyPaths = @(), [bool]$AllUsers = $true, $Item = $null)
    $r = [PSCustomObject]@{ Success=$false; Reason=''; Method='Com' }
    if (-not (Initialize-DeploymentApi)) {
        $r.Reason = 'WinRT Deployment API not available'
        return $r
    }
    try {
        $pm = New-Object Windows.Management.Deployment.PackageManager
        $opts = New-Object Windows.Management.Deployment.AddPackageOptions
        try { $opts.DeferRegistrationWhenPackagesAreInUse = $true } catch {}
        try { $opts.ForceUpdateFromAnyVersion = $true } catch {}
        try { $opts.ForceAppShutdown = $true } catch {}
        foreach ($dp in $DependencyPaths) {
            try {
                $dpUri = New-Object Windows.Foundation.Uri $dp
                $opts.DependencyPackageUris.Add($dpUri)
            } catch {}
        }
        $pkgUri = New-Object Windows.Foundation.Uri $PackagePath
        $op = $pm.AddPackageByUriAsync($pkgUri, $opts)
        $pkgName = [System.IO.Path]::GetFileName($PackagePath)
        [void](Wait-DeploymentOperation -Operation $op -PkgName $pkgName -Item $Item)
        $r.Success = $true
        $r.Reason  = 'Installed via COM API'
        return $r
    } catch {
        $r.Reason = $_.Exception.Message
        return $r
    }
}

# ── APPX Hata Kodu Tanımları / APPX Error Code Definitions ────────────────────
$script:AppxErrors = @{
    EN = @{
        '80070002'='File or path is not found'
        '8007000B'='Package is not correctly formatted'
        '80070057'='One or more arguments are not valid'
        '80070005'='Access denied - system protected'
        '80073CF0'='Package could not be opened'
        '80073CF1'='Package not found'
        '80073CF2'='Package data is not valid'
        '80073CF3'='Package failed dependency or conflict validation'
        '80073CF4'='Not enough disk space'
        '80073CF5'='Network failure'
        '80073CF6'='Cannot be registered'
        '80073CF7'='Cannot be unregistered'
        '80073CF8'='Cancelled by user'
        '80073CF9'='Install failed'
        '80073CFA'='Removal failed'
        '80073CFB'='Already exists (reinstall blocked)'
        '80073CFC'='Cannot start - try reinstalling'
        '80073CFD'='Prerequisite not satisfied'
        '80073CFE'='Repository corrupted'
        '80073CFF'='Developer license or sideloading required'
        '80073D00'='Currently updating'
        '80073D01'='Blocked by policy'
        '80073D02'='Resources in use'
        '80073D06'='Cannot downgrade - higher version installed'
        '80073D0A'='Firewall not running'
        '80073D10'='Wrong processor architecture'
        '80073D11'='Sideload limit exceeded'
        '80080200'='Packaging API internal error'
        '80080203'='Missing required file'
        '80080204'='AppxManifest.xml is not valid (or OS too old)'
        '80080205'='AppxBlockMap.xml is not valid'
        '80080206'='Package contents corrupted'
        '800B0100'='No signature present'
        '800B0109'='Untrusted root certificate'
        '800B010A'='Certificate chain error'
    }
    TR = @{
        '80070002'='Dosya veya yol bulunamadı'
        '8007000B'='Paket doğru biçimlendirilmemiş'
        '80070057'='Bir veya daha fazla argüman geçersiz'
        '80070005'='Erişim reddedildi - sistem korumalı'
        '80073CF0'='Paket açılamadı'
        '80073CF1'='Paket bulunamadı'
        '80073CF2'='Paket verisi geçersiz'
        '80073CF3'='Paket bağımlılık veya çakışma doğrulamasından geçemedi'
        '80073CF4'='Yeterli disk alanı yok'
        '80073CF5'='Ağ hatası'
        '80073CF6'='Kaydedilemiyor'
        '80073CF7'='Kaydı silinemiyor'
        '80073CF8'='Kullanıcı tarafından iptal edildi'
        '80073CF9'='Kurulum başarısız'
        '80073CFA'='Kaldırma başarısız'
        '80073CFB'='Zaten mevcut (yeniden yükleme engellendi)'
        '80073CFC'='Başlatılamıyor - yeniden yüklemeyi deneyin'
        '80073CFD'='Önkoşul karşılanmadı'
        '80073CFE'='Depo bozulmuş'
        '80073CFF'='Geliştirici lisansı veya dışarıdan yükleme (sideloading) gerekli'
        '80073D00'='Şu anda güncelleniyor'
        '80073D01'='İlke tarafından engellendi'
        '80073D02'='Kaynaklar kullanımda'
        '80073D06'='Sürüm düşürülemiyor - daha yüksek bir sürüm yüklü'
        '80073D0A'='Güvenlik duvarı çalışmıyor'
        '80073D10'='Yanlış işlemci mimarisi'
        '80073D11'='Dışarıdan yükleme sınırı aşıldı'
        '80080200'='Paketleme API''si dahili hatası'
        '80080203'='Gerekli dosya eksik'
        '80080204'='AppxManifest.xml geçersiz (ya da işletim sistemi çok eski)'
        '80080205'='AppxBlockMap.xml geçersiz'
        '80080206'='Paket içeriği bozulmuş'
        '800B0100'='İmza mevcut değil'
        '800B0109'='Güvenilmeyen kök sertifikası'
        '800B010A'='Sertifika zinciri hatası'
    }
}

# Hata mesajı üret / Produce error message
function Resolve-AppxInstallError {
    param([string]$Msg, [string]$PackagePath = '')
    # Gerçek mesajı dön / Return real message
    if ($PackagePath -and $PackagePath -match '\.(exe|msi)$') {
        $prefix = if ($script:Lang -eq 'TR') { 'Yükleyici Hatası' } else { 'Installer Error' }
        $shortMsg = if ($Msg.Length -gt 120) { $Msg.Substring(0, 120) + '...' } else { $Msg }
        return "${prefix}: $shortMsg"
    }

    # Hata kodunu çıkar / Extract error code
    $code = ''
    if ($Msg -match '(?:HRESULT|0x)[\s:]*(?:0x)?([0-9A-Fa-f]{8})') {
        $code = $matches[1].ToUpper()
    }

    $failPrefix = if ($script:Lang -eq 'TR') { 'Kurulum başarısız' } else { 'Install failed' }

    if ($code) {
        $table = $script:AppxErrors[$script:Lang]
        if (-not $table) { $table = $script:AppxErrors['EN'] }
        if ($table.ContainsKey($code)) {
            return "$($table[$code]) (0x$code)"
        }
        return "${failPrefix}: 0x$code"
    }

    # Kod yok - mesajı kısalt / No code - shorten message
    $shortMsg = if ($Msg.Length -gt 100) { $Msg.Substring(0, 100) + '...' } else { $Msg }
    return "${failPrefix}: $shortMsg"
}

# ─── Uygulamaları Yükle tıklama işleyicisi / Install Apps click handler ─────────────────────────────────────
$btnInstall.Add_Click({
    # Yönetici iznini kontrol et / Check admin privileges
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $warnRes = Show-CustomMessageBox -Title (T 'AdminTitle') -Icon Info -Buttons YesNo `
            -Message (T 'AdminMsgInstall') `
            -Details (T 'AdminContinue')
        if ($warnRes -ne 'Yes') { return }
    }

    # ─── Yüklenecek dosyaları belirle / Determine files to install ──────────────────────────────
    $installRoot = $null
    $allFiles = @()

    # Sadece seçili dosyaları kullan / Use only selected files
    $selectedLocalFiles = @($script:Packages | Where-Object { $_.IsChecked -and $_.Url -and (Test-Path -LiteralPath $_.Url -PathType Leaf -ErrorAction SilentlyContinue) })

    if ($selectedLocalFiles.Count -gt 0) {
        foreach ($pkg in $selectedLocalFiles) {
            $allFiles += Get-Item -LiteralPath $pkg.Url -ErrorAction SilentlyContinue
        }
        if ($allFiles.Count -gt 0) {
            $installRoot = [System.IO.Path]::GetDirectoryName($allFiles[0].FullName)
        }
    } else {
        # İndirme klasörünü tara / Scan download folder
        if (-not [string]::IsNullOrWhiteSpace($script:lastPackagePath) -and (Test-Path $script:lastPackagePath)) {
            $installRoot = $script:lastPackagePath
        }

        # 2. Kullanıcıya sor / 2. Ask user
        if (-not $installRoot) {
            $fd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fd.Description = 'Select folder containing .appx / .msix / .exe / .msi packages to install'
            $fd.ShowNewFolderButton = $false
            $defaultRoot = if (-not [string]::IsNullOrWhiteSpace($script:DownloadFolder) -and (Test-Path $script:DownloadFolder)) {
                $script:DownloadFolder
            } else {
                Join-Path ([Environment]::GetFolderPath('Desktop')) 'StoreDownload'
            }
            if (Test-Path $defaultRoot) { $fd.SelectedPath = $defaultRoot }
            if ($fd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $installRoot = $fd.SelectedPath
        }

        if (-not (Test-Path $installRoot)) {
            Set-Status "Install folder not found: $installRoot"
            return
        }

        Set-Status "Scanning: $installRoot"

        # ─── Paket dosyalarını topla / Collect package files ────────────────────────────────────
        $allFiles = @(Get-ChildItem -Path $installRoot -Include *.appx,*.appxbundle,*.msix,*.msixbundle,*.exe,*.msi -Recurse -ErrorAction SilentlyContinue)
    }
    if ($allFiles.Count -eq 0) {
        Show-CustomMessageBox -Title (T 'NoPackagesTitle') -Icon Info -Buttons OK `
            -Message (T 'NoPackagesMsg') `
            -Details ((T 'NoPackagesDetails') -f $installRoot) | Out-Null
        Set-Status "No packages found in $installRoot"
        return
    }

    # ─── Seçilmeyen dosyaları da listeye ekle / Add unselected files to list ──
    foreach ($fi in $allFiles) {
        $exists = $script:Packages | Where-Object { $_.FileName -eq $fi.Name } | Select-Object -First 1
        if (-not $exists) {
            $item = New-Object PackageItem
            $item.FileName  = $fi.Name
            # Dosya adından sürüm bilgisini çıkar / Extract version info from filename
            $version = $null
            $parts = $fi.BaseName -split '_'
            if ($parts.Count -ge 2) {
                $vStr = $parts[1]
                if ($vStr -match '^\d+\.\d+\.\d+\.\d+$') { $version = $vStr }
            }
            $item.Version   = if ($version) { $version } else { '-' }
            $item.SizeBytes = $fi.Length
            $item.SizeText  = Format-Size $fi.Length
            $item.Url       = $fi.FullName
            $item.RowFg     = Get-PrimaryFgBrush
            if (Test-IsDependency $fi.Name) {
                Set-StatusBadge $item 'DEPENDENCY' '#1E3A5F' '#93C5FD'
            } else {
                Set-StatusBadge $item 'MAIN APP' '#14532D' '#86EFAC'
            }
            $script:Packages.Add($item)
        }
    }



    # Dosyaları sınıflandır / Classify files
    $frameworkPattern = 'Microsoft\.(NET\.Native|VCLibs|UI\.Xaml|WinJS|WindowsAppRuntime|WinAppRuntime)'
    $bundles    = @($allFiles | Where-Object { $_.Name -match '\.(appxbundle|msixbundle)$' })
    $singles    = @($allFiles | Where-Object { $_.Name -match '\.(appx|msix)$' -and $_.Name -notmatch 'BlockMap' })
    $installers = @($allFiles | Where-Object { $_.Name -match '\.(exe|msi)$' })

    $frameworkFiles  = @()
    $standaloneFiles = @()
    foreach ($sf in $singles) {
        $baseName = ($sf.Name -split '_')[0]
        if ($baseName -match $frameworkPattern) { $frameworkFiles += $sf }
        else                                    { $standaloneFiles += $sf }
    }

    # Kurulum kuyruğu / Installation queue
    # Çerçeveleri atla / Skip frameworks
    $installQueue = [System.Collections.ArrayList]@()
    foreach ($b in $bundles)         { [void]$installQueue.Add($b) }
    foreach ($s in $standaloneFiles) { [void]$installQueue.Add($s) }
    foreach ($i in $installers)      { [void]$installQueue.Add($i) }

    # Yalnızca çerçeveleri kur / Install only frameworks
    if ($installQueue.Count -eq 0 -and $frameworkFiles.Count -gt 0) {
        foreach ($ff in ($frameworkFiles | Sort-Object Length -Descending)) {
            [void]$installQueue.Add($ff)
        }
        $frameworkFiles = @()
    }

    $total      = $installQueue.Count
    $current    = 0
    $successCnt = 0
    $failCnt    = 0
    $failedDetails = New-Object System.Collections.Generic.List[string]
    $sysProtected = 'Microsoft\.Copilot|Microsoft\.549981C3F5F10|Microsoft\.Windows\.Cortana'

    $progMain.Value = 0
    $script:cancelInstall = $false
    Show-Cancel -OpKey 'install'

    foreach ($pkgFile in $installQueue) {
        if ($script:cancelInstall) { break }
        $current++
        $pct = [Math]::Round(($current / [Math]::Max(1,$total)) * 100)
        $progMain.Value = $pct
        Set-Status ("$(T 'BtnInstall') {0}/{1}: {2}" -f $current, $total, $pkgFile.Name)

        # İlgili listview öğesini bul / Find related listview item
        $item = $script:Packages | Where-Object { $_.FileName -eq $pkgFile.Name } | Select-Object -First 1

        # Arayüzü pompala - durum değişimi anında görünsün / Pump UI - show status change instantly
        Invoke-DispatcherPump

        # ─── Sistem korumalı paketleri atla / Skip system protected packages ──────────────────────────
        if ($pkgFile.Name -match $sysProtected) {
            if ($item) { Set-StatusBadge $item 'SKIPPED (system)' '#27272A' '#A1A1AA' }
            continue
        }

        # ─── OS derleme uyumluluk kontrolü / OS build compatibility check ─────────────────────────────
        $manifestInfo = Get-PackageManifestInfo -PackageFile $pkgFile
        $currentBuild = [System.Environment]::OSVersion.Version.Build
        if ($manifestInfo.MinOSVersion -ne 'Unknown') {
            try {
                $requiredBuild = [int](($manifestInfo.MinOSVersion -split '\.')[2])
                if ($requiredBuild -gt $currentBuild) {
                    $failCnt++
                    $reason = if ($script:Lang -eq 'TR') {
                        "Build $requiredBuild gerekli (mevcut: $currentBuild)"
                    } else {
                        "Requires build $requiredBuild (current: $currentBuild)"
                    }
                    if ($item) { Set-StatusBadge $item "INCOMPATIBLE" '#450A0A' '#FCA5A5' }
                    $failedDetails.Add("• $($pkgFile.Name)`n  → $reason")
                    Add-HistoryEntry $pkgFile.Name (Format-Size $pkgFile.Length) 'Incompatible' '#450A0A' '#FCA5A5'
                    continue
                }
            } catch {}
        }

        # ─── Manifest bağımlılıklarını dosyalara eşle / Map manifest deps to files ──────────────────────
        $matchedDepPaths = @()
        $missingDeps     = @()

        if ($manifestInfo.Dependencies.Count -gt 0) {
            foreach ($dep in $manifestInfo.Dependencies) {
                $minVer = [Version]'0.0.0.0'
                if ($dep.MinVersion) { try { $minVer = [Version]$dep.MinVersion } catch {} }

                # Klasördeki tekli paketlerde ara / Search in single packages in folder
                $candidates = @($singles | Where-Object {
                    $bn = ($_.Name -split '_')[0]
                    $bn -match [regex]::Escape($dep.Name)
                })

                if ($candidates.Count -gt 0) {
                    $best = $null; $bestVer = [Version]'0.0.0.0'
                    foreach ($c in $candidates) {
                        $parts = $c.Name -split '_'
                        if ($parts.Count -ge 2) {
                            try {
                                $v = [Version]$parts[1]
                                if ($v -ge $minVer -and $v -gt $bestVer) { $best = $c; $bestVer = $v }
                            } catch { if (-not $best) { $best = $c } }
                        } else {
                            if (-not $best) { $best = $c }
                        }
                    }
                    if ($best) { $matchedDepPaths += $best.FullName }
                    else      { $missingDeps += "$($dep.Name) (>= $minVer)" }
                } else {
                    # Sistemde zaten kurulu mu? / Already installed on system?
                    $installedPkg = Get-AppxPackage -Name "*$($dep.Name)*" -ErrorAction SilentlyContinue
                    $alreadyInstalled = $false
                    foreach ($p in $installedPkg) {
                        try { if ([Version]$p.Version -ge $minVer) { $alreadyInstalled = $true; break } } catch {}
                    }
                    if (-not $alreadyInstalled) { $missingDeps += "$($dep.Name) (>= $minVer)" }
                }
            }

            # Bağımlılık uyarısı / Dependency warning
            if ($missingDeps.Count -gt 0) {
                $depsList = ($missingDeps | ForEach-Object { "  - $_" }) -join "`n"
                $res = Show-CustomMessageBox -Title (T 'MissingDepsTitle') -Icon Warning -Buttons YesNo `
                        -Message ((T 'MissingDepsMsg') -f $pkgFile.Name) `
                        -Details $depsList
                if ($res -ne 'Yes') {
                    if ($item) { Set-StatusBadge $item 'CANCELLED (deps)' '#27272A' '#A1A1AA' }
                    $failCnt++
                    continue
                }
            }

            # Bağımlılık dosyalarını arayüzde işaretle / Mark dep files in UI
            foreach ($dp in $matchedDepPaths) {
                $dpName = [System.IO.Path]::GetFileName($dp)
                $dItem = $script:Packages | Where-Object { $_.FileName -eq $dpName } | Select-Object -First 1
                if ($dItem) { Set-StatusBadge $dItem 'DEP (auto)' '#1E3A5F' '#93C5FD' }
            }
        }

        # ─── Kurulum stratejileri / Installation strategies ────────────────────────────────────
        $installed = $false
        $reason    = ''
        $ext       = $pkgFile.Extension.ToLowerInvariant()

        if ($ext -eq '.exe' -or $ext -eq '.msi') {
            # Klasik yükleyici / Classic installer
            if ($item) { Set-StatusBadge $item 'INSTALLING (exe/msi)' '#2A2419' '#FDE68A' }

            Invoke-DispatcherPump
            try {
                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                if ($ext -eq '.msi') {
                    $pInfo.FileName = 'msiexec.exe'
                    $pInfo.Arguments = "/i `"$($pkgFile.FullName)`" /qn /norestart"
                } else {
                    $pInfo.FileName = $pkgFile.FullName
                    $pInfo.Arguments = '/silent /install'
                }
                $pInfo.Verb = 'runas'
                $pInfo.WindowStyle = 'Hidden'
                $proc = [System.Diagnostics.Process]::Start($pInfo)
                $proc.WaitForExit()
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                    $installed = $true
                    $reason = "Installer Success (exit $($proc.ExitCode))"
                } else {
                    $reason = "Installer exit code $($proc.ExitCode)"
                }
            } catch {
                $reason = "Launch failed: $($_.Exception.Message)"
            }
        } else {
            # MSIX/APPX/BUNDLE - strateji zinciri / strategy chain
            $needsElev = Test-PackageNeedsElevation -FilePath $pkgFile.FullName

            # ── Force Reinstall: ayar açıksa önce mevcut sürümü kaldır ─────────────
            # / Force Reinstall: if enabled, remove the existing version first so
            #   Add-AppxPackage doesn't short-circuit with PackageAlreadyExists / 0x80073D06.
            if ($script:AppSettings.ForceReinstall -and
                $manifestInfo.Identity -and
                $manifestInfo.Identity.Name -and
                ($pkgFile.Name -notmatch $frameworkPattern)) {
                if ($item) { Set-StatusBadge $item 'REMOVING (force)' '#2A2419' '#FDE68A' }
                Invoke-DispatcherPump
                $rmRes = Remove-InstalledForReinstall -PackageName $manifestInfo.Identity.Name
                Set-Status ("Force reinstall: {0} (removed={1})" -f `
                        $manifestInfo.Identity.Name, $rmRes.Removed)
            }

            # ── Strateji 1: COM API / Strategy 1: COM API ──
            if (-not $needsElev) {
                if ($item) { Set-StatusBadge $item 'INSTALLING (COM)' '#2A2419' '#FDE68A' }

                Invoke-DispatcherPump
                $comRes = Invoke-ComDeployInstall -PackagePath $pkgFile.FullName `
                                                  -DependencyPaths $matchedDepPaths `
                                                  -AllUsers $true -Item $item
                if ($comRes.Success) {
                    $installed = $true
                    $reason = $comRes.Reason
                } else {
                    $reason = $comRes.Reason
                }
            }

            # ── Strateji 2: Provisioning / Strategy 2: Provisioning ──
            if (-not $installed -and -not $needsElev) {
                if ($item) { Set-StatusBadge $item 'INSTALLING (Provision)' '#2A2419' '#FDE68A' }

                Invoke-DispatcherPump
                try {
                    $params = @{ Online=$true; PackagePath=$pkgFile.FullName; SkipLicense=$true; ErrorAction='Stop' }
                    if ($matchedDepPaths.Count -gt 0) { $params['DependencyPackagePath'] = [string[]]$matchedDepPaths }
                    Add-AppxProvisionedPackage @params | Out-Null
                    $installed = $true
                    $reason = 'Installed via Add-AppxProvisionedPackage (all users)'
                } catch {
                    $reason = "Provision: $($_.Exception.Message)"
                }
            }

            # ── Strateji 3: AllUsers / Strategy 3: AllUsers ──
            if (-not $installed) {
                if ($item) { Set-StatusBadge $item 'INSTALLING (AllUsers)' '#2A2419' '#FDE68A' }

                Invoke-DispatcherPump
                try {
                    $params = @{
                        Path                       = $pkgFile.FullName
                        ErrorAction                = 'Stop'
                        ForceApplicationShutdown   = $true
                        ForceUpdateFromAnyVersion  = $true
                    }
                    if ($matchedDepPaths.Count -gt 0) { $params['DependencyPath'] = [string[]]$matchedDepPaths }
                    $cmdInfo = Get-Command Add-AppxPackage -ErrorAction SilentlyContinue
                    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('AllUsers')) { $params['AllUsers'] = $true }
                    Add-AppxPackage @params
                    $installed = $true
                    $reason = 'Installed via Add-AppxPackage (all users)'
                } catch {
                    $reason = "AllUsers: $($_.Exception.Message)"
                }
            }

            # ── Strateji 4: Mevcut Kullanıcı / Strategy 4: Current User ──
            if (-not $installed) {
                if ($item) { Set-StatusBadge $item 'INSTALLING (User)' '#2A2419' '#FDE68A' }

                Invoke-DispatcherPump
                try {
                    $params = @{
                        Path                       = $pkgFile.FullName
                        ErrorAction                = 'Stop'
                        ForceApplicationShutdown   = $true
                        ForceUpdateFromAnyVersion  = $true
                    }
                    if ($matchedDepPaths.Count -gt 0) { $params['DependencyPath'] = [string[]]$matchedDepPaths }
                    Add-AppxPackage @params
                    $installed = $true
                    $reason = 'Installed for current user'
                } catch {
                    $reason = "User fallback: $($_.Exception.Message)"
                }
            }
        }

        # ─── Arayüzü güncelle / Update UI ─────────────────────────────────────────────
        if ($installed) {
            $successCnt++
            if ($item) { Set-StatusBadge $item 'INSTALLED' '#14532D' '#86EFAC' }
            # Bağımlılık dosyalarını da "yüklendi" işaretle / Mark dep files as "installed" too
            foreach ($dp in $matchedDepPaths) {
                $dpName = [System.IO.Path]::GetFileName($dp)
                $dItem = $script:Packages | Where-Object { $_.FileName -eq $dpName } | Select-Object -First 1
                if ($dItem) { Set-StatusBadge $dItem 'DEP OK' '#14532D' '#86EFAC' }
            }
            Add-HistoryEntry $pkgFile.Name (Format-Size $pkgFile.Length) 'Installed' '#14532D' '#86EFAC'
            
            # ── Kurulumdan sonra sil / Delete after install ──────────────
            if ($script:AppSettings.DeleteAfterInstall) {
                try {
                    Remove-Item -LiteralPath $pkgFile.FullName -Force -ErrorAction SilentlyContinue
                    Set-Status ("Deleted package after install: $($pkgFile.Name)")
                } catch {}
            }
        } else {
            $failCnt++
            $resolvedReason = Resolve-AppxInstallError -Msg $reason -PackagePath $pkgFile.FullName
            if ($item) {
                Set-StatusBadge $item 'FAILED' '#450A0A' '#FCA5A5'
                # Detayı hata listesine ekle / Add detail to error list
            }
            # Listeye paket adı + yerelleştirilmiş hata mesajı kaydet / Save package name + localized error message to list
            $failedDetails.Add("• $($pkgFile.Name)`n  → $resolvedReason")
            Add-HistoryEntry $pkgFile.Name (Format-Size $pkgFile.Length) 'Failed' '#450A0A' '#FCA5A5'
        }
    }

    $progMain.Value = 100
    Set-Status (((T 'InstallResultTitle') + ": {0}/{1}") -f $successCnt, ($successCnt + $failCnt))
    Hide-Cancel -OpKey 'install'

    # ── Sonraki güncellemeyi başlat / Start next update ──
    $inUpdateQueue = ($script:UpdateQueue -and $script:UpdateQueue.Count -gt 0) -or `
                     ($script:UpdateQueueTotal -gt 0 -and $script:UpdateQueueDone -lt $script:UpdateQueueTotal)
    if ($inUpdateQueue) {
        # Bu uygulama için kurulum başarılıysa sayacı artır / Increment success counter for this app
        if ($successCnt -gt 0) {
            $script:UpdateQueueSuccess++
        }

        if ($script:UpdateQueue -and $script:UpdateQueue.Count -gt 0) {
            $window.Dispatcher.BeginInvoke([Action]{ Start-NextUpdateInQueue },
                [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
        } else {
            # Son uygulama da bitti / Last app finished too
            Start-NextUpdateInQueue
        }
        return
    }

    # Özet diyaloğunu göster / Show summary dialog
    if ($failCnt -gt 0) {
        # Hata detaylarını hazırla / Prepare error details
        $detailsText = if ($failedDetails.Count -gt 0) {
            ($failedDetails -join "`n`n")
        } else {
            ((T 'InstallResultDetails') -f $successCnt, $failCnt)
        }
        Show-CustomMessageBox -Title (T 'InstallResultTitle') -Icon Warning -Buttons OK `
            -Message ((T 'InstallResultIssues') + "`n" + ((T 'InstallResultDetails') -f $successCnt, $failCnt)) `
            -Details $detailsText | Out-Null
    } elseif ($successCnt -gt 0) {
        Show-CustomMessageBox -Title (T 'InstallResultTitle') -Icon Success -Buttons OK `
            -Message ((T 'InstallResultSuccess') -f $successCnt) | Out-Null
    }
})

$btnOpenFolder.Add_Click({
    if (Test-Path $script:DownloadFolder) { Start-Process explorer.exe $script:DownloadFolder }
})

# ── Başlat / Start ─────────────────────────────────────────────────
$script:CurrentTheme = $script:AppSettings.Theme
Set-Language
Set-AppTheme -ThemeName $script:AppSettings.Theme
Update-ActionButtonsState
Set-Status ($script:Strings[$script:Lang].StatusReady)


if ($lblDlFolder)      { $lblDlFolder.Text = $script:DownloadFolder }
if ($cmbSettingsLang)  { $cmbSettingsLang.SelectedIndex = if ($script:Lang -eq 'EN') { 0 } else { 1 } }

# ── Açılışta tüm ComboBox'ları ayarlardan yükle ─────────────────────────────
# At startup load ALL comboboxes (Fetch + Installed + Settings) from saved settings.
# Sync flag'leri kayıt döngüsünü engeller / Sync flags prevent save-loop during init
Write-SettingsLog "Açılış: Combo'lar yükleniyor — DefaultArch='$($script:AppSettings.DefaultArch)', DefaultRing='$($script:AppSettings.DefaultRing)'"
$script:SyncingRing = $true
$script:SyncingArch = $true
try {
    # Mimari (Arch) — Fetch + Settings sayfaları
    $archIdx = @('x64','x86','ARM64','ARM').IndexOf($script:AppSettings.DefaultArch)
    if ($archIdx -ge 0) {
        if ($cmbArch)         { $cmbArch.SelectedIndex         = $archIdx }
        if ($cmbSettingsArch) { $cmbSettingsArch.SelectedIndex = $archIdx }
        Write-SettingsLog "  Arch combo'ları index=$archIdx olarak ayarlandı"
    } else {
        Write-SettingsLog "  Arch index bulunamadı! Değer: '$($script:AppSettings.DefaultArch)'"
    }

    # Kanal (Ring) — Fetch + Installed + Settings sayfaları
    $ringIdx = @('Retail','Preview','WIS','WIF','Slow','Fast').IndexOf($script:AppSettings.DefaultRing)
    if ($ringIdx -ge 0) {
        if ($cmbRing)          { $cmbRing.SelectedIndex          = $ringIdx }
        if ($cmbInstalledRing) { $cmbInstalledRing.SelectedIndex = $ringIdx }
        if ($cmbSettingsRing)  { $cmbSettingsRing.SelectedIndex  = $ringIdx }
        Write-SettingsLog "  Ring combo'ları index=$ringIdx olarak ayarlandı"
    } else {
        Write-SettingsLog "  Ring index bulunamadı! Değer: '$($script:AppSettings.DefaultRing)'"
    }

    # Tema (Theme) — Settings sayfası
    if ($cmbSettingsTheme) {
        $cmbSettingsTheme.SelectedIndex = switch ($script:CurrentTheme) {
            'Dark'   { 0 }
            'Light'  { 1 }
            'iTunes' { 2 }
            'Intel'  { 3 }
            default  { 0 }
        }
    }
} finally {
    $script:SyncingRing = $false
    $script:SyncingArch = $false
}

if ($chkForceReinstall) {
    $chkForceReinstall.IsChecked = [bool]$script:AppSettings.ForceReinstall
}
if ($chkDeleteAfterInstall) {
    $chkDeleteAfterInstall.IsChecked = [bool]$script:AppSettings.DeleteAfterInstall
}

# Background overlay — kayıtlı değer uygula / Apply saved overlay state
if ($script:AppSettings.BackgroundOverlay) {
    Set-BackgroundOverlay -OverlayType $script:AppSettings.BackgroundOverlay
}

# Kapanışta kaydet / Save on close
$window.Add_Closing({
    Save-AppSettings
})

# Mutex serbest bırak / Release mutex on close
$window.Add_Closed({
    try {
        if ($script:SingleInstanceMutex) {
            $script:SingleInstanceMutex.ReleaseMutex()
            $script:SingleInstanceMutex.Dispose()
            $script:SingleInstanceMutex = $null
        }
    } catch {}
})

# ── Komut satırı parametrelerini uygula / Apply command-line parameters ──────
if ($Fetch -or $Ring -or $Arch -or $Download -or $Install -or $Update -or $List) {

    # Ring ayarla
    if ($Ring) {
        $ringMap = @{
            'Retail'='Retail'; 'RP'='Preview'; 'Preview'='Preview'
            'WIS'='WIS'; 'WIF'='WIF'; 'Slow'='Slow'; 'Fast'='Fast'
        }
        $ringLabel = if ($ringMap.ContainsKey($Ring)) { $ringMap[$Ring] } else { 'Retail' }
        if ($cmbRing) {
            $item = $cmbRing.Items | Where-Object { $_.Content -eq $ringLabel } | Select-Object -First 1
            if ($item) { $cmbRing.SelectedItem = $item }
        }
        if ($cmbInstalledRing) {
            $item = $cmbInstalledRing.Items | Where-Object { $_.Content -eq $ringLabel } | Select-Object -First 1
            if ($item) { $cmbInstalledRing.SelectedItem = $item }
        }
    }

    # Arch ayarla
    if ($Arch -and $cmbArch) {
        $item = $cmbArch.Items | Where-Object { $_.Content -eq $Arch } | Select-Object -First 1
        if ($item) { $cmbArch.SelectedItem = $item }
    }

    # -List: Installed Apps sekmesine geç
    if ($List) {
        $NavList.SelectedIndex = 1   # Installed Apps
    }

    # -Update: Installed Apps sekmesine geç ve güncelleme denetimini başlat
    if ($Update) {
        $NavList.SelectedIndex = 1
        # Pencere yüklendikten sonra rescan tetikle
        $window.Add_ContentRendered({
            Start-Sleep -Milliseconds 500
            if ($btnRescan) { $btnRescan.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
        })
    }

    # -Fetch: Fetch sekmesine geç, PFN/URL yaz ve getir
    if ($Fetch) {
        $NavList.SelectedIndex = 0   # Fetch sekmesi
        $cmbPackage.Text = $Fetch
        $txtUrl.Text     = ''

        # Otomatik indirme/kurulum bayrakları
        if ($Install) {
            $script:AutoDownloadAfterFetch  = $true
            $script:AutoInstallAfterDownload = $true
        } elseif ($Download) {
            $script:AutoDownloadAfterFetch  = $true
            $script:AutoInstallAfterDownload = $false
        }

        # Pencere yüklendikten sonra Fetch tetikle
        $window.Add_ContentRendered({
            Start-Sleep -Milliseconds 300
            if ($btnFetch.IsEnabled) {
                $btnFetch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
        })
    }
}

# Pencereyi göster / Show window
# ContentRendered: Açılış tamamlandıktan SONRA event handler'larını bağla
# After all combos are populated and window is rendered, attach sync handlers.
# This prevents any startup-time SelectionChanged from triggering Save-AppSettings.
$window.Add_ContentRendered({
    Write-SettingsLog "ContentRendered: Sync handler'ları bağlanıyor..."

    # Ring (Kanal) ComboBox'ları — Fetch / Installed / Settings sayfaları
    if ($cmbRing) {
        $cmbRing.Add_SelectionChanged({
            if ($script:InitInProgress) { return }
            $s = Get-ComboContentString $cmbRing.SelectedItem
            if ($s) { Sync-RingSelection -RingLabel $s }
        })
    }
    if ($cmbInstalledRing) {
        $cmbInstalledRing.Add_SelectionChanged({
            if ($script:InitInProgress) { return }
            $s = Get-ComboContentString $cmbInstalledRing.SelectedItem
            if ($s) { Sync-RingSelection -RingLabel $s }
        })
    }
    if ($cmbSettingsRing) {
        $cmbSettingsRing.Add_SelectionChanged({
            if ($script:InitInProgress) { return }
            $s = Get-ComboContentString $cmbSettingsRing.SelectedItem
            if ($s) { Sync-RingSelection -RingLabel $s }
        })
    }

    # Arka Plan Overlay ComboBox'ı / Background Overlay ComboBox (Instant Preview)
    if ($cmbSettingsOverlay) {
        $cmbSettingsOverlay.Add_SelectionChanged({
            if ($script:InitInProgress) { return }
            $s = Get-ComboContentString $cmbSettingsOverlay.SelectedItem
            if ($s) {
                $script:AppSettings.BackgroundOverlay = $s
                Set-BackgroundOverlay -OverlayType $s
                Save-AppSettings
            }
        })
    }

    # Tema ComboBox'ı / Theme ComboBox (Instant Preview)
    if ($cmbSettingsTheme) {
        $cmbSettingsTheme.Add_SelectionChanged({
            if ($script:InitInProgress) { return }
            $themeName = switch ($cmbSettingsTheme.SelectedIndex) {
                0 { 'Dark' }
                1 { 'Light' }
                2 { 'iTunes' }
                3 { 'Intel' }
                4 { 'Dracula' }
                5 { 'Nord' }
                6 { 'Solarized Dark' }
                7 { 'Solarized Light' }
                8 { 'Monokai' }
                9 { 'Synthwave' }
                10 { 'Cyberpunk' }
                11 { 'Gruvbox' }
                12 { 'Tokyo Night' }
                13 { 'Catppuccin' }
                14 { 'GitHub Dark' }
                default { 'Dark' }
            }
            Set-AppTheme -ThemeName $themeName
            # Anında uygula ve kaydet
            $script:CurrentTheme = $themeName
            Save-AppSettings
        })
    }

    # Arch (Mimari) ComboBox'ları — Fetch / Settings sayfaları
    if ($cmbArch) {
        $cmbArch.Add_SelectionChanged({
            if ($script:InitInProgress) { return }
            $s = Get-ComboContentString $cmbArch.SelectedItem
            if ($s) { Sync-ArchSelection -ArchLabel $s }
        })
    }
    if ($cmbSettingsArch) {
        $cmbSettingsArch.Add_SelectionChanged({
            if ($script:InitInProgress) { return }
            $s = Get-ComboContentString $cmbSettingsArch.SelectedItem
            if ($s) { Sync-ArchSelection -ArchLabel $s }
        })
    }

    # En son flag'i kaldır — kullanıcı eylemleri artık kaydedilebilir
    $script:InitInProgress = $false
    Write-SettingsLog "ContentRendered: InitInProgress=false — Save-AppSettings artık aktif"
})

# ═══════════════════════════════════════════════════════════════════════════════
# WINGET SEKMESİ / WINGET TAB (UniGetUI-style with batch operations)
# ═══════════════════════════════════════════════════════════════════════════════
$script:WingetExe = $null
$script:WingetReady = $false
$script:WingetPackages = New-Object 'System.Collections.ObjectModel.ObservableCollection[WingetItem]'
$script:WingetAllPackages = @()  # Filtreleme için tam liste

function Get-WingetPath {
    $wp = Get-Command winget -ErrorAction SilentlyContinue
    if ($wp) { return $wp.Source }
    $aiPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $aiPath) { return $aiPath }
    $wpkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
    if ($wpkg) {
        $loc = Join-Path $wpkg.InstallLocation 'winget.exe'
        if (Test-Path $loc) { return $loc }
    }
    return $null
}

function Test-WingetAvailable {
    if (-not $script:WingetExe) { $script:WingetExe = Get-WingetPath }
    if (-not $script:WingetExe) { return $false }
    if (-not (Test-Path $script:WingetExe)) { $script:WingetExe = $null; return $false }
    return $true
}

function Parse-WingetListOutput {
    param([string]$Output)
    $_wgItems = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Output)) { return $_wgItems }

    # Her satiri \r ile bol, en uzun parcayi al (progress bar kalintisi)
    $_wgLines = ($Output -split "`n") | ForEach-Object {
        $_wgParts = $_ -split "`r"
        ($_wgParts | Sort-Object Length -Descending | Select-Object -First 1) -replace '\x1B\[[0-9;]*[mGKHF]', ''
    }

    # Header satirini bul
    $_wgHdrIdx = -1
    for ($_wgIdx = 0; $_wgIdx -lt $_wgLines.Count; $_wgIdx++) {
        if ($_wgLines[$_wgIdx] -match 'Name\s+Id\s+Version') { $_wgHdrIdx = $_wgIdx; break }
    }
    if ($_wgHdrIdx -lt 0) { return $_wgItems }

    $_wgH    = $_wgLines[$_wgHdrIdx]
    $_wgNPos = $_wgH.IndexOf('Name')
    $_wgIPos = $_wgH.IndexOf('Id',        [Math]::Max(0, $_wgNPos + 4))
    $_wgVPos = $_wgH.IndexOf('Version',   [Math]::Max(0, $_wgIPos + 2))
    $_wgAPos = $_wgH.IndexOf('Available', [Math]::Max(0, $_wgVPos + 7))
    $_wgSPos = $_wgH.IndexOf('Source',    [Math]::Max(0, $_wgAPos + 9))
    if ($_wgNPos -lt 0 -or $_wgIPos -lt 0 -or $_wgVPos -lt 0) { return $_wgItems }
    if ($_wgAPos -lt 0) { $_wgAPos = $_wgVPos + 20 }
    if ($_wgSPos -lt 0) { $_wgSPos = $_wgAPos + 10 }

    for ($_wgIdx = $_wgHdrIdx + 2; $_wgIdx -lt $_wgLines.Count; $_wgIdx++) {
        $_wgDl = $_wgLines[$_wgIdx]
        if ([string]::IsNullOrWhiteSpace($_wgDl)) { continue }
        if ($_wgDl.Trim() -match '^\d+\s+package' -or $_wgDl.Trim() -match '^[-\s]+$') { continue }
        try {
            $_wgName  = if ($_wgDl.Length -gt $_wgNPos) { $_wgDl.Substring($_wgNPos, [Math]::Min($_wgIPos - $_wgNPos, $_wgDl.Length - $_wgNPos)).Trim() } else { '' }
            $_wgId    = if ($_wgDl.Length -gt $_wgIPos) { $_wgDl.Substring($_wgIPos, [Math]::Min($_wgVPos - $_wgIPos, $_wgDl.Length - $_wgIPos)).Trim() } else { '' }
            $_wgVer   = if ($_wgDl.Length -gt $_wgVPos) { $_wgDl.Substring($_wgVPos, [Math]::Min($_wgAPos - $_wgVPos, $_wgDl.Length - $_wgVPos)).Trim() } else { '' }
            $_wgAvail = if ($_wgDl.Length -gt $_wgAPos) { $_wgDl.Substring($_wgAPos, [Math]::Min($_wgSPos - $_wgAPos, $_wgDl.Length - $_wgAPos)).Trim() } else { '' }
            $_wgSrc   = if ($_wgDl.Length -gt $_wgSPos) { $_wgDl.Substring($_wgSPos).Trim() } else { '' }

            # Ellipsis temizle
            $_wgId    = $_wgId    -replace '[…\u2026ÔÇĞ].*', ''
            $_wgName  = $_wgName  -replace '[…\u2026]$', '...'
            $_wgVer   = $_wgVer   -replace '[…\u2026ÔÇĞ].*', ''
            $_wgAvail = $_wgAvail -replace '[…\u2026ÔÇĞ].*', ''

            # > prefix temizle
            if ($_wgAvail -match '^>\s*(.+)') { $_wgAvail = $matches[1].Trim() }
            if ($_wgAvail -eq '0') { $_wgAvail = '' }

            if (-not $_wgName -or -not $_wgId) { continue }
            if (-not $_wgVer) { $_wgVer = '—' }
            if (-not $_wgSrc) { $_wgSrc = 'winget' }

            # ── Gizle: winget ile guncellenemeyen paketler ──────────────────
            # MSIX\... → Microsoft Store uygulamasi
            if ($_wgId -match '^MSIX\\') { continue }
            # ARP\... → Add/Remove Programs kaydi, winget upgrade desteklemiyor
            if ($_wgId -match '^ARP\\') { continue }

            $_wgWi = New-Object WingetItem
            $_wgWi.Name             = $_wgName
            $_wgWi.Id               = $_wgId
            $_wgWi.InstalledVersion = $_wgVer
            $_wgWi.AvailableVersion = $_wgAvail
            $_wgWi.Source           = $_wgSrc
            $_wgWi.IsSelected       = $false
            $_wgWi.HasUpdate        = ($_wgAvail -and $_wgAvail -ne $_wgVer -and $_wgAvail -notmatch '^(winget|msstore|Unknown|0)$')
            if ($_wgWi.HasUpdate) {
                $_wgWi.RowStatus   = (T 'WingetBadgeUpdate')
                $_wgWi.RowStatusBg = '#2D1F00'
                $_wgWi.RowStatusFg = '#FDE68A'
            } else {
                $_wgWi.RowStatus   = (T 'WingetBadgeUpToDate')
                $_wgWi.RowStatusBg = '#0D2818'
                $_wgWi.RowStatusFg = '#86EFAC'
            }
            $_wgItems.Add($_wgWi)
        } catch { }
    }
    return $_wgItems
}
function Get-WingetInstalledList {
    param([string]$SourceFilter = '')
    if (-not (Test-WingetAvailable)) { return @() }
    try {
        if ($SourceFilter) {
            $_giOut = winget list --source $SourceFilter --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        } else {
            $_giOut = winget list --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        }
        return Parse-WingetListOutput -Output $_giOut
    } catch { return @() }
}
function Get-WingetSources {
    if (-not (Test-WingetAvailable)) { return @('winget') }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $script:WingetExe
        $psi.Arguments              = "source list"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $null = $p.Start()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $sources = @('All')
        foreach ($line in ($out -split "`r?`n")) {
            if ($line -match '^(winget|msstore)\s') { $sources += ($line -split '\s+')[0] }
        }
        if ($sources.Count -eq 1) { $sources = @('All', 'winget', 'msstore') }
        return $sources | Select-Object -Unique
    } catch { return @('All', 'winget', 'msstore') }
}

function Initialize-WingetTab {
    if ($script:WingetReady) { return }
    # UI thread'i bloklamadan arka planda winget yolunu bul
    $script:WingetReady = $true  # Çift çağrıyı önle
    if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetChecking') }
    if ($lvWinget) { $lvWinget.ItemsSource = $script:WingetPackages }
    # Kaynak listesini doldur — statik temel + sisteme kayıtlı dinamik kaynaklar
    if ($cmbWingetSource) {
        $cmbWingetSource.Items.Clear()
        $cmbWingetSource.Items.Add('All')
        $cmbWingetSource.Items.Add('winget')    # Resmi Microsoft winget community reposu
        $cmbWingetSource.Items.Add('msstore')   # Microsoft Store

        # Sisteme kayıtlı ek kaynakları arka planda ekle
        $script:_wSrcJob = Start-Job -ScriptBlock {
            try {
                $out = winget source list --accept-source-agreements 2>&1 | Out-String
                $extras = @()
                foreach ($ln in ($out -split "`r?`n")) {
                    if ($ln -match '^(\S+)\s+https?://') {
                        $sn = ($ln -split '\s+')[0]
                        if ($sn -notin @('winget','msstore','Name')) { $extras += $sn }
                    }
                }
                return $extras
            } catch { return @() }
        }
        $script:_wSrcTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:_wSrcTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:_wSrcTimer.Add_Tick({
            if ($script:_wSrcJob.State -eq 'Running') { return }
            $script:_wSrcTimer.Stop()
            try {
                $extras = Receive-Job $script:_wSrcJob -ErrorAction SilentlyContinue
                Remove-Job $script:_wSrcJob -Force -ErrorAction SilentlyContinue
                if ($extras -and $cmbWingetSource) {
                    foreach ($sn in $extras) {
                        if (-not $cmbWingetSource.Items.Contains($sn)) {
                            $cmbWingetSource.Items.Add($sn)
                        }
                    }
                }
            } catch { }
        })
        $script:_wSrcTimer.Start()
        $cmbWingetSource.SelectedIndex = 0
    }
    # Arka planda winget yolunu bul, sonra otomatik yükle
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $wp = $null
        $candidates = @(
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
            "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller*\winget.exe"
        )
        foreach ($c in $candidates) {
            $found = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found -and (Test-Path $found.FullName)) { $wp = $found.FullName; break }
        }
        if (-not $wp) {
            $cmd = Get-Command winget -ErrorAction SilentlyContinue
            if ($cmd) { $wp = $cmd.Source }
        }
        return $wp
    })
    $handle = $ps.BeginInvoke()
    # DispatcherTimer ile tamamlanmayı kontrol et (UI thread'i bloklamaz)
    $script:_wingetInitTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:_wingetInitTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:_wingetInitHandle = $handle
    $script:_wingetInitPs = $ps
    $script:_wingetInitRs = $rs
    $script:_wingetInitTimer.Add_Tick({
        if ($script:_wingetInitHandle.IsCompleted) {
            $script:_wingetInitTimer.Stop()
            $wp = $script:_wingetInitPs.EndInvoke($script:_wingetInitHandle) | Select-Object -Last 1
            $script:_wingetInitPs.Dispose()
            $script:_wingetInitRs.Close()
            $script:_wingetInitRs.Dispose()
            if ($wp -and (Test-Path $wp)) {
                $script:WingetExe = $wp
                # InstallerHashOverride — sadece non-admin context'te gecerlidir.
                # Script admin olarak calistiginda 'winget settings --enable' admin ayarini
                # degistirir; oysa hash override KULLANICI ayarlarinda olmalidir.
                # Bu nedenle ayarı ayrı bir non-elevated process'te etkinlestiriyoruz.
                try {
                    # Winget ayar dosyasini dogrudan yaz (en guvenilir yol)
                    $wgSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json"
                    if (Test-Path $wgSettingsPath) {
                        $wgJson = Get-Content $wgSettingsPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if (-not $wgJson) { $wgJson = [PSCustomObject]@{} }
                    } else {
                        $wgJson = [PSCustomObject]@{}
                    }
                    if (-not $wgJson.PSObject.Properties['experimentalFeatures']) {
                        $wgJson | Add-Member -MemberType NoteProperty -Name 'experimentalFeatures' -Value ([PSCustomObject]@{})
                    }
                    if (-not $wgJson.experimentalFeatures.PSObject.Properties['installerHashOverride']) {
                        $wgJson.experimentalFeatures | Add-Member -MemberType NoteProperty -Name 'installerHashOverride' -Value $true
                    } else {
                        $wgJson.experimentalFeatures.installerHashOverride = $true
                    }
                    $wgJson | ConvertTo-Json -Depth 10 | Set-Content $wgSettingsPath -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                } catch { }
                # Ek olarak winget settings CLI ile de dene (non-admin powershell)
                try {
                    $psiHash = New-Object System.Diagnostics.ProcessStartInfo
                    $psiHash.FileName  = 'powershell.exe'
                    $psiHash.Arguments = "-NoProfile -WindowStyle Hidden -Command `"& '$wp' settings --enable InstallerHashOverride`""
                    $psiHash.UseShellExecute = $false
                    $psiHash.CreateNoWindow  = $true
                    # RunAsInvoker: admin token devralmaz, user context'te calisir
                    $psiHash.EnvironmentVariables['__COMPAT_LAYER'] = 'RunAsInvoker'
                    $phash = [System.Diagnostics.Process]::Start($psiHash)
                    if ($phash) { $null = $phash.WaitForExit(3000) }
                } catch { }
                if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetReady') }
                if ($btnWingetRefresh) { $btnWingetRefresh.IsEnabled = $true }
                # İlk açılışta otomatik yükle
                Refresh-WingetList
            } else {
                $script:WingetReady = $false
                if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetNotFound') }
                if ($btnWingetRefresh) { $btnWingetRefresh.IsEnabled = $false }
            }
        }
    })
    $script:_wingetInitTimer.Start()
}

function Refresh-WingetList {
    if (-not (Test-WingetAvailable)) {
        if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetNotAvail') }
        return
    }
    if ($btnWingetRefresh)    { $btnWingetRefresh.IsEnabled    = $false }
    if ($btnWingetUpgrade)    { $btnWingetUpgrade.IsEnabled    = $false }
    $script:WingetPackages.Clear()
    $script:WingetAllPackages = @()
    if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetRunning') }
    if ($progWinget) { $progWinget.Visibility = 'Visible'; $progWinget.IsIndeterminate = $true }

    # Loading overlay'i goster
    if ($pnlWingetLoading) {
        if ($lblWingetLoading)    { $lblWingetLoading.Text    = (T 'WingetRunning') }
        if ($lblWingetLoadingSub) { $lblWingetLoadingSub.Text = (T 'WingetLoadingSub') }
        $pnlWingetLoading.Visibility = 'Visible'
    }

    $srcFilter = if ($cmbWingetSource -and $cmbWingetSource.SelectedIndex -gt 0) { $cmbWingetSource.SelectedItem.ToString() } else { '' }
    $tmpAll = [System.IO.Path]::Combine($env:TEMP, "wg_all_$([System.Diagnostics.Process]::GetCurrentProcess().Id).txt")
    $tmpUpd = [System.IO.Path]::Combine($env:TEMP, "wg_upd_$([System.Diagnostics.Process]::GetCurrentProcess().Id).txt")

    $script:_wRefJob = Start-Job -ScriptBlock {
        param($src, $outAll, $outUpd)
        # Buffer genislet — ellipsis sorununu onler
        try { $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(500, 9999) } catch { }
        # Turkce karakter encoding — winget ciktisindaki bozulmayi onler
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        try {
            # Tum yuklu paketler
            if ($src) { $all = winget list --source $src --accept-source-agreements --disable-interactivity 2>&1 }
            else       { $all = winget list --accept-source-agreements --disable-interactivity 2>&1 }
            [System.IO.File]::WriteAllLines($outAll, $all, [System.Text.Encoding]::UTF8)
            # Sadece guncelleme olanlari ayri al (ID eslestirmesi icin)
            if ($src) { $upd = winget list --upgrade-available --source $src --accept-source-agreements --disable-interactivity 2>&1 }
            else       { $upd = winget list --upgrade-available --accept-source-agreements --disable-interactivity 2>&1 }
            [System.IO.File]::WriteAllLines($outUpd, $upd, [System.Text.Encoding]::UTF8)
        } catch { }
    } -ArgumentList $srcFilter, $tmpAll, $tmpUpd

    $script:_wRefTmpAll = $tmpAll
    $script:_wRefTmpUpd = $tmpUpd
    $script:_wRefTimer  = New-Object System.Windows.Threading.DispatcherTimer
    $script:_wRefTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:_wRefTimer.Add_Tick({
        if ($script:_wRefJob.State -eq 'Running') { return }
        $script:_wRefTimer.Stop()
        try { Remove-Job $script:_wRefJob -Force -ErrorAction SilentlyContinue } catch { }

        if ($progWinget) { $progWinget.IsIndeterminate = $false; $progWinget.Visibility = 'Collapsed' }
        if ($btnWingetRefresh) { $btnWingetRefresh.IsEnabled = $true }
        # Loading overlay'i gizle
        if ($pnlWingetLoading) { $pnlWingetLoading.Visibility = 'Collapsed' }

        $_wgAllOut = $null; $_wgUpdOut = $null
        if (Test-Path $script:_wRefTmpAll) {
            try { $_wgAllOut = [System.IO.File]::ReadAllText($script:_wRefTmpAll, [System.Text.Encoding]::UTF8) } catch { }
            try { Remove-Item $script:_wRefTmpAll -Force -ErrorAction SilentlyContinue } catch { }
        }
        if (Test-Path $script:_wRefTmpUpd) {
            try { $_wgUpdOut = [System.IO.File]::ReadAllText($script:_wRefTmpUpd, [System.Text.Encoding]::UTF8) } catch { }
            try { Remove-Item $script:_wRefTmpUpd -Force -ErrorAction SilentlyContinue } catch { }
        }

        if ([string]::IsNullOrWhiteSpace($_wgAllOut)) {
            if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetError') }
            return
        }

        $pkgs = Parse-WingetListOutput -Output $_wgAllOut

        # --upgrade-available ciktisindaki ID'leri bul ve HasUpdate=true yap
        if (-not [string]::IsNullOrWhiteSpace($_wgUpdOut)) {
            $_wgUpdLines = $_wgUpdOut -split "`n"
            $_wgUpdIds   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $_wgUpdVers  = @{}
            # Header bul
            $_wgUHdr = -1
            for ($_wgUi = 0; $_wgUi -lt $_wgUpdLines.Count; $_wgUi++) {
                if ($_wgUpdLines[$_wgUi] -match 'Name\s+Id\s+Version') { $_wgUHdr = $_wgUi; break }
            }
            if ($_wgUHdr -ge 0) {
                $_wgUH    = $_wgUpdLines[$_wgUHdr]
                $_wgUIPos = $_wgUH.IndexOf('Id',       [Math]::Max(0, $_wgUH.IndexOf('Name') + 4))
                $_wgUVPos = $_wgUH.IndexOf('Version',  [Math]::Max(0, $_wgUIPos + 2))
                $_wgUAPos = $_wgUH.IndexOf('Available',[Math]::Max(0, $_wgUVPos + 7))
                $_wgUSPos = $_wgUH.IndexOf('Source',   [Math]::Max(0, $_wgUAPos + 9))
                if ($_wgUAPos -lt 0) { $_wgUAPos = $_wgUVPos + 20 }
                if ($_wgUSPos -lt 0) { $_wgUSPos = $_wgUAPos + 10 }
                for ($_wgUi = $_wgUHdr + 2; $_wgUi -lt $_wgUpdLines.Count; $_wgUi++) {
                    $_wgUDl = ($($_wgUpdLines[$_wgUi] -split "`r") | Sort-Object Length -Descending | Select-Object -First 1)
                    if ([string]::IsNullOrWhiteSpace($_wgUDl)) { continue }
                    if ($_wgUDl.Trim() -match '^\d+\s+package' -or $_wgUDl.Trim() -match '^[-\s]+$') { continue }
                    $_wgUID  = if ($_wgUDl.Length -gt $_wgUIPos) { $_wgUDl.Substring($_wgUIPos, [Math]::Min($_wgUVPos - $_wgUIPos, $_wgUDl.Length - $_wgUIPos)).Trim() -replace '[…ÔÇĞ].*','' } else { '' }
                    $_wgUAv  = if ($_wgUDl.Length -gt $_wgUAPos) { $_wgUDl.Substring($_wgUAPos, [Math]::Min($_wgUSPos - $_wgUAPos, $_wgUDl.Length - $_wgUAPos)).Trim() -replace '[…ÔÇĞ].*','' } else { '' }
                    if ($_wgUID -and $_wgUID -notmatch '^MSIX\\|^ARP\\') {
                        $null = $_wgUpdIds.Add($_wgUID)
                        if ($_wgUAv -and $_wgUAv -ne '0') { $_wgUpdVers[$_wgUID] = $_wgUAv }
                    }
                }
            }
            # HasUpdate ve AvailableVersion guncelle
            foreach ($pkg in $pkgs) {
                if ($_wgUpdIds.Contains($pkg.Id)) {
                    $pkg.HasUpdate = $true
                    if ($_wgUpdVers.ContainsKey($pkg.Id)) { $pkg.AvailableVersion = $_wgUpdVers[$pkg.Id] }
                    $pkg.RowStatus   = (T 'WingetBadgeUpdate')
                    $pkg.RowStatusBg = '#2D1F00'
                    $pkg.RowStatusFg = '#FDE68A'
                } elseif (-not $pkg.HasUpdate -and $pkg.InstalledVersion -and $pkg.InstalledVersion -ne '—') {
                    $pkg.AvailableVersion = $pkg.InstalledVersion
                    $pkg.RowStatus   = (T 'WingetBadgeUpToDate')
                    $pkg.RowStatusBg = '#0D2818'
                    $pkg.RowStatusFg = '#86EFAC'
                }
            }
        } else {
            foreach ($pkg in $pkgs) {
                if (-not $pkg.HasUpdate -and $pkg.InstalledVersion -and $pkg.InstalledVersion -ne '—') {
                    $pkg.AvailableVersion = $pkg.InstalledVersion
                    $pkg.RowStatus   = (T 'WingetBadgeUpToDate')
                    $pkg.RowStatusBg = '#0D2818'
                    $pkg.RowStatusFg = '#86EFAC'
                }
            }
        }

        $script:WingetAllPackages = $pkgs
        Apply-WingetFilters

        $_wgTotal = $pkgs.Count
        $_wgUpd   = @($pkgs | Where-Object { $_.HasUpdate }).Count
        if ($lblWingetStatus) {
            if ($_wgUpd -gt 0) {
                $lblWingetStatus.Text = [string]::Format((T 'WingetLoadedUpd'), $_wgTotal, $_wgUpd)
            } else {
                $lblWingetStatus.Text = [string]::Format((T 'WingetLoaded'), $_wgTotal)
            }
        }
        if ($btnWingetUpgrade) {
            $label = if ($script:Lang -eq 'TR') { '⬆ Tümünü Güncelle' } else { '⬆ Update All' }
            if ($_wgUpd -gt 0) { $label += " ($_wgUpd)" }
            $btnWingetUpgrade.Content   = $label
            $btnWingetUpgrade.IsEnabled = ($_wgUpd -gt 0)
        }
        Update-WingetCount
    })
    $script:_wRefTimer.Start()
}

# WingetItem PropertyChanged handler — IsSelected degisince butonlari guncelle
$script:WingetItemPropChanged = [System.ComponentModel.PropertyChangedEventHandler]{
    param($s, $e)
    if ($e.PropertyName -eq 'IsSelected') { Update-WingetSelectionButtons }
}

function Apply-WingetFilters {
    if (-not $script:WingetAllPackages) {
        if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetNoPackages') }
        return
    }
    $filtered = @($script:WingetAllPackages)

    # Gizlenen güncellemeleri listeden tamamen çıkar
    $ignored = if ($script:AppSettings -and $script:AppSettings.WingetIgnoredUpdates) {
        @($script:AppSettings.WingetIgnoredUpdates)
    } else { @() }
    if ($ignored.Count -gt 0) {
        $filtered = @($filtered | Where-Object { $ignored -notcontains $_.Id })
    }

    $q = if ($txtWingetQuery) { $txtWingetQuery.Text.Trim().ToLowerInvariant() } else { '' }
    if ($q) {
        $filtered = @($filtered | Where-Object { $_.Name.ToLowerInvariant().Contains($q) -or $_.Id.ToLowerInvariant().Contains($q) })
    }
    $showUpdatesOnly = if ($chkWingetShowUpdates) { $chkWingetShowUpdates.IsChecked } else { $false }
    if ($showUpdatesOnly) {
        # Gizlenen paketleri "Show Updates Only" modunda da gizle
        $filtered = @($filtered | Where-Object { $_.HasUpdate })
    }

    # Eski handler'lari temizle, yenilerini ekle
    $script:WingetPackages.Clear()
    foreach ($p in $filtered) {
        try { $p.remove_PropertyChanged($script:WingetItemPropChanged) } catch { }
        try { $p.add_PropertyChanged($script:WingetItemPropChanged) } catch { }
        $script:WingetPackages.Add($p)
    }
    if ($lvWinget) { $lvWinget.Items.Refresh() }
    Update-WingetSelectionButtons
}
function Update-WingetCount {
    $total    = if ($script:WingetAllPackages) { $script:WingetAllPackages.Count } else { 0 }
    $visible  = $script:WingetPackages.Count
    $updates  = @($script:WingetAllPackages | Where-Object { $_.HasUpdate }).Count
    $selected = @($script:WingetPackages | Where-Object { $_.IsSelected }).Count

    # Sade tek satır: '43 paket · 1 güncelleme'  /  filtreliyken '42/43 paket · 1 güncelleme'
    $pkgPart = if ($visible -eq $total) {
        if ($script:Lang -eq 'TR') { "$total paket" } else { "$total packages" }
    } else {
        if ($script:Lang -eq 'TR') { "$visible/$total paket" } else { "$visible/$total packages" }
    }
    $updPart = if ($updates -gt 0) {
        if ($script:Lang -eq 'TR') { " · $updates güncelleme" }
        else { if ($updates -eq 1) { ' · 1 update' } else { " · $updates updates" } }
    } else { '' }
    $txt = $pkgPart + $updPart
    if ($lblWingetCount) { $lblWingetCount.Text = $txt }

    # Header checkbox durumunu guncelle (hepsi seciliyse checked, hic yoksa unchecked, karisiksa null)
    try {
        if ($script:_wgHeaderChk) {
            if ($visible -eq 0 -or $selected -eq 0) {
                $script:_wgHeaderChk.IsChecked = $false
            } elseif ($selected -eq $visible) {
                $script:_wgHeaderChk.IsChecked = $true
            } else {
                $script:_wgHeaderChk.IsChecked = $null  # indeterminate
            }
        }
    } catch { }
}

function Update-WingetSelectionButtons {
    $anySelected  = @($script:WingetPackages | Where-Object { $_.IsSelected }).Count -gt 0
    $hasUpdSelec  = @($script:WingetPackages | Where-Object { $_.IsSelected -and $_.HasUpdate }).Count -gt 0
    $totalUpdates = @($script:WingetAllPackages | Where-Object { $_.HasUpdate }).Count
    # Birleşik buton: seçim varsa sadece seçili+güncellemesi olanları say,
    # seçim yoksa tüm güncellenebilirleri say.
    $selectedCount = @($script:WingetPackages | Where-Object { $_.IsSelected }).Count
    if ($btnWingetUpgrade) {
        if ($selectedCount -gt 0) {
            $selUpdCount = @($script:WingetPackages | Where-Object { $_.IsSelected -and $_.HasUpdate }).Count
            $label = if ($script:Lang -eq 'TR') { '⬆ Seçileni Güncelle' } else { '⬆ Update Selected' }
            if ($selUpdCount -gt 0) { $label += " ($selUpdCount)" }
            $btnWingetUpgrade.Content   = $label
            $btnWingetUpgrade.IsEnabled = ($selUpdCount -gt 0)
        } else {
            $label = if ($script:Lang -eq 'TR') { '⬆ Tümünü Güncelle' } else { '⬆ Update All' }
            if ($totalUpdates -gt 0) { $label += " ($totalUpdates)" }
            $btnWingetUpgrade.Content   = $label
            $btnWingetUpgrade.IsEnabled = ($totalUpdates -gt 0)
        }
    }
    Update-WingetCount
}

function Resolve-WingetError {
    # Winget exit code'larini insan okunabilir mesaja cevir
    # Kaynak: https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget
    param([int]$Code)
    $map = @{
        0            = ''                                          # Basari
        -9999        = 'Install did not complete (version unchanged after upgrade)' # Ozel: versiyon degismedi
        -1978335231  = 'Internal error'                           # INTERNAL_ERROR
        -1978335230  = 'Invalid command line arguments'           # INVALID_CL_ARGUMENTS
        -1978335229  = 'Command execution failed'                 # COMMAND_FAILED
        -1978335228  = 'Failed to open manifest'                  # MANIFEST_FAILED
        -1978335227  = 'Operation cancelled'                      # CTRL_SIGNAL_RECEIVED
        -1978335226  = 'ShellExecute install failed'              # SHELLEXEC_INSTALL_FAILED
        -1978335225  = 'Manifest version too high — update winget' # UNSUPPORTED_MANIFESTVERSION
        -1978335224  = 'Download failed'                          # DOWNLOAD_FAILED
        -1978335216  = 'No applicable installer for this system'  # NO_APPLICABLE_INSTALLER
        -1978335215  = 'Installer hash mismatch — try --ignore-security-hash' # INSTALLER_HASH_MISMATCH
        -1978335214  = 'Source not found'                         # SOURCE_NAME_DOES_NOT_EXIST
        -1978335212  = 'Package not found'                        # NO_APPLICATIONS_FOUND
        -1978335210  = 'Multiple packages matched'                # MULTIPLE_APPLICATIONS_FOUND
        -1978335209  = 'No manifest found'                        # NO_MANIFEST_FOUND
        -1978335207  = 'Admin privileges required'                # COMMAND_REQUIRES_ADMIN
        -1978335205  = 'Blocked by policy (Store)'                # MSSTORE_BLOCKED_BY_POLICY
        -1978335204  = 'App blocked by policy'                    # MSSTORE_APP_BLOCKED_BY_POLICY
        -1978335202  = 'Microsoft Store install failed'           # MSSTORE_INSTALL_FAILED
        -1978335189  = 'No applicable update found (already up to date)' # UPDATE_NOT_APPLICABLE
        -1978335188  = 'Some upgrades failed (--all)'             # UPDATE_ALL_HAS_FAILURE
        -1978335187  = 'Installer failed security check'          # INSTALLER_SECURITY_CHECK_FAILED
        -1978335186  = 'Download size mismatch'                   # DOWNLOAD_SIZE_MISMATCH
        -1978335184  = 'Uninstall command failed'                 # EXEC_UNINSTALL_COMMAND_FAILED
        -1978335174  = 'Blocked by Group Policy'                  # BLOCKED_BY_POLICY
        -1978335167  = 'Package agreements not accepted'          # PACKAGE_AGREEMENTS_NOT_ACCEPTED
        -1978335164  = 'REST API endpoint not found'              # RESTAPI_ENDPOINT_NOT_FOUND
        -1978335162  = 'Source agreements not accepted'           # SOURCE_AGREEMENTS_NOT_ACCEPTED
        -1978335159  = 'MSI install failed'                       # MSI_INSTALL_FAILED
        -1978335153  = 'Upgrade version not newer than installed' # UPGRADE_VERSION_NOT_NEWER
        -1978335152  = 'Upgrade version unknown'                  # UPGRADE_VERSION_UNKNOWN
        -1978335143  = 'Unsupported argument (--silent not supported by this installer)' # UNSUPPORTED_ARGUMENT
        -1978335146  = 'Installer cannot run as administrator'    # INSTALLER_PROHIBITS_ELEVATION
        -1978335135  = 'Package already installed'                # PACKAGE_ALREADY_INSTALLED
        -1978335128  = 'Package is pinned — upgrade blocked'      # PACKAGE_IS_PINNED
        -1978335127  = 'Stub package installed'                   # PACKAGE_IS_STUB
        -1978335125  = 'Failed to download dependencies'          # DOWNLOAD_DEPENDENCIES
        -1978335123  = 'Service unavailable — try again later'    # SERVICE_UNAVAILABLE
        -1978335115  = 'Authentication failed'                    # AUTHENTICATION_FAILED
        -1978335113  = 'Authentication cancelled by user'         # AUTHENTICATION_CANCELLED_BY_USER
    }
    if ($map.ContainsKey($Code)) { return $map[$Code] }
    if ($Code -eq 0) { return '' }
    return "Unknown error (0x{0:X8})" -f [uint32]$Code
}

function Invoke-WingetBatchOperation {
    param([string]$Operation, [object[]]$Packages)
    if (-not $Packages -or $Packages.Count -eq 0) { return }

    $total = $Packages.Count
    if ($progWinget)      { $progWinget.Visibility = 'Visible'; $progWinget.IsIndeterminate = $false; $progWinget.Value = 0; $progWinget.Maximum = $total }
    if ($lblWingetStatus) { $lblWingetStatus.Text = [string]::Format((T 'WingetUpdating'), 0, $total) }
    if ($btnWingetRefresh)    { $btnWingetRefresh.IsEnabled    = $false }
    if ($btnWingetUpgrade)    { $btnWingetUpgrade.IsEnabled    = $false }

    # İptal mekanizması: tmpCancel dosyası oluşturulduğunda worker bir sonraki
    # pakete geçmeden önce dosyayı görerek döngüden çıkar.
    # (Start-Job ayrı runspace'te çalıştığından script: scope paylaşılamaz.)
    $script:cancelWinget = $false
    $tmpIn     = [System.IO.Path]::Combine($env:TEMP, "wg_in_$([System.Diagnostics.Process]::GetCurrentProcess().Id).txt")
    $tmpOut    = [System.IO.Path]::Combine($env:TEMP, "wg_out_$([System.Diagnostics.Process]::GetCurrentProcess().Id).txt")
    $tmpCancel = [System.IO.Path]::Combine($env:TEMP, "wg_cancel_$([System.Diagnostics.Process]::GetCurrentProcess().Id).flag")
    # Önceki iptal bayrağını temizle
    try { Remove-Item $tmpCancel -Force -ErrorAction SilentlyContinue } catch { }
    $script:_wBatchTmpCancel = $tmpCancel
    $Packages | ForEach-Object { "$($_.Id)`t$($_.Source)" } | Out-File $tmpIn -Encoding UTF8 -Force

    # İptal butonunu göster
    Show-Cancel -OpKey 'winget'

    # Spinner timer â€” aktif pakette braille animasyonu
    $script:_wBatchSpinFrames = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F)
    $script:_wBatchSpinIdx    = 0
    $script:_wBatchActiveId   = $null
    $script:_wBatchSpinTimer  = New-Object System.Windows.Threading.DispatcherTimer
    $script:_wBatchSpinTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $script:_wBatchSpinTimer.Add_Tick({
        $script:_wBatchSpinIdx = ($script:_wBatchSpinIdx + 1) % $script:_wBatchSpinFrames.Length
        $frame = [string]$script:_wBatchSpinFrames[$script:_wBatchSpinIdx]
        if ($script:_wBatchActiveId) {
            $pkg = $script:WingetPackages | Where-Object { $_.Id -eq $script:_wBatchActiveId } | Select-Object -First 1
            if ($pkg) {
                # Eğer progress UI tarafından "%" veya "⚙" yazılmışsa, spinner üzerine yazma
                $cur = [string]$pkg.StatusText
                if ($cur -match '%$' -or $cur -eq '⚙') { return }
                $pkg.StatusText = $frame
            }
        }
    })
    $script:_wBatchSpinTimer.Start()

    $script:_wBatchJob = Start-Job -ScriptBlock {
        param($operation, $tmpIn, $tmpOut, $tmpCancel)
        $results = [System.Collections.Generic.List[string]]::new()

        # ── Hash Mismatch Gerçek Bypass ───────────────────────────────────────────
        # Winget, admin (yükseltilmiş) context'te hash bypass'ına izin VERMEZ.
        # Tek gerçek çözüm: kurulumu NON-ADMIN bir PowerShell process'inde çalıştırmak.
        # Bu fonksiyon geçici bir PS1 script yazar, onu normal kullanıcı bağlamında çalıştırır.
        function Invoke-WingetNonAdmin {
            param([string]$PkgId, [string]$PkgSrc, [string]$Op)
            try {
                # Winget settings.json'a InstallerHashOverride yaz (kullanıcı profilinde)
                $wgSettings = "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json"
                if (Test-Path $wgSettings) {
                    $j = try { Get-Content $wgSettings -Raw | ConvertFrom-Json } catch { $null }
                } else { $j = $null }
                if (-not $j) { $j = [PSCustomObject]@{} }
                if (-not $j.PSObject.Properties['experimentalFeatures']) {
                    $j | Add-Member -MemberType NoteProperty -Name 'experimentalFeatures' -Value ([PSCustomObject]@{})
                }
                if (-not $j.experimentalFeatures.PSObject.Properties['installerHashOverride']) {
                    $j.experimentalFeatures | Add-Member -MemberType NoteProperty -Name 'installerHashOverride' -Value $true
                } else { $j.experimentalFeatures.installerHashOverride = $true }
                $j | ConvertTo-Json -Depth 10 | Set-Content $wgSettings -Encoding UTF8 -Force

                # Geçici script dosyası oluştur
                $tmpScript = [System.IO.Path]::Combine($env:TEMP, "wg_hash_$([System.Diagnostics.Process]::GetCurrentProcess().Id)_$([System.IO.Path]::GetRandomFileName()).ps1")
                $srcArg = if ($PkgSrc -and $PkgSrc -notin @('','winget','msstore')) { "--source `"$PkgSrc`"" } else { '' }
                @"
`$null = winget $Op --id "$PkgId" --exact $srcArg --silent --ignore-security-hash --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1
exit `$LASTEXITCODE
"@ | Set-Content $tmpScript -Encoding UTF8 -Force

                # Non-admin process olarak çalıştır (RunAsInvoker — token yükseltmesini engeller)
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName  = 'powershell.exe'
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tmpScript`""
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow  = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                # __COMPAT_LAYER=RunAsInvoker: process'in yükseltilmiş token talep etmesini önler
                $psi.EnvironmentVariables['__COMPAT_LAYER'] = 'RunAsInvoker'

                $p = [System.Diagnostics.Process]::Start($psi)
                $null = $p.StandardOutput.ReadToEnd()
                $null = $p.StandardError.ReadToEnd()
                $p.WaitForExit(120000)  # Max 2 dakika
                $ec = $p.ExitCode
                try { Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue } catch { }
                return $ec
            } catch {
                return -1
            }
        }

        # ── İndirme ilerleme yakalayıcı: winget'i Process API ile çalıştırıp ──
        # stdout'u satır satır okuyup tmpOut'a PROG: satırları yazar.
        # Winget redirect altında "9.00 MB / 83.2 MB" formatını yansıtır
        # (progress bar bozulur ama MB sayıları okunabilir kalır).
        function Invoke-WingetWithProgress {
            # NOT: $Args yerine $WingetArgs kullanılıyor — $Args PowerShell'in
            # otomatik değişkeni olduğundan param() ile override edildiğinde
            # edge case'lerde öngörülemeyen davranış gösterir.
            param([string]$PkgId, [string[]]$WingetArgs, [string]$OutFile)
            try {
                # winget.exe direkt çağrıldığında AppExecutionAlias (UWP launcher)
                # devreye girer: gerçek winget bir child process olarak başlar ve
                # launcher hemen 0 döner — $proc.ExitCode yanlış (launcher'ın kodu).
                # Çözüm: cmd.exe /c winget ... kullanmak. cmd.exe AppExecutionAlias'ı
                # doğru resolve eder ve asıl winget'in exit code'unu döner.
                $argLine = ($WingetArgs | ForEach-Object {
                    if ($_ -match '[\s"]') {
                        '"' + ($_ -replace '"','\"') + '"'
                    } else { $_ }
                }) -join ' '

                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName  = 'cmd.exe'
                $psi.Arguments = "/c winget $argLine"
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow  = $true
                $psi.RedirectStandardOutput = $true
                # stderr'i bilerek redirect ETMİYORUZ — eğer redirect edersek ve
                # winget stdout drain'i sırasında stderr buffer'ını doldurursa
                # proses deadlock'a girer. Redirect edilmemiş stderr gizli pencere
                # içinde sessizce kaybolur (CreateNoWindow=$true).
                $psi.RedirectStandardError  = $false
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $psi

                # Progress regex (winget redirect altında çıktı): "  4.86 MB / 35.7 MB"
                $rxMB = [regex]'(\d+(?:[.,]\d+)?)\s*(KB|MB|GB|B)\s*/\s*(\d+(?:[.,]\d+)?)\s*(KB|MB|GB|B)'

                # Hız hesaplama state'i (paket başında reset edildi, dış scope'tan)
                $lastWrite = [DateTime]::MinValue

                $convertToBytes = {
                    param($num, $unit)
                    $n = [double]($num -replace ',','.')
                    switch ($unit.ToUpper()) {
                        'B'  { return $n }
                        'KB' { return $n * 1024 }
                        'MB' { return $n * 1024 * 1024 }
                        'GB' { return $n * 1024 * 1024 * 1024 }
                    }
                    return 0
                }

                [void]$proc.Start()

                # Senkron satır satır okuma — winget bittiğinde ReadLine null döner.
                # Bu Start-Job (ayrı runspace) içinde olduğu için ana UI'ı bloklamaz.
                # Hız ve ETA hesabı UI tarafında yapılır (daha sağlam).
                $lastWrite = [DateTime]::MinValue
                while ($true) {
                    $ln = $proc.StandardOutput.ReadLine()
                    if ($null -eq $ln) { break }
                    if (-not $ln) { continue }

                    $m = $rxMB.Match($ln)
                    if (-not $m.Success) { continue }

                    $recvB  = & $convertToBytes $m.Groups[1].Value $m.Groups[2].Value
                    $totalB = & $convertToBytes $m.Groups[3].Value $m.Groups[4].Value
                    if ($totalB -le 0) { continue }

                    # En fazla ~250ms'de bir yaz (UI 300ms'de okur, dosyayı doldurmasın)
                    $now = [DateTime]::Now
                    $delta = ($now - $lastWrite).TotalMilliseconds
                    if ($delta -lt 250 -and $recvB -lt $totalB) { continue }
                    $lastWrite = $now

                    $pct = [int](($recvB * 100) / $totalB)
                    if ($pct -gt 100) { $pct = 100 }

                    # Format: PROG:pkgId|recvBytes|totalBytes|pct|tickMs
                    # tickMs = .NET DateTime.Ticks/10000 ms — UI hız hesaplaması için
                    $tickMs = [long]($now.Ticks / 10000)
                    $progLine = "PROG:{0}|{1}|{2}|{3}|{4}" -f `
                        $PkgId, [long]$recvB, [long]$totalB, $pct, $tickMs
                    Add-Content $OutFile -Value $progLine -Encoding UTF8 -Force
                }

                # stderr redirect edilmediği için boşaltmaya gerek yok.
                $proc.WaitForExit()

                # Kurulum aşamasını işaretle (indirme bitti, kurulum başlıyor sinyali)
                Add-Content $OutFile -Value ("STAGE:{0}|installing" -f $PkgId) -Encoding UTF8 -Force

                return $proc.ExitCode
            } catch {
                return -1
            }
        }

        try {
            # Zone identifier temizle (SmartScreen uyarısını önler)
            try {
                @("$env:USERPROFILE\AppData\Local\Temp", "$env:USERPROFILE\Downloads") | ForEach-Object {
                    if (Test-Path $_) {
                        Get-ChildItem $_ -Include @("*.exe","*.msi","*.msix","*.appx") -Recurse -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-1) } |
                            ForEach-Object { Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue }
                    }
                }
            } catch { }

            $pkgLines = Get-Content $tmpIn -Encoding UTF8 -ErrorAction SilentlyContinue
            foreach ($line in $pkgLines) {
                $parts  = $line -split "`t"
                $pkgId  = $parts[0].Trim()
                $pkgSrc = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { '' }
                if (-not $pkgId) { continue }
                # ── İptal kontrolü: her paket öncesinde cancel flag dosyasını kontrol et
                if ($tmpCancel -and (Test-Path $tmpCancel)) {
                    Add-Content $tmpOut -Value 'CANCELLED' -Encoding UTF8 -Force
                    break
                }
                Add-Content $tmpOut -Value "ACTIVE:$pkgId" -Encoding UTF8 -Force
                try {
                    # ── 1. Deneme: WAU yaklaşımı: -h + -e + -s winget ────────────────────
                    # WAU referans: -h (kisa form) daha genis installer destegi saglar
                    # -e (--exact), -s winget: ambiguous match onler (NTLite Legacy sorunu)
                    $src = if ($pkgSrc -and $pkgSrc -notin @('winget','msstore','')) { $pkgSrc } else { 'winget' }
                    $baseArgs = @($operation, '--id', $pkgId, '-e', '-h', '-s', $src,
                                  '--accept-source-agreements', '--accept-package-agreements'
                                  )
                    $exitCode = Invoke-WingetWithProgress -PkgId $pkgId -WingetArgs $baseArgs -OutFile $tmpOut

                    # ── 2. Deneme: Upgrade basarisiz → install --force (WAU yaklaşımı) ───
                    # WAU: upgrade calismazsa install --force ile tekrar dener
                    if ($exitCode -ne 0 -and $exitCode -ne -1978335189) {
                        $installArgs = @('install', '--id', $pkgId, '-e', '-h', '--force',
                                         '-s', $src,
                                         '--accept-source-agreements', '--accept-package-agreements'
                                         )
                        $exitCode = Invoke-WingetWithProgress -PkgId $pkgId -WingetArgs $installArgs -OutFile $tmpOut
                    }

                    # ── 3. Deneme: --override ile Inno Setup /VERYSILENT ─────────────────
                    # Bazi installer'lar (NTLite gibi) -h'yi desteklemez.
                    if ($exitCode -ne 0 -and $exitCode -ne -1978335189) {
                        $overrideArgs = @($operation, '--id', $pkgId, '-e',
                                         '-s', $src,
                                         '--override', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-',
                                         '--accept-source-agreements', '--accept-package-agreements',
                                         '--disable-interactivity')
                        $null = winget @overrideArgs 2>&1
                        $exitCode = $LASTEXITCODE
                    }

                    # ── 4. Deneme: Hash mismatch → NON-ADMIN process'te yeniden dene ─────
                    # -1978335215 = INSTALLER_HASH_MISMATCH (0x8A150011)
                    # -1978335187 = INSTALLER_SECURITY_CHECK_FAILED
                    if ($exitCode -eq -1978335215 -or $exitCode -eq -1978335187) {
                        $exitCode = Invoke-WingetNonAdmin -PkgId $pkgId -PkgSrc $pkgSrc -Op $operation
                    }

                    $success = ($exitCode -eq 0 -or $exitCode -eq -1978335189)

                    # ── Doğrulama: WAU Confirm-Installation yaklaşımı ────────────────────
                    # winget export ile kurulum doğrula (winget list'ten daha güvenilir)
                    if ($success) {
                        try {
                            $jsonFile = "$env:TEMP\wg_confirm_$([System.IO.Path]::GetRandomFileName()).json"
                            $null = winget export -s winget -o $jsonFile --include-versions 2>&1
                            if (Test-Path $jsonFile) {
                                $pkgs = (Get-Content $jsonFile -Raw | ConvertFrom-Json).Sources.Packages
                                $match = $pkgs | Where-Object { $_.PackageIdentifier -eq $pkgId }
                                Remove-Item $jsonFile -Force -ErrorAction SilentlyContinue
                                if (-not $match) {
                                    # winget export'ta yok — kurulum olmamış
                                    $success  = $false
                                    $exitCode = -9999
                                }
                            }
                        } catch { }
                    }

                    $results.Add("$pkgId`t$success`t$exitCode")
                } catch {
                    $results.Add("$pkgId`tFalse`t-1")
                }
            }
        } finally {
            $results | Out-File $tmpOut -Encoding UTF8 -Force
            try { Remove-Item $tmpIn -Force -ErrorAction SilentlyContinue } catch { }
        }
    } -ArgumentList $Operation, $tmpIn, $tmpOut, $tmpCancel

    $script:_wBatchTmpOut = $tmpOut
    $script:_wBatchTotal  = $total
    $script:_wBatchTimer  = New-Object System.Windows.Threading.DispatcherTimer
    $script:_wBatchTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:_wBatchTimer.Add_Tick({
        if (Test-Path $script:_wBatchTmpOut) {
            try {
                $content = Get-Content $script:_wBatchTmpOut -Encoding UTF8 -ErrorAction SilentlyContinue
                $activeLine = $content | Where-Object { $_ -match '^ACTIVE:' } | Select-Object -Last 1
                if ($activeLine) {
                    $newActiveId = $activeLine -replace '^ACTIVE:', ''
                    if ($newActiveId -ne $script:_wBatchActiveId) {
                        if ($script:_wBatchActiveId) {
                            $prev = $script:WingetPackages | Where-Object { $_.Id -eq $script:_wBatchActiveId } | Select-Object -First 1
                            if ($prev) { $prev.IsUpdating = $false; $prev.StatusText = '' }
                        }
                        $script:_wBatchActiveId = $newActiveId
                        $cur = $script:WingetPackages | Where-Object { $_.Id -eq $script:_wBatchActiveId } | Select-Object -First 1
                        if ($cur) { $cur.IsUpdating = $true }
                    }
                }

                # ── Canlı indirme ilerlemesi: son iki PROG: satırını parse et ──
                # Format: PROG:pkgId|recvBytes|totalBytes|pct|tickMs
                # Hız ve ETA UI'da hesaplanır (ardışık iki satırın farkından).
                $progDetail = ''
                if ($script:_wBatchActiveId) {
                    $rxPattern = '^PROG:' + [regex]::Escape($script:_wBatchActiveId) + '\|'
                    $progLines = @($content | Where-Object { $_ -match $rxPattern })
                    $rxStage  = '^STAGE:' + [regex]::Escape($script:_wBatchActiveId) + '\|'
                    $lastStage = $content | Where-Object { $_ -match $rxStage } | Select-Object -Last 1

                    if ($progLines.Count -gt 0) {
                        $lastProg = $progLines[-1]
                        $parts = ($lastProg -replace '^PROG:[^|]+\|','') -split '\|'
                        if ($parts.Count -ge 4) {
                            $recvB  = [long]$parts[0]
                            $totalB = [long]$parts[1]
                            $pct    = [int]$parts[2]

                            # Hız: bu paketin ilk PROG satırı veya son ~2sn'lik bir referansı bul
                            $speedBps = 0
                            $etaSec = -1
                            if ($parts.Count -ge 5 -and $progLines.Count -ge 2) {
                                # Geriye doğru tarayıp ~1.5–3 saniye önceki satırı bul
                                $tickNow = [long]$parts[4]
                                $refIdx = -1
                                for ($i = $progLines.Count - 2; $i -ge 0; $i--) {
                                    $rp = ($progLines[$i] -replace '^PROG:[^|]+\|','') -split '\|'
                                    if ($rp.Count -lt 5) { continue }
                                    $rTick = [long]$rp[4]
                                    $diff = $tickNow - $rTick
                                    if ($diff -ge 1500) { $refIdx = $i; break }
                                    if ($diff -ge 800 -and $refIdx -lt 0) { $refIdx = $i }
                                }
                                if ($refIdx -ge 0) {
                                    $rp = ($progLines[$refIdx] -replace '^PROG:[^|]+\|','') -split '\|'
                                    $rRecv = [long]$rp[0]
                                    $rTick = [long]$rp[4]
                                    $tDelta = ($tickNow - $rTick) / 1000.0
                                    $bDelta = $recvB - $rRecv
                                    if ($tDelta -gt 0 -and $bDelta -gt 0) {
                                        $speedBps = [long]($bDelta / $tDelta)
                                        if ($speedBps -gt 0 -and $totalB -gt $recvB) {
                                            $etaSec = [int](($totalB - $recvB) / $speedBps)
                                        }
                                    }
                                }
                            }

                            # Birim seçimi
                            $unit = if ($totalB -ge 1GB) { 'GB' } else { 'MB' }
                            $div  = if ($unit -eq 'GB') { 1GB } else { 1MB }
                            $recvN  = [math]::Round($recvB  / $div, 1)
                            $totalN = [math]::Round($totalB / $div, 1)
                            $spdMBps = [math]::Round($speedBps / 1MB, 1)
                            $etaTxt = if ($etaSec -lt 0) {
                                '—'
                            } elseif ($etaSec -ge 60) {
                                "{0}d {1}sn" -f ([int]($etaSec / 60)), ($etaSec % 60)
                            } else {
                                "{0}sn" -f $etaSec
                            }
                            $spdTxt = if ($speedBps -gt 0) {
                                "{0} MB/sn" -f $spdMBps
                            } else { '— MB/sn' }

                            $progDetail = "{0:N1}/{1:N1} {2} · {3}% · {4} · ETA {5}" -f `
                                $recvN, $totalN, $unit, $pct, $spdTxt, $etaTxt

                            # Aktif satırın StatusText alanına kompakt yüzde göster
                            $cur = $script:WingetPackages | Where-Object { $_.Id -eq $script:_wBatchActiveId } | Select-Object -First 1
                            if ($cur) { $cur.StatusText = "{0}%" -f $pct }
                        }
                    }
                    elseif ($lastStage -and ($lastStage -match 'installing')) {
                        $cur = $script:WingetPackages | Where-Object { $_.Id -eq $script:_wBatchActiveId } | Select-Object -First 1
                        if ($cur) { $cur.StatusText = '⚙' }
                        $progDetail = (T 'WingetInstalling')
                    }
                }

                $done = ($content | Where-Object { $_ -match '^[^\t]+\t(True|False)' }).Count
                if ($progWinget) { $progWinget.Value = $done }
                if ($lblWingetStatus) {
                    $base = [string]::Format((T 'WingetUpdating'), $done, $script:_wBatchTotal)
                    if ($progDetail) {
                        # Aktif paket adını da bul
                        $actName = $script:_wBatchActiveId
                        if ($script:_wBatchActiveId) {
                            $actPkg = $script:WingetPackages | Where-Object { $_.Id -eq $script:_wBatchActiveId } | Select-Object -First 1
                            if ($actPkg -and $actPkg.Name) { $actName = $actPkg.Name }
                        }
                        $lblWingetStatus.Text = "{0} — {1}: {2}" -f $base, $actName, $progDetail
                    } else {
                        $lblWingetStatus.Text = $base
                    }
                }
            } catch { }
        }

        if ($script:_wBatchJob.State -eq 'Running') { return }
        $script:_wBatchTimer.Stop()
        $script:_wBatchSpinTimer.Stop()
        try { Remove-Job $script:_wBatchJob -Force -ErrorAction SilentlyContinue } catch { }

        foreach ($pkg in $script:WingetPackages) { $pkg.IsUpdating = $false; $pkg.StatusText = '' }

        # İptal bayrağını temizle (her iki taraf da)
        $script:cancelWinget = $false
        try { if ($script:_wBatchTmpCancel -and (Test-Path $script:_wBatchTmpCancel)) { Remove-Item $script:_wBatchTmpCancel -Force -ErrorAction SilentlyContinue } } catch { }

        # İptal butonunu gizle
        Hide-Cancel -OpKey 'winget'
        if ($btnWingetRefresh)    { $btnWingetRefresh.IsEnabled    = $true }
        if ($btnWingetUpgrade)    { $btnWingetUpgrade.IsEnabled    = $true }

        $ok = 0; $fail = 0; $wasCancelled = $false
        if (Test-Path $script:_wBatchTmpOut) {
            try {
                $resultLines = Get-Content $script:_wBatchTmpOut -Encoding UTF8 -ErrorAction SilentlyContinue
                # İptal satırı var mı kontrol et
                $wasCancelled = ($resultLines | Where-Object { $_ -eq 'CANCELLED' }).Count -gt 0
                foreach ($rl in $resultLines) {
                    if (-not $rl.Trim() -or $rl -match '^(ACTIVE|PROG|STAGE|CANCELLED):' -or $rl -eq 'CANCELLED') { continue }
                    $rp = $rl -split "`t"
                    if ($rp.Count -ge 2 -and $rp[1] -eq 'True') {
                        $ok++
                        $updPkg = $script:WingetPackages | Where-Object { $_.Id -eq $rp[0] } | Select-Object -First 1
                        if ($updPkg) {
                            $updPkg.HasUpdate    = $false
                            $updPkg.RowStatus    = (T 'WingetBadgeDone')
                            $updPkg.RowStatusBg  = '#0D2818'
                            $updPkg.RowStatusFg  = '#86EFAC'
                        }
                    } else {
                        $fail++
                        # Hata kodunu coz ve pakette goster
                        $errCode = if ($rp.Count -ge 3) { try { [int]$rp[2] } catch { 0 } } else { 0 }
                        $errMsg  = Resolve-WingetError -Code $errCode
                        $failPkg = $script:WingetPackages | Where-Object { $_.Id -eq $rp[0] } | Select-Object -First 1
                        if ($failPkg) {
                            if ($errCode -eq -1978335215) {
                                # Hash mismatch: ozel mesaj + InstallerHashOverride oneri
                                $failPkg.RowStatus   = '✗ Hash mismatch (run as non-admin + --ignore-security-hash)'
                                $failPkg.RowStatusBg = '#2D1A00'
                                $failPkg.RowStatusFg = '#FCD34D'
                                # Hash mismatch listesine ekle (retry icin)
                                if (-not $script:_wHashMismatchPkgs) { $script:_wHashMismatchPkgs = @() }
                                $script:_wHashMismatchPkgs += $failPkg
                            } else {
                                $failPkg.RowStatus   = if ($errMsg) { "✗ $errMsg" } else { '✗ Failed' }
                                $failPkg.RowStatusBg = '#2D0A0A'
                                $failPkg.RowStatusFg = '#FCA5A5'
                            }
                        }
                    }
                }
            } catch { }
            try { Remove-Item $script:_wBatchTmpOut -Force -ErrorAction SilentlyContinue } catch { }
        }

        if ($progWinget) { $progWinget.Visibility = 'Collapsed' }
        if ($lblWingetStatus) {
            if ($wasCancelled) {
                $cancelledMsg = if ($script:Lang -eq 'TR') {
                    if ($ok -gt 0) { "İptal edildi. $ok paket güncellendi." } else { 'Güncelleme iptal edildi.' }
                } else {
                    if ($ok -gt 0) { "Cancelled. $ok package(s) updated." } else { 'Update cancelled.' }
                }
                $lblWingetStatus.Text = $cancelledMsg
            } elseif ($fail -gt 0) {
                $hashFails = if ($script:_wHashMismatchPkgs) { $script:_wHashMismatchPkgs.Count } else { 0 }
                if ($hashFails -gt 0 -and $hashFails -eq $fail) {
                    $lblWingetStatus.Text = "Hash mismatch: non-admin bypass denendi ama başarısız. Winget'i güncelleyin (Ayarlar → Winget Güncelle)."
                } else {
                    $lblWingetStatus.Text = [string]::Format((T 'WingetDoneFail'), $ok, $fail)
                }
            } else {
                $lblWingetStatus.Text = [string]::Format((T 'WingetDone'), $ok)
            }
        }
        $script:_wHashMismatchPkgs = @()
        # Tam yenileme yerine sadece guncellenen paketlerin durumunu guncelle
        # Bu sayede liste kaybolmuyor
        Update-WingetSelectionButtons
        if ($lvWinget) { $lvWinget.Items.Refresh() }
    })
    $script:_wBatchTimer.Start()
}

if ($btnWingetRefresh) {
    $btnWingetRefresh.Add_Click({ Refresh-WingetList })
}

if ($txtWingetQuery) {
    $txtWingetQuery.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
            if (-not $script:WingetAllPackages -or $script:WingetAllPackages.Count -eq 0) {
                if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetRunning') }
                Refresh-WingetList
            } else {
                Apply-WingetFilters
            }
            $e.Handled = $true
        }
    })
}

if ($cmbWingetSource) {
    $cmbWingetSource.Add_SelectionChanged({
        # İlk doldurma sırasında tetiklenmeyi önle
        if ($script:WingetExe -and $script:WingetAllPackages -and $script:WingetAllPackages.Count -gt 0) {
            Refresh-WingetList
        }
    })
}

if ($chkWingetShowUpdates) {
    $chkWingetShowUpdates.Add_Checked({ Apply-WingetFilters })
    $chkWingetShowUpdates.Add_Unchecked({ Apply-WingetFilters })
}


if ($chkWingetAllUsers) {
    $chkWingetAllUsers.Add_Checked({ if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetAllUsers') } })
    $chkWingetAllUsers.Add_Unchecked({ if ($lblWingetStatus) { $lblWingetStatus.Text = '' } })
}

# btnWingetSelectAll / btnWingetDeselectAll kaldırıldı — header checkbox toggle ediyor

if ($lvWinget) {
    $lvWinget.Add_CellEditEnding({ 
        # Checkbox değişikliği sonrası UI güncelle
        [System.Windows.Application]::Current.Dispatcher.Invoke([System.Action]{
            Update-WingetSelectionButtons
        })
    })
    $lvWinget.Add_CurrentCellChanged({ Update-WingetSelectionButtons })
    $lvWinget.Add_SelectionChanged({ Update-WingetSelectionButtons })
    # PropertyChanged event'ini dinle
    $script:WingetPackages.Add_CollectionChanged({
        param($sender, $e)
        Update-WingetSelectionButtons
    })

    # Header checkbox: tümünü seç / kaldır
    $lvWinget.Add_Loaded({
        try {
            # Kolon 0 header'ındaki CheckBox'ı bul
            $col0Header = $lvWinget.Columns[0].GetCellContent($lvWinget)
            # VisualTreeHelper ile header presenter'ı bul
            $headerPresenter = $null
            $queue = New-Object System.Collections.Generic.Queue[System.Windows.DependencyObject]
            $queue.Enqueue($lvWinget)
            while ($queue.Count -gt 0) {
                $node = $queue.Dequeue()
                if ($node -is [System.Windows.Controls.CheckBox]) {
                    $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
                    # DataGridColumnHeader icindeyse header checkbox'i
                    $p = $parent
                    while ($p -ne $null) {
                        if ($p -is [System.Windows.Controls.Primitives.DataGridColumnHeader]) {
                            $script:_wgHeaderChk = $node
                            $node.Add_Click({
                                $isChecked = $script:_wgHeaderChk.IsChecked -eq $true
                                foreach ($pkg in $script:WingetPackages) { $pkg.IsSelected = $isChecked }
                                if ($lvWinget) { $lvWinget.Items.Refresh() }
                                Update-WingetSelectionButtons
                            })
                            break
                        }
                        $p = [System.Windows.Media.VisualTreeHelper]::GetParent($p)
                    }
                    if ($script:_wgHeaderChk) { break }
                }
                $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                for ($ci = 0; $ci -lt $childCount; $ci++) {
                    $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $ci))
                }
            }
        } catch { }
    })
}


if ($btnWingetUpgrade) {
    $btnWingetUpgrade.Add_Click({
        # Seçim varsa: sadece seçili+güncellemesi olanları yükselt.
        # Seçim yoksa: tüm bekleyen güncellemeleri yükselt.
        $anySelected = @($script:WingetPackages | Where-Object { $_.IsSelected }).Count -gt 0
        if ($anySelected) {
            $targets = @($script:WingetPackages | Where-Object { $_.IsSelected -and $_.HasUpdate })
        } else {
            $targets = @($script:WingetAllPackages | Where-Object { $_.HasUpdate })
        }
        if ($targets.Count -eq 0) {
            if ($lblWingetStatus) { $lblWingetStatus.Text = (T 'WingetNoPackages') }
            return
        }
        Invoke-WingetBatchOperation -Operation 'upgrade' -Packages $targets
    })
}

# ── Winget Context Menu ──────────────────────────────────────────────────────
# Sag tik menusunu acmadan once secili satiri belirle
if ($lvWinget) {
    $lvWinget.ContextMenu.Add_Opened({
        $item = $lvWinget.SelectedItem
        if (-not $item) { $lvWinget.ContextMenu.IsOpen = $false; return }
        # Hide Update: sadece guncelleme olan paketlerde goster
        if ($ctxWingetHide) { $ctxWingetHide.Visibility = if ($item.HasUpdate) { 'Visible' } else { 'Collapsed' } }
    })
}

# Copy ID
if ($ctxWingetCopyId) {
    $ctxWingetCopyId.Add_Click({
        $item = $lvWinget.SelectedItem
        if ($item) { [System.Windows.Clipboard]::SetText($item.Id) }
    })
}

# Copy Name
if ($ctxWingetCopyName) {
    $ctxWingetCopyName.Add_Click({
        $item = $lvWinget.SelectedItem
        if ($item) { [System.Windows.Clipboard]::SetText($item.Name) }
    })
}

# Hide Update — guncellemeyi kalici olarak gizle
if ($ctxWingetHide) {
    $ctxWingetHide.Add_Click({
        $item = $lvWinget.SelectedItem
        if (-not $item) { return }
        # Ignored listesine ekle
        if (-not $script:AppSettings.WingetIgnoredUpdates) { $script:AppSettings.WingetIgnoredUpdates = @() }
        if ($script:AppSettings.WingetIgnoredUpdates -notcontains $item.Id) {
            $script:AppSettings.WingetIgnoredUpdates = @($script:AppSettings.WingetIgnoredUpdates) + $item.Id
        }
        Save-AppSettings
        # Listeden aninda kaldir
        $script:WingetAllPackages = @($script:WingetAllPackages | Where-Object { $_.Id -ne $item.Id })
        Apply-WingetFilters
        if ($lblWingetStatus) {
            $lblWingetStatus.Text = "'$($item.Name)' $(T 'WingetHideUpdate')"
        }
    })
}
# btnWingetUpgradeAll kaldırıldı — btnWingetUpgrade artık her iki işlevi de yapıyor.

$null = $window.ShowDialog()
