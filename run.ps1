#!/bin/pwsh

$Env:VCENTER_URI = "vcs8e-vc.ocp2.dev.cluster.com"
$Env:VCENTER_SECRET_PATH = "/home/jcallen/mdc/ci-ibm-creds.xml"

Set-PowerCLIConfiguration -InvalidCertificateAction:Ignore -Confirm:$false > $null 
$server = Connect-VIServer -Server $Env:VCENTER_URI -Credential (Import-Clixml $Env:VCENTER_SECRET_PATH) 

$cluster = "vcs-ci-workload"

# Setup...

$queue = New-Object System.Collections.Queue
$syncQueue = [System.Collections.Queue]::Synchronized($queue)

$clusterHosts = Get-VMHost -Location (Get-Cluster $cluster)
$onehost = Get-Random -InputObject $clusterHosts 

$tempRealtimeStats = $onehost | Get-StatType -Realtime

$realtimeStats = @()
foreach ($t in $tempRealtimeStats) {
	if (!$t.StartsWith("sys")) {
		$realtimeStats += $t
	}
}

$statThread = Start-ThreadJob -ScriptBlock {
	#$count = 0

	:forever while ($true) {
		#$stats = (get-vmhost dt $clusterHosts | get-stat -IntervalSecs 20 -MaxSamples 1 -Stat $realtimeStats) 

		$tempRealtimeStats = $using:realtimeStats
		$tempServer = $using:server

		$stats = (Get-VMHost -Server $tempServer -Name host-ci000.ibmvcenter.vmc-ci.devcluster.openshift.com | Get-Stat -IntervalSecs 20 -MaxSamples 1 -Stat $tempRealtimeStats -Server $tempServer) 

		$outputArray = @()
		$entityType = @{}
		foreach ($s in $stats) {
			if (!$entityType.ContainsKey($s.EntityId)) {
				$entityType[$s.EntityId] = (Get-View -Server $tempServer -Id $s.EntityId).GetType().Name
			}

			$timestamp = [int64](New-TimeSpan -Start (Get-Date "01/01/1970") -End ($s.Timestamp)).TotalMilliseconds
			$metric = $s.MetricId.Replace(".", "_")

			$outputArray += [string]::Format('{0}{{instance="{1}",mobtype="{2}",name="{3}",mobid="{4}"}} {5} {6}', 
				$metric, 
				$s.Instance, 
				$entityType[$s.EntityId], 
				$s.Entity, 
				$s.EntityId, 
				$s.Value, 
				$timestamp)



		}

		$tempQueue = $using:syncQueue
		$tempQueue.Enqueue($outputArray)

		# TODO: This should be how long did the above take a sleep the difference between the next scrape
		Start-Sleep -Seconds 10
	#	if ($count -eq 5) {
	#		break forever
	#	}

	#	$count++
	}
}

# Below section is from the following gist: 
# https://gist.github.com/rminderhoud/c603a0a30587ae5c957b211ba386bf37
$webThread = Start-ThreadJob -ScriptBlock {
	$http = [System.Net.HttpListener]::new() 
	$http.Prefixes.Add("http://*:8080/")
	$http.Start()

	if ($http.IsListening) {
		Write-Host " HTTP Server Ready!  " -f 'black' -b 'gre'
	}

	try {
		while ($http.IsListening) {
			$contextTask = $http.GetContextAsync()
			$context = $contextTask.GetAwaiter().GetResult()
			if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.RawUrl -eq '/metrics') {
				# We can log the request to the terminal
				Write-Host "$($context.Request.UserHostAddress)  =>  $($context.Request.Url)" -f 'mag'

				$tempQueue = $using:syncQueue

				if ($tempQueue.Count -gt 0) {
					$metrics = $tempQueue.Dequeue()
        
					#resposed to the request
					$buffer = [System.Text.Encoding]::UTF8.GetBytes([string]$metrics) # convert htmtl to bytes
					$context.Response.ContentLength64 = $buffer.Length
					$context.Response.OutputStream.Write($buffer, 0, $buffer.Length) #stream to broswer
					$context.Response.OutputStream.Close() # close the response
				}
    
			}	
		}

	}
	finally {
		$http.Stop()
	}
}

$webThread | Wait-Job