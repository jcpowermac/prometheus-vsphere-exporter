#!/bin/pwsh
Write-Information -MessageData "Starting prometheus vsphere exporter" -InformationAction Continue

Set-PowerCLIConfiguration -InvalidCertificateAction:Ignore -Confirm:$false > $null

Write-Information -MessageData "Connecting to $($Env:VCENTER_URI)" -InformationAction Continue
$server = Connect-VIServer -Server $Env:VCENTER_URI -Credential (Import-Clixml $Env:VCENTER_SECRET_PATH)

$queue = New-Object System.Collections.Queue
$syncQueue = [System.Collections.Queue]::Synchronized($queue)

Write-Information -MessageData "Getting available statistics types" -InformationAction Continue
$clusterHosts = Get-VMHost -Location (Get-Cluster $Env:VCENTER_CLUSTER)
$onehost = Get-Random -InputObject $clusterHosts

$tempRealtimeStats = $onehost | Get-StatType -Realtime

$realtimeStats = @()
foreach ($t in $tempRealtimeStats) {
	if (!$t.StartsWith("sys")) {
		$realtimeStats += $t
	}
}

$tempRealtimeStats = ""

Write-Information -MessageData "Starting statistics thread" -InformationAction Continue

$statThread = Start-ThreadJob -Name statistics -ScriptBlock {
	:forever while ($true) {

		$startTime = Get-Date

		$tempRealtimeStatTypes = $using:realtimeStats
		$tempServer = $using:server
		$tempClusterHosts = $using:clusterHosts

		$stats = (Get-VMHost $tempClusterHosts | Get-Stat -IntervalSecs 20 -MaxSamples 1 -Stat $tempRealtimeStatTypes)

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

		# empty array
		$outputArray = @()

		$endTime = Get-Date
		$processSeconds = [int64](New-TimeSpan -Start $startTime -End $endTime).TotalSeconds
		$sleepSeconds = $Env:SCRAPE_DELAY - $processSeconds
		Write-Information -MessageData "Sleep: $($sleepSeconds)" -InformationAction Continue
		Start-Sleep -Seconds $sleepSeconds
	}
}

Write-Information -MessageData "Starting HTTPd thread" -InformationAction Continue

# Below section is from the following gist:
# https://gist.github.com/rminderhoud/c603a0a30587ae5c957b211ba386bf37
$webThread = Start-ThreadJob -Name web -ScriptBlock {
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

					# Add newlines per string
					$OFS = "`n"
					$buffer = [System.Text.Encoding]::UTF8.GetBytes([string]$metrics) # convert htmtl to bytes
					$context.Response.ContentLength64 = $buffer.Length
					$context.Response.OutputStream.Write($buffer, 0, $buffer.Length) #stream to broswer
					$context.Response.OutputStream.Close() # close the response
				}
				else {
					$buffer = [System.Text.Encoding]::UTF8.GetBytes([string]"") # convert htmtl to bytes
					$context.Response.ContentLength64 = $buffer.Length
					$context.Response.OutputStream.Write($buffer, 0, $buffer.Length) #stream to broswer
					$context.Response.OutputStream.Close() # close the response
					Write-Error -Message "No metrics in queue."
				}

			}
		}

	}
	finally {
		$http.Stop()
	}
}

while ($true) {
	Start-Sleep -Seconds $Env:THREAD_STATUS_DELAY
	Get-Job
	$statThread | Receive-Job
	$webThread | Receive-Job
}
