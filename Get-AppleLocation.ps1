<#
.SYNOPSIS
    Finds the location of a WiFi access point from its BSSID using Apple's Location Services.
#>

param (
    [Parameter(Mandatory=$true, Position=0)]
    [string]$BSSID,

    [switch]$Map,

    [switch]$All
)

# Force TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Functions

function Get-VarintBytes {
    param ([long]$Value)
    $bytes = @()
    do {
        $byte = $Value -band 0x7F
        $Value = $Value -shr 7
        if ($Value -ne 0) {
            $byte = $byte -bor 0x80
        }
        $bytes += [byte]$byte
    } while ($Value -ne 0)
    return $bytes
}

function Read-Varint {
    param (
        [byte[]]$Data,
        [ref]$Index
    )
    [long]$result = 0
    $shift = 0
    
    while ($true) {
        if ($Index.Value -ge $Data.Length) { break }
        $byte = $Data[$Index.Value]
        $Index.Value++
        
        $part = [long]($byte -band 0x7F)
        $result = $result -bor ($part -shl $shift)
        
        if (-not ($byte -band 0x80)) { break }
        $shift += 7
    }
    return $result
}

function Format-MACAddress {
    param ([string]$MAC)
    $clean = $MAC -replace "[:\-\.]", ""
    if ($clean.Length -ne 12) { return $MAC } 
    return -join ($clean.ToCharArray() | ForEach-Object { 
        $i++; $_; if ($i % 2 -eq 0 -and $i -lt 12) { ':' } 
    })
}

# Main

$BSSID = Format-MACAddress $BSSID
Write-Host "Searching for location of BSSID: $BSSID"

# 1. Construct the Protobuf Payload
$bssidBytes = [System.Text.Encoding]::UTF8.GetBytes($BSSID)

# WifiDevice (Field 2) -> BSSID (Field 1)
$wifiDevicePayload = @(0x0A) + (Get-VarintBytes $bssidBytes.Length) + $bssidBytes

# Root -> WifiDevice (Field 2)
$rootPayload = @()
$rootPayload += 0x12
$rootPayload += (Get-VarintBytes $wifiDevicePayload.Length)
$rootPayload += $wifiDevicePayload
$rootPayload += 0x18; $rootPayload += 0x00 # Unknown1
$rootPayload += 0x20; $rootPayload += 0x01 # ReturnSingleResult

# 2. Construct the Header
$header = @(
    0x00, 0x01, 0x00, 0x05, 
    0x65, 0x6E, 0x5F, 0x55, 0x53, # en_US
    0x00, 0x13, 
    0x63, 0x6F, 0x6D, 0x2E, 0x61, 0x70, 0x70, 0x6C, 0x65, 0x2E, 0x6C, 0x6F, 0x63, 0x61, 0x74, 0x69, 0x6F, 0x6E, 0x64,
    0x00, 0x0A, 
    0x38, 0x2E, 0x31, 0x2E, 0x31, 0x32, 0x42, 0x34, 0x31, 0x31, 
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00
)

$header += [byte]$rootPayload.Length
$requestData = $header + $rootPayload

# 3. Send Request
$url = "https://gs-loc.apple.com/clls/wloc"
$userAgent = "locationd/1753.17 CFNetwork/889.9 Darwin/17.2.0"

try {
    $req = [System.Net.WebRequest]::Create($url)
    $req.Method = "POST"
    $req.UserAgent = $userAgent
    $req.ContentType = "application/x-www-form-urlencoded"
    $req.ContentLength = $requestData.Length
    
    $stream = $req.GetRequestStream()
    $stream.Write($requestData, 0, $requestData.Length)
    $stream.Close()

    $resp = $req.GetResponse()
    $respStream = $resp.GetResponseStream()
    $ms = New-Object System.IO.MemoryStream
    $respStream.CopyTo($ms)
    $responseBytes = $ms.ToArray()
    $resp.Close()
    $ms.Close()
}
catch {
    Write-Host "HTTP Error Code: " $_.Exception.Response.StatusCode -ForegroundColor Red
    Write-Host "Description: " $_.Exception.Message -ForegroundColor Red
    exit
}

