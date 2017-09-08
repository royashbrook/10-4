#setup file paths
$scriptPath = split-path -parent $MyInvocation.MyCommand.Path
$log = join-path $scriptPath ("{0}_log.txt" -f (Get-Date -F "yyyyMMdd"))
$cfg = join-path $scriptPath "config.xml"
$csh = join-path $scriptPath "cache.xml"

"Event Start: {0}" -f (Get-Date) >> $log

# load config info
$xml = New-Object Xml
$xml.PreserveWhitespace = $true
$xml.Load($cfg)
$cs =  $xml.SelectNodes('/settings/connectionstring').innerText
$sql = $xml.SelectNodes('/settings/sql').innerText
$sb  = $xml.SelectNodes('/settings/scriptblock').innerText
$mt  = $xml.SelectNodes('/settings/maxthreads').innerText
$ld  = $xml.SelectNodes('/settings/logdays').innerText
$xml = $null

# get our data
try{
    #use a cache file, age 10 minutes
    if (-not ($csh | Test-Path) -or ((New-TimeSpan (Get-ItemProperty $csh).LastWriteTime (get-date)).TotalMinutes -gt 10)){
        "refreshing cache" >> $log
        $dt = new-object System.Data.DataTable
        $da = new-object System.Data.SqlClient.SqlDataAdapter $sql,$cs 
        $da.Fill($dt) > $null
        $da.Dispose()
        $dt | Export-Clixml $csh
    }else{
        "using cache" >> $log
    }
    $dt = Import-Clixml $csh
    "Records Found: {0}" -f $dt.rows.count >> $log
}catch{
    "Exception: {0}" -f $_.Exception.Message
}

# if we have some data
if ($dt.Count -gt 0){

    # multithreading setup
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $mt)
    $pool.ApartmentState = "MTA"
    $pool.Open()
    $runspaces = @()
 
    # for each row in our data, run our scriptblock
    #      from config and add process to hashtable
    foreach ($row in $dt) {
        $runspace = [PowerShell]::Create()
        $runspace.AddScript( [Scriptblock]::Create($sb) ) > $null
        $runspace.AddArgument($row) > $null
        $runspace.RunspacePool = $pool
        $runspaces += @{ Pipe = $runspace; Status = $runspace.BeginInvoke();}
    }

    # wait for the tasks to finish
    while ($runspaces.Status.IsCompleted -contains $false) {
        Start-Sleep -Milliseconds 100 > $null
    }

    # get the results and cleanup
    foreach ($runspace in $runspaces ) {
        $runspace.Pipe.EndInvoke($runspace.Status) | Format-List * >> $log
        $runspace.Pipe.Dispose()
    }
    $pool.Close() ; $pool.Dispose()

}else{
    "No records found to send." >> $log
}

"Event End: {0}" -f (Get-Date) >> $log

# cleanup old logs
Get-ChildItem  $scriptPath\*_log.txt |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-[int]($ld)) } |
    Remove-Item