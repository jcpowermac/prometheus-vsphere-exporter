#!/bin/pwsh

$global:DebugPreference = $Env:DEBUG_PREFERENCE
$global:VerbosePreference = $Env:DEBUG_PREFERENCE

$DebugPreference = $Env:DEBUG_PREFERENCE
$VerbosePreference = $Env:DEBUG_PREFERENCE

Write-Information -MessageData "Starting prometheus vsphere exporter" -InformationAction Continue

Set-PowerCLIConfiguration -InvalidCertificateAction:Ignore -Confirm:$false > $null

Write-Information -MessageData "Connecting to $($Env:VCENTER_URI)" -InformationAction Continue
$server = Connect-VIServer -Server $Env:VCENTER_URI -Credential (Import-Clixml $Env:VCENTER_SECRET_PATH)

$queue = New-Object System.Collections.Queue
$syncQueue = [System.Collections.Queue]::Synchronized($queue)

Write-Information -MessageData "Getting available statistics types" -InformationAction Continue
$clusterHosts = Get-VMHost -Location (Get-Cluster $Env:VCENTER_CLUSTER)

# Intersection of stats, because of course we need this...
# If the cluster hosts are different hardware or ESXi versions
# they could have different StatTypes.

$intsectRealtimeStatTypes = @()
foreach ($h in $clusterHosts) {
	if ($intsectRealtimeStatTypes.Count -eq 0) {
		$intsectRealtimeStatTypes = ($h | Get-StatType -Realtime)
	}
	else {
		$tempStatTypes = ($h | Get-StatType -Realtime)
		$intsectRealtimeStatTypes = ($intsectRealtimeStatTypes | Where-Object { $tempStatTypes -contains $_ })
	}
}

$realtimeStats = @()

foreach ($r in $intsectRealtimeStatTypes) {
	if (!$r.StartsWith("sys")) {
		$realtimeStats += $r
	}
}

$intsectRealtimeStatTypes = ""

Write-Information -MessageData "Starting statistics thread" -InformationAction Continue

$statThread = Start-ThreadJob -Name statistics -ThrottleLimit 10 -ScriptBlock {
    $DebugPreference = $Env:DEBUG_PREFERENCE
    $VerbosePreference = $Env:DEBUG_PREFERENCE
	:forever while ($true) {

		$startTime = Get-Date
		Write-Verbose "Start Time: $($startTime)"

		$tempRealtimeStatTypes = $using:realtimeStats
		$tempServer = $using:server
		$tempClusterHosts = $using:clusterHosts
		$stats = (Get-VMHost -Server $tempServer -Name $tempClusterHosts | Get-Stat -Server $tempServer -IntervalSecs 20 -MaxSamples 1 -Stat $tempRealtimeStatTypes)

		Write-Verbose "Statistic count: $($stats.Count)"

		$outputArray = @()
		$entityType = @{}

		foreach ($s in $stats) {
			if (!$entityType.ContainsKey($s.EntityId)) {
				$entityType[$s.EntityId] = (Get-View -Server $tempServer -Id $s.EntityId).GetType().Name
			}

			$timestamp = [int64](New-TimeSpan -Start (Get-Date "01/01/1970") -End ($s.Timestamp)).TotalMilliseconds
			$metric = $s.MetricId.Replace(".", "_")

            $metric = "vsphere_host_$($metric)"

            $outputArray += [string]::Format('# HELP {0} {1}', $metric, $s.Description)
            $outputArray += [string]::Format('# TYPE {0} gauge', $metric)
			$outputArray += [string]::Format('{0}{{stat_instance="{1}",motype="{2}",name="{3}",moid="{4}"}} {5} {6}',
				$metric,
				$s.Instance,
				$entityType[$s.EntityId],
				$s.Entity,
				$s.EntityId,
				$s.Value,
				$timestamp)
        }

        Write-Verbose "Statistic: Before Enqueue"
		$tempQueue = $using:syncQueue
		$tempQueue.Enqueue($outputArray)
        Write-Verbose "Statistic: After Enqueue"

		# empty array
		$outputArray = @()

		$endTime = Get-Date
		Write-Verbose "Statistic: End Time: $($endTime)"

		$processSeconds = [int64](New-TimeSpan -Start $startTime -End $endTime).TotalSeconds
		$sleepSeconds = $Env:SCRAPE_DELAY - $processSeconds
		Write-Verbose "Statistic: Calculated Sleep: $($sleepSeconds)"

        if ($sleepSeconds -gt 0) {
		    Start-Sleep -Seconds $sleepSeconds
        }
	}
}

Write-Information -MessageData "Starting HTTPd thread" -InformationAction Continue

# Below section is from the following gist:
# https://gist.github.com/rminderhoud/c603a0a30587ae5c957b211ba386bf37

$webThread = Start-ThreadJob -Name web -ScriptBlock {
    $DebugPreference = $Env:DEBUG_PREFERENCE
	$http = [System.Net.HttpListener]::new()
	$http.Prefixes.Add("http://*:8080/")

    Write-Information -MessageData "HTTPd: Starting" -InformationAction Continue
	$http.Start()

	if ($http.IsListening) {
        Write-Information -MessageData "HTTPd: Ready" -InformationAction Continue
	}

	try {
		while ($http.IsListening) {
            Write-Debug "HTTPd: Before GetContextAsync()"
			$contextTask = $http.GetContextAsync()
            Write-Debug "HTTPd: Before GetAwaiter()"
            $startTime = Get-Date
            Write-Debug "HTTPd: Waiter Start: $($startTime)"
			$context = $contextTask.GetAwaiter().GetResult()
			if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.RawUrl -eq '/metrics') {
				Write-Debug "$($context.Request.UserHostAddress) => $($context.Request.Url)"
			    $tempQueue = $using:syncQueue

				if ($tempQueue.Count -gt 0) {
					$metrics = $tempQueue.Dequeue()
					# Add newlines per string
					$OFS = "`n"
					$buffer = [System.Text.Encoding]::UTF8.GetBytes([string]$metrics) # convert htmtl to bytes
                    $metrics = @()
					$context.Response.ContentLength64 = $buffer.Length
					$context.Response.OutputStream.Write($buffer, 0, $buffer.Length) #stream to broswer
					$context.Response.OutputStream.Close() # close the response
				}
				else {
					$buffer = [System.Text.Encoding]::UTF8.GetBytes([string]"") # convert htmtl to bytes
					$context.Response.ContentLength64 = $buffer.Length
					$context.Response.OutputStream.Write($buffer, 0, $buffer.Length) #stream to broswer
					$context.Response.OutputStream.Close() # close the response
					Write-Host "HTTPd: No metrics in queue."
				}
                $endTime = Get-Date
                Write-Debug "HTTPd: Waiter End: $($endTime)"
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

	Write-Information -InformationAction Continue -MessageData "Statistic: Thread Results"
    $statOutput = Receive-Job -Job $statThread
    $statOutput

	Write-Information -InformationAction Continue -MessageData "HTTPd: Thread Results"
	$webOutput = Receive-Job -Job $webThread
    $webOutput
}