# 4. Parse Response
if ($responseBytes.Length -le 10) {
    Write-Warning "Response empty or too short."
    exit
}

$protoBytes = $responseBytes[10..($responseBytes.Length - 1)]
$idx = 0
$results = @{}

while ($idx -lt $protoBytes.Length) {
    $tag = Read-Varint $protoBytes ([ref]$idx)
    $fieldNum = $tag -shr 3
    $wireType = $tag -band 7

    if ($fieldNum -eq 2 -and $wireType -eq 2) { 
        # Field 2: WifiDevice (Repeated)
        $len = Read-Varint $protoBytes ([ref]$idx)
        $end = $idx + $len
        
        $currentBSSID = ""
        $lat = $null
        $lon = $null

        while ($idx -lt $end) {
            $subTag = Read-Varint $protoBytes ([ref]$idx)
            $subField = $subTag -shr 3
            $subWire = $subTag -band 7

            if ($subField -eq 1 -and $subWire -eq 2) {
                $strLen = Read-Varint $protoBytes ([ref]$idx)
                $currentBSSID = [System.Text.Encoding]::UTF8.GetString($protoBytes, $idx, $strLen)
                $idx += $strLen
            }
            elseif ($subField -eq 2 -and $subWire -eq 2) {
                $locLen = Read-Varint $protoBytes ([ref]$idx)
                $locEnd = $idx + $locLen
                while ($idx -lt $locEnd) {
                    $locTag = Read-Varint $protoBytes ([ref]$idx)
                    $locField = $locTag -shr 3
                    if ($locField -eq 1) { $lat = Read-Varint $protoBytes ([ref]$idx) }
                    elseif ($locField -eq 2) { $lon = Read-Varint $protoBytes ([ref]$idx) }
                    else { $null = Read-Varint $protoBytes ([ref]$idx) }
                }
            }
            else {
                 if ($subWire -eq 0) { $null = Read-Varint $protoBytes ([ref]$idx) }
                 elseif ($subWire -eq 2) { $l = Read-Varint $protoBytes ([ref]$idx); $idx += $l }
            }
        }

        if ($currentBSSID -and $lat -ne $null -and $lon -ne $null) {
            $formattedMAC = Format-MACAddress $currentBSSID
            $results[$formattedMAC] = @{ Lat = $lat * 1e-8; Lon = $lon * 1e-8 }
        }
    }
    else {
        if ($wireType -eq 0) { $null = Read-Varint $protoBytes ([ref]$idx) }
        elseif ($wireType -eq 2) { $l = Read-Varint $protoBytes ([ref]$idx); $idx += $l }
        elseif ($wireType -eq 5) { $idx += 4 }
        elseif ($wireType -eq 1) { $idx += 8 }
        else { $idx++ }
    }
}

# 5. Output Results
$foundAny = $false
$targetBSSID = $BSSID.ToUpper()

if ($All) { $keys = $results.Keys } else { $keys = @($targetBSSID) }

foreach ($key in $keys) {
    if ($results.ContainsKey($key)) {
        $data = $results[$key]
        if ($data.Lat -eq -180.0 -and $data.Lon -eq -180.0) { continue }

        $foundAny = $true
        Write-Host ""
        Write-Host "BSSID:     $key" -ForegroundColor Green
        Write-Host "Latitude:  $($data.Lat)"
        Write-Host "Longitude: $($data.Lon)"
        Write-Host "Google Maps: https://www.google.com/maps/search/?api=1&query=$($data.Lat),$($data.Lon)"

        if ($Map) {
            Start-Process "https://www.google.com/maps/search/?api=1&query=$($data.Lat),$($data.Lon)"
        }
    }
}

if (-not $foundAny) {
    Write-Host "The BSSID was not found." -ForegroundColor Yellow
}