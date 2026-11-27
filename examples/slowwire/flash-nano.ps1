# STK500v1, ATmega328P only. Never writes bootloader, EEPROM, fuses or lock bits.
param([string]$Port='COM9',[string]$Image="$PSScriptRoot/../../.build/nano.bin",[string]$Backup='C:/Just-Things/Projects/sb0/.work/nano-bringup/original-flash.bin')
$ErrorActionPreference='Stop'
$imageBytes=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Image).Path)
$originalBytes=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Backup).Path)
if ($imageBytes.Length -eq 0 -or $imageBytes.Length -gt 30720 -or $originalBytes.Length -ne 32768) { throw 'Invalid image or backup size' }
$serialLink=[IO.Ports.SerialPort]::new($Port,57600,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serialLink.ReadTimeout=2000; $serialLink.WriteTimeout=2000
$serialLink.DtrEnable=$false; $serialLink.RtsEnable=$false
function Exchange([byte[]]$command,[int]$length) {
    $serialLink.Write($command,0,$command.Length)
    $answer=[byte[]]::new($length)
    for($i=0;$i -lt $length;$i++){ $answer[$i]=[byte]$serialLink.ReadByte() }
    if($answer[0] -ne 0x14 -or $answer[$length-1] -ne 0x10){ throw 'Bootloader rejected operation' }
    return ,$answer
}
function Address([int]$offset){ $wordAddress=$offset/2; $null=Exchange ([byte[]]@(0x55,($wordAddress -band 255),(($wordAddress -shr 8) -band 255),0x20)) 2 }
try {
    $serialLink.Open(); Start-Sleep -Milliseconds 150
    $serialLink.DtrEnable=$true; $serialLink.RtsEnable=$true
    Start-Sleep -Milliseconds 70; $serialLink.DiscardInBuffer()
    $null=Exchange ([byte[]]@(0x30,0x20)) 2
    $signature=Exchange ([byte[]]@(0x75,0x20)) 5
    if([BitConverter]::ToString($signature[1..3]) -ne '1E-95-0F'){ throw 'Wrong MCU; refusing flash' }
    $null=Exchange ([byte[]]@(0x50,0x20)) 2
    $pageEnd=[int]([Math]::Ceiling($imageBytes.Length/128)*128)
    for($offset=0;$offset -lt $pageEnd;$offset+=128){
        Address $offset
        $packet=[byte[]]::new(133); $packet[0]=0x64; $packet[1]=0; $packet[2]=128; $packet[3]=0x46; $packet[132]=0x20
        for($i=0;$i -lt 128;$i++){ $packet[4+$i]=if($offset+$i -lt $imageBytes.Length){$imageBytes[$offset+$i]}else{255} }
        $null=Exchange $packet 2
    }
    $verified=[byte[]]::new(32768)
    for($offset=0;$offset -lt 32768;$offset+=128){
        Address $offset
        $page=Exchange ([byte[]]@(0x74,0,128,0x46,0x20)) 130
        [Array]::Copy($page,1,$verified,$offset,128)
    }
    for($i=0;$i -lt 32768;$i++){
        $expected=if($i -lt $imageBytes.Length){$imageBytes[$i]}elseif($i -lt $pageEnd){255}else{$originalBytes[$i]}
        if($verified[$i] -ne $expected){throw "Read-back mismatch at byte $i"}
    }
    $null=Exchange ([byte[]]@(0x51,0x20)) 2
    [ordered]@{port=$Port;signature='1E950F';image_bytes=$imageBytes.Length;read_back='PASS - full 32768 bytes';untouched_flash='PASS - all bytes beyond programmed pages';bootloader='preserved';image_sha256=(Get-FileHash -LiteralPath $Image).Hash;backup_sha256=(Get-FileHash -LiteralPath $Backup).Hash;created_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content "$PSScriptRoot/../../.build/nano-flash.json" -Encoding utf8
    Write-Output 'Nano flashed; full flash read-back passed; bootloader preserved.'
} finally {if($serialLink.IsOpen){$serialLink.Close()};$serialLink.Dispose()}
