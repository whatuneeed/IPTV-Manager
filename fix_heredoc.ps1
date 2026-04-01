$lines = Get-Content 'C:\IPTV-Manager\IPTV-Manager.sh'
for ($i = 225; $i -le 428; $i++) {
    $lines[$i] = $lines[$i].Replace('\$', '$').Replace('\\\\', '\\').Replace('%%', '%')
}
Set-Content 'C:\IPTV-Manager\IPTV-Manager.sh' $lines -NoNewline
