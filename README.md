### Overview 
Simple PowerShell script to find the location of a WiFi access point from its BSSID using Apple's Location Services. It can also open a Google Maps link to the found coordinates using your default browser.

### Instructions/Usage
To find the location of a bssid run the following: `.\Get-AppleLocation.ps1 -BSSID "68:51:34:8C:1D:50"`

To find the location and display it on a map run the following: `.\Get-AppleLocation.ps1 -BSSID "68:51:34:8C:1D:50" -Map`

To display other nearby BSSIDs with their coordinates, run the following: `.\Get-AppleLocation.ps1 -BSSID "68:51:34:8C:1D:50" -All`

